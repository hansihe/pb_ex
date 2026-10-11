defmodule PB.CEL.ProtoType do
  # CEL types in the generated `cel.expr.Type` map shape, used for type
  # values, `PB.CEL.Checked.to_proto/1` and schema field types. The public
  # shorthand is `PB.CEL.Type`; the checker has its own representation.
  @moduledoc false

  alias PB.CEL.Proto
  alias PB.CEL.WellKnownTypes

  @type t :: Proto.type()
  @type input ::
          t
          | :dyn
          | :null
          | :bool
          | :int
          | :uint
          | :double
          | :string
          | :bytes
          | :type
          | {:list, input}
          | {:map, input, input}
          | {:message, String.t()}
          | {:optional, input}

  @primitive_types %{
    bool: :BOOL,
    int: :INT64,
    uint: :UINT64,
    double: :DOUBLE,
    string: :STRING,
    bytes: :BYTES
  }

  @type_names Map.keys(@primitive_types) ++
                [:dyn, :null, :null_type, :type, :list, :map, :optional_type]

  @spec dyn() :: t
  def dyn, do: oneof(:dyn, %{})

  @spec null() :: t
  def null, do: oneof(:null, :NULL_VALUE)

  @spec bool() :: t
  def bool, do: primitive(:BOOL)

  @spec int() :: t
  def int, do: primitive(:INT64)

  @spec uint() :: t
  def uint, do: primitive(:UINT64)

  @spec double() :: t
  def double, do: primitive(:DOUBLE)

  @spec string() :: t
  def string, do: primitive(:STRING)

  @spec bytes() :: t
  def bytes, do: primitive(:BYTES)

  @spec timestamp() :: t
  def timestamp, do: well_known(:TIMESTAMP)

  @spec duration() :: t
  def duration, do: well_known(:DURATION)

  @spec wrapper(atom) :: t
  def wrapper(kind) when kind in [:BOOL, :INT64, :UINT64, :DOUBLE, :STRING, :BYTES] do
    oneof(:wrapper, kind)
  end

  @spec well_known(atom) :: t
  def well_known(kind) when kind in [:TIMESTAMP, :DURATION], do: oneof(:well_known, kind)

  @spec error() :: t
  def error, do: oneof(:error, %{})

  @spec type(t) :: t
  def type(type \\ dyn()), do: oneof(:type, type)

  @spec list(t) :: t
  def list(elem_type \\ dyn()), do: oneof(:list_type, %{elem_type: elem_type})

  @spec map(t, t) :: t
  def map(key_type \\ dyn(), value_type \\ dyn()) do
    oneof(:map_type, %{key_type: key_type, value_type: value_type})
  end

  @spec message(String.t()) :: t
  def message(name) when is_binary(name), do: oneof(:message_type, name)

  @spec optional(t) :: t
  def optional(value_type), do: abstract("optional_type", [value_type])

  @spec abstract(String.t(), [t]) :: t
  def abstract(name, params) when is_binary(name) and is_list(params) do
    oneof(:abstract_type, %{name: name, parameter_types: params})
  end

  @spec coerce(input) :: t
  def coerce(%{type_kind: {_kind, _value}} = type), do: type
  def coerce(:dyn), do: dyn()
  def coerce(:null), do: null()
  def coerce(:bool), do: bool()
  def coerce(:int), do: int()
  def coerce(:uint), do: uint()
  def coerce(:double), do: double()
  def coerce(:string), do: string()
  def coerce(:bytes), do: bytes()
  def coerce(:type), do: type()
  def coerce({:list, elem_type}), do: list(coerce(elem_type))
  def coerce({:map, key_type, value_type}), do: map(coerce(key_type), coerce(value_type))
  def coerce({:message, name}) when is_binary(name), do: message(name)
  def coerce({:optional, value_type}), do: optional(coerce(value_type))

  @spec denotation(String.t()) :: {:ok, t} | :error
  def denotation(name) when is_binary(name) do
    case WellKnownTypes.type_denotation(name) do
      {:ok, type} ->
        {:ok, type}

      :error ->
        case String.to_existing_atom(name) do
          atom when atom in @type_names -> {:ok, denotation_atom(atom)}
          _other -> :error
        end
    end
  rescue
    ArgumentError -> :error
  end

  defp oneof(kind, value), do: %{type_kind: {kind, value}}

  defp primitive(kind), do: oneof(:primitive, kind)

  defp denotation_atom(:dyn), do: dyn()
  defp denotation_atom(:null), do: null()
  defp denotation_atom(:null_type), do: null()
  defp denotation_atom(:type), do: type()
  defp denotation_atom(:list), do: list(dyn())
  defp denotation_atom(:map), do: map(dyn(), dyn())
  defp denotation_atom(:optional_type), do: optional(dyn())
  defp denotation_atom(atom), do: primitive(Map.fetch!(@primitive_types, atom))
end
