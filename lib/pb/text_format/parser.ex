defmodule PB.TextFormat.Parser do
  @moduledoc false

  # Schema-free recursive-descent parser for protobuf text format. Turns lexer
  # tokens into a syntax tree; the decoder then checks it against the schema.
  #
  #   message := { field } (end of input | "}" | ">")
  #   field   := name [":"] value [";" | ","]
  #   name    := identifier | "[" identifier { ("." | "/") identifier } "]"
  #   value   := message_value | list | scalar
  #   message_value := "{" message "}" | "<" message ">"
  #   list    := "[" [ element { "," element } ] "]"
  #   element := message_value | scalar
  #   scalar  := string { string } | ["-"] (integer | float | identifier)
  #
  # The grammar is the union of what C++ accepts for known fields and when
  # skipping unknown or reserved ones, so a field's value can be parsed
  # without knowing its type. Rules that depend on the field are left to the
  # decoder: scalar fields require the colon, a list only fits a repeated
  # field, and list elements must all match the field's type. Without a colon
  # the value must be a message or a list, since C++ treats a colon-less field
  # as a message in every case.
  #
  # The one value rule applied here is that a minus sign may only precede an
  # identifier when it is `inf`, `infinity` or `nan` (any case), which is what
  # C++ enforces even for skipped fields.

  alias PB.TextFormat.Lexer

  @max_depth PB.Wire.max_decode_depth()

  @type name :: {:field, String.t()} | {:extension, String.t()} | {:type_url, String.t()}

  @type field :: %{
          kind: :field,
          name: name,
          colon: boolean,
          value: value,
          offset: non_neg_integer()
        }

  @type value ::
          %{kind: :message, fields: [field], offset: non_neg_integer()}
          | %{kind: :list, values: [value], offset: non_neg_integer()}
          | %{kind: :string, value: binary, offset: non_neg_integer()}
          | %{
              kind: :integer | :float | :identifier,
              value: String.t(),
              negative: boolean,
              offset: non_neg_integer()
            }

  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @spec parse(binary) :: {:ok, [field]} | {:error, Lexer.error()}
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, fields, _rest} <- parse_fields(tokens, :eof, 0, []) do
      {:ok, fields}
    end
  end

  # ── messages ─────────────────────────────────────────────────────────

  defp parse_fields([%{kind: :eof} | _] = tokens, :eof, _depth, acc),
    do: {:ok, Enum.reverse(acc), tokens}

  defp parse_fields([%{kind: :eof} = token | _], close, _depth, _acc),
    do: error(~s(expected "#{close}", found #{describe(token)}), token)

  defp parse_fields([%{kind: :symbol, value: close} | rest], close, _depth, acc),
    do: {:ok, Enum.reverse(acc), rest}

  defp parse_fields([%{kind: :symbol, value: value} = token | _], close, _depth, _acc)
       when value in [">", "}"] and close != :eof,
       do: error(~s(expected "#{close}", found #{describe(token)}), token)

  defp parse_fields(tokens, close, depth, acc) do
    with {:ok, field, rest} <- parse_field(tokens, depth) do
      parse_fields(skip_separator(rest), close, depth, [field | acc])
    end
  end

  defp skip_separator([%{kind: :symbol, value: value} | rest]) when value in [";", ","], do: rest
  defp skip_separator(tokens), do: tokens

  defp parse_field([token | _] = tokens, depth) do
    with {:ok, name, rest} <- parse_name(tokens) do
      {colon, rest} =
        case rest do
          [%{kind: :symbol, value: ":"} | rest] -> {true, rest}
          rest -> {false, rest}
        end

      with {:ok, value, rest} <- parse_value(rest, colon, depth) do
        {:ok, %{kind: :field, name: name, colon: colon, value: value, offset: token.offset}, rest}
      end
    end
  end

  defp parse_name([%{kind: :identifier, value: name} | rest]), do: {:ok, {:field, name}, rest}

  defp parse_name([%{kind: :symbol, value: "["} | rest]) do
    with {:ok, parts, rest} <- parse_bracketed_name(rest, []) do
      name = Enum.join(parts)
      tag = if String.contains?(name, "/"), do: :type_url, else: :extension
      {:ok, {tag, name}, rest}
    end
  end

  defp parse_name([token | _]), do: error("expected field name, found #{describe(token)}", token)

  defp parse_bracketed_name([%{kind: :identifier, value: part} | rest], acc) do
    case rest do
      [%{kind: :symbol, value: sep} | rest] when sep in [".", "/"] ->
        parse_bracketed_name(rest, [sep, part | acc])

      [%{kind: :symbol, value: "]"} | rest] ->
        {:ok, Enum.reverse([part | acc]), rest}

      [token | _] ->
        error(~s(expected "]", found #{describe(token)}), token)
    end
  end

  defp parse_bracketed_name([token | _], _acc),
    do: error("expected identifier, found #{describe(token)}", token)

  # ── values ───────────────────────────────────────────────────────────

  defp parse_value([%{kind: :symbol, value: open} | _] = tokens, _colon, depth)
       when open in ["{", "<"],
       do: parse_message(tokens, depth)

  defp parse_value([%{kind: :symbol, value: "["} = token | rest], _colon, depth),
    do: parse_list(rest, token, depth)

  defp parse_value(tokens, true, _depth), do: parse_scalar(tokens)

  defp parse_value([token | _], false, _depth),
    do: error(~s(expected ":" or a message value, found #{describe(token)}), token)

  defp parse_message([%{kind: :symbol, value: open} = token | rest], depth) do
    if depth >= @max_depth do
      error("message nesting exceeds the depth limit of #{@max_depth}", token)
    else
      close = if open == "{", do: "}", else: ">"

      with {:ok, fields, rest} <- parse_fields(rest, close, depth + 1, []) do
        {:ok, %{kind: :message, fields: fields, offset: token.offset}, rest}
      end
    end
  end

  defp parse_list([%{kind: :symbol, value: "]"} | rest], open, _depth),
    do: {:ok, %{kind: :list, values: [], offset: open.offset}, rest}

  defp parse_list(tokens, open, depth), do: parse_list_elements(tokens, open, depth, [])

  defp parse_list_elements(tokens, open, depth, acc) do
    with {:ok, value, rest} <- parse_element(tokens, depth) do
      case rest do
        [%{kind: :symbol, value: "]"} | rest] ->
          {:ok, %{kind: :list, values: Enum.reverse([value | acc]), offset: open.offset}, rest}

        [%{kind: :symbol, value: ","} | rest] ->
          parse_list_elements(rest, open, depth, [value | acc])

        [token | _] ->
          error(~s(expected "," or "]", found #{describe(token)}), token)
      end
    end
  end

  defp parse_element([%{kind: :symbol, value: open} | _] = tokens, depth)
       when open in ["{", "<"],
       do: parse_message(tokens, depth)

  defp parse_element(tokens, _depth), do: parse_scalar(tokens)

  defp parse_scalar([%{kind: :string} = token | _] = tokens) do
    {strings, rest} = Enum.split_while(tokens, &(&1.kind == :string))
    value = strings |> Enum.map(& &1.value) |> IO.iodata_to_binary()
    {:ok, %{kind: :string, value: value, offset: token.offset}, rest}
  end

  defp parse_scalar([%{kind: :symbol, value: "-"} = minus | rest]) do
    case rest do
      [%{kind: kind} = token | rest] when kind in [:integer, :float] ->
        {:ok, number(token, true, minus.offset), rest}

      [%{kind: :identifier, value: value} = token | rest] ->
        if String.downcase(value) in ["inf", "infinity", "nan"] do
          {:ok, number(token, true, minus.offset), rest}
        else
          error(~s(expected a number after "-", found #{describe(token)}), token)
        end

      [token | _] ->
        error(~s(expected a number after "-", found #{describe(token)}), token)
    end
  end

  defp parse_scalar([%{kind: kind} = token | rest]) when kind in [:integer, :float, :identifier],
    do: {:ok, number(token, false, token.offset), rest}

  defp parse_scalar([token | _]), do: error("expected a value, found #{describe(token)}", token)

  defp number(token, negative, offset),
    do: %{kind: token.kind, value: token.value, negative: negative, offset: offset}

  # ── helpers ──────────────────────────────────────────────────────────

  defp describe(%{kind: :eof}), do: "end of input"
  defp describe(%{kind: :string}), do: "a string"
  defp describe(%{value: value}), do: ~s("#{value}")

  defp error(message, token), do: {:error, %{message: message, offset: token.offset}}
end
