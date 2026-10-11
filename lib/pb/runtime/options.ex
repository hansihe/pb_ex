defmodule PB.Runtime.Options do
  @moduledoc false

  alias PB.Runtime.Errors

  @doc """
  Validates a keyword list whose options are all booleans, returning the list
  unchanged or a `PB.Runtime.Errors` reason for an unknown key, a non-boolean
  value, or something that is not a keyword list.
  """
  @spec validate_booleans(term, [atom]) :: {:ok, keyword} | {:error, term}
  def validate_booleans(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      unknown = Keyword.keys(opts) -- allowed

      cond do
        unknown != [] ->
          {:error, {:unknown_options, unknown}}

        invalid = Enum.find(opts, fn {_key, value} -> not is_boolean(value) end) ->
          {:error, {:invalid_option, elem(invalid, 0), elem(invalid, 1)}}

        true ->
          {:ok, opts}
      end
    else
      {:error, {:invalid_options, Errors.type_of(opts)}}
    end
  end

  def validate_booleans(opts, _allowed), do: {:error, {:invalid_options, Errors.type_of(opts)}}
end
