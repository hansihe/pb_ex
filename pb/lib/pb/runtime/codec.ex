defmodule PB.Runtime.Codec do
  @moduledoc false

  def adapter_to_proto(adapter, fqn, value, path \\ []) do
    call_adapter(adapter, fqn, :to_proto, value, path)
  end

  def adapter_from_proto(adapter, fqn, value, path \\ []) do
    call_adapter(adapter, fqn, :from_proto, value, path)
  end

  defp call_adapter(adapter, fqn, direction, value, path) do
    {module, function} = Map.fetch!(adapter, direction)

    case apply(module, function, [value]) do
      {:ok, value} ->
        {:ok, value}

      {:error, %{__exception__: true} = error} ->
        {:error, PB.Error.prepend_path(error, path)}

      {:error, reason} ->
        {:error, {:adapter_error, fqn, direction, path, reason}}

      other ->
        {:error, {:adapter_error, fqn, direction, path, {:invalid_return, other}}}
    end
  rescue
    exception ->
      {:error, {:adapter_error, fqn, direction, path, exception}}
  end
end
