defmodule CEL.Value do
  @moduledoc """
  CEL values, as evaluation returns them and as variables can be bound.

  Values are tagged so that CEL's distinctions survive, most importantly `int`
  versus `uint` and `string` versus `bytes`:

  | CEL | Value |
  |-----|-------|
  | `null` | `:null` |
  | `bool`, `int`, `uint`, `double` | `{:bool, true}`, `{:int, -1}`, `{:uint, 1}`, `{:double, 1.5}` (`:nan`, `:infinity` and `:negative_infinity` for the special doubles) |
  | `string`, `bytes` | `{:string, "a"}`, `{:bytes, <<1>>}` |
  | `google.protobuf.Timestamp`, `Duration` | `{:timestamp, unix_nanoseconds}`, `{:duration, nanoseconds}` |
  | `list`, `map` | `{:list, [value]}`, `{:map, %{value => value}}` |
  | a message | `{:message, name, payload}`, its `CEL.TypeProvider`'s name and payload |
  | an enum value | `{:enum, name, number}`, equal to `{:int, number}` |
  | `optional_type` | `{:optional, :none}`, `{:optional, {:some, value}}` |
  | a type | `{:type, _}`; `type_name/1` gives its name, such as `"int"` |

  `to_native/1` turns a value into a plain Elixir term. The constructors
  (`int/1`, `string/1`, ...) build values, for example in a custom function's
  result.
  """

  alias CEL.Checker.Types, as: CType
  alias CEL.ProtoType
  alias CEL.Runtime.Time

  @type special_double :: :nan | :infinity | :negative_infinity
  @type double_value :: float | special_double

  @type t ::
          :null
          | {:bool, boolean}
          | {:int, integer}
          | {:uint, non_neg_integer}
          | {:double, double_value}
          | {:string, String.t()}
          | {:bytes, binary}
          | Time.timestamp()
          | Time.duration()
          | {:enum, CEL.TypeProvider.name(), integer}
          | {:object, String.t(), binary}
          | {:list, [t]}
          | {:map, %{t => t}}
          | {:message, CEL.TypeProvider.name(), CEL.TypeProvider.payload()}
          | {:optional, :none | {:some, t}}
          | {:type, term}

  defguardp is_value(value)
            when value == :null or
                   (is_tuple(value) and tuple_size(value) >= 1 and
                      elem(value, 0) in [
                        :bool,
                        :int,
                        :uint,
                        :double,
                        :string,
                        :bytes,
                        :timestamp,
                        :duration,
                        :enum,
                        :object,
                        :list,
                        :map,
                        :message,
                        :optional,
                        :type
                      ])

  @spec null() :: t
  def null, do: :null

  @spec bool(boolean) :: t
  def bool(value) when is_boolean(value), do: {:bool, value}

  @spec int(integer) :: t
  def int(value) when is_integer(value), do: {:int, value}

  @spec uint(non_neg_integer) :: t
  def uint(value) when is_integer(value) and value >= 0, do: {:uint, value}

  @spec double(double_value) :: t
  def double(value) when value in [:nan, :infinity, :negative_infinity], do: {:double, value}
  def double(value) when is_float(value), do: {:double, value}

  @spec string(String.t()) :: t
  def string(value) when is_binary(value), do: {:string, value}

  @spec bytes(binary) :: t
  def bytes(value) when is_binary(value), do: {:bytes, value}

  @spec timestamp(integer) :: t
  def timestamp(value) when is_integer(value), do: {:timestamp, value}

  @spec duration(integer) :: t
  def duration(value) when is_integer(value), do: {:duration, value}

  @spec enum(CEL.TypeProvider.name(), integer) :: t
  def enum(type, value) when (is_atom(type) or is_binary(type)) and is_integer(value),
    do: {:enum, type, value}

  @spec object(String.t(), binary) :: t
  def object(type_url, value) when is_binary(type_url) and is_binary(value) do
    {:object, type_url, value}
  end

  @spec list([t]) :: t
  def list(values) when is_list(values), do: {:list, values}

  @spec map(%{t => t}) :: t
  def map(values) when is_map(values), do: {:map, values}

  @spec optional_none() :: t
  def optional_none, do: {:optional, :none}

  @spec optional_some(t) :: t
  def optional_some(value), do: {:optional, {:some, value}}

  @doc false
  @spec from_constant(map) :: t
  def from_constant(%{constant_kind: {:null_value, :NULL_VALUE}}), do: null()
  def from_constant(%{constant_kind: {:bool_value, value}}), do: bool(value)
  def from_constant(%{constant_kind: {:int64_value, value}}), do: int(value)
  def from_constant(%{constant_kind: {:uint64_value, value}}), do: uint(value)
  def from_constant(%{constant_kind: {:double_value, value}}), do: double(value)
  def from_constant(%{constant_kind: {:string_value, value}}), do: string(value)
  def from_constant(%{constant_kind: {:bytes_value, value}}), do: bytes(value)

  @doc false
  @spec coerce(term, CEL.Type.t() | CType.t() | ProtoType.t()) ::
          {:ok, t} | {:error, String.t()}
  def coerce(value, type) when is_value(value) do
    type = CType.from_input(type)
    actual = type_of(value)

    if CType.assignable?(type, actual) or CType.well_known_assignable?(type, actual) do
      {:ok, value}
    else
      type_error(value, type)
    end
  end

  def coerce(nil, type) do
    type = CType.from_input(type)

    if CType.type_kind(type) in [:null, :wrapper] or CType.dyn?(type),
      do: {:ok, null()},
      else: type_error(nil, type)
  end

  def coerce(value, type) do
    type = CType.from_input(type)

    cond do
      CType.dyn?(type) ->
        infer(value)

      CType.primitive?(type, :BOOL) and is_boolean(value) ->
        {:ok, bool(value)}

      CType.primitive?(type, :INT64) and is_integer(value) ->
        {:ok, int(value)}

      CType.primitive?(type, :UINT64) and is_integer(value) and value >= 0 ->
        {:ok, uint(value)}

      CType.primitive?(type, :DOUBLE) and is_float(value) ->
        {:ok, double(value)}

      CType.primitive?(type, :STRING) and is_binary(value) ->
        {:ok, string(value)}

      CType.primitive?(type, :BYTES) and is_binary(value) ->
        {:ok, bytes(value)}

      type == CType.timestamp() and is_struct(value, DateTime) ->
        value |> DateTime.to_unix(:nanosecond) |> Time.timestamp()

      type == CType.timestamp() and is_map(value) ->
        time_message(value, type, :timestamp)

      type == CType.duration() and is_map(value) ->
        time_message(value, type, :duration)

      is_list(value) ->
        case CType.list_elem(type) do
          {:ok, elem_type} -> coerce_list(value, elem_type)
          :error -> type_error(value, type)
        end

      is_map(value) ->
        case CType.map_types(type) do
          {:ok, key_type, value_type} -> coerce_map(value, key_type, value_type)
          :error -> type_error(value, type)
        end

      true ->
        type_error(value, type)
    end
  end

  # A `google.protobuf.Timestamp` or `Duration` as PB decodes it,
  # `%{seconds: s, nanos: n}`, with either key absent when zero.
  defp time_message(value, type, kind) do
    with [] <- Map.keys(value) -- [:seconds, :nanos],
         {:ok, time} <- Time.from_proto_map(kind, value) do
      {:ok, time}
    else
      _invalid -> type_error(value, type)
    end
  end

  @doc false
  @spec infer(term) :: {:ok, t} | {:error, String.t()}
  def infer(value) when is_value(value), do: {:ok, value}
  def infer(nil), do: {:ok, null()}
  def infer(value) when is_boolean(value), do: {:ok, bool(value)}
  def infer(value) when is_integer(value), do: {:ok, int(value)}
  def infer(value) when is_float(value), do: {:ok, double(value)}
  def infer(value) when is_binary(value), do: {:ok, string(value)}

  def infer(value) when is_list(value) do
    with {:ok, values} <- map_while_ok(value, &infer/1) do
      {:ok, list(values)}
    end
  end

  def infer(%DateTime{} = value), do: coerce(value, :timestamp)

  def infer(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      with {:ok, key} <- infer(key),
           {:ok, val} <- infer(val) do
        {:cont, {:ok, Map.put(acc, key, val)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, map(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  def infer(value), do: {:error, "cannot convert #{inspect(value)} to a CEL value"}

  @doc false
  @spec type_of(t) :: CType.t()
  def type_of(value), do: CType.value_type(value)

  @doc """
  The name of a type value, such as `type(x)` returns: `"int"`, `"string"`,
  `"null_type"`, `"list"`, `"map"`, `"type"`, `"optional_type"`,
  `"google.protobuf.Timestamp"`, or a message's or enum's full name.

  These are CEL's runtime type names, as in cel-go and cel-cpp: they have no
  parameters, so the type of `[1]` is `"list"`. Type values are equal when
  their names are.

      iex> {:ok, type} = CEL.eval("type([1])")
      iex> CEL.Value.type_name(type)
      "list"
  """
  @spec type_name(t) :: String.t()
  def type_name({:type, type}), do: type_value_name(type)

  @doc """
  Converts a CEL value into a plain Elixir term, discarding the type tags.

  CEL entry points (`CEL.Program.eval/2`, `eval/3`) return tagged values of
  type `t:t/0` — `{:int, 5}`, `{:string, "x"}`, nested `{:list, …}`/`{:map, …}`
  — so that distinctions plain Elixir would erase (`int` vs `uint`, `string` vs
  `bytes`) survive evaluation. `to_native/1` strips those tags off when you just
  want an ordinary value back; it is the rough inverse of `infer/1`.

  Distinctions with no plain-Elixir counterpart are necessarily lost:

    * `int` and `uint` both become a plain `t:integer/0`.
    * `string` and `bytes` both become a plain `t:binary/0`.
    * an `enum` becomes its integer value.
    * a `type` becomes its name, as `type_name/1` gives it.
    * `null` and an empty `optional` both become `nil`.
    * a non-finite `double` stays the atom `:nan`/`:infinity`/`:negative_infinity`,
      since Elixir floats cannot represent those.

  A message becomes its payload, which its `CEL.TypeProvider` owns: for
  `PB.CEL.types/1`, the message's fields. Values that have no native Elixir
  form pass through unchanged in their `t:t/0` shape: `timestamp`/`duration`
  and an un-decoded `object` (an `Any` whose type the provider does not
  know).

  ## Examples

      iex> CEL.Value.to_native({:int, 5})
      5

      iex> CEL.Value.to_native({:list, [{:int, 1}, {:string, "a"}]})
      [1, "a"]

      iex> CEL.Value.to_native({:map, %{{:string, "k"} => {:bool, true}}})
      %{"k" => true}
  """
  @spec to_native(t) :: term
  def to_native(:null), do: nil
  def to_native({:bool, value}), do: value
  def to_native({:int, value}), do: value
  def to_native({:uint, value}), do: value
  def to_native({:double, value}), do: value
  def to_native({:string, value}), do: value
  def to_native({:bytes, value}), do: value
  def to_native({:enum, _type, value}), do: value
  def to_native({:list, values}), do: Enum.map(values, &to_native/1)

  def to_native({:map, values}),
    do: Map.new(values, fn {key, value} -> {to_native(key), to_native(value)} end)

  def to_native({:message, _name, payload}), do: payload

  def to_native({:optional, :none}), do: nil
  def to_native({:optional, {:some, value}}), do: to_native(value)
  def to_native({:timestamp, _ns} = value), do: value
  def to_native({:duration, _ns} = value), do: value
  def to_native({:object, _type_url, _value} = value), do: value
  def to_native({:type, _type} = value), do: type_name(value)

  defp coerce_list(values, elem_type) do
    with {:ok, values} <- map_while_ok(values, &coerce(&1, elem_type)) do
      {:ok, list(values)}
    end
  end

  defp coerce_map(values, key_type, value_type) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- coerce(key, key_type),
           {:ok, value} <- coerce(value, value_type) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, map(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_while_ok(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp type_error(value, type) do
    {:error, "cannot convert #{inspect(value)} to #{CType.format(type)}"}
  end

  defp type_value_name(%{type_kind: {:dyn, %{}}}), do: "dyn"
  defp type_value_name(%{type_kind: {:null, :NULL_VALUE}}), do: "null_type"

  defp type_value_name(%{type_kind: {:primitive, _primitive}} = type),
    do: type |> CType.from_cel() |> CType.format()

  defp type_value_name(%{type_kind: {:wrapper, primitive}}),
    do: type_value_name(%{type_kind: {:primitive, primitive}})

  defp type_value_name(%{type_kind: {:type, _type}}), do: "type"
  defp type_value_name(%{type_kind: {:abstract_type, %{name: name}}}), do: name
  defp type_value_name(%{type_kind: {:list_type, _list}}), do: "list"
  defp type_value_name(%{type_kind: {:map_type, _map}}), do: "map"
  defp type_value_name(%{type_kind: {:message_type, name}}), do: to_string(name)
  defp type_value_name(:dyn), do: "dyn"
  defp type_value_name(:null), do: "null_type"
  defp type_value_name({:type, _type}), do: "type"
  defp type_value_name({:list, _elem_type}), do: "list"
  defp type_value_name({:map, _key_type, _value_type}), do: "map"
  defp type_value_name({:message, name}), do: to_string(name)
  defp type_value_name({:optional, _value_type}), do: "optional_type"
  defp type_value_name({:abstract, name, _params}), do: name
  defp type_value_name(type), do: type |> CType.from_input() |> CType.format()
end
