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
end
