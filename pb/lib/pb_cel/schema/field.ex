defmodule PB.CEL.Schema.Field do
  @moduledoc false

  alias CEL.ProtoType
  alias CEL.WellKnownTypes

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

  @spec cel_type(CEL.Message.Schema.schema(), t()) :: {:ok, ProtoType.t()} | {:error, String.t()}
  def cel_type(schema, %{cardinality: :map, map_key: key, map_value: value}) do
    with {:ok, key_type} <- singular_cel_type(schema, key),
         {:ok, value_type} <- singular_cel_type(schema, value) do
      {:ok, ProtoType.map(key_type, value_type)}
    end
  end

  def cel_type(schema, %{cardinality: :repeated} = field) do
    with {:ok, elem_type} <- singular_cel_type(schema, field) do
      {:ok, ProtoType.list(elem_type)}
    end
  end

  def cel_type(schema, field), do: singular_cel_type(schema, field)

  @spec singular_cel_type(CEL.Message.Schema.schema(), t()) ::
          {:ok, ProtoType.t()} | {:error, String.t()}
  def singular_cel_type(_schema, %{type: type}) when signed_int_type?(type),
    do: {:ok, ProtoType.int()}

  def singular_cel_type(_schema, %{type: type}) when unsigned_int_type?(type),
    do: {:ok, ProtoType.uint()}

  def singular_cel_type(_schema, %{type: type}) when float_type?(type),
    do: {:ok, ProtoType.double()}

  def singular_cel_type(_schema, %{type: :TYPE_BOOL}), do: {:ok, ProtoType.bool()}
  def singular_cel_type(_schema, %{type: :TYPE_STRING}), do: {:ok, ProtoType.string()}
  def singular_cel_type(_schema, %{type: :TYPE_BYTES}), do: {:ok, ProtoType.bytes()}

  def singular_cel_type(_schema, %{type: :TYPE_ENUM, type_name: type_name}),
    do: {:ok, ProtoType.message(Atom.to_string(type_name))}

  def singular_cel_type(_schema, %{type: :TYPE_ENUM}), do: {:ok, ProtoType.int()}

  def singular_cel_type(_schema, %{type: type, type_name: type_name})
      when message_type?(type) do
    name = Atom.to_string(type_name)

    case WellKnownTypes.field_type(name) do
      {:ok, type} -> {:ok, type}
      :error -> {:ok, ProtoType.message(name)}
    end
  end

  def singular_cel_type(_schema, %{type: type}) do
    {:error, "unsupported protobuf field type #{inspect(type)}"}
  end
end
