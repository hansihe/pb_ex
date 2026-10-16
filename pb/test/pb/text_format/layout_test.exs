defmodule PB.TextFormat.LayoutTest do
  use ExUnit.Case, async: true

  alias PB.TextFormat.Layout

  @entries [
    {:scalar, "a", "1"},
    {:list, "b", ["1", "2"]},
    {:message, "c",
     [{:scalar, "d", ~S("x")}, {:message, "e", []}, {:message, "f", [{:scalar, "g", "true"}]}]},
    {:message, "h", []}
  ]

  defp render(entries, single_line),
    do: entries |> Layout.render(single_line) |> IO.iodata_to_binary()

  test "multi-line output indents nested messages by two spaces" do
    assert render(@entries, false) == """
           a: 1
           b: [1, 2]
           c {
             d: "x"
             e {}
             f {
               g: true
             }
           }
           h {}
           """
  end

  test "single-line output separates fields with one space" do
    assert render(@entries, true) == ~S(a: 1 b: [1, 2] c { d: "x" e {} f { g: true } } h {})
  end

  test "an empty message renders as empty text" do
    assert render([], false) == ""
    assert render([], true) == ""
  end
end
