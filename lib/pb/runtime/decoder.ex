defmodule PB.Runtime.Decoder do
  @moduledoc false

  alias PB.Runtime.Codec
  alias PB.Runtime.Decoder.Finalize
  alias PB.Runtime.Decoder.Scan
  alias PB.Runtime.Errors
  alias PB.Runtime.Options
  alias PB.Runtime.Schema, as: RuntimeSchema

  @typedoc "Public runtime decode options accepted by `PB.decode/4`."
  @type opts :: keyword()

  @typedoc "Normalized decode options shared by scan and finalization."
  @type normalized_opts :: Scan.opts()

  @opts [defaults: {:boolean, false}, message_names: {[nil, :root], nil}]

  @typedoc "Decoded public message term."
  @type decoded :: term()

  @spec decode(PB.schema(), PB.Schema.Compiled.message_name(), binary()) ::
          {:ok, decoded()} | {:error, PB.Error.t()}
  @spec decode(PB.schema(), PB.Schema.Compiled.message_name(), binary(), opts()) ::
          {:ok, decoded()} | {:error, PB.Error.t()}
  def decode(schema, message_name, binary, opts \\ []) do
    result =
      with {:ok, opts} <- normalize_opts(opts),
           {:ok, msg} <- RuntimeSchema.fetch_message(schema, message_name),
           :ok <- ensure_binary(binary) do
        with {:ok, acc, <<>>} <- Scan.fields(schema, msg, binary, 0, opts, []),
             {:ok, decoded} <- Finalize.message(acc, msg, schema, opts, []),
             {:ok, decoded} <- root_adapter_from_proto(msg, message_name, decoded, []),
             decoded = maybe_put_root_message_name(decoded, msg, message_name, opts) do
          {:ok, decoded}
        end
      end

    Errors.normalize_result(result, :decode, message_name)
  end

  @spec decode!(PB.schema(), PB.Schema.Compiled.message_name(), binary()) :: decoded()
  @spec decode!(PB.schema(), PB.Schema.Compiled.message_name(), binary(), opts()) ::
          decoded()
  def decode!(schema, message_name, binary, opts \\ []) do
    case decode(schema, message_name, binary, opts) do
      {:ok, decoded} ->
        decoded

      {:error, %{__exception__: true} = error} ->
        raise error
    end
  end

  @spec normalize_opts(term()) :: {:ok, normalized_opts()} | {:error, term()}
  defp normalize_opts(opts), do: Options.validate(opts, @opts)

  @spec ensure_binary(term()) :: :ok | {:error, term()}
  defp ensure_binary(binary) when is_binary(binary), do: :ok
  defp ensure_binary(binary), do: {:error, {:invalid_value, [], :binary, Errors.type_of(binary)}}

  defp maybe_put_root_message_name(
         decoded,
         %{projection: %{adapter: adapter}},
         _message_name,
         _opts
       )
       when not is_nil(adapter),
       do: decoded

  defp maybe_put_root_message_name(decoded, _msg, message_name, %{message_names: :root})
       when is_map(decoded) and not is_struct(decoded) do
    Map.put(decoded, :__message_name__, message_name)
  end

  defp maybe_put_root_message_name(decoded, _msg, _message_name, _opts), do: decoded

  @spec root_adapter_from_proto(
          PB.Schema.Compiled.message(),
          PB.Schema.Compiled.message_name(),
          decoded(),
          Scan.path()
        ) ::
          {:ok, decoded()} | {:error, term()}
  defp root_adapter_from_proto(msg, fqn, value, path) do
    case message_adapter(msg) do
      nil -> {:ok, value}
      adapter -> Codec.adapter_from_proto(adapter, fqn, value, path)
    end
  end

  defp message_adapter(%{projection: %{adapter: adapter}}) when not is_nil(adapter), do: adapter
  defp message_adapter(_msg), do: nil
end
