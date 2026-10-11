defmodule PB.TextFormat.Lexer do
  @moduledoc false

  # Tokenizer for protobuf text format. Follows the C++ `io::Tokenizer` as
  # configured by `TextFormat::Parser`: `#` line comments, an optional `f`/`F`
  # float suffix, a number may not run straight into an identifier, and string
  # literals may not span lines. Unicode escapes are stricter than C++: they
  # reject surrogates (even as a valid pair) and code points above U+10FFFF, as
  # the conformance suite requires.
  #
  # The lexer is schema-free. Number tokens keep their source text, because
  # whether `1f`, `0x1` or `012` is acceptable depends on the target field.
  # String tokens hold the unescaped bytes of a single literal; adjacent
  # literals are concatenated by the parser, and UTF-8 is only checked when a
  # value binds to a `string` field.
  #
  # Every other printable ASCII character is a single-character `:symbol`
  # token; the parser decides which ones are meaningful.

  @type token :: %{
          required(:kind) => :identifier | :integer | :float | :string | :symbol | :eof,
          required(:offset) => non_neg_integer(),
          optional(:value) => binary
        }

  @type error :: %{message: String.t(), offset: non_neg_integer()}

  defmodule State do
    @moduledoc false
    defstruct [:source, :bytes, index: 0, tokens: []]
  end

  @spec tokenize(binary) :: {:ok, [token]} | {:error, error}
  def tokenize(source) when is_binary(source) do
    tokenize_loop(%State{source: source, bytes: byte_size(source)})
  end

  @doc """
  Converts a byte offset into a 1-based `{line, column}` pair, counting columns
  in bytes.
  """
  @spec position(binary, non_neg_integer()) :: {pos_integer(), pos_integer()}
  def position(source, offset) when is_binary(source) do
    prefix = binary_part(source, 0, min(offset, byte_size(source)))
    lines = :binary.split(prefix, "\n", [:global])
    {length(lines), byte_size(List.last(lines)) + 1}
  end

  defp tokenize_loop(%State{} = state) do
    byte = byte(state)

    cond do
      eof?(state) ->
        {:ok, Enum.reverse([%{kind: :eof, offset: state.index} | state.tokens])}

      whitespace?(byte) ->
        state |> advance(1) |> tokenize_loop()

      byte == ?# ->
        state |> skip_comment() |> tokenize_loop()

      ident_start?(byte) ->
        lex_identifier(state)

      digit?(byte) or (byte == ?. and digit?(byte(state, 1))) ->
        lex_number(state)

      byte in [?", ?'] ->
        lex_string(state, byte)

      byte < 0x20 ->
        error("invalid control character in text", state.index)

      byte >= 0x80 ->
        error(
          "unexpected non-ASCII byte 0x#{hex_byte(byte)} outside a string literal",
          state.index
        )

      true ->
        state
        |> add_token(%{kind: :symbol, value: <<byte>>, offset: state.index})
        |> advance(1)
        |> tokenize_loop()
    end
  end

  # A NUL byte ends the comment without being consumed, so the main loop
  # rejects it as a control character (as C++ does).
  defp skip_comment(%State{} = state) do
    case byte(state) do
      nil -> state
      ?\n -> advance(state, 1)
      0 -> state
      _ -> state |> advance(1) |> skip_comment()
    end
  end

  defp lex_identifier(%State{} = state) do
    start = state.index
    state = consume_while(state, &ident_continue?/1)

    state
    |> add_token(%{kind: :identifier, value: slice(state, start), offset: start})
    |> tokenize_loop()
  end

  # ── numbers ──────────────────────────────────────────────────────────

  defp lex_number(%State{} = state) do
    start = state.index

    if byte(state) == ?. and identifier_before?(state) do
      error("need space between identifier and decimal point", start)
    else
      with {:ok, state, kind} <- consume_number(state),
           :ok <- check_number_end(state, kind) do
        state
        |> add_token(%{kind: kind, value: slice(state, start), offset: start})
        |> tokenize_loop()
      end
    end
  end

  defp consume_number(%State{} = state) do
    case {byte(state), byte(state, 1)} do
      {?0, x} when x in [?x, ?X] -> consume_hex(advance(state, 2))
      {?0, d} when d in ?0..?9 -> consume_octal(advance(state, 1))
      _ -> consume_decimal(state)
    end
  end

  defp consume_hex(%State{} = state) do
    start = state.index
    state = consume_while(state, &hex_digit?/1)

    if state.index == start do
      error(~s("0x" must be followed by hex digits), state.index)
    else
      {:ok, state, :integer}
    end
  end

  defp consume_octal(%State{} = state) do
    state = consume_while(state, &octal_digit?/1)

    if digit?(byte(state)) do
      error("numbers starting with a leading zero must be in octal", state.index)
    else
      {:ok, state, :integer}
    end
  end

  defp consume_decimal(%State{} = state) do
    state = consume_while(state, &digit?/1)

    {state, kind} =
      if byte(state) == ?. do
        {state |> advance(1) |> consume_while(&digit?/1), :float}
      else
        {state, :integer}
      end

    with {:ok, state, kind} <- consume_exponent(state, kind) do
      if byte(state) in [?f, ?F] do
        {:ok, advance(state, 1), :float}
      else
        {:ok, state, kind}
      end
    end
  end

  defp consume_exponent(%State{} = state, kind) do
    if byte(state) in [?e, ?E] do
      state = advance(state, 1)
      state = if byte(state) in [?+, ?-], do: advance(state, 1), else: state
      start = state.index
      state = consume_while(state, &digit?/1)

      if state.index == start do
        error(~s("e" must be followed by an exponent), state.index)
      else
        {:ok, state, :float}
      end
    else
      {:ok, state, kind}
    end
  end

  defp check_number_end(%State{} = state, kind) do
    byte = byte(state)

    cond do
      ident_start?(byte) ->
        error("need space between number and identifier", state.index)

      byte == ?. and kind == :float ->
        error("already saw a decimal point or exponent; can't have another one", state.index)

      byte == ?. ->
        error("hex and octal numbers must be integers", state.index)

      true ->
        :ok
    end
  end

  # C++ rejects `foo.5`: a leading-dot float glued to the identifier before it.
  defp identifier_before?(%State{tokens: [%{kind: :identifier} = token | _]} = state),
    do: token.offset + byte_size(token.value) == state.index

  defp identifier_before?(%State{}), do: false

  # ── strings ──────────────────────────────────────────────────────────

  defp lex_string(%State{} = state, quote) do
    start = state.index
    scan_string(advance(state, 1), quote, [], start)
  end

  defp scan_string(%State{} = state, quote, acc, start) do
    case byte(state) do
      nil ->
        error("unterminated string literal", start)

      ^quote ->
        value = IO.iodata_to_binary(Enum.reverse(acc))

        state
        |> advance(1)
        |> add_token(%{kind: :string, value: value, offset: start})
        |> tokenize_loop()

      ?\n ->
        error("string literals may not span lines", state.index)

      0 ->
        error("NUL byte in string literal", state.index)

      ?\\ when state.index + 1 == state.bytes ->
        error("unterminated string literal", start)

      ?\\ ->
        with {:ok, state, bytes} <- escape(state) do
          scan_string(state, quote, [bytes | acc], start)
        end

      byte ->
        scan_string(advance(state, 1), quote, [byte | acc], start)
    end
  end

  defp escape(%State{} = state) do
    escape_start = state.index
    state = advance(state, 1)
    byte = byte(state)

    cond do
      translated = simple_escape(byte) ->
        {:ok, advance(state, 1), translated}

      octal_digit?(byte) ->
        escape_octal(state)

      byte in [?x, ?X] ->
        escape_hex(advance(state, 1), escape_start)

      byte == ?u ->
        escape_codepoint(advance(state, 1), 4, escape_start)

      byte == ?U ->
        escape_codepoint(advance(state, 1), 8, escape_start)

      true ->
        error("invalid escape sequence in string literal", escape_start)
    end
  end

  # One to three octal digits. Values above 0o377 keep their low byte, as the
  # C++ `static_cast<char>` does.
  defp escape_octal(%State{} = state) do
    {digits, state} = take_up_to(state, 3, &octal_digit?/1)
    {:ok, state, Bitwise.band(String.to_integer(digits, 8), 0xFF)}
  end

  defp escape_hex(%State{} = state, escape_start) do
    case take_up_to(state, 2, &hex_digit?/1) do
      {"", _state} -> error("expected hex digits for escape sequence", escape_start)
      {digits, state} -> {:ok, state, String.to_integer(digits, 16)}
    end
  end

  defp escape_codepoint(%State{} = state, width, escape_start) do
    case take_up_to(state, width, &hex_digit?/1) do
      {digits, state} when byte_size(digits) == width ->
        codepoint = String.to_integer(digits, 16)

        cond do
          codepoint in 0xD800..0xDFFF ->
            error("unicode escape may not encode a surrogate code point", escape_start)

          codepoint > 0x10FFFF ->
            error("unicode escape is beyond U+10FFFF", escape_start)

          true ->
            {:ok, state, <<codepoint::utf8>>}
        end

      _short ->
        error("expected #{width} hex digits for unicode escape sequence", escape_start)
    end
  end

  defp simple_escape(?a), do: 0x07
  defp simple_escape(?b), do: 0x08
  defp simple_escape(?f), do: 0x0C
  defp simple_escape(?n), do: ?\n
  defp simple_escape(?r), do: ?\r
  defp simple_escape(?t), do: ?\t
  defp simple_escape(?v), do: 0x0B
  defp simple_escape(?\\), do: ?\\
  defp simple_escape(??), do: ??
  defp simple_escape(?'), do: ?'
  defp simple_escape(?"), do: ?"
  defp simple_escape(_), do: nil

  # ── helpers ──────────────────────────────────────────────────────────

  defp take_up_to(%State{} = state, max, pred) do
    start = state.index
    state = take_up_to_loop(state, max, pred)
    {slice(state, start), state}
  end

  defp take_up_to_loop(state, 0, _pred), do: state

  defp take_up_to_loop(state, max, pred) do
    if pred.(byte(state)), do: state |> advance(1) |> take_up_to_loop(max - 1, pred), else: state
  end

  defp consume_while(%State{} = state, pred) do
    if pred.(byte(state)), do: state |> advance(1) |> consume_while(pred), else: state
  end

  defp add_token(%State{} = state, token), do: %State{state | tokens: [token | state.tokens]}

  defp advance(%State{} = state, count), do: %State{state | index: state.index + count}

  defp slice(%State{} = state, start), do: binary_part(state.source, start, state.index - start)

  defp byte(%State{} = state, ahead \\ 0) do
    index = state.index + ahead
    if index < state.bytes, do: :binary.at(state.source, index), else: nil
  end

  defp error(message, offset), do: {:error, %{message: message, offset: offset}}

  defp hex_byte(byte), do: byte |> Integer.to_string(16) |> String.pad_leading(2, "0")

  defp eof?(%State{} = state), do: state.index >= state.bytes
  defp whitespace?(byte), do: byte in [?\s, ?\t, ?\n, ?\r, ?\v, ?\f]
  defp digit?(byte), do: byte in ?0..?9
  defp octal_digit?(byte), do: byte in ?0..?7
  defp hex_digit?(byte), do: digit?(byte) or byte in ?a..?f or byte in ?A..?F
  defp ident_start?(byte), do: byte == ?_ or byte in ?a..?z or byte in ?A..?Z
  defp ident_continue?(byte), do: ident_start?(byte) or digit?(byte)
end
