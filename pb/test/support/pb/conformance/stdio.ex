defmodule PB.TestSupport.Conformance.Stdio do
  @moduledoc false

  @spec configure!() :: :ok
  def configure! do
    :io.setopts(:standard_io, encoding: :latin1)
  end

  @spec read_frame() :: {:ok, binary()} | :eof | {:error, term()}
  def read_frame do
    case read_exact(4) do
      {:ok, <<length::little-unsigned-32>>} -> read_exact(length)
      other -> other
    end
  end

  @spec write_frame(binary()) :: :ok | {:error, term()}
  def write_frame(payload) when is_binary(payload) do
    configure!()
    IO.binwrite(:stdio, <<byte_size(payload)::little-unsigned-32, payload::binary>>)
  end

  defp read_exact(length) when is_integer(length) and length >= 0 do
    read_exact(length, [])
  end

  defp read_exact(0, acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

  defp read_exact(length, acc) do
    case IO.binread(:stdio, length) do
      data when is_binary(data) ->
        read_exact(length - byte_size(data), [data | acc])

      :eof when acc == [] ->
        :eof

      :eof ->
        {:error, :unexpected_eof}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
