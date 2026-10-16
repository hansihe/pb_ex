defmodule PB.Schema.Prepare do
  @moduledoc false

  # Prepares a schema for runtime encode/decode.
  #
  # Preparation is the final schema phase. It assumes the compiler and annotators
  # have already resolved semantic facts such as presence, cardinality, encoding,
  # map shape, and validation metadata. It then writes only runtime-facing
  # metadata: numeric indexes, encoded tags, enum refs, adapter refs,
  # required/default field lists, and oneof lookup maps.
  #
  # This module is intentionally strict. Missing messages, enums, map-entry
  # fields, or extension maps are compiler/transform bugs, so the code uses
  # `Map.fetch!/2` and pattern matches instead of compatibility fallback paths.
  #
  # `prepare/1` may be called again after transforms such as adapter application
  # or slicing. Re-running it refreshes references that can otherwise become
  # stale, especially map-entry value fields whose target message gained an
  # adapter.

  alias PB.Schema.Projection
  alias PB.Wire

  @doc """
  Returns a runtime-ready schema.

  The returned schema is the shape consumed by `PB.Runtime.Encoder`,
  `PB.Runtime.Decoder`, validation, JSON, CEL, and message equality.
  Runtime code should treat prepared metadata as part of the schema contract and
  should not re-derive it on hot paths.
  """
  def prepare(schema) when is_map(schema) do
    schema
    # Drop any precomputed standard-rule schema (PB.Validate.Schema): it is
    # derived from this schema, so transforms that re-prepare must not carry a
    # stale copy. PB.compile/2 reattaches it after this final prepare.
    |> Map.delete(:standard_rule_schema)
    |> prepare_message_fields()
    |> prepare_map_references()
    |> prepare_schema_extensions()
  end

  defp prepare_message_fields(schema) do
    messages =
      Map.new(schema.messages, fn {fqn, msg} ->
        {fqn, prepare_message_fields(schema, msg)}
      end)

    Map.put(schema, :messages, messages)
  end

  defp prepare_message_fields(schema, msg) do
    fields_by_name =
      Map.new(msg.fields_by_name, fn {name, field} ->
        {name, prepare_field(schema, field)}
      end)

    extensions_by_name =
      Map.new(msg.extensions_by_name, fn {name, field} ->
        {name, prepare_field(schema, field)}
      end)

    msg
    |> Map.put(:fields_by_name, fields_by_name)
    |> Map.put(:extensions_by_name, extensions_by_name)
    |> prepare_message_runtime_info()
  end

  defp prepare_schema_extensions(schema) do
    global =
      Map.new(schema.extensions_by_name, fn {name, field} ->
        field =
          schema
          |> prepare_field(field)
          |> prepare_map_reference(schema)

        {name, field}
      end)

    Map.put(
      schema,
      :extensions_by_name,
      Map.merge(global, extensions_from_messages(schema.messages))
    )
  end

  defp prepare_field(schema, %{type: :TYPE_MESSAGE, type_name: type_name} = field) do
    case fetch_type!(schema.messages, type_name, :unknown_message) do
      %{projection: %Projection{adapter: adapter}} when not is_nil(adapter) ->
        Map.put(field, :adapter, adapter)

      %{kind: :message} ->
        Map.delete(field, :adapter)
    end
    |> prepare_field_runtime_info()
  end

  defp prepare_field(schema, %{type: :TYPE_ENUM, type_name: type_name} = field) do
    enum = fetch_type!(schema.enums, type_name, :unknown_enum)

    field
    |> Map.put(:enum, enum)
    |> prepare_field_runtime_info()
  end

  defp prepare_field(_schema, field), do: prepare_field_runtime_info(field)

  # A missing referenced type usually means the schema was compiled without
  # `--include_imports`. Surface a diagnosable PB.SchemaError instead of the raw
  # KeyError that Map.fetch!/2 would raise mid-prepare.
  defp fetch_type!(types, type_name, kind) do
    case Map.fetch(types, type_name) do
      {:ok, type} ->
        type

      :error ->
        raise PB.SchemaError, kind: kind, name: type_name, type_name: type_name
    end
  end

  # Map semantics are decided in `PB.Schema.Compiler`. This pass only
  # refreshes the nested entry/key/value references after the first field pass
  # has attached fresh enum and adapter metadata.
  defp prepare_map_references(schema) do
    messages =
      Map.new(schema.messages, fn {fqn, msg} ->
        {fqn, prepare_message_map_references(schema, msg)}
      end)

    Map.put(schema, :messages, messages)
  end

  defp prepare_message_map_references(schema, msg) do
    fields_by_name =
      Map.new(msg.fields_by_name, fn {name, field} ->
        {name, prepare_map_reference(field, schema)}
      end)

    extensions_by_name =
      Map.new(msg.extensions_by_name, fn {name, field} ->
        {name, prepare_map_reference(field, schema)}
      end)

    msg
    |> Map.put(:fields_by_name, fields_by_name)
    |> Map.put(:extensions_by_name, extensions_by_name)
    |> prepare_message_runtime_info()
  end

  defp prepare_map_reference(%{cardinality: :map, type_name: type_name} = field, schema) do
    %{map_entry: true, fields_by_name: fields_by_name} = Map.fetch!(schema.messages, type_name)

    field
    |> Map.put(:map_entry, Map.fetch!(schema.messages, type_name))
    |> Map.put(:map_key, Map.fetch!(fields_by_name, :key))
    |> Map.put(:map_value, Map.fetch!(fields_by_name, :value))
  end

  defp prepare_map_reference(field, _schema), do: field

  defp prepare_message_runtime_info(%{fields_by_name: fields_by_name, oneofs: oneofs} = msg) do
    extensions_by_name = Map.fetch!(msg, :extensions_by_name)

    msg
    |> Map.put(:fields_by_number, number_index(fields_by_name))
    |> Map.put(:extensions_by_number, number_index(extensions_by_name))
    |> Map.put(:required_fields, required_fields(fields_by_name))
    |> Map.put(:default_fields, default_fields(fields_by_name))
    |> Map.put(:oneofs_by_name, oneofs_by_name(oneofs))
    |> Map.put(:oneof_field_names, oneof_field_names(oneofs))
  end

  defp prepare_field_runtime_info(field) do
    field
    |> Map.put(:tag, Wire.encode_tag(field.number, field.wire_type))
    |> maybe_put_packed_tag()
  end

  defp number_index(fields_by_name) do
    Map.new(fields_by_name, fn {_name, field} -> {field.number, field} end)
  end

  defp required_fields(fields_by_name) do
    fields_by_name
    |> Enum.flat_map(fn {name, field} ->
      if field.presence == :required, do: [{name, field.type}], else: []
    end)
  end

  defp default_fields(fields_by_name) do
    fields_by_name
    |> Enum.sort_by(fn {_name, field} -> field.number end)
    |> Enum.flat_map(fn {_name, field} ->
      if default_field?(field), do: [field], else: []
    end)
  end

  defp oneofs_by_name(oneofs) do
    Map.new(oneofs, fn {_idx, oneof} -> {oneof.name, oneof} end)
  end

  defp oneof_field_names(oneofs) do
    oneofs
    |> Enum.flat_map(fn {_idx, oneof} -> oneof.fields end)
    |> Map.new(&{&1, true})
  end

  defp extensions_from_messages(messages) do
    messages
    |> Enum.flat_map(fn {_fqn, msg} -> msg.extensions_by_name end)
    |> Map.new()
  end

  defp default_field?(%{presence: :oneof}), do: false
  defp default_field?(%{type: :TYPE_MESSAGE, cardinality: :singular}), do: false
  defp default_field?(_field), do: true

  defp maybe_put_packed_tag(%{cardinality: :repeated, type: type, number: number} = field) do
    if Wire.packable_type?(type) do
      Map.put(field, :packed_tag, Wire.encode_tag(number, 2))
    else
      Map.delete(field, :packed_tag)
    end
  end

  defp maybe_put_packed_tag(field), do: Map.delete(field, :packed_tag)
end
