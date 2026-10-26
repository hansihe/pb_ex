defmodule PB.WellKnownTypes.Json do
  @moduledoc false

  # Native adapters for the protobuf JSON value well-known types.
  #
  # These adapters map `google.protobuf.Value`, `google.protobuf.ListValue`, and
  # `google.protobuf.Struct` to JSON-shaped Elixir terms.

  alias PB.Runtime.Errors

  # NOTE (parked, see PRODUCTION.md §4.1): this 2^53 guard is the one WKT
  # validity rule that still lives here rather than in PB.WellKnownTypes.Spec,
  # because it is also the one place the two layers *disagree* — the ProtoJSON
  # backend (PB.JSON.WKT) accepts any number for a Value, this adapter rejects
  # integers a double cannot represent exactly. Reconcile when the frontend
  # unification lands; until then it is deliberately left as-is.
  @safe_integer_min -9_007_199_254_740_991
  @safe_integer_max 9_007_199_254_740_991

  @type safe_integer :: -9_007_199_254_740_991..9_007_199_254_740_991
  @type number_value :: float() | safe_integer()
  @type value :: nil | boolean() | number_value() | binary() | array() | object()
  @type array :: [value()]
  @type object :: %{optional(binary()) => value()}

  @projections [
    {:"google.protobuf.Value",
     [
       adapter: %PB.Adapter{
         to_proto: {__MODULE__, :to_proto_value},
         from_proto: {__MODULE__, :from_proto_value},
         type: quote(do: PB.WellKnownTypes.Json.value())
       }
     ]},
    {:"google.protobuf.ListValue",
     [
       adapter: %PB.Adapter{
         to_proto: {__MODULE__, :to_proto_list_value},
         from_proto: {__MODULE__, :from_proto_list_value},
         type: quote(do: PB.WellKnownTypes.Json.array())
       }
     ]},
    {:"google.protobuf.Struct",
     [
       adapter: %PB.Adapter{
         to_proto: {__MODULE__, :to_proto_struct},
         from_proto: {__MODULE__, :from_proto_struct},
         type: quote(do: PB.WellKnownTypes.Json.object())
       }
     ]}
  ]

  @doc false
  @spec projections() :: [{PB.Schema.Compiled.message_name(), keyword()}]
  def projections, do: @projections

  # These adapters are *one level deep*. Recursion is owned by the runtime
  # engine (wire codec / `PB.Runtime.Frontend`): on decode it converts a
  # message's children to their native form *before* this adapter runs, so a
  # `struct_value`/`list_value`/map entry already holds a native term; on encode
  # it recurses *after* this adapter runs, so we leave child terms native and
  # let the engine turn them back into proto-maps. Error paths for nested terms
  # are likewise built by the engine — these functions only report at their own
  # level.

  @spec to_proto_value(value()) :: {:ok, map()} | {:error, PB.Error.t()}
  def to_proto_value(nil), do: {:ok, %{kind: {:null_value, :NULL_VALUE}}}
  def to_proto_value(value) when is_boolean(value), do: {:ok, %{kind: {:bool_value, value}}}

  def to_proto_value(value) when is_integer(value) do
    if safe_integer?(value) do
      {:ok, %{kind: {:number_value, value}}}
    else
      out_of_range([], @safe_integer_min, @safe_integer_max, value)
    end
  end

  def to_proto_value(value) when is_float(value), do: {:ok, %{kind: {:number_value, value}}}
  def to_proto_value(value) when is_binary(value), do: {:ok, %{kind: {:string_value, value}}}
  def to_proto_value(value) when is_list(value), do: {:ok, %{kind: {:list_value, value}}}

  def to_proto_value(value) when is_map(value) and not is_struct(value),
    do: {:ok, %{kind: {:struct_value, value}}}

  def to_proto_value(value), do: invalid_value([], :json_value, value)

  @spec from_proto_value(map()) :: {:ok, value()} | {:error, PB.Error.t()}
  def from_proto_value(%{kind: {:null_value, value}}) when value in [:NULL_VALUE, 0],
    do: {:ok, nil}

  def from_proto_value(%{kind: {:null_value, value}}), do: invalid_value([], :null_value, value)

  def from_proto_value(%{kind: {:number_value, value}}) when is_number(value), do: {:ok, value}

  def from_proto_value(%{kind: {:number_value, value}}),
    do: invalid_value([], :finite_number, value)

  def from_proto_value(%{kind: {:string_value, value}}) when is_binary(value), do: {:ok, value}
  def from_proto_value(%{kind: {:string_value, value}}), do: invalid_value([], :binary, value)

  def from_proto_value(%{kind: {:bool_value, value}}) when is_boolean(value), do: {:ok, value}
  def from_proto_value(%{kind: {:bool_value, value}}), do: invalid_value([], :boolean, value)

  # struct_value/list_value children are already native (the engine recursed).
  def from_proto_value(%{kind: {:struct_value, value}}), do: {:ok, value}
  def from_proto_value(%{kind: {:list_value, value}}), do: {:ok, value}

  def from_proto_value(%{}), do: {:ok, nil}
  def from_proto_value(value), do: invalid_value([], :protobuf_value_message, value)

  @spec to_proto_list_value(array()) :: {:ok, map()} | {:error, PB.Error.t()}
  def to_proto_list_value(value) when is_list(value), do: {:ok, %{values: value}}
  def to_proto_list_value(value), do: invalid_value([], :json_array, value)

  @spec from_proto_list_value(map()) :: {:ok, array()} | {:error, PB.Error.t()}
  def from_proto_list_value(%{values: values}) when is_list(values), do: {:ok, values}
  def from_proto_list_value(%{}), do: {:ok, []}
  def from_proto_list_value(value), do: invalid_value([], :protobuf_list_value_message, value)

  @spec to_proto_struct(object()) :: {:ok, map()} | {:error, PB.Error.t()}
  def to_proto_struct(object) when is_map(object) and not is_struct(object) do
    with :ok <- ensure_binary_keys(object), do: {:ok, %{fields: object}}
  end

  def to_proto_struct(value), do: invalid_value([], :json_object, value)

  @spec from_proto_struct(map()) :: {:ok, object()} | {:error, PB.Error.t()}
  # Field keys come from a `map<string, Value>`, so they are already binary, and
  # the values are already native (the engine recursed).
  def from_proto_struct(%{fields: fields}) when is_map(fields), do: {:ok, fields}
  def from_proto_struct(%{}), do: {:ok, %{}}
  def from_proto_struct(value), do: invalid_value([], :protobuf_struct_message, value)

  defp ensure_binary_keys(object) do
    Enum.reduce_while(object, :ok, fn {key, _value}, :ok ->
      if is_binary(key) do
        {:cont, :ok}
      else
        {:halt, invalid_value([{:key, key}], :binary_key, key)}
      end
    end)
  end

  defp safe_integer?(value), do: value >= @safe_integer_min and value <= @safe_integer_max

  defp invalid_value(path, expected, value) do
    {:error,
     %PB.ValueError{
       kind: :invalid_value,
       path: path,
       expected: expected,
       got: Errors.type_of(value)
     }}
  end

  defp out_of_range(path, min, max, value) do
    {:error,
     %PB.ValueError{
       kind: :value_out_of_range,
       path: path,
       min: min,
       max: max,
       value: value
     }}
  end
end
