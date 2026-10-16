defmodule PB.Codegen.Encoder do
  @moduledoc """
  Emit per-message protobuf encoders from a `PB.Codegen` context.

  Public roots expose `encode_<name>/1,2` and `encode_<name>!/1,2`. Private
  helpers use the same non-throwing internal result contract as generated
  decoders.
  """

  @doc """
  Emit all encoder declarations for the given context.

  Returns a list of top-level quoted AST nodes. Splice into a `defmodule` body.
  """
  def emit_all(ctx) do
    targets = build_targets(ctx)

    Enum.flat_map(targets, fn {fqn, target} ->
      emit_message(ctx, fqn, target, targets)
    end)
  end

  @doc """
  Emit encoder declarations for a single message FQN.
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
        Enum.flat_map(msg.fields_by_name, fn {_name, info} ->
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

  defp public_name(name), do: :"encode_#{name}"
  defp bang_name(name), do: :"encode_#{name}!"
  defp impl_name(name), do: :"__encode_#{name}"
  defp field_step_name(msg_name, field_name), do: :"__encode_field_#{msg_name}_#{field_name}"
  defp oneof_step_name(msg_name, oneof_name), do: :"__encode_oneof_#{msg_name}_#{oneof_name}"

  # Per-message emission

  defp emit_message(ctx, fqn, target, targets) do
    msg = ctx.schema.messages[fqn]

    fields =
      msg.fields_by_name
      |> Map.values()
      |> Enum.sort_by(& &1.number)

    regular_fields = Enum.reject(fields, &oneof_member_field?(msg, &1))

    oneofs =
      msg.oneofs
      |> Enum.sort_by(fn {idx, _oneof} -> idx end)
      |> Enum.map(fn {_idx, oneof} -> oneof end)

    public = public_name(target.name)
    bang = bang_name(target.name)
    impl = impl_name(target.name)

    known_fields = Enum.map(fields, & &1.name)
    oneof_members = Enum.flat_map(oneofs, & &1.fields)
    oneof_names = Enum.map(oneofs, & &1.name)

    field_steps = Enum.map(regular_fields, &field_step_name(target.name, &1.name))
    oneof_steps = Enum.map(oneofs, &oneof_step_name(target.name, &1.name))

    required_fields =
      fields
      |> Enum.filter(&PB.Schema.Features.required?/1)
      |> Enum.map(&{&1.name, &1.type})

    step_captures =
      Enum.map(field_steps ++ oneof_steps, fn step ->
        local_capture(step, 4)
      end)

    impl_def =
      quote do
        defp unquote(impl)(data, path, opts) do
          with :ok <- PB.Codegen.Runtime.validate_encode_message(data, path),
               :ok <-
                 PB.Codegen.Runtime.validate_encode_known_fields(
                   data,
                   unquote(fqn),
                   unquote(Macro.escape(known_fields)),
                   unquote(Macro.escape(oneof_members)),
                   unquote(Macro.escape(oneof_names)),
                   path,
                   opts
                 ),
               :ok <-
                 PB.Codegen.Runtime.validate_encode_required_fields(
                   data,
                   unquote(Macro.escape(required_fields)),
                   path
                 ),
               {:ok, acc} <-
                 PB.Codegen.Runtime.encode_fields(
                   data,
                   path,
                   opts,
                   [],
                   [unquote_splicing(step_captures)]
                 ),
               {:ok, encoded} <-
                 PB.Codegen.Runtime.finish_encode_fields(
                   acc,
                   Map.get(data, PB.UnknownField.key(), [])
                 ) do
            {:ok, encoded}
          end
        end
      end

    root_adapter_ast = root_adapter_ast(msg, fqn)

    public_defs =
      if target.visibility == :def do
        quote do
          def unquote(public)(data, opts \\ []) do
            result =
              with {:ok, opts} <- PB.Codegen.Runtime.normalize_encode_opts(opts),
                   {:ok, data} <- unquote(root_adapter_ast),
                   opts = unquote(root_encode_opts_ast(msg)),
                   {:ok, iodata} <- unquote(impl)(data, [], opts) do
                {:ok, iodata}
              end

            PB.Codegen.Runtime.normalize_encode_result(result, unquote(fqn))
          end

          def unquote(bang)(data, opts \\ []) do
            case unquote(public)(data, opts) do
              {:ok, value} -> value
              {:error, %{__exception__: true} = error} -> raise error
            end
          end
        end
      else
        quote(do: nil)
      end

    field_defs =
      Enum.map(regular_fields, fn field ->
        emit_field_step(ctx, target.name, field, targets)
      end)

    oneof_defs =
      Enum.map(oneofs, fn oneof ->
        emit_oneof_step(ctx, msg, target.name, oneof, targets)
      end)

    [public_defs, impl_def] ++ field_defs ++ oneof_defs
  end

  defp oneof_member_field?(msg, field) do
    if PB.Schema.Features.oneof?(field) do
      case msg.oneofs[field.oneof_index] do
        nil -> false
        oneof -> field.name in oneof.fields
      end
    else
      false
    end
  end

  # Field helpers

  defp emit_field_step(ctx, msg_name, field, targets) do
    step = field_step_name(msg_name, field.name)
    field_path = quote(do: path ++ [unquote(field.name)])
    encode_expr = field_encode_expr(ctx, field, quote(do: value), quote(do: value_path), targets)

    append_ast =
      quote do
        with {:ok, encoded} <- unquote(encode_expr) do
          {:ok, [{unquote(field.number), encoded} | acc]}
        end
      end

    # Message fields are never skipped (see PB.Codegen.Runtime.skip_encode_field?/2),
    # so only emit the guard where a default value can actually be elided.
    present_ast =
      if skippable_field?(field) do
        field_ast = Macro.escape(runtime_field(ctx, field))

        quote do
          if PB.Codegen.Runtime.skip_encode_field?(unquote(field_ast), value) do
            {:ok, acc}
          else
            unquote(append_ast)
          end
        end
      else
        append_ast
      end

    quote do
      defp unquote(step)(data, acc, path, opts) do
        _ = opts

        case Map.fetch(data, unquote(field.name)) do
          :error ->
            {:ok, acc}

          {:ok, value} ->
            value_path = unquote(field_path)
            unquote(present_ast)
        end
      end
    end
  end

  defp skippable_field?(field), do: field.type != :TYPE_MESSAGE

  defp emit_oneof_step(ctx, msg, msg_name, oneof, targets) do
    step = oneof_step_name(msg_name, oneof.name)
    wrapper_path = quote(do: path ++ [unquote(oneof.name)])
    clauses = Enum.map(oneof.fields, &oneof_member_clause(ctx, msg, oneof, &1, targets))

    unknown_member =
      clause(
        quote(do: {field_name, _value} when is_atom(field_name)),
        quote do
          {:error, {:invalid_oneof, unquote(wrapper_path), {:unknown_member, field_name}}}
        end
      )

    invalid_shape =
      clause(
        quote(do: _value),
        quote do
          {:error, {:invalid_oneof, unquote(wrapper_path), :expected_member_tuple}}
        end
      )

    dispatch = build_case(quote(do: value), clauses ++ [unknown_member, invalid_shape])

    quote do
      defp unquote(step)(data, acc, path, opts) do
        _ = opts

        case Map.fetch(data, unquote(oneof.name)) do
          :error ->
            {:ok, acc}

          {:ok, nil} ->
            {:error, :absent}

          {:ok, value} ->
            unquote(dispatch)
        end
      end
    end
  end

  defp oneof_member_clause(ctx, msg, oneof, field_name, targets) do
    field = Map.fetch!(msg.fields_by_name, field_name)
    member_path = quote(do: path ++ [unquote(oneof.name), unquote(field.name)])
    encode_expr = field_encode_expr(ctx, field, quote(do: value), quote(do: value_path), targets)

    clause(
      quote(do: {unquote(field.name), value}),
      quote do
        value_path = unquote(member_path)

        with {:ok, encoded} <- unquote(encode_expr) do
          {:ok, [{unquote(field.number), encoded} | acc]}
        end
      end
    )
  end

  defp build_case(subject, clauses) do
    {:case, [], [subject, [do: clauses]]}
  end

  defp clause(pattern, body) do
    {:->, [], [[pattern], body]}
  end

  # Encode expressions returning {:ok, iodata} or {:error, reason}.

  defp field_encode_expr(ctx, field, value_ast, path_ast, targets) do
    cond do
      map_field?(ctx, field) ->
        quote do
          PB.Codegen.Runtime.encode_map(
            unquote(value_ast),
            unquote(path_ast),
            fn entry, entry_path ->
              unquote(
                singular_encode_expr(ctx, field, quote(do: entry), quote(do: entry_path), targets)
              )
            end
          )
        end

      PB.Schema.Features.packed?(field) ->
        field_ast = Macro.escape(runtime_field(ctx, field))

        quote do
          PB.Codegen.Runtime.encode_packed(
            unquote(value_ast),
            unquote(field_ast),
            unquote(path_ast)
          )
        end

      PB.Schema.Features.repeated?(field) ->
        quote do
          PB.Codegen.Runtime.encode_repeated(
            unquote(value_ast),
            unquote(path_ast),
            fn item, item_path ->
              unquote(
                singular_encode_expr(ctx, field, quote(do: item), quote(do: item_path), targets)
              )
            end
          )
        end

      true ->
        singular_encode_expr(ctx, field, value_ast, path_ast, targets)
    end
  end

  defp singular_encode_expr(ctx, field, value_ast, path_ast, targets) do
    field_ast = Macro.escape(runtime_field(ctx, field))
    typed_expr = typed_value_expr(ctx, field, value_ast, path_ast, targets)

    quote do
      with {:ok, body} <- unquote(typed_expr) do
        PB.Codegen.Runtime.encode_tagged(unquote(field_ast), body)
      end
    end
  end

  defp typed_value_expr(ctx, %{type: :TYPE_MESSAGE} = field, value_ast, path_ast, targets) do
    inner_expr =
      cond do
        adapter = field[:adapter] ->
          adapter_ast = Macro.escape(adapter)

          # Apply the adapter one level, then recurse so native children it
          # leaves behind reach their own adapters.
          quote do
            with {:ok, value} <-
                   PB.Runtime.Codec.adapter_to_proto(
                     unquote(adapter_ast),
                     unquote(field.type_name),
                     unquote(value_ast),
                     unquote(path_ast)
                   ) do
              unquote(message_encode_expr(field, quote(do: value), path_ast, targets))
            end
          end

        true ->
          message_encode_expr(field, value_ast, path_ast, targets)
      end

    field_ast = Macro.escape(runtime_field(ctx, field))

    quote do
      with {:ok, inner} <- unquote(inner_expr) do
        PB.Codegen.Runtime.encode_message_value(unquote(field_ast), inner)
      end
    end
  end

  defp typed_value_expr(ctx, field, value_ast, path_ast, _targets) do
    field_ast = Macro.escape(runtime_field(ctx, field))

    quote do
      PB.Codegen.Runtime.encode_typed_value(
        unquote(field_ast),
        unquote(value_ast),
        unquote(path_ast)
      )
    end
  end

  defp message_encode_expr(field, value_ast, path_ast, targets) do
    case targets[field.type_name] do
      nil ->
        quote do
          {:error, {:unknown_message, unquote(field.type_name)}}
        end

      inline ->
        fun = impl_name(inline.name)

        quote do
          unquote(fun)(unquote(value_ast), unquote(path_ast), opts)
        end
    end
  end

  defp map_field?(ctx, field) do
    PB.Schema.Features.map?(field) and field.type == :TYPE_MESSAGE and
      match?(%{map_entry: true}, ctx.schema.messages[field.type_name])
  end

  defp local_capture(function, arity) do
    {:&, [], [{:/, [context: Elixir, imports: [{2, Kernel}]], [{function, [], Elixir}, arity]}]}
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
      PB.Runtime.Codec.adapter_to_proto(unquote(adapter_ast), unquote(fqn), data, [])
    end
  end

  defp root_adapter_ast(_msg, _fqn) do
    quote do
      {:ok, data}
    end
  end

  # The root adapter runs one level (above); recursion keeps adapters on so the
  # native children it leaves behind reach their own adapters.
  defp root_encode_opts_ast(_msg) do
    quote do
      opts
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
