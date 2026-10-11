defmodule PB.Runtime.Options do
  @moduledoc false

  alias PB.Runtime.Errors

  @typedoc """
  Accepted options, each with its allowed values (`:any`, `:boolean`, `:list`
  for any list, or a list of the values themselves) and default.
  """
  @type spec :: [{atom, {:any | :boolean | :list | [term], term}}]

  @doc """
  Validates a keyword list against `spec`, returning a map of every option in
  the spec (defaults filled in) or a `PB.Runtime.Errors` reason for an unknown
  key, a value outside the allowed ones, or something that is not a keyword
  list.
  """
  @spec validate(term, spec) :: {:ok, map} | {:error, term}
  def validate(opts, spec) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- Keyword.keys(spec) do
        [] -> collect(opts, spec)
        unknown -> {:error, {:unknown_options, unknown}}
      end
    else
      {:error, {:invalid_options, Errors.type_of(opts)}}
    end
  end

  def validate(opts, _spec), do: {:error, {:invalid_options, Errors.type_of(opts)}}

  defp collect(opts, spec) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {name, {values, default}}, {:ok, acc} ->
      value = Keyword.get(opts, name, default)

      if allowed?(values, value),
        do: {:cont, {:ok, Map.put(acc, name, value)}},
        else: {:halt, {:error, {:invalid_option, name, value}}}
    end)
  end

  defp allowed?(:any, _value), do: true
  defp allowed?(:boolean, value), do: is_boolean(value)
  defp allowed?(:list, value), do: is_list(value)
  defp allowed?(values, value), do: value in values
end
