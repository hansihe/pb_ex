defmodule PB.CEL.Schema.Field do
  @moduledoc false

  # CEL types of PB's compiled fields, in `CEL.Type` shorthand. Enum and
  # message types are named by PB's atoms; the well-known types are the CEL
  # types they stand for.

  @signed_int_types [
    :TYPE_INT32,
    :TYPE_INT64,
    :TYPE_SINT32,
    :TYPE_SINT64,
    :TYPE_SFIXED32,
    :TYPE_SFIXED64
  ]

  @unsigned_int_types [:TYPE_UINT32, :TYPE_UINT64, :TYPE_FIXED32, :TYPE_FIXED64]
  @float_types [:TYPE_FLOAT, :TYPE_DOUBLE]
  @message_types [:TYPE_MESSAGE, :TYPE_GROUP]

  @type t :: map()

  defguard signed_int_type?(type) when type in @signed_int_types
  defguard unsigned_int_type?(type) when type in @unsigned_int_types
  defguard float_type?(type) when type in @float_types
  defguard message_type?(type) when type in @message_types

  @well_known_types %{
    "google.protobuf.Timestamp": :timestamp,
    "google.protobuf.Duration": :duration,
    "google.protobuf.Any": :dyn,
    "google.protobuf.Value": :dyn,
    "google.protobuf.ListValue": {:list, :dyn},
    "google.protobuf.Struct": {:map, :string, :dyn},
    "google.protobuf.Int32Value": {:wrapper, :int},
    "google.protobuf.Int64Value": {:wrapper, :int},
    "google.protobuf.UInt32Value": {:wrapper, :uint},
    "google.protobuf.UInt64Value": {:wrapper, :uint},
    "google.protobuf.FloatValue": {:wrapper, :double},
    "google.protobuf.DoubleValue": {:wrapper, :double},
    "google.protobuf.BoolValue": {:wrapper, :bool},
    "google.protobuf.StringValue": {:wrapper, :string},
    "google.protobuf.BytesValue": {:wrapper, :bytes}
  }

  @spec cel_type(PB.schema(), t()) :: {:ok, CEL.Type.t()} | {:error, String.t()}
  def cel_type(schema, %{cardinality: :map, map_key: key, map_value: value}) do
    with {:ok, key_type} <- singular_cel_type(schema, key),
         {:ok, value_type} <- singular_cel_type(schema, value) do
      {:ok, {:map, key_type, value_type}}
    end
  end

  def cel_type(schema, %{cardinality: :repeated} = field) do
    with {:ok, elem_type} <- singular_cel_type(schema, field) do
      {:ok, {:list, elem_type}}
    end
  end

  def cel_type(schema, field), do: singular_cel_type(schema, field)

  @spec singular_cel_type(PB.schema(), t()) :: {:ok, CEL.Type.t()} | {:error, String.t()}
  def singular_cel_type(_schema, %{type: type}) when signed_int_type?(type), do: {:ok, :int}
  def singular_cel_type(_schema, %{type: type}) when unsigned_int_type?(type), do: {:ok, :uint}
  def singular_cel_type(_schema, %{type: type}) when float_type?(type), do: {:ok, :double}
  def singular_cel_type(_schema, %{type: :TYPE_BOOL}), do: {:ok, :bool}
  def singular_cel_type(_schema, %{type: :TYPE_STRING}), do: {:ok, :string}
  def singular_cel_type(_schema, %{type: :TYPE_BYTES}), do: {:ok, :bytes}

  def singular_cel_type(_schema, %{type: :TYPE_ENUM, type_name: type_name}),
    do: {:ok, {:enum, type_name}}

  def singular_cel_type(_schema, %{type: :TYPE_ENUM}), do: {:ok, :int}

  def singular_cel_type(_schema, %{type: type, type_name: type_name})
      when message_type?(type) do
    {:ok, Map.get(@well_known_types, type_name, {:message, type_name})}
  end

  def singular_cel_type(_schema, %{type: type}) do
    {:error, "unsupported protobuf field type #{inspect(type)}"}
  end
end
