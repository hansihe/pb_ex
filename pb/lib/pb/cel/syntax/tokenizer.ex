defmodule PB.CEL.Syntax.Tokenizer do
  @moduledoc false

  alias PB.CEL.Error

  @int64_max 0x7FFFFFFFFFFFFFFF
  @int64_min_abs 0x8000000000000000
  @uint64_max 0xFFFFFFFFFFFFFFFF

  @reserved MapSet.new(~w(
    as break const continue else for function if import let loop package
    namespace return var void while
  ))

  @type token :: %{
          required(:kind) => atom,
          required(:offset) => non_neg_integer(),
          optional(:value) => term
        }

  defmodule State do
    @moduledoc false
    defstruct [:source, :bytes, :location, index: 0, offset: 0, tokens: []]
  end

  @spec tokenize(String.t(), keyword) :: {:ok, [token]} | {:error, Error.t()}
  def tokenize(source, opts \\ []) when is_binary(source) and is_list(opts) do
    %State{source: source, bytes: byte_size(source), location: Keyword.get(opts, :location)}
    |> tokenize_loop()
  end

  defp tokenize_loop(%State{} = state) do
    cond do
      eof?(state) ->
        {:ok, Enum.reverse([token(:eof, nil, state.offset) | state.tokens])}

      whitespace?(byte(state)) ->
        state |> advance_one() |> tokenize_loop()

      starts_with?(state, "//") ->
        state |> skip_comment() |> tokenize_loop()

      string_prefix(state) ->
        lex_string_token(state)

      byte(state) == ?` ->
        lex_quoted_identifier_token(state)

      digit?(byte(state)) or (byte(state) == ?. and digit?(byte(state, 1))) ->
        lex_number(state)

      ident_start?(byte(state)) ->
        lex_word(state)

      true ->
        lex_symbol(state)
    end
  end

  defp lex_word(%State{} = state) do
    start_index = state.index
    start_offset = state.offset
    state = consume_while(state, &ident_continue?/1)
    text = binary_part(state.source, start_index, state.index - start_index)

    token =
      case text do
        "true" ->
          token(:bool, true, start_offset)

        "false" ->
          token(:bool, false, start_offset)

        "null" ->
          token(:null, nil, start_offset)

        "in" ->
          token(:op, "in", start_offset)

        text ->
          token(
            if(MapSet.member?(@reserved, text), do: :reserved, else: :ident),
            text,
            start_offset
          )
      end

    tokenize_loop(add_token(state, token))
  end

  defp lex_symbol(%State{} = state) do
    start_offset = state.offset

    cond do
      op = two_char_operator(state) ->
        state
        |> advance_ascii(2)
        |> add_token(token(:op, op, start_offset))
        |> tokenize_loop()

      byte(state) in ~c"+-*/%!?:<>" ->
        op = <<byte(state)>>

        state
        |> advance_ascii(1)
        |> add_token(token(:op, op, start_offset))
        |> tokenize_loop()

      byte(state) in ~c".,()[]{}" ->
        punct = <<byte(state)>>

        state
        |> advance_ascii(1)
        |> add_token(token(:punct, punct, start_offset))
        |> tokenize_loop()

      true ->
        error(state, "unexpected character #{inspect(current_char(state))}")
    end
  end

  defp two_char_operator(state) do
    Enum.find(["<=", ">=", "==", "!=", "&&", "||"], &starts_with?(state, &1))
  end

  defp lex_number(%State{} = state) do
    start_index = state.index
    start_offset = state.offset

    with {:ok, state, kind} <- consume_number(state) do
      text = binary_part(state.source, start_index, state.index - start_index)

      case parse_number_value(kind, text) do
        {:ok, value} ->
          tokenize_loop(add_token(state, token(kind, value, start_offset)))

        {:ok, token_kind, value} ->
          tokenize_loop(add_token(state, token(token_kind, value, start_offset)))

        {:error, message} ->
          error(state, message, start_offset)
      end
    else
      {:error, message, offset} -> error(state, message, offset)
    end
  end

  defp consume_number(state) do
    cond do
      starts_with?(state, "0x") or starts_with?(state, "0X") ->
        consume_hex_number(state)

      byte(state) == ?. ->
        consume_decimal_number(state, true)

      true ->
        consume_decimal_number(state, false)
    end
  end

  defp consume_hex_number(state) do
    state = advance_ascii(state, 2)
    digit_start = state.offset
    state = consume_while(state, &hex_digit?/1)

    cond do
      state.offset == digit_start ->
        {:error, "expected hexadecimal digit", state.offset}

      byte(state) in ~c"uU" ->
        {:ok, advance_ascii(state, 1), :uint}

      ident_start?(byte(state)) ->
        {:error, "invalid integer literal suffix", state.offset}

      true ->
        {:ok, state, :int}
    end
  end

  defp consume_decimal_number(state, leading_dot?) do
    state =
      if leading_dot? do
        state
        |> advance_ascii(1)
        |> consume_while(&digit?/1)
      else
        consume_while(state, &digit?/1)
      end

    {state, float?} =
      cond do
        leading_dot? ->
          {state, true}

        byte(state) == ?. and digit?(byte(state, 1)) ->
          state =
            state
            |> advance_ascii(1)
            |> consume_while(&digit?/1)

          {state, true}

        true ->
          {state, false}
      end

    with {:ok, state, exponent?} <- maybe_consume_exponent(state) do
      float? = float? or exponent?

      cond do
        float? and byte(state) in ~c"uU" ->
          {:error, "invalid float literal suffix", state.offset}

        not float? and byte(state) in ~c"uU" ->
          {:ok, advance_ascii(state, 1), :uint}

        ident_start?(byte(state)) ->
          {:error, "invalid numeric literal suffix", state.offset}

        float? ->
          {:ok, state, :double}

        true ->
          {:ok, state, :int}
      end
    end
  end

  defp maybe_consume_exponent(state) do
    if byte(state) in ~c"eE" do
      state = advance_ascii(state, 1)

      state =
        if byte(state) in ~c"+-" do
          advance_ascii(state, 1)
        else
          state
        end

      digit_start = state.offset
      state = consume_while(state, &digit?/1)

      if state.offset == digit_start do
        {:error, "expected exponent digits", state.offset}
      else
        {:ok, state, true}
      end
    else
      {:ok, state, false}
    end
  end

  defp parse_number_value(:int, text) do
    {base, digits} = integer_digits(text)
    value = String.to_integer(digits, base)

    cond do
      value <= @int64_max -> {:ok, value}
      value == @int64_min_abs -> {:ok, :int_min_abs, value}
      true -> {:error, "int literal exceeds int64 range"}
    end
  end

  defp parse_number_value(:uint, text) do
    text = String.trim_trailing(String.trim_trailing(text, "u"), "U")
    {base, digits} = integer_digits(text)
    value = String.to_integer(digits, base)

    if value <= @uint64_max do
      {:ok, value}
    else
      {:error, "uint literal exceeds uint64 range"}
    end
  end

  defp parse_number_value(:double, text) do
    text = if String.starts_with?(text, "."), do: "0" <> text, else: text

    case Float.parse(text) do
      {value, ""} -> {:ok, value}
      _other -> {:error, "invalid float literal"}
    end
  end

  defp integer_digits("0x" <> rest), do: {16, rest}
  defp integer_digits("0X" <> rest), do: {16, rest}
  defp integer_digits(rest), do: {10, rest}

  defp lex_string_token(%State{} = state) do
    case string_prefix(state) do
      {kind, raw?, prefix_size} ->
        case lex_string(state, kind, raw?, prefix_size) do
          {:ok, state, token} -> tokenize_loop(add_token(state, token))
          {:error, message, offset} -> error(state, message, offset)
        end

      nil ->
        error(state, "expected string literal")
    end
  end

  defp lex_quoted_identifier_token(%State{} = state) do
    start_offset = state.offset
    state = advance_ascii(state, 1)
    scan_quoted_identifier(state, [], start_offset)
  end

  defp scan_quoted_identifier(state, acc, start_offset) do
    cond do
      eof?(state) ->
        error(state, "unterminated quoted identifier", start_offset)

      byte(state) == ?` ->
        value = acc |> Enum.reverse() |> IO.iodata_to_binary()

        state
        |> advance_ascii(1)
        |> add_token(token(:quoted_ident, value, start_offset))
        |> tokenize_loop()

      newline?(byte(state)) ->
        error(state, "newline in quoted identifier", state.offset)

      byte(state) == ?\\ ->
        case escape(state, :string) do
          {:ok, state, escaped} ->
            scan_quoted_identifier(state, [escaped | acc], start_offset)

          {:error, message, offset} ->
            error(state, message, offset)
        end

      true ->
        {char, state} = take_char(state)
        scan_quoted_identifier(state, [char | acc], start_offset)
    end
  end

  defp lex_string(state, kind, raw?, prefix_size) do
    start_offset = state.offset
    state = advance_ascii(state, prefix_size)
    quote = byte(state)
    triple? = starts_with?(state, <<quote, quote, quote>>)
    delimiter_size = if triple?, do: 3, else: 1
    state = advance_ascii(state, delimiter_size)
    scan_string(state, kind, raw?, quote, triple?, [], start_offset)
  end

  defp scan_string(state, kind, raw?, quote, triple?, acc, start_offset) do
    cond do
      eof?(state) ->
        {:error, "unterminated string literal", start_offset}

      closes_string?(state, quote, triple?) ->
        delimiter_size = if triple?, do: 3, else: 1
        value = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, advance_ascii(state, delimiter_size), token(kind, value, start_offset)}

      not triple? and newline?(byte(state)) ->
        {:error, "newline in string literal", state.offset}

      raw? ->
        {char, state} = take_char(state)
        scan_string(state, kind, raw?, quote, triple?, [char | acc], start_offset)

      byte(state) == ?\\ ->
        case escape(state, kind) do
          {:ok, state, escaped} ->
            scan_string(state, kind, raw?, quote, triple?, [escaped | acc], start_offset)

          {:error, message, offset} ->
            {:error, message, offset}
        end

      true ->
        {char, state} = take_char(state)
        scan_string(state, kind, raw?, quote, triple?, [char | acc], start_offset)
    end
  end

  defp closes_string?(state, quote, true), do: starts_with?(state, <<quote, quote, quote>>)
  defp closes_string?(state, quote, false), do: byte(state) == quote

  defp escape(state, kind) do
    offset = state.offset
    state = advance_ascii(state, 1)

    cond do
      eof?(state) ->
        {:error, "unterminated escape sequence", offset}

      simple_escape = simple_escape(byte(state)) ->
        {:ok, advance_ascii(state, 1), escape_binary(kind, simple_escape)}

      byte(state) in ~c"xX" ->
        escape_fixed_hex(state, kind, 2, offset)

      byte(state) == ?u ->
        escape_fixed_hex(state, kind, 4, offset)

      byte(state) == ?U ->
        if kind == :bytes do
          {:error, "\\U escapes are not valid in bytes literals", offset}
        else
          escape_fixed_hex(state, kind, 8, offset)
        end

      byte(state) in ?0..?3 ->
        escape_octal(state, kind, offset)

      true ->
        {:error, "invalid escape sequence", offset}
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
  defp simple_escape(?"), do: ?"
  defp simple_escape(?'), do: ?'
  defp simple_escape(?`), do: ?`
  defp simple_escape(_), do: nil

  defp escape_fixed_hex(state, kind, digits, offset) do
    state = advance_ascii(state, 1)

    with {:ok, hex, state} <-
           take_ascii_digits(state, digits, &hex_digit?/1, "hexadecimal", offset) do
      value = String.to_integer(hex, 16)
      escape_codepoint(state, kind, value, digits, offset)
    end
  end

  defp escape_octal(state, kind, offset) do
    with {:ok, octal, state} <- take_ascii_digits(state, 3, &octal_digit?/1, "octal", offset) do
      value = String.to_integer(octal, 8)
      escape_codepoint(state, kind, value, 3, offset)
    end
  end

  defp escape_codepoint(state, :bytes, value, width, offset) when width in [2, 3] do
    if value <= 0xFF do
      {:ok, state, <<value>>}
    else
      {:error, "bytes escape exceeds byte range", offset}
    end
  end

  defp escape_codepoint(state, kind, value, _width, offset) when kind in [:string, :bytes] do
    if valid_codepoint?(value) do
      {:ok, state, <<value::utf8>>}
    else
      {:error, "invalid unicode code point", offset}
    end
  end

  defp escape_binary(:bytes, value), do: <<value>>
  defp escape_binary(:string, value), do: <<value::utf8>>

  defp take_ascii_digits(state, count, pred, name, offset) do
    if state.index + count <= state.bytes do
      start = state.index
      state = advance_ascii(state, count)
      text = binary_part(state.source, start, count)

      if text |> :binary.bin_to_list() |> Enum.all?(pred) do
        {:ok, text, state}
      else
        {:error, "invalid #{name} escape", offset}
      end
    else
      {:error, "invalid #{name} escape", offset}
    end
  end

  defp valid_codepoint?(value) do
    value in 0..0xD7FF or value in 0xE000..0x10FFFF
  end

  defp string_prefix(state) do
    cond do
      quote?(byte(state)) ->
        {:string, false, 0}

      byte(state) in ~c"rR" and quote?(byte(state, 1)) ->
        {:string, true, 1}

      byte(state) in ~c"bB" and quote?(byte(state, 1)) ->
        {:bytes, false, 1}

      byte(state) in ~c"bB" and byte(state, 1) in ~c"rR" and quote?(byte(state, 2)) ->
        {:bytes, true, 2}

      byte(state) in ~c"rR" and byte(state, 1) in ~c"bB" and quote?(byte(state, 2)) ->
        {:bytes, true, 2}

      true ->
        nil
    end
  end

  defp skip_comment(state) do
    state
    |> advance_ascii(2)
    |> skip_comment_loop()
  end

  defp skip_comment_loop(state) do
    cond do
      eof?(state) -> state
      byte(state) == ?\n -> advance_one(state)
      true -> state |> advance_one() |> skip_comment_loop()
    end
  end

  defp token(:eof, _value, offset), do: %{kind: :eof, offset: offset}
  defp token(kind, nil, offset), do: %{kind: kind, offset: offset}
  defp token(kind, value, offset), do: %{kind: kind, value: value, offset: offset}

  defp add_token(%State{} = state, token), do: %State{state | tokens: [token | state.tokens]}

  defp error(%State{} = state, message, offset \\ nil) do
    {:error,
     Error.exception(
       phase: :parse,
       message: message,
       offset: offset || state.offset,
       location: state.location
     )}
  end

  defp consume_while(state, pred) do
    if pred.(byte(state)) do
      state |> advance_ascii(1) |> consume_while(pred)
    else
      state
    end
  end

  defp advance_ascii(%State{} = state, count) do
    %State{state | index: state.index + count, offset: state.offset + count}
  end

  defp advance_one(%State{} = state) do
    {_char, state} = take_char(state)
    state
  end

  defp take_char(%State{} = state) do
    rest = binary_part(state.source, state.index, state.bytes - state.index)
    {char, _rest} = String.next_codepoint(rest)
    {char, %State{state | index: state.index + byte_size(char), offset: state.offset + 1}}
  end

  defp current_char(%State{} = state) do
    if eof?(state) do
      nil
    else
      {char, _state} = take_char(state)
      char
    end
  end

  defp starts_with?(%State{} = state, prefix) do
    prefix_size = byte_size(prefix)

    state.index + prefix_size <= state.bytes and
      binary_part(state.source, state.index, prefix_size) == prefix
  end

  defp byte(%State{} = state, offset \\ 0) do
    index = state.index + offset

    if index < state.bytes do
      :binary.at(state.source, index)
    else
      nil
    end
  end

  defp eof?(%State{} = state), do: state.index >= state.bytes
  defp whitespace?(byte), do: byte in [?\t, ?\n, ?\f, ?\r, ?\s]
  defp newline?(byte), do: byte in [?\n, ?\r]
  defp quote?(byte), do: byte in [?\", ?']
  defp digit?(byte), do: byte in ?0..?9
  defp octal_digit?(byte), do: byte in ?0..?7
  defp hex_digit?(byte), do: digit?(byte) or byte in ?a..?f or byte in ?A..?F
  defp ident_start?(byte), do: byte == ?_ or byte in ?a..?z or byte in ?A..?Z
  defp ident_continue?(byte), do: ident_start?(byte) or digit?(byte)
end
