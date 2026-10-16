defmodule PB.CEL.Error do
  @moduledoc """
  Unified error raised by CEL evaluation, including protovalidate `cel` rules.

  `:phase` discriminates `:parse`, `:check`, or `:eval`. Callers `rescue
  PB.CEL.Error` once and inspect `:phase` to discriminate if needed.

  Parse and check errors say where in the source the error was found: for a
  check error, the position of the expression it is about, as
  `PB.CEL.Checked.position/2` gives it.

    * `:offset` — the offset in code points.
    * `:line` and `:column` — the 1-based line and column, in code points.
    * `:location` — the source's location, as given to `PB.CEL.parse/2`.
  """

  defexception [:message, :phase, :offset, :line, :column, :location, :expr_id, :details]

  @type phase :: :parse | :check | :eval
  @type t :: %__MODULE__{
          message: String.t(),
          phase: phase,
          offset: non_neg_integer() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          location: String.t() | nil,
          expr_id: integer() | nil,
          details: map() | nil
        }

  @doc """
  Builds the error. `:message` is always a string: a non-string reason from
  the runtime is described in words and kept as `details.reason`.
  """
  @impl Exception
  def exception(opts) when is_list(opts) do
    {message, details} = message_and_details(opts)

    %__MODULE__{
      message: message,
      phase: Keyword.fetch!(opts, :phase),
      offset: Keyword.get(opts, :offset),
      line: Keyword.get(opts, :line),
      column: Keyword.get(opts, :column),
      location: Keyword.get(opts, :location),
      expr_id: Keyword.get(opts, :expr_id),
      details: details
    }
  end

  defp message_and_details(opts) do
    details = Keyword.get(opts, :details)

    case Keyword.fetch!(opts, :message) do
      message when is_binary(message) -> {message, details}
      reason -> {describe(reason), Map.put(details || %{}, :reason, reason)}
    end
  end

  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason) when is_atom(reason), do: humanize(reason)

  defp describe(reason) when is_tuple(reason) and is_atom(elem(reason, 0)) do
    [tag | rest] = Tuple.to_list(reason)
    humanize(tag) <> ": " <> Enum.map_join(rest, ", ", &inspect/1)
  end

  defp describe(reason), do: inspect(reason)

  defp humanize(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  @impl Exception
  def message(%__MODULE__{message: msg, line: nil, offset: nil}), do: msg
  def message(%__MODULE__{message: msg, line: nil, offset: offset}),
    do: "#{msg} at offset #{offset}"
  def message(%__MODULE__{message: msg, line: line, column: column}),
    do: "#{msg} at line #{line}, column #{column}"
end
