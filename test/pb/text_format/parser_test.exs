defmodule PB.TextFormat.ParserTest do
  use ExUnit.Case, async: true

  alias PB.TextFormat.Parser

  # Strips offsets so trees can be compared structurally.
  defp tree(source) do
    {:ok, fields} = Parser.parse(source)
    Enum.map(fields, &simplify/1)
  end

  defp simplify(%{kind: :field} = field),
    do: {field.name, field.colon, simplify(field.value)}

  defp simplify(%{kind: :message, fields: fields}), do: {:message, Enum.map(fields, &simplify/1)}
  defp simplify(%{kind: :list, values: values}), do: {:list, Enum.map(values, &simplify/1)}
  defp simplify(%{kind: :string, value: value}), do: {:string, value}
  defp simplify(%{kind: kind, value: value, negative: true}), do: {kind, "-" <> value}
  defp simplify(%{kind: kind, value: value}), do: {kind, value}

  defp error(source) do
    {:error, %{message: message, offset: offset}} = Parser.parse(source)
    {message, offset}
  end

  describe "fields" do
    test "parses scalar fields with their colon" do
      assert tree("a: 1 b: -2.5 c: FOO d: 'x'") == [
               {{:field, "a"}, true, {:integer, "1"}},
               {{:field, "b"}, true, {:float, "-2.5"}},
               {{:field, "c"}, true, {:identifier, "FOO"}},
               {{:field, "d"}, true, {:string, "x"}}
             ]
    end

    test "empty input is an empty message" do
      assert tree("") == []
      assert tree("  # just a comment\n") == []
    end

    test "concatenates adjacent string literals into one value" do
      assert tree(~s(a: 'first' "second"\n'third')) == [
               {{:field, "a"}, true, {:string, "firstsecondthird"}}
             ]
    end

    test "accepts one optional , or ; after each field" do
      assert tree("a: 1, b: 2; c: 3") ==
               [
                 {{:field, "a"}, true, {:integer, "1"}},
                 {{:field, "b"}, true, {:integer, "2"}},
                 {{:field, "c"}, true, {:integer, "3"}}
               ]

      assert tree("m { a: 1, }") == [
               {{:field, "m"}, false, {:message, [{{:field, "a"}, true, {:integer, "1"}}]}}
             ]
    end

    test "rejects a doubled separator" do
      assert {~s(expected field name, found ","), 5} = error("a: 1,, b: 2")
      assert {~s(expected field name, found ";"), 9} = error("m { a: 1;; }")
    end

    test "parses extension and type URL names" do
      assert tree("[pkg.ext]: 1 [type.googleapis.com/pkg.Msg] {}") == [
               {{:extension, "pkg.ext"}, true, {:integer, "1"}},
               {{:type_url, "type.googleapis.com/pkg.Msg"}, false, {:message, []}}
             ]
    end

    test "allows whitespace and comments inside a bracketed name" do
      assert tree("[ pkg . # c\n ext ]: 1") == [{{:extension, "pkg.ext"}, true, {:integer, "1"}}]
    end

    test "rejects malformed field names" do
      assert {~s(expected field name, found "1"), 0} = error("1: 2")
      assert {~s(expected field name, found "}"), 0} = error("}")
      assert {~s(expected identifier, found "]"), 1} = error("[]: 1")
      assert {~s(expected "]", found ":"), 4} = error("[a.b: 1")
    end
  end

  describe "messages" do
    test "accepts braces or angle brackets, with or without a colon" do
      assert tree("a { x: 1 } b: < y: 2 >") == [
               {{:field, "a"}, false, {:message, [{{:field, "x"}, true, {:integer, "1"}}]}},
               {{:field, "b"}, true, {:message, [{{:field, "y"}, true, {:integer, "2"}}]}}
             ]
    end

    test "rejects mismatched or missing closing delimiters" do
      assert {~s(expected "}", found ">"), 9} = error("a { x: 1 >")
      assert {~s(expected ">", found "}"), 9} = error("a < x: 1 }")
      assert {~s(expected "}", found end of input), 8} = error("a { x: 1")
    end

    test "requires a colon before a scalar value" do
      assert {~s(expected ":" or a message value, found "1"), 2} = error("a 1")
    end

    test "limits message nesting to the maximum depth" do
      max = Parser.max_depth()
      nested = fn depth -> String.duplicate("a {", depth) <> String.duplicate("}", depth) end

      assert {:ok, _} = Parser.parse(nested.(max))

      assert {"message nesting exceeds the depth limit of 100", offset} = error(nested.(max + 1))
      assert offset == 3 * max + 2
    end
  end

  describe "lists" do
    test "parses scalar and message lists, empty lists, and colon-less lists" do
      assert tree("a: [1, -2] b: [] c [{x: 1}, <y: 2>]") == [
               {{:field, "a"}, true, {:list, [{:integer, "1"}, {:integer, "-2"}]}},
               {{:field, "b"}, true, {:list, []}},
               {{:field, "c"}, false,
                {:list,
                 [
                   {:message, [{{:field, "x"}, true, {:integer, "1"}}]},
                   {:message, [{{:field, "y"}, true, {:integer, "2"}}]}
                 ]}}
             ]
    end

    test "list elements may be strings made of several literals" do
      assert tree("a: ['x' 'y', 'z']") == [
               {{:field, "a"}, true, {:list, [{:string, "xy"}, {:string, "z"}]}}
             ]
    end

    test "rejects malformed lists" do
      assert {~s(expected "," or "]", found ";"), 5} = error("a: [1; 2]")
      assert {~s(expected "," or "]", found "2"), 6} = error("a: [1 2]")
      assert {~s(expected a value, found "]"), 6} = error("a: [1,]")
      assert {~s(expected a value, found ","), 6} = error("a: [1,,2]")
      assert {~s(expected a value, found "["), 4} = error("a: [[1]]")
    end
  end

  describe "minus sign" do
    test "may precede numbers and inf/infinity/nan in any case" do
      assert tree("a: -1 b: -.5 c: -inf d: -Infinity e: -NaN") == [
               {{:field, "a"}, true, {:integer, "-1"}},
               {{:field, "b"}, true, {:float, "-.5"}},
               {{:field, "c"}, true, {:identifier, "-inf"}},
               {{:field, "d"}, true, {:identifier, "-Infinity"}},
               {{:field, "e"}, true, {:identifier, "-NaN"}}
             ]
    end

    test "records the offset of the minus sign" do
      {:ok, [%{value: value}]} = Parser.parse("a: - 1")
      assert value.offset == 3
    end

    test "rejects other identifiers and non-numbers" do
      assert {~s(expected a number after "-", found "FOO"), 4} = error("a: -FOO")
      assert {~s(expected a number after "-", found a string), 4} = error("a: -'x'")
    end
  end

  test "reports lexer errors" do
    assert {"string literals may not span lines", 5} = error("a: 'x\n'")
  end
end
