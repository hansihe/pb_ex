defmodule PB.CEL.WellKnownTypes do
  @moduledoc false

  alias PB.CEL.Type
  alias PB.CEL.Value
  alias PB.CEL.Runtime.Time
  alias PB.WellKnownTypes.Codec, as: WKTCodec
  alias PB.WellKnownTypes.Time, as: WKTTime
  alias PB.Wire

  @type_url_prefix PB.WellKnownTypes.Any.default_prefix()
  @timestamp_type "google.protobuf.Timestamp"
  @duration_type "google.protobuf.Duration"
  @timestamp_type_url @type_url_prefix <> @timestamp_type
  @duration_type_url @type_url_prefix <> @duration_type

  @wrapper_types %{
    "google.protobuf.Int32Value" => :int,
    "google.protobuf.Int64Value" => :int,
    "google.protobuf.UInt32Value" => :uint,
    "google.protobuf.UInt64Value" => :uint,
    "google.protobuf.FloatValue" => :double,
    "google.protobuf.DoubleValue" => :double,
    "google.protobuf.BoolValue" => :bool,
    "google.protobuf.StringValue" => :string,
    "google.protobuf.BytesValue" => :bytes
  }

  @wrapper_defaults %{
    "google.protobuf.Int32Value" => {:int, 0},
    "google.protobuf.Int64Value" => {:int, 0},
    "google.protobuf.UInt32Value" => {:uint, 0},
    "google.protobuf.UInt64Value" => {:uint, 0},
    "google.protobuf.FloatValue" => {:double, 0.0},
    "google.protobuf.DoubleValue" => {:double, 0.0},
    "google.protobuf.BoolValue" => {:bool, false},
    "google.protobuf.StringValue" => {:string, ""},
    "google.protobuf.BytesValue" => {:bytes, ""}
  }

  @literal_messages MapSet.new(
                      Map.keys(@wrapper_types) ++
                        [
                          "google.protobuf.Any",
                          "google.protobuf.ListValue",
                          "google.protobuf.Struct",
                          "google.protobuf.Value"
                        ]
                    )

  @spec literal_message?(String.t()) :: boolean
  def literal_message?(name) when is_binary(name), do: MapSet.member?(@literal_messages, name)

  @spec field_type(String.t()) :: {:ok, Type.t()} | :error
  def field_type(name) when is_binary(name) do
    cond do
      wrapper_type = @wrapper_types[name] ->
        {:ok, wrapper_field_type(wrapper_type)}

      name == @timestamp_type ->
        {:ok, Type.timestamp()}

      name == @duration_type ->
        {:ok, Type.duration()}

      name == "google.protobuf.Any" ->
        {:ok, Type.dyn()}

      name == "google.protobuf.ListValue" ->
        {:ok, Type.list(Type.dyn())}

      name == "google.protobuf.Struct" ->
        {:ok, Type.map(Type.string(), Type.dyn())}

      name == "google.protobuf.Value" ->
        {:ok, Type.dyn()}

      true ->
        :error
    end
  end

  @spec literal_type(String.t(), %{String.t() => Type.t()}) :: {:ok, Type.t()} | :error
  def literal_type(message_name, fields) do
    cond do
      wrapper_type = @wrapper_types[message_name] ->
        {:ok, wrapper_literal_type(wrapper_type)}

      message_name == "google.protobuf.ListValue" ->
        {:ok, Map.get(fields, "values", Type.list(Type.dyn()))}

      message_name == "google.protobuf.Struct" ->
        {:ok, Map.get(fields, "fields", Type.map(Type.string(), Type.dyn()))}

      message_name == "google.protobuf.Value" ->
        {:ok, value_literal_type(fields)}

      true ->
        :error
    end
  end

  @spec literal_value(String.t(), %{String.t() => Value.t()}) ::
          {:ok, Value.t()} | {:error, String.t()} | :error
  def literal_value(message_name, fields) do
    cond do
      Map.has_key?(@wrapper_defaults, message_name) ->
        value =
          fields
          |> Map.get("value", Map.fetch!(@wrapper_defaults, message_name))
          |> maybe_float32_wrapper(message_name)

        {:ok, value}

      message_name == "google.protobuf.ListValue" ->
        {:ok, Map.get(fields, "values", Value.list([]))}

      message_name == "google.protobuf.Struct" ->
        {:ok, Map.get(fields, "fields", Value.map(%{}))}

      message_name == "google.protobuf.Value" ->
        {:ok, value_literal_value(fields)}

      message_name == "google.protobuf.Any" ->
        any_literal_value(fields)

      true ->
        :error
    end
  end

  @spec object_value(String.t(), binary) :: {:ok, Value.t()} | {:error, term}
  def object_value(@timestamp_type_url, value) when is_binary(value) do
    with {:ok, message} <- WKTCodec.decode_timestamp(value) do
      WKTTime.from_proto_timestamp(message)
    end
  end

  def object_value(@duration_type_url, value) when is_binary(value) do
    with {:ok, message} <- WKTCodec.decode_duration(value),
         {:ok, {:duration, ns}} <- WKTTime.from_proto_duration(message),
         true <- Time.duration_ns?(ns) do
      {:ok, Value.duration(ns)}
    else
      false -> {:error, :duration_out_of_range}
      {:error, reason} -> {:error, reason}
    end
  end

  def object_value(type_url, value) when is_binary(type_url) and is_binary(value) do
    {:ok, Value.object(type_url, value)}
  end

  @spec to_object_value(Value.t()) :: {:ok, map} | {:error, term}
  def to_object_value({:timestamp, _ns} = value) do
    with {:ok, message} <- WKTTime.to_proto_timestamp(value),
         {:ok, iodata} <- WKTCodec.encode_timestamp(message) do
      {:ok, %{type_url: @timestamp_type_url, value: IO.iodata_to_binary(iodata)}}
    end
  end

  def to_object_value({:duration, _ns} = value) do
    with {:ok, message} <- WKTTime.to_proto_duration(value),
         {:ok, iodata} <- WKTCodec.encode_duration(message) do
      {:ok, %{type_url: @duration_type_url, value: IO.iodata_to_binary(iodata)}}
    end
  end

  @spec type_denotation(String.t()) :: {:ok, Type.t()} | :error
  def type_denotation(name) when is_binary(name) do
    case name do
      @timestamp_type -> {:ok, Type.timestamp()}
      @duration_type -> {:ok, Type.duration()}
      _other -> :error
    end
  end

  @spec type_url_name(String.t()) :: String.t()
  def type_url_name(@type_url_prefix <> name), do: name
  def type_url_name(type_url), do: type_url

  defp wrapper_field_type(:int), do: Type.wrapper(:INT64)
  defp wrapper_field_type(:uint), do: Type.wrapper(:UINT64)
  defp wrapper_field_type(:double), do: Type.wrapper(:DOUBLE)
  defp wrapper_field_type(:bool), do: Type.wrapper(:BOOL)
  defp wrapper_field_type(:string), do: Type.wrapper(:STRING)
  defp wrapper_field_type(:bytes), do: Type.wrapper(:BYTES)

  defp wrapper_literal_type(:int), do: Type.int()
  defp wrapper_literal_type(:uint), do: Type.uint()
  defp wrapper_literal_type(:double), do: Type.double()
  defp wrapper_literal_type(:bool), do: Type.bool()
  defp wrapper_literal_type(:string), do: Type.string()
  defp wrapper_literal_type(:bytes), do: Type.bytes()

  defp value_literal_type(fields) do
    cond do
      Map.has_key?(fields, "null_value") -> Type.null()
      Map.has_key?(fields, "number_value") -> Type.double()
      Map.has_key?(fields, "string_value") -> Type.string()
      Map.has_key?(fields, "bool_value") -> Type.bool()
      Map.has_key?(fields, "struct_value") -> Map.fetch!(fields, "struct_value")
      Map.has_key?(fields, "list_value") -> Map.fetch!(fields, "list_value")
      true -> Type.null()
    end
  end

  defp value_literal_value(fields) do
    cond do
      Map.has_key?(fields, "null_value") -> Value.null()
      Map.has_key?(fields, "number_value") -> Map.fetch!(fields, "number_value")
      Map.has_key?(fields, "string_value") -> Map.fetch!(fields, "string_value")
      Map.has_key?(fields, "bool_value") -> Map.fetch!(fields, "bool_value")
      Map.has_key?(fields, "struct_value") -> Map.fetch!(fields, "struct_value")
      Map.has_key?(fields, "list_value") -> Map.fetch!(fields, "list_value")
      true -> Value.null()
    end
  end

  defp any_literal_value(fields) when fields == %{}, do: {:error, "conversion error"}

  defp any_literal_value(fields) do
    type_url =
      case Map.get(fields, "type_url", Value.string("")) do
        {:string, value} -> value
        _other -> ""
      end

    value =
      case Map.get(fields, "value", Value.bytes("")) do
        {:bytes, value} -> value
        _other -> ""
      end

    {:ok, Value.object(type_url, value)}
  end

  defp maybe_float32_wrapper({:double, value}, "google.protobuf.FloatValue")
       when is_float(value),
       do: value |> Wire.encode_float32() |> Wire.decode_float32() |> Value.double()

  defp maybe_float32_wrapper(value, _message_name), do: value
end
