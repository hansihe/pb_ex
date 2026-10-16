defmodule PB.TextFormat.Scalars do
  @moduledoc false

  # Converts parser scalar nodes into field values, following the C++ text
  # format parser's per-type rules:
  #
  #   * integer fields take decimal, hex or octal integer literals; only signed
  #     types accept a minus sign, which allows one more negative value
  #   * float and double fields take decimal integers, floats, and
  #     `inf`/`infinity`/`nan` in any case, but not hex or octal; out-of-range
  #     values become infinity or zero, and floats are rounded to 32 bits the
  #     way C++ `SafeDoubleToFloat` does
  #   * bool fields take `true`/`True`/`t`, `false`/`False`/`f`, or the
  #     integers 0 and 1 in any base
  #
  # Errors are returned as `{:invalid_value, expected, got}` or
  # `{:value_out_of_range, min, max, value}`; the decoder adds the path.
  #
  # `format/2` goes the other way for the printer, writing text both PB and
  # C++ parse back to the same value:
  #
  #   * `string` values print as-is apart from `"`, `\\` and control
  #     characters; `bytes`, and `string` values that are not valid UTF-8,
  #     escape every byte outside printable ASCII as `\\xNN`
  #   * floats print the shortest text that reads back to the same value
  #     (for `float` fields, the same 32-bit value), positional when the
  #     decimal exponent is in -4..15 and scientific otherwise, without a
  #     trailing `.0`: `3`, `0.1`, `-0`, `1e+16`, `1.5e-7`, `inf`, `nan`
  #   * enums print their value name, or the number when it has none

  alias PB.Runtime.Scalar
  alias PB.Wire

  @float32_max 3.4028234663852886e38
  # Values up to here round to the float32 maximum rather than to infinity.
  @float32_max_rounded 3.4028235677973366e38

  @doc """
  Converts an integer literal for a field of the given integer type.
  """
  def integer(%{kind: :integer, value: text, negative: negative}, type) do
    {min, max} = Scalar.integer_range(type)

    if negative and min == 0 do
      {:error, {:invalid_value, :unsigned_integer, "-" <> text}}
    else
      magnitude = parse_integer(text)
      value = if negative, do: -magnitude, else: magnitude

      if value in min..max//1,
        do: {:ok, value},
        else: {:error, {:value_out_of_range, min, max, value}}
    end
  end

  def integer(node, _type), do: {:error, {:invalid_value, :integer, source(node)}}

  @doc """
  Converts a literal for a `TYPE_DOUBLE` or `TYPE_FLOAT` field.
  """
  def float(node, type) do
    with {:ok, value} <- double(node) do
      value = if node.negative, do: negate(value), else: value
      {:ok, if(type == :TYPE_FLOAT, do: to_float32(value), else: value)}
    end
  end

  defp double(%{kind: :integer, value: text} = node) do
    if hex_or_octal?(text),
      do: {:error, {:invalid_value, :decimal_number, source(node)}},
      else: {:ok, decimal_to_double(text)}
  end

  defp double(%{kind: :float, value: text}), do: {:ok, decimal_to_double(strip_suffix(text))}

  defp double(%{kind: :identifier, value: text} = node) do
    case String.downcase(text) do
      inf when inf in ["inf", "infinity"] -> {:ok, :infinity}
      "nan" -> {:ok, :nan}
      _ -> {:error, {:invalid_value, :number, source(node)}}
    end
  end

  defp double(node), do: {:error, {:invalid_value, :number, source(node)}}

  @doc """
  Converts a literal for a `TYPE_BOOL` field.
  """
  def bool(%{kind: :integer, value: text, negative: false} = node) do
    case parse_integer(text) do
      0 -> {:ok, false}
      1 -> {:ok, true}
      _ -> {:error, {:invalid_value, :boolean, source(node)}}
    end
  end

  def bool(%{kind: :identifier, value: text, negative: false}) when text in ["true", "True", "t"],
    do: {:ok, true}

  def bool(%{kind: :identifier, value: text, negative: false})
      when text in ["false", "False", "f"],
      do: {:ok, false}

  def bool(node), do: {:error, {:invalid_value, :boolean, source(node)}}

  @doc """
  Converts a literal for a `TYPE_STRING` (UTF-8 checked when `verify_utf8`)
  or `TYPE_BYTES` field.
  """
  def string(%{kind: :string, value: value}, verify_utf8) do
    if verify_utf8 and not String.valid?(value),
      do: {:error, {:invalid_value, :utf8_string, value}},
      else: {:ok, value}
  end

  def string(node, _verify_utf8), do: {:error, {:invalid_value, :string, source(node)}}

  @doc """
  The source text of a scalar node, for error reporting.
  """
  def source(%{kind: :string, value: value}), do: value
  def source(%{kind: kind}) when kind in [:message, :list], do: kind
  def source(%{value: value, negative: true}), do: "-" <> value
  def source(%{value: value}), do: value

  # ── numbers ──────────────────────────────────────────────────────────

  # The lexer only produces well-formed integer literals.
  defp parse_integer("0x" <> digits), do: String.to_integer(digits, 16)
  defp parse_integer("0X" <> digits), do: String.to_integer(digits, 16)
  defp parse_integer("0" <> digits) when digits != "", do: String.to_integer(digits, 8)
  defp parse_integer(digits), do: String.to_integer(digits)

  defp strip_suffix(text) do
    if String.ends_with?(text, ["f", "F"]),
      do: binary_part(text, 0, byte_size(text) - 1),
      else: text
  end

  defp hex_or_octal?(<<?0, next, _::binary>>), do: next in [?x, ?X] or next in ?0..?7
  defp hex_or_octal?(_text), do: false

  # Converts a decimal literal (digits, optional fraction, optional exponent;
  # either side of the point may be empty) to the nearest double, mapping
  # overflow to infinity and underflow to zero. `:erlang.binary_to_float/1`
  # rounds correctly but needs `D.DeX` form and rejects overflow, so the
  # literal is normalized first and absurd exponents are settled up front.
  defp decimal_to_double(text) do
    {mantissa, exponent} =
      case :binary.split(String.downcase(text), "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    {int, frac} =
      case :binary.split(mantissa, ".") do
        [int, frac] -> {int, frac}
        [int] -> {int, ""}
      end

    digits = String.trim_leading(int <> frac, "0")

    if digits == "" do
      0.0
    else
      # value = 0.d1d2d3... * 10^scale
      scale = exponent - byte_size(frac) + byte_size(digits)

      cond do
        scale > 310 -> :infinity
        scale < -330 -> 0.0
        true -> to_double(digits, scale - 1)
      end
    end
  end

  defp to_double(<<first, rest::binary>>, exponent) do
    rest = if rest == "", do: "0", else: rest
    :erlang.binary_to_float(<<first, ?., rest::binary, ?e, Integer.to_string(exponent)::binary>>)
  rescue
    ArgumentError -> :infinity
  end

  defp negate(:infinity), do: :negative_infinity
  defp negate(:nan), do: :nan
  defp negate(value), do: -value

  defp to_float32(value) when is_float(value) do
    cond do
      value > @float32_max_rounded -> :infinity
      value > @float32_max -> @float32_max
      value < -@float32_max_rounded -> :negative_infinity
      value < -@float32_max -> -@float32_max
      true -> Wire.decode_float32(Wire.encode_float32(value))
    end
  end

  defp to_float32(special), do: special

  # ── printing ─────────────────────────────────────────────────────────

  @doc """
  Text for an already validated value of `field`.
  """
  @spec format(map, term) :: iodata
  def format(%{type: :TYPE_STRING}, value), do: quote_string(value)
  def format(%{type: :TYPE_BYTES}, value), do: quote_bytes(value)
  def format(%{type: :TYPE_BOOL}, true), do: "true"
  def format(%{type: :TYPE_BOOL}, false), do: "false"
  def format(%{type: :TYPE_ENUM}, value) when is_atom(value), do: Atom.to_string(value)

  def format(%{type: :TYPE_ENUM} = field, value) do
    case get_in(field, [:enum, :by_number, value]) do
      nil -> Integer.to_string(value)
      name -> Atom.to_string(name)
    end
  end

  def format(%{type: :TYPE_DOUBLE}, value), do: format_double(value)
  def format(%{type: :TYPE_FLOAT}, value), do: format_float32(value)
  def format(_integer_field, value), do: Integer.to_string(value)

  @doc """
  A quoted `bytes` literal: printable ASCII as-is, everything else escaped.
  """
  @spec quote_bytes(binary) :: iodata
  def quote_bytes(bytes), do: [?", escape(bytes, false, []), ?"]

  @doc """
  A quoted `string` literal: valid UTF-8 is kept, invalid UTF-8 is escaped
  like `bytes`.
  """
  @spec quote_string(binary) :: iodata
  def quote_string(string), do: [?", escape(string, String.valid?(string), []), ?"]

  defp escape(<<byte, rest::binary>>, utf8, acc),
    do: escape(rest, utf8, [acc, escape_byte(byte, utf8)])

  defp escape(<<>>, _utf8, acc), do: acc

  defp escape_byte(?", _utf8), do: ~S(\")
  defp escape_byte(?\\, _utf8), do: ~S(\\)
  defp escape_byte(?\n, _utf8), do: ~S(\n)
  defp escape_byte(?\r, _utf8), do: ~S(\r)
  defp escape_byte(?\t, _utf8), do: ~S(\t)
  defp escape_byte(byte, _utf8) when byte in 0x20..0x7E, do: byte
  defp escape_byte(byte, true) when byte >= 0x80, do: byte

  # Always two digits: the parser reads at most two, so a following hex digit
  # cannot be absorbed into the escape.
  defp escape_byte(byte, _utf8),
    do: ["\\x", byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")]

  defp format_double(value) when is_integer(value), do: format_double(:erlang.float(value))
  defp format_double(value) when is_float(value), do: format_finite(value, &double_digits/1)
  defp format_double(special), do: format_special(special)

  defp format_float32(value) when is_number(value) do
    case Wire.decode_float32(Wire.encode_float32(value)) do
      rounded when is_float(rounded) -> format_finite(rounded, &float32_digits/1)
      special -> format_special(special)
    end
  end

  defp format_float32(special), do: format_special(special)

  defp format_special(:infinity), do: "inf"
  defp format_special(:negative_infinity), do: "-inf"
  defp format_special(:nan), do: "nan"

  defp format_finite(value, digits_fun) do
    <<sign::1, _::63>> = <<value::float-64>>
    {digits, point} = digits_fun.(abs(value))
    if(sign == 1, do: "-", else: "") <> layout(digits, point)
  end

  # `:short` gives the shortest digits that read back as the same double.
  defp double_digits(value), do: value |> :erlang.float_to_binary([:short]) |> decimal_digits()

  # The fewest significant digits (at most 9) that read back as the same
  # 32-bit float.
  defp float32_digits(value) do
    target = Wire.encode_float32(value)

    Enum.find_value(1..9, fn precision ->
      text = :erlang.float_to_binary(value, [{:scientific, precision - 1}])
      {parsed, ""} = Float.parse(text)
      if Wire.encode_float32(parsed) == target, do: decimal_digits(text)
    end)
  end

  # Splits a decimal rendering into significant digits and the position of
  # the decimal point: value = 0.digits * 10^point.
  defp decimal_digits(text) do
    {mantissa, exponent} =
      case :binary.split(text, "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    {int, frac} =
      case :binary.split(mantissa, ".") do
        [int, frac] -> {int, frac}
        [int] -> {int, ""}
      end

    all = int <> frac
    stripped = String.trim_leading(all, "0")
    point = byte_size(int) + exponent - (byte_size(all) - byte_size(stripped))
    {String.trim_trailing(stripped, "0"), point}
  end

  defp layout("", _point), do: "0"

  defp layout(digits, point) when point - 1 >= -4 and point - 1 < 16 do
    count = byte_size(digits)

    cond do
      point >= count ->
        digits <> String.duplicate("0", point - count)

      point > 0 ->
        binary_part(digits, 0, point) <> "." <> binary_part(digits, point, count - point)

      true ->
        "0." <> String.duplicate("0", -point) <> digits
    end
  end

  defp layout(<<first, rest::binary>>, point) do
    exponent = point - 1
    sign = if exponent < 0, do: "-", else: "+"
    fraction = if rest == "", do: "", else: "." <> rest
    <<first>> <> fraction <> "e" <> sign <> Integer.to_string(abs(exponent))
  end
end
