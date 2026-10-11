defmodule PB.CEL.Value do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Runtime CEL values.
  #
  # Values are tagged to preserve CEL distinctions that plain Elixir terms would
  # erase, most importantly `int` versus `uint` and `string` versus `bytes`.
  @moduledoc false

  alias PB.CEL.Checker.Types, as: CType
  alias PB.CEL.Proto
  alias PB.CEL.Runtime.NoMessageRuntime
  alias PB.CEL.Runtime.NoMessageSchema
  alias PB.CEL.ProtoType
  alias PB.CEL.WellKnownTypes
  alias PB.WellKnownTypes.Time, as: WKTTime

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
          | PB.WellKnownTypes.timestamp()
          | PB.WellKnownTypes.duration()
          | {:enum, String.t(), integer}
          | {:object, String.t(), binary}
          | {:list, [t]}
          | {:map, %{t => t}}
          | {:message, String.t() | atom(), %{(String.t() | atom()) => t}}
          | {:optional, :none | {:some, t}}
          | {:type, ProtoType.t() | CType.t()}

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
  def timestamp(value) when is_integer(value), do: WKTTime.timestamp(value)

  @spec duration(integer) :: t
  def duration(value) when is_integer(value), do: WKTTime.duration(value)

  @spec enum(String.t(), integer) :: t
  def enum(type, value) when is_binary(type) and is_integer(value), do: {:enum, type, value}

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

  @spec from_constant(map) :: t
  def from_constant(%{constant_kind: {:null_value, :NULL_VALUE}}), do: null()
  def from_constant(%{constant_kind: {:bool_value, value}}), do: bool(value)
  def from_constant(%{constant_kind: {:int64_value, value}}), do: int(value)
  def from_constant(%{constant_kind: {:uint64_value, value}}), do: uint(value)
  def from_constant(%{constant_kind: {:double_value, value}}), do: double(value)
  def from_constant(%{constant_kind: {:string_value, value}}), do: string(value)
  def from_constant(%{constant_kind: {:bytes_value, value}}), do: bytes(value)

  @spec from_expr_value(Proto.expr_value() | Proto.value()) :: {:ok, t} | {:error, term}
  def from_expr_value(expr_value), do: from_expr_value(expr_value, [])

  @spec from_expr_value(Proto.expr_value() | Proto.value(), keyword) :: {:ok, t} | {:error, term}
  def from_expr_value(expr_value, opts) when is_list(opts) do
    message_schema = Keyword.get(opts, :message_schema, NoMessageSchema)
    message_runtime = Keyword.get(opts, :message_runtime, NoMessageRuntime)
    schema = opts |> Keyword.get(:schema) |> message_schema.normalize()

    do_from_expr_value(expr_value, {message_schema, message_runtime, schema})
  end

  defp do_from_expr_value(%{kind: {:value, value}}, schema), do: do_from_expr_value(value, schema)
  defp do_from_expr_value(%{kind: {:error, _error}}, _schema), do: {:error, :expr_error}
  defp do_from_expr_value(%{kind: {:unknown, _unknown}}, _schema), do: {:error, :expr_unknown}
  defp do_from_expr_value(%{kind: {:null_value, :NULL_VALUE}}, _schema), do: {:ok, null()}
  defp do_from_expr_value(%{kind: {:bool_value, value}}, _schema), do: {:ok, bool(value)}
  defp do_from_expr_value(%{kind: {:int64_value, value}}, _schema), do: {:ok, int(value)}
  defp do_from_expr_value(%{kind: {:uint64_value, value}}, _schema), do: {:ok, uint(value)}

  defp do_from_expr_value(%{kind: {:double_value, value}}, _schema)
       when is_float(value) or value in [:nan, :infinity, :negative_infinity] do
    {:ok, double(value)}
  end

  defp do_from_expr_value(%{kind: {:string_value, value}}, _schema), do: {:ok, string(value)}
  defp do_from_expr_value(%{kind: {:bytes_value, value}}, _schema), do: {:ok, bytes(value)}

  defp do_from_expr_value(%{kind: {:enum_value, enum}}, _schema) do
    {:ok, enum(Map.fetch!(enum, :type), Map.get(enum, :value, 0))}
  end

  defp do_from_expr_value(%{kind: {:object_value, object}}, schema) do
    type_url = Map.fetch!(object, :type_url)
    value = Map.get(object, :value, "")

    case WellKnownTypes.object_value(type_url, value) do
      {:ok, {:object, ^type_url, ^value}} ->
        schema_object_value(schema, type_url, value)

      result ->
        result
    end
  end

  defp do_from_expr_value(%{kind: {:list_value, list}}, schema) do
    with {:ok, values} <-
           map_while_ok(Map.get(list, :values, []), &do_from_expr_value(&1, schema)) do
      {:ok, list(values)}
    end
  end

  defp do_from_expr_value(%{kind: {:map_value, map}}, schema) do
    map
    |> Map.get(:entries, [])
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, key} <- do_from_expr_value(entry.key, schema),
           {:ok, value} <- do_from_expr_value(entry.value, schema) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, map(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_from_expr_value(%{kind: {:type_value, type_name}}, schema) when is_binary(type_name) do
    case ProtoType.denotation(type_name) do
      {:ok, type} ->
        {:ok, {:type, type}}

      :error ->
        schema_type_value(schema, type_name)
    end
  end

  defp do_from_expr_value(%{kind: {kind, _value}}, _schema),
    do: {:error, {:unsupported_value_kind, kind}}

  @spec from_expr_value!(Proto.expr_value() | Proto.value()) :: t
  @spec from_expr_value!(Proto.expr_value() | Proto.value(), keyword) :: t
  def from_expr_value!(expr_value, opts \\ []) do
    case from_expr_value(expr_value, opts) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "cannot decode CEL expr value: #{inspect(reason)}"
    end
  end

  defp schema_object_value({_message_schema, _message_runtime, nil}, type_url, value),
    do: {:ok, object(type_url, value)}

  defp schema_object_value({message_schema, message_runtime, schema}, type_url, value) do
    type_name = WellKnownTypes.type_url_name(type_url)

    case message_schema.resolve_message(schema, type_name) do
      {:ok, message} ->
        # Unpacking an `Any` needs both the wire codec (foundation) and the
        # injected message runtime, so alternate proto backends route through
        # their configured provider rather than a hardwired default.
        with {:ok, decoded} <- PB.decode(value, schema, message),
             {:ok, value} <- message_runtime.from_decoded(schema, message, decoded) do
          {:ok, value}
        else
          {:error, reason} -> {:error, {:object_decode_error, message, reason}}
        end

      :error ->
        {:ok, object(type_url, value)}
    end
  end

  defp schema_type_value({_message_schema, _message_runtime, nil}, type_name),
    do: {:error, {:unsupported_type_value, type_name}}

  defp schema_type_value({message_schema, _message_runtime, schema}, type_name) do
    cond do
      match?({:ok, _message}, message_schema.resolve_message(schema, type_name)) ->
        {:ok, message} = message_schema.resolve_message(schema, type_name)
        {:ok, {:type, ProtoType.message(Atom.to_string(message))}}

      match?({:ok, _enum}, message_schema.resolve_enum(schema, type_name)) ->
        {:ok, enum} = message_schema.resolve_enum(schema, type_name)
        {:ok, {:type, ProtoType.message(Atom.to_string(enum))}}

      true ->
        {:error, {:unsupported_type_value, type_name}}
    end
  end

  @spec to_expr_value(t) :: {:ok, Proto.expr_value()} | {:error, term}
  def to_expr_value(value) when is_value(value) do
    with {:ok, value} <- to_value(value) do
      {:ok, %{kind: {:value, value}}}
    end
  end

  @spec to_expr_value!(t) :: Proto.expr_value()
  def to_expr_value!(value) do
    case to_expr_value(value) do
      {:ok, expr_value} -> expr_value
      {:error, reason} -> raise ArgumentError, "cannot encode CEL expr value: #{inspect(reason)}"
    end
  end

  @spec coerce(term, PB.CEL.Type.t() | CType.t() | ProtoType.t()) ::
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

    if CType.type_kind(type) == :null or CType.dyn?(type),
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
        value |> DateTime.to_unix(:nanosecond) |> PB.CEL.Runtime.Time.timestamp()

      type == CType.timestamp() and is_map(value) ->
        time_message(value, type, &WKTTime.from_proto_timestamp/1)

      type == CType.duration() and is_map(value) ->
        time_message(value, type, &WKTTime.from_proto_duration/1)

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
  defp time_message(value, type, from_proto) do
    with [] <- Map.keys(value) -- [:seconds, :nanos],
         {:ok, time} <- from_proto.(value) do
      {:ok, time}
    else
      _invalid -> type_error(value, type)
    end
  end

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

  @spec type_of(t) :: CType.t()
  def type_of(value), do: CType.value_type(value)

  @doc """
  Converts a CEL value into a plain Elixir term, discarding the type tags.

  CEL entry points (`PB.CEL.Program.eval/2`, `eval/3`) return tagged values of
  type `t:t/0` — `{:int, 5}`, `{:string, "x"}`, nested `{:list, …}`/`{:map, …}`
  — so that distinctions plain Elixir would erase (`int` vs `uint`, `string` vs
  `bytes`) survive evaluation. `to_native/1` strips those tags off when you just
  want an ordinary value back; it is the rough inverse of `infer/1`.

  Distinctions with no plain-Elixir counterpart are necessarily lost:

    * `int` and `uint` both become a plain `t:integer/0`.
    * `string` and `bytes` both become a plain `t:binary/0`.
    * an `enum` becomes its integer value.
    * `null` and an empty `optional` both become `nil`.
    * a non-finite `double` stays the atom `:nan`/`:infinity`/`:negative_infinity`,
      since Elixir floats cannot represent those.

  Values that have no native Elixir form pass through unchanged in their
  `t:t/0` shape: `timestamp`/`duration` (already the native well-known-type
  representation — see `PB.WellKnownTypes`), an un-decoded `object` (an `Any`
  that was not resolved against a schema), and a `type` value.

  ## Examples

      iex> PB.CEL.Value.to_native({:int, 5})
      5

      iex> PB.CEL.Value.to_native({:list, [{:int, 1}, {:string, "a"}]})
      [1, "a"]

      iex> PB.CEL.Value.to_native({:map, %{{:string, "k"} => {:bool, true}}})
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

  def to_native({:message, _name, fields}),
    do: Map.new(fields, fn {key, value} -> {key, to_native(value)} end)

  def to_native({:optional, :none}), do: nil
  def to_native({:optional, {:some, value}}), do: to_native(value)
  def to_native({:timestamp, _ns} = value), do: value
  def to_native({:duration, _ns} = value), do: value
  def to_native({:object, _type_url, _value} = value), do: value
  def to_native({:type, _type} = value), do: value

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

  defp to_value(:null), do: {:ok, %{kind: {:null_value, :NULL_VALUE}}}
  defp to_value({:bool, value}), do: {:ok, %{kind: {:bool_value, value}}}
  defp to_value({:int, value}), do: {:ok, %{kind: {:int64_value, value}}}
  defp to_value({:uint, value}), do: {:ok, %{kind: {:uint64_value, value}}}
  defp to_value({:double, value}), do: {:ok, %{kind: {:double_value, value}}}
  defp to_value({:string, value}), do: {:ok, %{kind: {:string_value, value}}}
  defp to_value({:bytes, value}), do: {:ok, %{kind: {:bytes_value, value}}}

  defp to_value({:timestamp, _ns} = value) do
    with {:ok, object} <- WellKnownTypes.to_object_value(value) do
      {:ok, %{kind: {:object_value, object}}}
    end
  end

  defp to_value({:duration, _ns} = value) do
    with {:ok, object} <- WellKnownTypes.to_object_value(value) do
      {:ok, %{kind: {:object_value, object}}}
    end
  end

  defp to_value({:enum, type, value}) do
    {:ok, %{kind: {:enum_value, %{type: type, value: value}}}}
  end

  defp to_value({:object, type_url, value}) do
    {:ok, %{kind: {:object_value, %{type_url: type_url, value: value}}}}
  end

  defp to_value({:list, values}) do
    with {:ok, values} <- map_while_ok(values, &to_value/1) do
      {:ok, %{kind: {:list_value, %{values: values}}}}
    end
  end

  defp to_value({:map, values}) do
    values
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- to_value(key),
           {:ok, value} <- to_value(value) do
        {:cont, {:ok, [%{key: key, value: value} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, %{kind: {:map_value, %{entries: Enum.reverse(entries)}}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_value({:type, type}), do: {:ok, %{kind: {:type_value, type_value_name(type)}}}
  defp to_value({:message, _name, _fields}), do: {:error, :message_value_encoding_not_supported}
  defp to_value({:optional, _optional}), do: {:error, :optional_value_encoding_not_supported}

  defp type_value_name(%{type_kind: {:dyn, %{}}}), do: "dyn"
  defp type_value_name(%{type_kind: {:null, :NULL_VALUE}}), do: "null_type"

  defp type_value_name(%{type_kind: {:primitive, _primitive}} = type),
    do: type |> CType.from_cel() |> CType.format()

  defp type_value_name(%{type_kind: {:type, _type}}), do: "type"
  defp type_value_name(%{type_kind: {:list_type, _list}}), do: "list"
  defp type_value_name(%{type_kind: {:map_type, _map}}), do: "map"
  defp type_value_name(%{type_kind: {:message_type, name}}), do: name
  defp type_value_name(:dyn), do: "dyn"
  defp type_value_name(:null), do: "null_type"
  defp type_value_name({:type, _type}), do: "type"
  defp type_value_name({:list, _elem_type}), do: "list"
  defp type_value_name({:map, _key_type, _value_type}), do: "map"
  defp type_value_name({:message, name}), do: name
  defp type_value_name(type), do: type |> CType.from_input() |> CType.format()
end
