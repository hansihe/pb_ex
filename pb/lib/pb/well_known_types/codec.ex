defmodule PB.WellKnownTypes.Codec do
  @moduledoc false

  @roots [
    double_value: :"google.protobuf.DoubleValue",
    float_value: :"google.protobuf.FloatValue",
    int64_value: :"google.protobuf.Int64Value",
    uint64_value: :"google.protobuf.UInt64Value",
    int32_value: :"google.protobuf.Int32Value",
    uint32_value: :"google.protobuf.UInt32Value",
    bool_value: :"google.protobuf.BoolValue",
    string_value: :"google.protobuf.StringValue",
    bytes_value: :"google.protobuf.BytesValue",
    timestamp: :"google.protobuf.Timestamp",
    duration: :"google.protobuf.Duration",
    value: :"google.protobuf.Value",
    list_value: :"google.protobuf.ListValue",
    struct: :"google.protobuf.Struct"
  ]

  # The bundled main schema already contains every well-known type and its
  # reachable closure, so these codecs reference it directly rather than
  # embedding a sliced copy. `PB.encode/decode` accept the schema module and
  # resolve it to the embedded compiled schema (an O(1) module-attribute fetch).
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
end
