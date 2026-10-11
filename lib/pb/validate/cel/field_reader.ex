defmodule PB.Validate.CEL.FieldReader do
  @moduledoc false

  # Schema-backed CEL protobuf field reads.
  #
  # Read boundary used by `PB.Validate.CEL.MessageRuntime`. Runtime message
  # storage remains presence-preserving: absent fields stay absent in the stored
  # map. `read/5` materializes protobuf/CEL defaults for absent fields,
  # `present?/5` observes stored presence without materializing, and
  # `read_optional/5` wraps a present field value in `optional.some` while leaving
  # absent fields as `optional.none`.

  alias PB.Validate.CEL.MessageRuntime, as: Message
  alias PB.Validate.CEL.MessageSchema, as: Schema
  alias PB.CEL.Schema.Field
  alias PB.CEL.Value
  alias PB.Runtime.Scalar
  alias PB.UnknownField

  require Field

  @wrapper_fields %{
    "google.protobuf.Int32Value": %{type: :TYPE_INT32, cardinality: :singular},
    "google.protobuf.Int64Value": %{type: :TYPE_INT64, cardinality: :singular},
    "google.protobuf.UInt32Value": %{type: :TYPE_UINT32, cardinality: :singular},
    "google.protobuf.UInt64Value": %{type: :TYPE_UINT64, cardinality: :singular},
    "google.protobuf.FloatValue": %{type: :TYPE_FLOAT, cardinality: :singular},
    "google.protobuf.DoubleValue": %{type: :TYPE_DOUBLE, cardinality: :singular},
    "google.protobuf.BoolValue": %{type: :TYPE_BOOL, cardinality: :singular},
    "google.protobuf.StringValue": %{type: :TYPE_STRING, cardinality: :singular},
    "google.protobuf.BytesValue": %{type: :TYPE_BYTES, cardinality: :singular}
  }

  @extension_key :__extensions__

  @type field_name :: atom()
  @type fields :: map()
  @type message_info :: map()

  @spec fetch(Schema.schema(), message_info(), fields(), field_name(), map()) ::
          {:ok, term()} | :error
  def fetch(schema, msg, fields, field, info) do
    case fetch_entry(schema, msg, fields, field, info) do
      {:ok, {^field, value}} -> {:ok, value}
      {:ok, {_oneof_name, {^field, value}}} -> {:ok, value}
      :error -> :error
    end
  end

  @spec fetch_entry(Schema.schema(), message_info(), fields(), field_name(), map()) ::
          {:ok, {atom(), term()}} | :error
  defp fetch_entry(_schema, msg, fields, field, info) when is_map(fields) and is_atom(field) do
    case Map.fetch(fields, field) do
      {:ok, value} -> {:ok, {field, value}}
      :error -> fetch_oneof_entry(msg, fields, field, info)
    end
  end

  defp fetch_entry(_schema, _msg, _fields, _field, _info), do: :error

  @spec read(Schema.schema(), message_info(), fields(), field_name(), map()) ::
          {:ok, Value.t()} | {:error, term()}
  def read(schema, msg, fields, field, info) do
    case fetch(schema, msg, fields, field, info) do
      {:ok, value} -> Message.field_value(schema, info, value)
      :error -> default_value(schema, info)
    end
  end

  @spec present?(Schema.schema(), message_info(), fields(), field_name(), map()) :: boolean()
  def present?(schema, msg, fields, field, info) do
    case fetch(schema, msg, fields, field, info) do
      {:ok, value} -> set?(info, value)
      :error -> false
    end
  end

  # CEL's `has()`: a repeated or map field is set when non-empty, and a field
  # without presence when it differs from its default, so a stored empty list
  # or zero (as `PB.decode(defaults: true)` writes) is not set.
  defp set?(%{cardinality: :repeated}, value), do: value != []
  defp set?(%{cardinality: :map}, value), do: value != %{}

  defp set?(info, value),
    do: not (Scalar.implicit_presence?(info) and Scalar.default_value?(info, value))

  @doc """
  Reads a proto2 extension value. Resolved extensions are stored under
  `:__extensions__` keyed by fully-qualified name; an absent extension
  materializes its default like a declared field.
  """
  @spec read_extension(Schema.schema(), message_info(), fields(), atom(), map()) ::
          {:ok, Value.t()} | {:error, term()}
  def read_extension(schema, _msg, fields, extension, info) do
    case fetch_extension(fields, extension) do
      {:ok, value} -> Message.field_value(schema, info, value)
      :error -> default_value(schema, info)
    end
  end

  @spec extension_present?(Schema.schema(), message_info(), fields(), atom(), map()) :: boolean()
  def extension_present?(_schema, _msg, fields, extension, _info) do
    match?({:ok, _value}, fetch_extension(fields, extension))
  end

  defp fetch_extension(fields, extension) when is_map(fields) and is_atom(extension) do
    with {:ok, extensions} <- Map.fetch(fields, @extension_key) do
      Map.fetch(extensions, extension)
    end
  end

  defp fetch_extension(_fields, _extension), do: :error

  @spec read_optional(Schema.schema(), message_info(), fields(), field_name(), map()) ::
          {:ok, Value.t()} | {:error, term()}
  def read_optional(schema, msg, fields, field, info) do
    case fetch(schema, msg, fields, field, info) do
      {:ok, value} ->
        if set?(info, value) do
          with {:ok, value} <- Message.field_value(schema, info, value) do
            {:ok, Value.optional_some(value)}
          end
        else
          {:ok, Value.optional_none()}
        end

      :error ->
        {:ok, Value.optional_none()}
    end
  end

  @spec default_value(Schema.schema(), map()) :: {:ok, Value.t()} | {:error, term()}
  def default_value(_schema, %{cardinality: :repeated}), do: {:ok, Value.list([])}
  def default_value(_schema, %{cardinality: :map}), do: {:ok, Value.map(%{})}

  def default_value(_schema, %{
        cardinality: :singular,
        type: type,
        type_name: :"google.protobuf.Any"
      })
      when Field.message_type?(type) do
    {:ok, Value.null()}
  end

  def default_value(_schema, %{cardinality: :singular, type: type, type_name: type_name})
      when Field.message_type?(type) and is_map_key(@wrapper_fields, type_name) do
    {:ok, Value.null()}
  end

  def default_value(schema, %{cardinality: :singular, type: type, type_name: type_name})
      when Field.message_type?(type) do
    Message.from_proto_fields(schema, type_name, %{})
  end

  def default_value(schema, field) do
    field = maybe_enum_field(schema, field)

    case Scalar.default_value(field, []) do
      {:ok, value} -> Message.field_value(schema, field, value)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec raw_fields_for_encode(Schema.schema(), atom(), fields()) :: {:ok, fields()}
  def raw_fields_for_encode(schema, message, fields) when is_atom(message) and is_map(fields) do
    with {:ok, msg} <- Schema.fetch_message(schema, message) do
      encoded =
        msg.fields_by_name
        |> Enum.reduce(%{}, fn {field, info}, acc ->
          case fetch_entry(schema, msg, fields, field, info) do
            {:ok, {key, value}} -> Map.put(acc, key, value)
            :error -> acc
          end
        end)
        |> Map.merge(extra_storage_fields(msg, fields))
        |> maybe_put_unknown_fields(fields)

      {:ok, encoded}
    else
      :error -> {:ok, fields}
    end
  end

  @spec wrapper_field(Schema.schema(), atom()) :: map() | nil
  def wrapper_field(_schema, type_name) when is_atom(type_name),
    do: Map.get(@wrapper_fields, type_name)

  defp fetch_oneof_entry(msg, fields, field, %{presence: :oneof, oneof_index: index}) do
    with %{name: oneof_name} <- msg.oneofs[index],
         {:ok, {^field, _value} = entry} <- Map.fetch(fields, oneof_name) do
      {:ok, {oneof_name, entry}}
    else
      _other -> :error
    end
  end

  defp fetch_oneof_entry(_msg, _fields, _field, _info), do: :error

  defp extra_storage_fields(msg, fields) do
    Map.drop(fields, known_storage_keys(msg))
  end

  defp known_storage_keys(msg) do
    oneof_names = Enum.map(msg.oneofs, fn {_index, oneof} -> oneof.name end)
    [UnknownField.key(), :__message_name__ | Map.keys(msg.fields_by_name) ++ oneof_names]
  end

  defp maybe_put_unknown_fields(encoded, fields) do
    case Map.fetch(fields, UnknownField.key()) do
      {:ok, unknowns} -> Map.put(encoded, UnknownField.key(), unknowns)
      :error -> encoded
    end
  end

  defp maybe_enum_field(_schema, field), do: field
end
