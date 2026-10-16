defmodule PB.CEL.Runtime.Encoders do
  @moduledoc false

  alias PB.CEL.Value

  @type result :: {:ok, Value.t()} | {:error, String.t()}

  @spec base64_encode([Value.t()]) :: result
  def base64_encode([{:bytes, bytes}]) do
    {:ok, Value.string(Base.encode64(bytes))}
  end

  def base64_encode(_values), do: no_such_overload()

  @spec base64_decode([Value.t()]) :: result
  def base64_decode([{:string, string}]) do
    case decode_base64(string) do
      {:ok, bytes} -> {:ok, Value.bytes(bytes)}
      :error -> {:error, "invalid base64"}
    end
  end

  def base64_decode(_values), do: no_such_overload()

  defp decode_base64(string) do
    with :error <- Base.decode64(string, padding: true),
         :error <- Base.decode64(string, padding: false),
         :error <- Base.url_decode64(string, padding: true) do
      Base.url_decode64(string, padding: false)
    end
  end

  defp no_such_overload, do: {:error, "no such overload"}
end
