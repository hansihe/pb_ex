defmodule PB.TextFormat.Layout do
  @moduledoc false

  # Renders the encoder's entries as text. The encoder decides what to print
  # and in which order; this module only decides where the whitespace goes.
  #
  # Multi-line output follows C++: one field per line, two-space indent,
  # `name: value` for scalars and `name {` ... `}` for messages, with a
  # trailing newline. Empty messages print as `name {}`. Single-line output
  # separates fields with one space and has no trailing space.

  @type entry ::
          {:scalar, String.t(), iodata}
          | {:list, String.t(), [iodata]}
          | {:message, String.t(), [entry]}

  @indent "  "

  @spec render([entry], boolean) :: iodata
  def render(entries, single_line)
  def render(entries, false), do: lines(entries, "")
  def render(entries, true), do: inline(entries)

  defp lines(entries, indent), do: Enum.map(entries, &line(&1, indent))

  defp line({:scalar, name, text}, indent), do: [indent, name, ": ", text, ?\n]
  defp line({:list, name, items}, indent), do: [indent, name, ": ", list(items), ?\n]
  defp line({:message, name, []}, indent), do: [indent, name, " {}\n"]

  defp line({:message, name, children}, indent),
    do: [indent, name, " {\n", lines(children, [indent, @indent]), indent, "}\n"]

  defp inline(entries), do: entries |> Enum.map(&inline_entry/1) |> Enum.intersperse(?\s)

  defp inline_entry({:scalar, name, text}), do: [name, ": ", text]
  defp inline_entry({:list, name, items}), do: [name, ": ", list(items)]
  defp inline_entry({:message, name, []}), do: [name, " {}"]
  defp inline_entry({:message, name, children}), do: [name, " { ", inline(children), " }"]

  defp list(items), do: [?[, Enum.intersperse(items, ", "), ?]]
end
