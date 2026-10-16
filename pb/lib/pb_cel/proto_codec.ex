defmodule PB.CEL.ProtoCodec do
  @moduledoc false

  # Protobuf codecs for the CEL expression protos (`cel.expr.*`) whose map
  # shapes `CEL.Proto` names, and conversion between `cel.expr.Value` maps and
  # CEL values. `Any` payloads (`object_value`) unpack and pack through the
  # protobuf binding, against an optional schema.

  alias CEL.ProtoType
  alias CEL.Value
  alias PB.CEL.MessageRuntime
  alias PB.CEL.MessageSchema

  @roots [
    parsed_expr: :"cel.expr.ParsedExpr",
    checked_expr: :"cel.expr.CheckedExpr",
    eval_state: :"cel.expr.EvalState",
    expr_value: :"cel.expr.ExprValue",
    value: :"cel.expr.Value"
  ]

  # Reference the bundled main schema directly (it already contains the
  # cel.expr.* closure) instead of embedding a sliced copy. `PB.encode/decode`
  # resolve the module to its embedded compiled schema (O(1)).
  @schema PB.Schema.Main

  for {name, root} <- @roots do
    encode = :"encode_#{name}"
    encode! = :"encode_#{name}!"
    decode = :"decode_#{name}"
    decode! = :"decode_#{name}!"

    @spec unquote(encode)(term) :: {:ok, iodata} | {:error, PB.error()}
    @spec unquote(encode)(term, keyword) :: {:ok, iodata} | {:error, PB.error()}
    def unquote(encode)(data, opts \\ []) do
      PB.encode(data, @schema, unquote(root), opts)
    end

    @spec unquote(encode!)(term) :: iodata
    @spec unquote(encode!)(term, keyword) :: iodata
    def unquote(encode!)(data, opts \\ []) do
      PB.encode!(data, @schema, unquote(root), opts)
    end

    @spec unquote(decode)(binary) :: {:ok, term} | {:error, PB.error()}
    @spec unquote(decode)(binary, keyword) :: {:ok, term} | {:error, PB.error()}
    def unquote(decode)(binary, opts \\ []) do
      PB.decode(binary, @schema, unquote(root), decode_opts(opts))
    end

    @spec unquote(decode!)(binary) :: term
    @spec unquote(decode!)(binary, keyword) :: term
    def unquote(decode!)(binary, opts \\ []) do
      PB.decode!(binary, @schema, unquote(root), decode_opts(opts))
    end
  end

  defp decode_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.put_new(opts, :defaults, true), else: opts
  end

  defp decode_opts(opts), do: opts

  @doc """
  Converts a `cel.expr.ExprValue` or `cel.expr.Value` map into a CEL value.
  `schema` (a schema map or `use PB.Schema` module) is what `Any` payloads
  and type values naming messages or enums resolve against.
  """
  @spec from_expr_value(CEL.Proto.expr_value() | CEL.Proto.value(), PB.schema() | module | nil) ::
          {:ok, Value.t()} | {:error, term}
  def from_expr_value(expr_value, schema \\ nil) do
    do_from_expr_value(expr_value, MessageSchema.normalize(schema))
  end

  @spec from_expr_value!(CEL.Proto.expr_value() | CEL.Proto.value(), PB.schema() | module | nil) ::
          Value.t()
  def from_expr_value!(expr_value, schema \\ nil) do
    case from_expr_value(expr_value, schema) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "cannot decode CEL expr value: #{inspect(reason)}"
    end
  end

  @doc """
  Converts a CEL value into a `cel.expr.ExprValue` map; timestamps and
  durations pack into `Any` payloads.
  """
  @spec to_expr_value(Value.t()) :: {:ok, CEL.Proto.expr_value()} | {:error, term}
  def to_expr_value(value) do
    with {:ok, value} <- to_value(value) do
      {:ok, %{kind: {:value, value}}}
    end
  end

  @spec to_expr_value!(Value.t()) :: CEL.Proto.expr_value()
  def to_expr_value!(value) do
    case to_expr_value(value) do
      {:ok, expr_value} -> expr_value
      {:error, reason} -> raise ArgumentError, "cannot encode CEL expr value: #{inspect(reason)}"
    end
  end

  defp do_from_expr_value(%{kind: {:value, value}}, schema), do: do_from_expr_value(value, schema)
  defp do_from_expr_value(%{kind: {:error, _error}}, _schema), do: {:error, :expr_error}
  defp do_from_expr_value(%{kind: {:unknown, _unknown}}, _schema), do: {:error, :expr_unknown}
  defp do_from_expr_value(%{kind: {:null_value, :NULL_VALUE}}, _schema), do: {:ok, Value.null()}
  defp do_from_expr_value(%{kind: {:bool_value, value}}, _schema), do: {:ok, Value.bool(value)}
  defp do_from_expr_value(%{kind: {:int64_value, value}}, _schema), do: {:ok, Value.int(value)}
  defp do_from_expr_value(%{kind: {:uint64_value, value}}, _schema), do: {:ok, Value.uint(value)}

  defp do_from_expr_value(%{kind: {:double_value, value}}, _schema)
       when is_float(value) or value in [:nan, :infinity, :negative_infinity] do
    {:ok, Value.double(value)}
  end

  defp do_from_expr_value(%{kind: {:string_value, value}}, _schema),
    do: {:ok, Value.string(value)}

  defp do_from_expr_value(%{kind: {:bytes_value, value}}, _schema), do: {:ok, Value.bytes(value)}

  defp do_from_expr_value(%{kind: {:enum_value, enum}}, _schema) do
    {:ok, Value.enum(Map.fetch!(enum, :type), Map.get(enum, :value, 0))}
  end

  defp do_from_expr_value(%{kind: {:object_value, object}}, schema) do
    MessageRuntime.from_any(schema, Map.fetch!(object, :type_url), Map.get(object, :value, ""))
  end

  defp do_from_expr_value(%{kind: {:list_value, list}}, schema) do
    with {:ok, values} <-
           map_while_ok(Map.get(list, :values, []), &do_from_expr_value(&1, schema)) do
      {:ok, Value.list(values)}
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
      {:ok, entries} -> {:ok, Value.map(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_from_expr_value(%{kind: {:type_value, type_name}}, schema) when is_binary(type_name) do
    case ProtoType.denotation(type_name) do
      {:ok, type} -> {:ok, {:type, type}}
      :error -> schema_type_value(schema, type_name)
    end
  end

  defp do_from_expr_value(%{kind: {kind, _value}}, _schema),
    do: {:error, {:unsupported_value_kind, kind}}

  defp schema_type_value(schema, type_name) do
    with :error <- MessageSchema.resolve_message(schema, type_name),
         :error <- MessageSchema.resolve_enum(schema, type_name) do
      {:error, {:unsupported_type_value, type_name}}
    else
      {:ok, name} -> {:ok, {:type, ProtoType.message(Atom.to_string(name))}}
    end
  end

  defp to_value(:null), do: {:ok, %{kind: {:null_value, :NULL_VALUE}}}
  defp to_value({:bool, value}), do: {:ok, %{kind: {:bool_value, value}}}
  defp to_value({:int, value}), do: {:ok, %{kind: {:int64_value, value}}}
  defp to_value({:uint, value}), do: {:ok, %{kind: {:uint64_value, value}}}
  defp to_value({:double, value}), do: {:ok, %{kind: {:double_value, value}}}
  defp to_value({:string, value}), do: {:ok, %{kind: {:string_value, value}}}
  defp to_value({:bytes, value}), do: {:ok, %{kind: {:bytes_value, value}}}

  defp to_value({kind, _ns} = value) when kind in [:timestamp, :duration] do
    with {:ok, object} <- MessageRuntime.to_any(nil, value) do
      {:ok, %{kind: {:object_value, object}}}
    end
  end

  defp to_value({:enum, type, value}),
    do: {:ok, %{kind: {:enum_value, %{type: to_string(type), value: value}}}}

  defp to_value({:object, type_url, value}),
    do: {:ok, %{kind: {:object_value, %{type_url: type_url, value: value}}}}

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

  defp to_value({:type, _type} = value), do: {:ok, %{kind: {:type_value, Value.type_name(value)}}}

  defp to_value({:message, _name, _fields}), do: {:error, :message_value_encoding_not_supported}
  defp to_value({:optional, _optional}), do: {:error, :optional_value_encoding_not_supported}

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
end
