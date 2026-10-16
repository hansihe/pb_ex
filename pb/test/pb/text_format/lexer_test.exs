defmodule PB.TextFormat.LexerTest do
  use ExUnit.Case, async: true

  alias PB.TextFormat.Lexer

  defp tokens(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    Enum.map(tokens, &{&1.kind, Map.get(&1, :value)})
  end

  defp value(source) do
    [{_kind, value}, {:eof, nil}] = tokens(source)
    value
  end

  defp error(source) do
    {:error, %{message: message, offset: offset}} = Lexer.tokenize(source)
    {message, offset}
  end

  describe "structure" do
    test "splits a field into identifier, symbols and values" do
      assert tokens("foo: 1 bar { baz: 'x' }") == [
               {:identifier, "foo"},
               {:symbol, ":"},
               {:integer, "1"},
               {:identifier, "bar"},
               {:symbol, "{"},
               {:identifier, "baz"},
               {:symbol, ":"},
               {:string, "x"},
               {:symbol, "}"},
               {:eof, nil}
             ]
    end

    test "every other printable character is a single-character symbol" do
      assert tokens("[a.b/c]<>,;-") == [
               {:symbol, "["},
               {:identifier, "a"},
               {:symbol, "."},
               {:identifier, "b"},
               {:symbol, "/"},
               {:identifier, "c"},
               {:symbol, "]"},
               {:symbol, "<"},
               {:symbol, ">"},
               {:symbol, ","},
               {:symbol, ";"},
               {:symbol, "-"},
               {:eof, nil}
             ]
    end

    test "skips all whitespace characters and # comments" do
      assert tokens(" \t\r\n\v\f# comment: 'x\nfoo # trailing") ==
               [{:identifier, "foo"}, {:eof, nil}]
    end

    test "a comment may run to the end of input" do
      assert tokens("# only a comment") == [{:eof, nil}]
    end

    test "records byte offsets, with eof at the end of input" do
      {:ok, tokens} = Lexer.tokenize("a: 'é' b")
      assert Enum.map(tokens, & &1.offset) == [0, 1, 3, 8, 9]
    end

    test "identifiers include underscores and digits after the first character" do
      assert value("_foo_1Bar") == "_foo_1Bar"
    end

    test "rejects control characters and non-ASCII bytes outside strings" do
      assert {"invalid control character in text", 2} = error("a \x01")
      assert {"invalid control character in text", 2} = error("a \0")
      assert {"invalid control character in text", 10} = error("# comment \0")
      assert {"unexpected non-ASCII byte 0xC3 outside a string literal", 0} = error("é")
    end
  end

  describe "numbers" do
    test "keeps the source text of integers" do
      for source <- ~w(0 7 123 0x7FFFFFFF 0XaBc 017 0777 18446744073709551616) do
        assert tokens(source) == [{:integer, source}, {:eof, nil}], source
      end
    end

    test "keeps the source text of floats" do
      for source <- ~w(1.5 1. .5 .123e2 1e5 1E-5 1e+5 1.5e10 1f 1F 1.5f 0f 0.5 0e1 1.f
                       1e-18446744073709551616) do
        assert tokens(source) == [{:float, source}, {:eof, nil}], source
      end
    end

    test "a minus sign is a separate symbol" do
      assert tokens("-1.5") == [{:symbol, "-"}, {:float, "1.5"}, {:eof, nil}]
      assert tokens("- 0x1") == [{:symbol, "-"}, {:integer, "0x1"}, {:eof, nil}]
    end

    test "a dot not followed by a digit is a symbol" do
      assert tokens(". a") == [{:symbol, "."}, {:identifier, "a"}, {:eof, nil}]
    end

    test "rejects malformed numbers" do
      assert {~s("0x" must be followed by hex digits), 2} = error("0x")
      assert {"numbers starting with a leading zero must be in octal", 2} = error("018")
      assert {~s("e" must be followed by an exponent), 2} = error("1e")
      assert {~s("e" must be followed by an exponent), 3} = error("1e+")
      assert {"need space between number and identifier", 1} = error("1a")
      assert {"need space between number and identifier", 2} = error("1fa")
      assert {"need space between number and identifier", 3} = error("0x1g")
      assert {"need space between number and identifier", 1} = error("1_")

      assert {"already saw a decimal point or exponent; can't have another one", 3} =
               error("1.2.3")

      assert {"already saw a decimal point or exponent; can't have another one", 3} =
               error("1e1.")

      assert {"hex and octal numbers must be integers", 3} = error("012.5")
      assert {"hex and octal numbers must be integers", 3} = error("0x1.5")
    end

    test "rejects a leading-dot float glued to an identifier" do
      assert {"need space between identifier and decimal point", 3} = error("foo.5")
      assert tokens("foo .5") == [{:identifier, "foo"}, {:float, ".5"}, {:eof, nil}]
    end
  end

  describe "strings" do
    test "accepts either quote character, each allowing the other inside" do
      assert value(~s('say "hi"')) == ~s(say "hi")
      assert value(~s("it's")) == "it's"
    end

    test "adjacent literals stay separate tokens" do
      assert tokens(~s('first' "second"\n'third')) == [
               {:string, "first"},
               {:string, "second"},
               {:string, "third"},
               {:eof, nil}
             ]
    end

    test "passes raw bytes through, including non-ASCII and tabs" do
      assert value("'é\tx'") == "é\tx"
    end

    test "translates basic escapes" do
      assert value(~S('\a\b\f\n\r\t\v\?\\\'\"')) == "\a\b\f\n\r\t\v?\\'\""
    end

    test "translates octal escapes of one to three digits" do
      assert value(~S('\341\210\264')) == "ሴ"
      assert value(~S('\0\7\12')) == <<0, 7, 10>>
      assert value(~S('\1234')) == "S4"
    end

    test "keeps the low byte of octal escapes above 0o377" do
      assert value(~S('\777')) == <<0xFF>>
    end

    test "translates hex escapes of one or two digits" do
      assert value(~S('\xe1\x88\xb4')) == "ሴ"
      assert value(~S('\x7')) == <<7>>
      assert value(~S('\X41')) == "A"
      assert value(~S('\x414')) == "A4"
    end

    test "leaves invalid UTF-8 from byte escapes for the decoder to judge" do
      assert value(~S('\300')) == <<0xC0>>
      assert value(~S('\xc0')) == <<0xC0>>
    end

    test "translates unicode escapes to UTF-8" do
      assert value(~S('ሴ')) == "ሴ"
      assert value(~S('\U00001234\U00010437')) == "ሴ𐐷"
      assert value(~S('\U0010FFFF')) == <<0x10FFFF::utf8>>
    end

    test "rejects surrogate code points, even as a valid pair" do
      for source <- [
            ~S('\ud801\udc37'),
            ~S('\ud800'),
            ~S('\udc00'),
            ~S('\U0000d800'),
            ~S('\U0000dc00'),
            ~S('\U0000d801\U00000dc37'),
            ~S('\U0000d801\udc37'),
            ~S('\ud801\U0000dc37')
          ] do
        assert {"unicode escape may not encode a surrogate code point", 1} = error(source),
               source
      end
    end

    test "rejects unicode escapes beyond U+10FFFF" do
      assert {"unicode escape is beyond U+10FFFF", 1} = error(~S('\U00110000'))
    end

    test "rejects malformed escapes" do
      assert {"expected hex digits for escape sequence", 1} = error(~S('\xg'))
      assert {"expected 4 hex digits for unicode escape sequence", 1} = error(~S('\u12'))
      assert {"expected 8 hex digits for unicode escape sequence", 1} = error(~S('\U0001234'))
      assert {"invalid escape sequence in string literal", 1} = error(~S('\q'))
      assert {"invalid escape sequence in string literal", 1} = error(~S('\8'))
    end

    test "rejects unterminated, multiline and NUL-containing literals" do
      assert {"unterminated string literal", 3} = error("a: 'abc")
      assert {"unterminated string literal", 0} = error("'abc\\")
      assert {"string literals may not span lines", 6} = error("'first\nsecond'")
      assert {"NUL byte in string literal", 2} = error("'a\0'")
    end
  end

  describe "position/2" do
    test "converts byte offsets to 1-based line and column" do
      source = "a: 1\nbé: 2\n"
      assert Lexer.position(source, 0) == {1, 1}
      assert Lexer.position(source, 3) == {1, 4}
      assert Lexer.position(source, 5) == {2, 1}
      assert Lexer.position(source, 9) == {2, 5}
      assert Lexer.position(source, byte_size(source)) == {3, 1}
    end
  end
end
