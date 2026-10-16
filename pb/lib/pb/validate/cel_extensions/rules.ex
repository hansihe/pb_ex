defmodule PB.Validate.CELExtensions.Rules do
  @moduledoc false

  @type result :: {:ok, CEL.Value.t()} | {:error, String.t()}

  @spec get_field([CEL.Value.t()], CEL.TypeProvider.t()) :: result
  def get_field([{:message, message, payload}, {:string, field}], {types, state}) do
    with {:ok, field} <- types.find_field(state, message, field),
         {:ok, value} <- types.get_field(state, payload, field) do
      {:ok, value}
    else
      :error -> {:error, "no such field #{inspect(field)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def get_field(_values, _types), do: {:error, "no such overload"}

  @spec unique([CEL.Value.t()], CEL.TypeProvider.t()) :: result
  def unique([{:list, values}], types) do
    {:ok, CEL.Value.bool(unique_values?(values, types))}
  end

  def unique(_values, _types), do: {:error, "no such overload"}

  defp unique_values?([], _types), do: true

  defp unique_values?([value | rest], types),
    do: unique_value?(value, rest, types) and unique_values?(rest, types)

  defp unique_value?(value, rest, types) do
    Enum.all?(rest, fn candidate ->
      not CEL.Runtime.Core.equal?(value, candidate, types)
    end)
  end
end
