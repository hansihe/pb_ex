defmodule PB.CEL.WellKnownTypes do
  @moduledoc false

  alias PB.CEL.ProtoType
  alias PB.CEL.Value
  alias PB.CEL.Runtime.Time
  alias PB.WellKnownTypes.Any
  alias PB.WellKnownTypes.Codec, as: WKTCodec
  alias PB.WellKnownTypes.Time, as: WKTTime
  alias PB.Wire

  @timestamp_type "google.protobuf.Timestamp"
  @duration_type "google.protobuf.Duration"
  @timestamp_type_url Any.type_url(@timestamp_type)
  @duration_type_url Any.type_url(@duration_type)

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

  @spec field_type(String.t()) :: {:ok, ProtoType.t()} | :error
  def field_type(name) when is_binary(name) do
    cond do
      wrapper_type = @wrapper_types[name] ->
        {:ok, wrapper_field_type(wrapper_type)}

      name == @timestamp_type ->
        {:ok, ProtoType.timestamp()}

      name == @duration_type ->
        {:ok, ProtoType.duration()}

      name == "google.protobuf.Any" ->
        {:ok, ProtoType.dyn()}

      name == "google.protobuf.ListValue" ->
        {:ok, ProtoType.list(ProtoType.dyn())}

      name == "google.protobuf.Struct" ->
        {:ok, ProtoType.map(ProtoType.string(), ProtoType.dyn())}

      name == "google.protobuf.Value" ->
        {:ok, ProtoType.dyn()}

      true ->
        :error
    end
  end

  @spec literal_type(String.t(), %{String.t() => ProtoType.t()}) :: {:ok, ProtoType.t()} | :error
  def literal_type(message_name, fields) do
    cond do
      wrapper_type = @wrapper_types[message_name] ->
        {:ok, wrapper_literal_type(wrapper_type)}

      message_name == "google.protobuf.ListValue" ->
        {:ok, Map.get(fields, "values", ProtoType.list(ProtoType.dyn()))}

      message_name == "google.protobuf.Struct" ->
        {:ok, Map.get(fields, "fields", ProtoType.map(ProtoType.string(), ProtoType.dyn()))}

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
  def object_value(type_url, value) when is_binary(type_url) and is_binary(value),
    do: object_value(type_url_name(type_url), type_url, value)

  defp object_value(@timestamp_type, _type_url, value) do
    with {:ok, message} <- WKTCodec.decode_timestamp(value) do
      WKTTime.from_proto_timestamp(message)
    end
  end

  defp object_value(@duration_type, _type_url, value) do
    with {:ok, message} <- WKTCodec.decode_duration(value),
         {:ok, {:duration, ns}} <- WKTTime.from_proto_duration(message),
         true <- Time.duration_ns?(ns) do
      {:ok, Value.duration(ns)}
    else
      false -> {:error, :duration_out_of_range}
      {:error, reason} -> {:error, reason}
    end
  end

  defp object_value(_name, type_url, value), do: {:ok, Value.object(type_url, value)}

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

  @spec type_denotation(String.t()) :: {:ok, ProtoType.t()} | :error
  def type_denotation(name) when is_binary(name) do
    case name do
      @timestamp_type -> {:ok, ProtoType.timestamp()}
      @duration_type -> {:ok, ProtoType.duration()}
      _other -> :error
    end
  end

  # Any host is accepted: the last path segment names the message, as for
  # ProtoJSON and Go's resolvers.
  @spec type_url_name(String.t()) :: String.t()
  def type_url_name(type_url) do
    case Any.split_type_url(type_url) do
      {:ok, _prefix, name} -> name
      :error -> type_url
    end
  end

  defp wrapper_field_type(:int), do: ProtoType.wrapper(:INT64)
  defp wrapper_field_type(:uint), do: ProtoType.wrapper(:UINT64)
  defp wrapper_field_type(:double), do: ProtoType.wrapper(:DOUBLE)
  defp wrapper_field_type(:bool), do: ProtoType.wrapper(:BOOL)
  defp wrapper_field_type(:string), do: ProtoType.wrapper(:STRING)
  defp wrapper_field_type(:bytes), do: ProtoType.wrapper(:BYTES)

  defp wrapper_literal_type(:int), do: ProtoType.int()
  defp wrapper_literal_type(:uint), do: ProtoType.uint()
  defp wrapper_literal_type(:double), do: ProtoType.double()
  defp wrapper_literal_type(:bool), do: ProtoType.bool()
  defp wrapper_literal_type(:string), do: ProtoType.string()
  defp wrapper_literal_type(:bytes), do: ProtoType.bytes()

  defp value_literal_type(fields) do
    cond do
      Map.has_key?(fields, "null_value") -> ProtoType.null()
      Map.has_key?(fields, "number_value") -> ProtoType.double()
      Map.has_key?(fields, "string_value") -> ProtoType.string()
      Map.has_key?(fields, "bool_value") -> ProtoType.bool()
      Map.has_key?(fields, "struct_value") -> Map.fetch!(fields, "struct_value")
      Map.has_key?(fields, "list_value") -> Map.fetch!(fields, "list_value")
      true -> ProtoType.null()
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
