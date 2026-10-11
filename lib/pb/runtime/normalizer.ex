defmodule PB.Runtime.Normalizer do
  @moduledoc false

  alias PB.Error
  alias PB.Runtime.Decoder
  alias PB.Runtime.Encoder
  alias PB.Runtime.Errors
  alias PB.Runtime.Options

  @opts [
    defaults: {:boolean, false},
    message_names: {[nil, :root], nil},
    unknown_fields: {[:error, :ignore], :error}
  ]

  @spec normalize(PB.schema(), PB.Schema.Compiled.message_name(), term(), keyword) ::
          {:ok, term()} | {:error, Error.t()}
  def normalize(schema, message_name, data, opts \\ []) do
    result =
      with {:ok, opts} <- normalize_opts(opts),
           {:ok, iodata} <- Encoder.encode(schema, message_name, data, opts.encode),
           binary = IO.iodata_to_binary(iodata) do
        Decoder.decode(schema, message_name, binary, opts.decode)
      end

    result
    |> normalize_operation()
    |> Errors.normalize_result(:normalize, message_name)
  end

  @spec normalize!(PB.schema(), PB.Schema.Compiled.message_name(), term(), keyword) ::
          term()
  def normalize!(schema, message_name, data, opts \\ []) do
    case normalize(schema, message_name, data, opts) do
      {:ok, value} -> value
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  defp normalize_opts(opts) do
    with {:ok, opts} <- Options.validate(opts, @opts) do
      {:ok,
       %{
         encode: [unknown_fields: opts.unknown_fields],
         decode: [defaults: opts.defaults, message_names: opts.message_names]
       }}
    end
  end

  defp normalize_operation({:error, %{__exception__: true} = error}) do
    {:error, %{error | operation: :normalize}}
  end

  defp normalize_operation(result), do: result
end
