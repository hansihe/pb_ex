defmodule PB.Codegen.Decoder do
  @moduledoc """
  Emit per-message protobuf decoders from a `PB.Codegen` context.

  The intermediate output is a flat list of top-level quoted definitions. The
  caller is responsible for wrapping them in a `defmodule` block.

  ## Calling conventions

    * Public roots expose `decode_<name>/1` and `decode_<name>!/1`.
    * Non-bang root decoders return `{:ok, map}` or
      `{:error, error}` (see `PB.Error`)`.
    * Bang root decoders return the decoded value or raise `PB.Error`.
    * Inline messages are emitted as private helpers and use the same
      non-throwing internal result contract.

  ## Example

      ctx =
        schema
        |> PB.Schema.Transform.slice(roots: [:"pkg.Order"])
        |> PB.Codegen.build()

      decls = PB.Codegen.Decoder.emit_all(ctx)

      mod_ast =
        quote do
          defmodule MyApp.OrderCodec do
            (unquote_splicing(decls))
          end
        end

      [{mod, _}] = Code.compile_quoted(mod_ast)
      MyApp.OrderCodec.decode_order(binary)
  """

  @doc """
  Emit all decoder declarations for the given context.

  Returns a list of top-level quoted AST nodes. Splice into a `defmodule` body.
  """
  def emit_all(ctx) do
    targets = build_targets(ctx)

    message_decls = Enum.flat_map(targets, fn {fqn, t} -> emit_message(ctx, fqn, t, targets) end)

    message_decls
  end

  @doc """
  Emit decoder declarations for a single message FQN.
  """
  def emit_function(ctx, fqn) do
    targets = build_targets(ctx)
    target = Map.fetch!(targets, fqn)
    emit_message(ctx, fqn, target, targets)
  end

  # Target discovery

  defp build_targets(ctx) do
    roots = MapSet.new(ctx.roots)

    base =
      Map.new(ctx.names, fn {fqn, name} ->
        vis = if MapSet.member?(roots, fqn), do: :def, else: :defp
        {fqn, %{name: name, visibility: vis}}
      end)

    map_entries =
      base
      |> Map.keys()
      |> Enum.flat_map(&map_entries_referenced(ctx, &1))
      |> Enum.uniq()

    Enum.reduce(map_entries, base, fn fqn, acc ->
      Map.put_new(acc, fqn, %{name: mangle(fqn), visibility: :defp})
    end)
  end

  defp map_entries_referenced(ctx, fqn) do
    case ctx.schema.messages[fqn] do
      nil ->
        []

      msg ->
        Enum.flat_map(msg.fields_by_name, fn {_n, info} ->
          if PB.Schema.Features.map?(info) do
            [info.type_name]
          else
            []
          end
        end)
    end
  end

  defp mangle(fqn) do
    fqn
    |> Atom.to_string()
    |> Macro.underscore()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.to_atom()
  end

  defp public_name(name), do: :"decode_#{name}"
  defp bang_name(name), do: :"decode_#{name}!"
  defp impl_name(name), do: :"__decode_#{name}"
  defp loop_name(name), do: :"__decode_loop_#{name}"
  defp packed_helper_name(msg_name, field_name), do: :"__decode_packed_#{msg_name}_#{field_name}"

  # Per-message emission

  defp emit_message(ctx, fqn, target, targets) do
    msg = ctx.schema.messages[fqn]

    fields =
      msg.fields_by_name
      |> Map.values()
      |> Enum.sort_by(& &1.number)

    public = public_name(target.name)
    bang = bang_name(target.name)
    impl = impl_name(target.name)
    loop = loop_name(target.name)

    {field_clauses, packed_helpers} = build_field_clauses(ctx, msg, fields, loop, target, targets)

    skip_clause =
      quote do
        _ -> unquote(unknown_body(loop))
      end

    dispatch = build_case(quote(do: fnum), field_clauses ++ extract_clauses(skip_clause))

    loop_defs =
      quote do
        defp unquote(loop)(<<>>, acc, _path), do: {:ok, acc}

        defp unquote(loop)(bin, acc, path) do
          with {:ok, tag, rest} <- PB.Wire.decode_tag(bin),
               fnum = Bitwise.>>>(tag, 3),
               wtype = Bitwise.&&&(tag, 0x07),
               :ok <- PB.Wire.validate_field_number(fnum),
               :ok <- PB.Wire.validate_wire_type(wtype) do
            unquote(dispatch)
          else
            {:error, reason} -> PB.Codegen.Runtime.decode_error_at(reason, path)
          end
        end
      end

    post_spec = Macro.escape(build_post_process(ctx, msg))

    impl_def =
      quote do
        defp unquote(impl)(binary, path) when is_binary(binary) do
          with {:ok, acc} <- unquote(loop)(binary, %{}, path),
               {:ok, acc} <-
                 PB.Codegen.Runtime.post_process_decode(acc, unquote(post_spec), path) do
            {:ok, acc}
          end
        end

        defp unquote(impl)(value, path) do
          PB.Codegen.Runtime.decode_error_at(
            {:invalid_value, [], :binary, PB.Runtime.Errors.type_of(value)},
            path
          )
        end
      end

    root_adapter_ast = root_adapter_ast(msg, fqn)

    public_defs =
      if target.visibility == :def do
        quote do
          def unquote(public)(binary) do
            result =
              with {:ok, value} <- unquote(impl)(binary, []),
                   {:ok, value} <- unquote(root_adapter_ast) do
                {:ok, value}
              end

            PB.Codegen.Runtime.normalize_decode_result(result, unquote(fqn))
          end

          def unquote(bang)(binary) do
            case unquote(public)(binary) do
              {:ok, value} -> value
              {:error, %{__exception__: true} = error} -> raise error
            end
          end
        end
      else
        quote(do: nil)
      end

    [public_defs, impl_def, loop_defs] ++ packed_helpers
  end

  defp build_case(subject, clauses) do
    {:case, [], [subject, [do: clauses]]}
  end

  defp extract_clauses(quoted) do
    case quoted do
      {:case, _, [_, [do: clauses]]} -> clauses
      [{:->, _, _} | _] = clauses -> clauses
      {:->, _, _} = clause -> [clause]
    end
  end

  # Field clauses

  defp build_field_clauses(ctx, msg, fields, loop, target, targets) do
    Enum.reduce(fields, {[], []}, fn field, {cls, pks} ->
      {clause, new_pks} = field_clause(ctx, msg, field, loop, target, targets)
      {cls ++ [clause], pks ++ new_pks}
    end)
  end

  defp field_clause(ctx, msg, field, loop, target, targets) do
    fnum = field.number
    name = field.name
    field_path = quote(do: path ++ [unquote(name)])

    repeated_path =
      quote(do: path ++ [unquote(name), {:index, length(Map.get(acc, unquote(name), []))}])

    siblings = oneof_siblings(msg, field)

    cond do
      field.cardinality in [:repeated, :map] and field.type == :TYPE_MESSAGE ->
        decode_expr = message_decode_expr(field, targets, repeated_path)

        body =
          compatible_body(
            field,
            loop,
            repeated_update_body(loop, name, decode_expr, repeated_path)
          )

        {clause(fnum, body), []}

      field.cardinality == :repeated and packable?(field.type) ->
        helper = packed_helper_name(target.name, name)
        packed_body = packed_path_body(loop, name, helper, field_path)
        singular_decode = scalar_decode_expr(ctx, field)
        unpacked_body = repeated_update_body(loop, name, singular_decode, repeated_path)

        body =
          quote do
            cond do
              wtype == 2 ->
                unquote(packed_body)

              wtype == unquote(field.wire_type) ->
                unquote(unpacked_body)

              true ->
                unquote(unknown_body(loop))
            end
          end

        packed_helper = build_packed_helper(ctx, field, helper)
        {clause(fnum, body), [packed_helper]}

      field.cardinality == :repeated ->
        decode_expr = scalar_decode_expr(ctx, field)

        body =
          compatible_body(
            field,
            loop,
            repeated_update_body(loop, name, decode_expr, repeated_path)
          )

        {clause(fnum, body), []}

      field.type == :TYPE_MESSAGE ->
        decode_expr = message_decode_expr(field, targets, field_path)

        body =
          compatible_body(
            field,
            loop,
            singular_put_body(loop, name, decode_expr, field_path, siblings)
          )

        {clause(fnum, body), []}

      true ->
        decode_expr = scalar_decode_expr(ctx, field)

        body =
          compatible_body(
            field,
            loop,
            singular_put_body(loop, name, decode_expr, field_path, siblings)
          )

        {clause(fnum, body), []}
    end
  end

  defp clause(pattern, body) do
    {:->, [], [[pattern], body]}
  end

  # A known field with a wire type it cannot have is kept as an unknown field,
  # as in the runtime decoder.
  defp compatible_body(field, loop, body) do
    quote do
      if wtype == unquote(field.wire_type) do
        unquote(body)
      else
        unquote(unknown_body(loop))
      end
    end
  end

  defp unknown_body(loop) do
    quote do
      with {:ok, raw, rest} <- PB.Wire.read_unknown_field(fnum, wtype, rest) do
        unknown = PB.UnknownField.from_raw(fnum, wtype, raw)
        unquote(loop)(rest, PB.UnknownField.append(acc, unknown), path)
      else
        {:error, reason} -> PB.Codegen.Runtime.decode_error_at(reason, path)
      end
    end
  end

  defp closed_enum_value_field(%{map_entry: %{fields_by_name: %{value: value}}}) do
    if value.type == :TYPE_ENUM and value.enum.features.enum_type == :CLOSED, do: value
  end

  defp closed_enum_value_field(_field), do: nil

  defp oneof_siblings(msg, field) do
    if PB.Schema.Features.oneof?(field) do
      case msg.oneofs[field.oneof_index] do
        nil ->
          []

        oneof ->
          if field.name in oneof.fields do
            Enum.reject(oneof.fields, &(&1 == field.name))
          else
            []
          end
      end
    else
      []
    end
  end

  # Body fragments. Each assumes `rest`, `acc`, and `path` are in scope.

  defp singular_put_body(loop, name, decode_expr, value_path, siblings) do
    deletes =
      Enum.reduce(siblings, quote(do: acc_new), fn sib, acc ->
        quote do
          Map.delete(unquote(acc), unquote(sib))
        end
      end)

    quote do
      value_path = unquote(value_path)

      case unquote(decode_expr) do
        {:ok, value, rest} ->
          acc_new = Map.put(acc, unquote(name), value)
          acc_new = unquote(deletes)
          unquote(loop)(rest, acc_new, path)

        {:error, %{__exception__: true} = error} ->
          {:error, error}

        {:error, reason} ->
          PB.Codegen.Runtime.decode_field_error(reason, value_path)

        {:unknown_field, unknown, rest} ->
          acc_new = PB.UnknownField.append(acc, unknown)
          unquote(loop)(rest, acc_new, path)
      end
    end
  end

  defp repeated_update_body(loop, name, decode_expr, value_path) do
    quote do
      value_path = unquote(value_path)

      case unquote(decode_expr) do
        {:ok, value, rest} ->
          acc_new = Map.update(acc, unquote(name), [value], &[value | &1])
          unquote(loop)(rest, acc_new, path)

        {:error, %{__exception__: true} = error} ->
          {:error, error}

        {:error, reason} ->
          PB.Codegen.Runtime.decode_field_error(reason, value_path)

        {:unknown_field, unknown, rest} ->
          acc_new = PB.UnknownField.append(acc, unknown)
          unquote(loop)(rest, acc_new, path)
      end
    end
  end

  defp packed_path_body(loop, name, helper, field_path) do
    quote do
      field_path = unquote(field_path)

      with {:ok, body, rest} <- PB.Wire.read_wire(2, rest),
           {:ok, values, unknowns} <- unquote(helper)(body, [], [], field_path, 0) do
        acc_new =
          if values == [] do
            acc
          else
            Map.update(acc, unquote(name), values, &(values ++ &1))
          end

        acc_new =
          unknowns
          |> Enum.reverse()
          |> Enum.reduce(acc_new, &PB.UnknownField.append(&2, &1))

        unquote(loop)(rest, acc_new, path)
      else
        {:error, %{__exception__: true} = error} -> {:error, error}
        {:error, reason} -> PB.Codegen.Runtime.decode_field_error(reason, field_path)
      end
    end
  end

  # Decode expressions returning {:ok, value, rest} or {:error, reason}.

  defp scalar_decode_expr(ctx, field) do
    scalar_read_expr(ctx, field, quote(do: rest))
  end

  defp scalar_read_expr(ctx, field, source) do
    field_ast = Macro.escape(runtime_field(ctx, field))
    wire_type = PB.Wire.wire_type(field.type)

    quote do
      with {:ok, raw, rest2} <- PB.Wire.read_wire(unquote(wire_type), unquote(source)) do
        case PB.Runtime.Scalar.decode(unquote(field_ast), raw) do
          {:ok, value} ->
            {:ok, value, rest2}

          {:error, {:closed_enum_value, raw_value}} ->
            unknown =
              PB.UnknownField.from_raw(
                unquote(field.number),
                unquote(wire_type),
                PB.Wire.encode_varint(raw_value)
              )

            {:unknown_field, unknown, rest2}

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

  defp message_decode_expr(field, targets, value_path) do
    type_name = field.type_name
    # A map entry whose closed enum value was rejected moves whole to the
    # unknown fields, as in the runtime decoder. The entry decoder keeps the
    # rejected value as an unknown field 2 with the value's wire type; other
    # unknown fields inside an entry are dropped with the entry kept.
    rejected_value = closed_enum_value_field(field)

    call =
      cond do
        inline = targets[type_name] ->
          fun = impl_name(inline.name)

          # Decode the child (its descendants reach native form), then apply
          # this field's adapter one level on the result.
          if field[:adapter] do
            quote do
              with {:ok, value} <- unquote(fun)(body, value_path) do
                unquote(maybe_adapter_from_proto(field, quote(do: value), quote(do: value_path)))
              end
            end
          else
            quote do
              unquote(fun)(body, value_path)
            end
          end

        true ->
          quote do
            {:ok, body}
          end
      end

    quote do
      value_path = unquote(value_path)

      with {:ok, body, raw_body, rest2} <-
             PB.Wire.read_message_field(
               unquote(field.number),
               unquote(field.encoding),
               rest
             ),
           {:ok, value} <- unquote(call) do
        if unquote(rejected_value != nil) and is_map(value) and
             Enum.any?(
               Map.get(value, PB.UnknownField.key(), []),
               &(&1.number == unquote(rejected_value && rejected_value.number) and
                   &1.wire_type == 0)
             ) do
          unknown =
            PB.UnknownField.from_raw(
              unquote(field.number),
              unquote(field.wire_type),
              IO.iodata_to_binary(raw_body)
            )

          {:unknown_field, unknown, rest2}
        else
          {:ok, value, rest2}
        end
      end
    end
  end

  defp maybe_adapter_from_proto(%{adapter: adapter, type_name: fqn}, value_ast, path_ast) do
    adapter_ast = Macro.escape(adapter)

    quote do
      PB.Runtime.Codec.adapter_from_proto(
        unquote(adapter_ast),
        unquote(fqn),
        unquote(value_ast),
        unquote(path_ast)
      )
    end
  end

  defp maybe_adapter_from_proto(_field, value_ast, _path_ast) do
    quote do
      {:ok, unquote(value_ast)}
    end
  end

  # Packed helpers

  defp build_packed_helper(ctx, field, helper) do
    read_expr = packed_read_expr(ctx, field)

    quote do
      defp unquote(helper)(<<>>, acc, unknowns, _path, _index), do: {:ok, acc, unknowns}

      defp unquote(helper)(bin, acc, unknowns, path, index) do
        value_path = path ++ [{:index, index}]

        case unquote(read_expr) do
          {:ok, value, rest} ->
            unquote(helper)(rest, [value | acc], unknowns, path, index + 1)

          {:unknown_field, unknown, rest} ->
            unquote(helper)(rest, acc, [unknown | unknowns], path, index + 1)

          {:error, %{__exception__: true} = error} ->
            {:error, error}

          {:error, reason} ->
            PB.Codegen.Runtime.decode_field_error(reason, value_path)
        end
      end
    end
  end

  defp packed_read_expr(ctx, field) do
    scalar_read_expr(ctx, field, quote(do: bin))
  end

  defp packable?(t),
    do:
      t in [
        :TYPE_DOUBLE,
        :TYPE_FLOAT,
        :TYPE_INT64,
        :TYPE_UINT64,
        :TYPE_INT32,
        :TYPE_UINT32,
        :TYPE_FIXED64,
        :TYPE_FIXED32,
        :TYPE_SFIXED64,
        :TYPE_SFIXED32,
        :TYPE_BOOL,
        :TYPE_ENUM,
        :TYPE_SINT32,
        :TYPE_SINT64
      ]

  # Post-processing

  defp build_post_process(ctx, msg) do
    reverse =
      msg.fields_by_name
      |> Enum.sort_by(fn {_name, info} -> info.number end)
      |> Enum.flat_map(fn {name, info} ->
        if info.cardinality == :repeated,
          do: [name],
          else: []
      end)

    maps =
      msg.fields_by_name
      |> Enum.sort_by(fn {_name, info} -> info.number end)
      |> Enum.flat_map(fn {name, info} ->
        case map_entry_fields(ctx, info) do
          {:ok, key_field, value_field} -> [{name, key_field, value_field}]
          :error -> []
        end
      end)

    oneofs =
      msg.oneofs
      |> Enum.sort_by(fn {idx, _oneof} -> idx end)
      |> Enum.map(fn {_idx, oneof} -> {oneof.name, oneof.fields} end)

    required =
      msg.fields_by_name
      |> Enum.sort_by(fn {_name, info} -> info.number end)
      |> Enum.flat_map(fn {name, info} ->
        if PB.Schema.Features.required?(info), do: [name], else: []
      end)

    %{
      reverse: reverse,
      maps: maps,
      oneofs: oneofs,
      required: required,
      defaults: decode_defaults(ctx, msg)
    }
  end

  defp is_map_entry?(ctx, type_name) do
    case ctx.schema.messages[type_name] do
      %{map_entry: true} -> true
      _ -> false
    end
  end

  defp map_field?(ctx, %{type: :TYPE_MESSAGE, cardinality: :map, type_name: type_name}) do
    is_map_entry?(ctx, type_name)
  end

  defp map_field?(_ctx, _field), do: false

  defp map_entry_fields(ctx, %{type: :TYPE_MESSAGE, cardinality: :map, type_name: type_name}) do
    case ctx.schema.messages[type_name] do
      %{map_entry: true, fields_by_name: %{key: key_field, value: value_field}} ->
        {:ok, runtime_field(ctx, key_field), runtime_field(ctx, value_field)}

      _ ->
        :error
    end
  end

  defp map_entry_fields(_ctx, _field), do: :error

  defp decode_defaults(ctx, msg) do
    msg.fields_by_name
    |> Enum.sort_by(fn {_name, info} -> info.number end)
    |> Enum.flat_map(fn {name, field} ->
      cond do
        PB.Runtime.Scalar.has_presence?(field) ->
          []

        map_field?(ctx, field) ->
          [{name, %{}}]

        field.cardinality == :repeated ->
          [{name, []}]

        true ->
          {:ok, value} = PB.Runtime.Scalar.default_value(runtime_field(ctx, field))
          [{name, value}]
      end
    end)
  end

  defp runtime_field(ctx, field) do
    field
    |> Map.take([
      :name,
      :number,
      :type,
      :wire_type,
      :type_name,
      :cardinality,
      :presence,
      :encoding,
      :oneof_index,
      :adapter,
      :features
    ])
    |> maybe_put_enum(ctx, field)
  end

  defp root_adapter_ast(%{projection: %{adapter: adapter}}, fqn) when not is_nil(adapter) do
    adapter_ast = Macro.escape(adapter)

    quote do
      PB.Runtime.Codec.adapter_from_proto(unquote(adapter_ast), unquote(fqn), value, [])
    end
  end

  defp root_adapter_ast(_msg, _fqn) do
    quote do
      {:ok, value}
    end
  end

  defp maybe_put_enum(field, ctx, %{type: :TYPE_ENUM, type_name: type_name}) do
    case ctx.schema.enums[type_name] do
      nil -> field
      enum -> Map.put(field, :enum, enum)
    end
  end

  defp maybe_put_enum(field, _ctx, _source), do: field
end
