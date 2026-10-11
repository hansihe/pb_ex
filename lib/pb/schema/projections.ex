defmodule PB.Schema.Projections do
  @moduledoc false

  alias PB.Schema.Projection

  @type message_spec :: %{
          required(:kind) => :struct | :unwrap,
          optional(:module) => module(),
          optional(:field) => atom(),
          required(:preserved_unknown_fields) => :drop | :reject | {:field, atom()},
          required(:extensions) => :reject | {:field, atom()}
        }

  @type oneof_spec :: %{
          required(:kind) => :identity
        }

  @extensions :__extensions__
  @message_option :"elixir.pb.v1.message"
  @oneof_option :"elixir.pb.v1.oneof"

  @doc """
  Applies all message and oneof projections to a draft or prepared schema.
  """
  @spec apply(map(), [{PB.Schema.Compiled.message_name(), keyword()}]) :: map()
  def apply(schema, projections) when is_map(schema) do
    schema
    |> projection_entries(projections)
    |> merge_entries()
    |> reject_adapter_representation_conflicts!()
    |> apply_merged(schema)
  end

  defp projection_entries(schema, projections) do
    proto_source_entries(schema) ++ projections_opt_entries(projections)
  end

  defp proto_source_entries(schema) do
    message_option_entries(schema) ++ oneof_option_entries(schema)
  end

  defp message_option_entries(schema) do
    Enum.flat_map(schema.messages, fn {fqn, message} ->
      case extension_option(message, @message_option) do
        nil ->
          []

        option ->
          [
            {fqn,
             normalize_message_spec(:proto_source, fqn, message_option_to_spec!(fqn, option)),
             :proto_source}
          ]
      end
    end)
  end

  defp oneof_option_entries(schema) do
    Enum.flat_map(schema.messages, fn {fqn, message} ->
      Enum.flat_map(message.oneofs, fn {_index, oneof} ->
        case extension_option(oneof, @oneof_option) do
          nil ->
            []

          option ->
            key = {fqn, oneof.name}

            [
              {key,
               normalize_oneof_spec(
                 :proto_source,
                 fqn,
                 oneof.name,
                 oneof_option_to_spec!(fqn, oneof.name, option)
               ), :proto_source}
            ]
        end
      end)
    end)
  end

  defp extension_option(entry, option_name) do
    get_in(entry, [:options, @extensions, option_name])
  end

  defp message_option_to_spec!(fqn, option) when is_map(option) do
    []
    |> maybe_put_option(:struct, Map.get(option, :struct))
    |> Keyword.merge(unwrap_option!(fqn, Map.get(option, :unwrap)))
    |> Keyword.merge(
      aux_policy_option!(
        fqn,
        :preserved_unknown_fields,
        Map.get(option, :preserved_unknown_fields)
      )
    )
    |> Keyword.merge(aux_policy_option!(fqn, :extensions, Map.get(option, :extensions)))
  end

  defp message_option_to_spec!(fqn, option),
    do: invalid_schema!(fqn, "invalid message representation option #{inspect(option)}")

  defp oneof_option_to_spec!(fqn, oneof_name, option) when is_map(option) do
    case Map.get(option, :representation) do
      :IDENTITY ->
        [representation: :identity]

      1 ->
        [representation: :identity]

      nil ->
        invalid_schema!(fqn, "oneof #{inspect(oneof_name)} option must set representation")

      other ->
        invalid_schema!(
          fqn,
          "invalid oneof #{inspect(oneof_name)} representation #{inspect(other)}"
        )
    end
  end

  defp oneof_option_to_spec!(fqn, oneof_name, option) do
    invalid_schema!(
      fqn,
      "invalid oneof #{inspect(oneof_name)} representation option #{inspect(option)}"
    )
  end

  defp unwrap_option!(_fqn, nil), do: []

  defp unwrap_option!(_fqn, %{target: {:only_field, true}}), do: [unwrap: true]

  defp unwrap_option!(fqn, %{target: {:only_field, false}}),
    do: invalid_schema!(fqn, "unwrap representation option only_field must be true")

  defp unwrap_option!(fqn, %{target: {:field, field}}), do: [unwrap: option_field!(fqn, field)]

  defp unwrap_option!(fqn, option),
    do: invalid_schema!(fqn, "invalid unwrap representation option #{inspect(option)}")

  defp aux_policy_option!(_fqn, _name, nil), do: []

  defp aux_policy_option!(fqn, name, %{policy: {policy, value}}) do
    [{name, aux_policy_value!(fqn, name, policy, value)}]
  end

  defp aux_policy_option!(fqn, name, option),
    do: invalid_schema!(fqn, "invalid #{name} representation option #{inspect(option)}")

  defp aux_policy_value!(_fqn, :preserved_unknown_fields, :drop, true), do: :drop
  defp aux_policy_value!(_fqn, :preserved_unknown_fields, :reject, true), do: :reject

  defp aux_policy_value!(fqn, :preserved_unknown_fields, :field, field),
    do: {:field, option_field!(fqn, field)}

  defp aux_policy_value!(_fqn, :extensions, :reject, true), do: :reject
  defp aux_policy_value!(fqn, :extensions, :field, field), do: {:field, option_field!(fqn, field)}

  defp aux_policy_value!(fqn, name, policy, value),
    do: invalid_schema!(fqn, "invalid #{name} representation option #{inspect({policy, value})}")

  defp maybe_put_option(opts, _name, nil), do: opts
  defp maybe_put_option(opts, name, value), do: Keyword.put(opts, name, value)

  defp option_field!(_fqn, field) when is_atom(field), do: field
  defp option_field!(_fqn, field) when is_binary(field) and field != "", do: String.to_atom(field)

  defp option_field!(fqn, field),
    do: invalid_schema!(fqn, "invalid representation field option #{inspect(field)}")

  defp projections_opt_entries(nil), do: []
  defp projections_opt_entries([]), do: []

  defp projections_opt_entries(projections) when is_list(projections) do
    Enum.flat_map(projections, &projection_entry_to_internal!/1)
  end

  defp projections_opt_entries(projections),
    do: invalid!(:projections_opt, nil, "expected a list, got: #{inspect(projections)}")

  @projection_entry_keys [
    :adapter,
    :struct,
    :unwrap,
    :preserved_unknown_fields,
    :extensions,
    :oneofs
  ]

  defp projection_entry_to_internal!({fqn, opts}) when is_atom(fqn) and is_list(opts) do
    unless Keyword.keyword?(opts) do
      invalid!(:projections_opt, fqn, "expected a keyword list, got: #{inspect(opts)}")
    end

    unknown = Keyword.keys(opts) -- @projection_entry_keys

    if unknown != [] do
      invalid!(:projections_opt, fqn, "unknown option(s) #{inspect(unknown)}")
    end

    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} ->
        other = Keyword.delete(opts, :adapter) |> Keyword.keys()

        if other != [] do
          invalid!(:projections_opt, fqn, "cannot combine :adapter with #{inspect(other)}")
        end

        [{fqn, normalize_adapter!(fqn, adapter), :projections_opt}]

      :error ->
        message_entry(fqn, opts) ++ oneof_entries(fqn, Keyword.get(opts, :oneofs))
    end
  end

  defp projection_entry_to_internal!(entry),
    do: invalid!(:projections_opt, nil, "expected {fqn, options}, got: #{inspect(entry)}")

  defp message_entry(fqn, opts) do
    has_struct = Keyword.has_key?(opts, :struct)
    has_unwrap = Keyword.has_key?(opts, :unwrap)
    has_oneofs = Keyword.has_key?(opts, :oneofs)

    has_aux =
      Keyword.has_key?(opts, :preserved_unknown_fields) or Keyword.has_key?(opts, :extensions)

    cond do
      has_struct or has_unwrap ->
        spec = normalize_message_spec(:projections_opt, fqn, Keyword.drop(opts, [:oneofs]))
        [{fqn, spec, :projections_opt}]

      has_aux ->
        invalid!(
          :projections_opt,
          fqn,
          ":preserved_unknown_fields and :extensions require :struct or :unwrap"
        )

      has_oneofs ->
        []

      true ->
        invalid!(:projections_opt, fqn, "must set :adapter, :struct, :unwrap or :oneofs")
    end
  end

  defp oneof_entries(_fqn, nil), do: []

  defp oneof_entries(fqn, oneofs) do
    unless is_list(oneofs) and Keyword.keyword?(oneofs) do
      invalid!(
        :projections_opt,
        fqn,
        ":oneofs must be a keyword list of {oneof_name, options}, got: #{inspect(oneofs)}"
      )
    end

    Enum.map(oneofs, fn {oneof_name, oneof_opts} ->
      key = {fqn, oneof_name}
      {key, normalize_oneof_spec(:projections_opt, fqn, oneof_name, oneof_opts), :projections_opt}
    end)
  end

  defp normalize_adapter!(_fqn, %PB.Adapter{} = adapter), do: adapter

  defp normalize_adapter!(fqn, other),
    do: invalid!(:projections_opt, fqn, ":adapter must be a %PB.Adapter{}, got #{inspect(other)}")

  defp normalize_message_spec(source, fqn, spec) do
    preserved_unknown_fields = Keyword.get(spec, :preserved_unknown_fields, :drop)
    extensions = Keyword.get(spec, :extensions, :reject)

    case {Keyword.fetch(spec, :struct), Keyword.fetch(spec, :unwrap)} do
      {{:ok, module}, :error} ->
        %{
          kind: :struct,
          module: normalize_struct_module!(source, fqn, module),
          preserved_unknown_fields:
            normalize_preserved_unknown_fields!(source, fqn, preserved_unknown_fields, :struct),
          extensions: normalize_extensions!(source, fqn, extensions, :struct)
        }

      {:error, {:ok, field}} ->
        %{
          kind: :unwrap,
          field: normalize_unwrap_field!(source, fqn, field),
          preserved_unknown_fields:
            normalize_preserved_unknown_fields!(source, fqn, preserved_unknown_fields, :unwrap),
          extensions: normalize_extensions!(source, fqn, extensions, :unwrap)
        }

      {{:ok, _module}, {:ok, _field}} ->
        invalid!(source, fqn, "cannot set both :struct and :unwrap")

      {:error, :error} ->
        invalid!(source, fqn, "must set :struct or :unwrap")
    end
  end

  defp normalize_struct_module!(_source, _fqn, module) when is_atom(module), do: module

  defp normalize_struct_module!(source, fqn, module) when is_binary(module) do
    case String.split(module, ".", trim: true) do
      [] -> normalize_struct_module!(source, fqn, nil)
      parts -> Module.concat(parts)
    end
  end

  defp normalize_struct_module!(source, fqn, module),
    do: invalid!(source, fqn, "invalid :struct module #{inspect(module)}")

  defp normalize_unwrap_field!(_source, _fqn, true), do: true
  defp normalize_unwrap_field!(_source, _fqn, field) when is_atom(field), do: field

  defp normalize_unwrap_field!(source, fqn, field),
    do: invalid!(source, fqn, "invalid :unwrap field #{inspect(field)}")

  defp normalize_preserved_unknown_fields!(_source, _fqn, policy, :struct)
       when policy in [:drop, :reject],
       do: policy

  defp normalize_preserved_unknown_fields!(_source, _fqn, {:field, field}, :struct)
       when is_atom(field),
       do: {:field, field}

  defp normalize_preserved_unknown_fields!(_source, _fqn, policy, :unwrap)
       when policy in [:drop, :reject],
       do: policy

  defp normalize_preserved_unknown_fields!(source, fqn, policy, kind) do
    invalid!(
      source,
      fqn,
      "invalid :preserved_unknown_fields policy for #{kind} #{inspect(policy)}"
    )
  end

  defp normalize_extensions!(_source, _fqn, :reject, _kind), do: :reject

  defp normalize_extensions!(_source, _fqn, {:field, field}, :struct) when is_atom(field),
    do: {:field, field}

  defp normalize_extensions!(source, fqn, policy, kind),
    do: invalid!(source, fqn, "invalid :extensions policy for #{kind} #{inspect(policy)}")

  defp normalize_oneof_spec(source, fqn, oneof_name, spec) do
    oneof = "oneof #{inspect(oneof_name)}"

    unless is_list(spec) and Keyword.keyword?(spec) do
      invalid!(source, fqn, "#{oneof} options must be a keyword list, got: #{inspect(spec)}")
    end

    unknown = Keyword.keys(spec) -- [:representation]

    if unknown != [] do
      invalid!(source, fqn, "unknown #{oneof} option(s) #{inspect(unknown)}")
    end

    case Keyword.fetch(spec, :representation) do
      {:ok, :identity} ->
        %{kind: :identity}

      {:ok, representation} ->
        invalid!(source, fqn, "invalid #{oneof} representation #{inspect(representation)}")

      :error ->
        invalid!(source, fqn, "#{oneof} must set :representation")
    end
  end

  defp merge_entries(entries) do
    Enum.reduce(entries, %{}, fn {key, spec, source}, acc ->
      case Map.fetch(acc, key) do
        :error ->
          Map.put(acc, key, %{spec: spec, source: source, sources: MapSet.new([source])})

        {:ok, %{spec: existing_spec, sources: sources} = existing} ->
          cond do
            MapSet.member?(sources, source) ->
              raise_duplicate_projection!(key)

            match?(^spec, existing_spec) ->
              Map.put(acc, key, %{existing | sources: MapSet.put(sources, source)})

            true ->
              raise_conflict!(key, existing.source, existing_spec, source, spec)
          end
      end
    end)
  end

  defp reject_adapter_representation_conflicts!(entries) do
    adapters =
      Enum.flat_map(entries, fn
        {fqn, %{spec: %PB.Adapter{} = adapter, source: source}} when is_atom(fqn) ->
          [{fqn, source, adapter}]

        _entry ->
          []
      end)

    representations =
      Enum.reduce(entries, %{}, fn
        {fqn, %{spec: spec, source: source}}, acc when is_atom(fqn) ->
          if representation_spec?(spec), do: Map.put_new(acc, fqn, {source, spec}), else: acc

        {{fqn, _oneof_name}, %{spec: spec, source: source}}, acc ->
          Map.put_new(acc, fqn, {source, spec})
      end)

    Enum.each(adapters, fn {fqn, adapter_source, adapter} ->
      case Map.fetch(representations, fqn) do
        {:ok, {representation_source, representation}} ->
          raise_conflict!(fqn, representation_source, representation, adapter_source, adapter)

        :error ->
          :ok
      end
    end)

    entries
  end

  defp representation_spec?(%PB.Adapter{}), do: false
  defp representation_spec?(_spec), do: true

  defp apply_merged(entries, schema) do
    %{messages: message_specs, oneofs: oneof_specs} = split_entries(entries)

    schema
    |> apply_message_specs(message_specs)
    |> apply_oneof_specs(oneof_specs)
  end

  defp split_entries(entries) do
    Enum.reduce(entries, %{messages: %{}, oneofs: %{}}, fn
      {{fqn, oneof_name} = key, %{spec: spec}}, acc when is_atom(fqn) and is_atom(oneof_name) ->
        put_in(acc.oneofs[key], spec)

      {fqn, %{spec: spec}}, acc when is_atom(fqn) ->
        put_in(acc.messages[fqn], spec)
    end)
  end

  defp apply_message_specs(schema, specs) do
    messages =
      Enum.reduce(specs, schema.messages, fn {fqn, spec}, messages ->
        msg = fetch_message!(messages, fqn)
        validate_message_target!(fqn, msg)
        validate_existing_message_projection!(fqn, msg, spec)

        case spec do
          %PB.Adapter{} = adapter ->
            put_message_projection(messages, fqn, msg, fn %Projection{} = projection ->
              %{projection | adapter: adapter}
            end)

          %{kind: :struct} ->
            validate_struct_spec!(fqn, msg, spec)

            put_message_projection(messages, fqn, msg, fn %Projection{} = projection ->
              %{
                projection
                | struct_mod: spec.module,
                  preserved_unknown_fields: spec.preserved_unknown_fields,
                  extensions: spec.extensions
              }
            end)

          %{kind: :unwrap} ->
            field = validate_unwrap_spec!(fqn, msg, spec)

            put_message_projection(messages, fqn, msg, fn %Projection{} = projection ->
              %{
                projection
                | unwrap_field: field.name,
                  preserved_unknown_fields: spec.preserved_unknown_fields,
                  extensions: spec.extensions
              }
            end)
        end
      end)

    Map.put(schema, :messages, messages)
  end

  defp validate_message_target!(fqn, %{map_entry: true}),
    do: invalid_schema!(fqn, "a map-entry message cannot be projected")

  defp validate_message_target!(_fqn, %{kind: :message}), do: :ok

  defp validate_existing_message_projection!(fqn, msg, %PB.Adapter{} = adapter) do
    cond do
      existing_adapter?(msg) ->
        raise_duplicate_projection!(fqn)

      representation = existing_message_representation(msg) ->
        raise_conflict!(fqn, :existing_schema, representation, :projections_opt, adapter)

      true ->
        :ok
    end
  end

  defp validate_existing_message_projection!(fqn, msg, spec) do
    cond do
      adapter = existing_adapter(msg) ->
        raise_conflict!(fqn, :existing_schema, adapter, :projections_opt, spec)

      representation = existing_message_representation(msg) ->
        case representation do
          ^spec ->
            :ok

          _other ->
            raise_conflict!(fqn, :existing_schema, representation, :projections_opt, spec)
        end

      true ->
        :ok
    end
  end

  defp existing_adapter?(msg), do: existing_adapter(msg) != nil

  defp existing_adapter(%{projection: %Projection{adapter: adapter}}), do: adapter
  defp existing_adapter(_msg), do: nil

  defp existing_message_representation(%{projection: %Projection{} = projection}) do
    cond do
      projection.struct_mod != nil ->
        %{
          kind: :struct,
          module: projection.struct_mod,
          preserved_unknown_fields: projection.preserved_unknown_fields,
          extensions: projection.extensions
        }

      projection.unwrap_field != nil ->
        %{
          kind: :unwrap,
          field: projection.unwrap_field,
          preserved_unknown_fields: projection.preserved_unknown_fields,
          extensions: projection.extensions
        }

      map_size(projection.oneofs) > 0 ->
        %{oneofs: projection.oneofs}

      true ->
        nil
    end
  end

  defp existing_message_representation(_msg), do: nil

  defp validate_struct_spec!(fqn, msg, spec) do
    struct_fields = struct_fields!(fqn, spec.module)

    if spec.extensions == :reject and map_size(msg.extensions_by_name) > 0 do
      invalid_schema!(
        fqn,
        "the message has extensions, so a struct projection needs extensions: {:field, name}"
      )
    end

    required =
      msg
      |> struct_message_fields()
      |> MapSet.union(auxiliary_fields(spec))

    missing = required |> MapSet.difference(struct_fields) |> MapSet.to_list() |> Enum.sort()

    if missing != [] do
      invalid_schema!(fqn, "#{inspect(spec.module)} is missing field(s) #{inspect(missing)}")
    end
  end

  defp struct_fields!(fqn, module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) do
      invalid_schema!(fqn, "#{inspect(module)} is not a struct module")
    end

    module.__struct__()
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
    |> MapSet.new()
  end

  defp struct_message_fields(msg) do
    field_names =
      msg.fields_by_name
      |> Map.values()
      |> Enum.reject(&oneof_field?/1)
      |> Enum.map(& &1.name)

    oneof_names =
      msg.oneofs
      |> Map.values()
      |> Enum.map(& &1.name)

    MapSet.new(field_names ++ oneof_names)
  end

  defp oneof_field?(%{presence: :oneof}), do: true
  defp oneof_field?(_field), do: false

  defp auxiliary_fields(spec) do
    [spec.preserved_unknown_fields, spec.extensions]
    |> Enum.flat_map(fn
      {:field, field} -> [field]
      _policy -> []
    end)
    |> MapSet.new()
  end

  defp validate_unwrap_spec!(fqn, msg, spec) do
    if spec.extensions == :reject and map_size(msg.extensions_by_name) > 0 do
      invalid_schema!(fqn, "an unwrap projection cannot represent the message's extensions")
    end

    regular_fields =
      msg.fields_by_name
      |> Map.values()
      |> Enum.reject(&oneof_field?/1)

    case {spec.field, regular_fields} do
      {true, [field]} ->
        field

      {true, fields} ->
        invalid_schema!(
          fqn,
          "unwrap needs exactly one field outside oneofs, got " <>
            inspect(Enum.map(fields, & &1.name))
        )

      {name, _fields} when is_atom(name) ->
        case Map.fetch(msg.fields_by_name, name) do
          {:ok, field} ->
            if oneof_field?(field) do
              invalid_schema!(fqn, "unwrap cannot target oneof field #{inspect(name)}")
            end

            field

          :error ->
            invalid_schema!(fqn, "unwrap targets unknown field #{inspect(name)}")
        end
    end
  end

  defp apply_oneof_specs(schema, specs) do
    messages =
      Enum.reduce(specs, schema.messages, fn {{fqn, oneof_name} = key, spec}, messages ->
        msg = fetch_message!(messages, fqn)
        validate_message_target!(fqn, msg)

        case spec.kind do
          :identity ->
            {index, oneof} = fetch_oneof!(msg, key)
            by_struct = identity_oneof_index!(messages, fqn, oneof)

            oneof = Map.put(oneof, :term_by_struct, by_struct)

            msg =
              msg
              |> Map.put(:oneofs, Map.put(msg.oneofs, index, oneof))
              |> put_projection(fn %Projection{} = projection ->
                %{
                  projection
                  | oneofs: Map.put(projection.oneofs, oneof_name, :identity)
                }
              end)

            Map.put(messages, fqn, msg)
        end
      end)

    Map.put(schema, :messages, messages)
  end

  defp fetch_message!(messages, fqn) do
    case Map.fetch(messages, fqn) do
      {:ok, msg} ->
        msg

      :error ->
        raise PB.SchemaError, kind: :unknown_message, operation: :compile, name: fqn
    end
  end

  defp fetch_oneof!(msg, {fqn, oneof_name}) do
    case Enum.find(msg.oneofs, fn {_index, oneof} -> oneof.name == oneof_name end) do
      nil ->
        invalid_schema!(fqn, "projection targets unknown oneof #{inspect(oneof_name)}")

      oneof ->
        oneof
    end
  end

  defp identity_oneof_index!(messages, fqn, oneof) do
    oneof.fields
    |> Enum.map(fn field_name ->
      field = Map.fetch!(messages[fqn].fields_by_name, field_name)

      unless field.type == :TYPE_MESSAGE do
        invalid_schema!(
          fqn,
          "identity oneof #{inspect(oneof.name)} needs message members, " <>
            "#{inspect(field.name)} is not one"
        )
      end

      target = fetch_message!(messages, field.type_name)

      unless struct_represented?(target) do
        invalid_schema!(
          fqn,
          "identity oneof #{inspect(oneof.name)} needs member #{inspect(field.name)}'s " <>
            "message #{inspect(field.type_name)} projected to a struct"
        )
      end

      {struct_module(target), field.name}
    end)
    |> Map.new(fn {module, field_name} ->
      {module, field_name}
    end)
    |> reject_duplicate_structs!(fqn, oneof)
  end

  defp reject_duplicate_structs!(by_struct, fqn, oneof) do
    if map_size(by_struct) != length(oneof.fields) do
      invalid_schema!(fqn, "identity oneof #{inspect(oneof.name)} members share a struct")
    end

    by_struct
  end

  defp struct_represented?(%{projection: %Projection{struct_mod: module}})
       when not is_nil(module),
       do: true

  defp struct_represented?(_msg), do: false

  defp struct_module(%{projection: %Projection{struct_mod: module}}) when not is_nil(module),
    do: module

  defp put_message_projection(messages, fqn, msg, fun) do
    Map.put(messages, fqn, put_projection(msg, fun))
  end

  defp put_projection(msg, fun) do
    projection =
      case Map.fetch(msg, :projection) do
        {:ok, %Projection{} = projection} -> projection
        :error -> %Projection{}
      end
      |> fun.()

    Map.put(msg, :projection, projection)
  end

  @spec raise_duplicate_projection!(term) :: no_return
  defp raise_duplicate_projection!(key),
    do: invalid!(:projections_opt, fqn(key), "#{describe(key)} is projected more than once")

  @spec raise_conflict!(term, atom, term, atom, term) :: no_return
  defp raise_conflict!(key, source_a, spec_a, source_b, spec_b) do
    invalid_schema!(
      fqn(key),
      "conflicting projections for #{describe(key)}: " <>
        "#{source_label(source_a)} declares #{inspect(spec_a)}, " <>
        "#{source_label(source_b)} declares #{inspect(spec_b)}"
    )
  end

  defp fqn({fqn, _oneof_name}), do: fqn
  defp fqn(fqn), do: fqn

  defp describe({_fqn, oneof_name}), do: "oneof #{inspect(oneof_name)}"
  defp describe(_fqn), do: "the message"

  defp source_label(:proto_source), do: "the .proto source"
  defp source_label(:projections_opt), do: "the :projections option"
  defp source_label(:existing_schema), do: "the schema"

  # A projection's own options are the caller's mistake (PB.OptionError) when
  # they came from the :projections option, and the schema's when they came
  # from a representation option in the .proto source. Mismatches between a
  # projection and the message it targets are always the schema's.
  @spec invalid!(:projections_opt | :proto_source, atom | nil, String.t()) :: no_return
  defp invalid!(:projections_opt, fqn, reason) do
    raise PB.OptionError,
      kind: :invalid_option,
      operation: :compile,
      message_name: fqn,
      option: :projections,
      reason: reason
  end

  defp invalid!(:proto_source, fqn, reason), do: invalid_schema!(fqn, reason)

  @spec invalid_schema!(atom, String.t()) :: no_return
  defp invalid_schema!(fqn, reason) do
    raise PB.SchemaError,
      kind: :invalid_schema,
      operation: :compile,
      type_name: fqn,
      reason: reason
  end
end
