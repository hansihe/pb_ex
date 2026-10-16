defmodule CEL.Options do
  @moduledoc false

  # Keyword option checks for the CEL entry points, raising `PB.OptionError` as
  # the rest of PB does.

  @typedoc """
  Accepted options, each with its allowed values (`:any`, `:boolean`, `:list`
  for any list, or a list of the values themselves) and default.
  """
  @type spec :: [{atom, {:any | :boolean | :list | [term], term}}]

  @doc """
  Validates a keyword list against `spec`, returning a map of every option in
  the spec (defaults filled in). Raises `PB.OptionError` for an unknown key, a
  value outside the allowed ones, or something that is not a keyword list.
  """
  @spec validate!(term, spec) :: map
  def validate!(opts, spec) do
    case validate(opts, spec) do
      {:ok, opts} -> opts
      {:error, fields} -> raise PB.OptionError, fields
    end
  end

  defp validate(opts, spec) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- Keyword.keys(spec) do
        [] -> collect(opts, spec)
        unknown -> {:error, kind: :unknown_options, options: unknown}
      end
    else
      {:error, kind: :invalid_options, reason: type_of(opts)}
    end
  end

  defp validate(opts, _spec), do: {:error, kind: :invalid_options, reason: type_of(opts)}

  defp collect(opts, spec) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {name, {values, default}}, {:ok, acc} ->
      value = Keyword.get(opts, name, default)

      if allowed?(values, value),
        do: {:cont, {:ok, Map.put(acc, name, value)}},
        else: {:halt, {:error, kind: :invalid_option, option: name, value: value}}
    end)
  end

  defp allowed?(:any, _value), do: true
  defp allowed?(:boolean, value), do: is_boolean(value)
  defp allowed?(:list, value), do: is_list(value)
  defp allowed?(values, value), do: value in values

  defp type_of(value) when is_binary(value), do: :binary
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(value) when is_integer(value), do: :integer
  defp type_of(value) when is_float(value), do: :float
  defp type_of(value) when is_atom(value), do: :atom
  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_map(value) and not is_struct(value), do: :map
  defp type_of(%module{}), do: {:struct, module}
  defp type_of(_value), do: :term
end
