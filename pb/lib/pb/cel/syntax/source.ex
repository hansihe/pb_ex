defmodule PB.CEL.Syntax.Source do
  # Positions in CEL source, as `cel.expr.SourceInfo` records them: offsets
  # count code points, and `line_offsets` holds where each line after the
  # first starts, then the source length plus one, as in cel-go and cel-cpp.
  @moduledoc false

  alias PB.CEL.Error

  @spec line_offsets(String.t()) :: [pos_integer]
  def line_offsets(source) when is_binary(source), do: line_offsets(source, 0, [])

  defp line_offsets("", offset, acc), do: Enum.reverse([offset + 1 | acc])

  defp line_offsets(source, offset, acc) do
    {codepoint, rest} = String.next_codepoint(source)
    acc = if codepoint == "\n", do: [offset + 1 | acc], else: acc
    line_offsets(rest, offset + 1, acc)
  end

  @doc """
  The 1-based line and column of `offset`.
  """
  @spec position([pos_integer], non_neg_integer) :: {pos_integer, pos_integer}
  def position(line_offsets, offset) do
    starts = Enum.take_while(line_offsets, &(&1 <= offset))
    {length(starts) + 1, offset - List.last(starts, 0) + 1}
  end

  @doc """
  Sets the error's line and column from its offset.
  """
  @spec locate(Error.t(), [pos_integer]) :: Error.t()
  def locate(%Error{offset: nil} = error, _line_offsets), do: error

  def locate(%Error{offset: offset} = error, line_offsets) do
    {line, column} = position(line_offsets, offset)
    %{error | line: line, column: column}
  end
end
