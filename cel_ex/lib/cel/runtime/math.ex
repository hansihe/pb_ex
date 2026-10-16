defmodule CEL.Runtime.Math do
  @moduledoc false

  import Bitwise

  alias CEL.Runtime.Number
  alias CEL.Value

  @min_int -9_223_372_036_854_775_808
  @max_int 9_223_372_036_854_775_807
  @max_uint 18_446_744_073_709_551_615

  @type result :: {:ok, Value.t()} | {:error, String.t()}

  @spec is_nan([Value.t()]) :: result
  def is_nan([{:double, :nan}]), do: {:ok, Value.bool(true)}
  def is_nan([{:double, _value}]), do: {:ok, Value.bool(false)}
  def is_nan([_value]), do: no_such_overload()
  def is_nan(_values), do: no_such_overload()

  @spec is_inf([Value.t()]) :: result
  def is_inf([{:double, value}]) when value in [:infinity, :negative_infinity],
    do: {:ok, Value.bool(true)}

  def is_inf([{:double, _value}]), do: {:ok, Value.bool(false)}
  def is_inf([_value]), do: no_such_overload()
  def is_inf(_values), do: no_such_overload()

  @spec is_finite([Value.t()]) :: result
  def is_finite([{:double, value}]) when is_float(value), do: {:ok, Value.bool(true)}
  def is_finite([{:double, _value}]), do: {:ok, Value.bool(false)}
  def is_finite([_value]), do: no_such_overload()
  def is_finite(_values), do: no_such_overload()

  @spec greatest([Value.t()]) :: result
  def greatest(values), do: extrema(:greatest, values)

  @spec least([Value.t()]) :: result
  def least(values), do: extrema(:least, values)

  @spec ceil([Value.t()]) :: result
  def ceil([value]), do: double_math(:ceil, value)
  def ceil(_values), do: no_such_overload()

  @spec floor([Value.t()]) :: result
  def floor([value]), do: double_math(:floor, value)
  def floor(_values), do: no_such_overload()

  @spec round([Value.t()]) :: result
  def round([value]), do: double_math(:round, value)
  def round(_values), do: no_such_overload()

  @spec trunc([Value.t()]) :: result
  def trunc([value]), do: double_math(:trunc, value)
  def trunc(_values), do: no_such_overload()

  @spec abs([Value.t()]) :: result
  def abs([value]), do: abs_value(value)
  def abs(_values), do: no_such_overload()

  @spec sign([Value.t()]) :: result
  def sign([value]), do: sign_value(value)
  def sign(_values), do: no_such_overload()

  @spec bit_and([Value.t()]) :: result
  def bit_and([left, right]), do: bit_binary(:and, left, right)
  def bit_and(_values), do: no_such_overload()

  @spec bit_or([Value.t()]) :: result
  def bit_or([left, right]), do: bit_binary(:or, left, right)
  def bit_or(_values), do: no_such_overload()

  @spec bit_xor([Value.t()]) :: result
  def bit_xor([left, right]), do: bit_binary(:xor, left, right)
  def bit_xor(_values), do: no_such_overload()

  @spec bit_not([Value.t()]) :: result
  def bit_not([value]), do: bit_not_value(value)
  def bit_not(_values), do: no_such_overload()

  @spec bit_shift_left([Value.t()]) :: result
  def bit_shift_left([value, offset]), do: bit_shift(:left, value, offset)
  def bit_shift_left(_values), do: no_such_overload()

  @spec bit_shift_right([Value.t()]) :: result
  def bit_shift_right([value, offset]), do: bit_shift(:right, value, offset)
  def bit_shift_right(_values), do: no_such_overload()

  defp extrema(function, [{:list, values}]), do: extrema_values(function, values)
  defp extrema(function, values), do: extrema_values(function, values)

  defp extrema_values(_function, []), do: no_such_overload()

  defp extrema_values(function, [value | rest]) do
    if numeric_value?(value) do
      Enum.reduce_while(rest, {:ok, value}, fn value, {:ok, selected} ->
        if numeric_value?(value) do
          {:cont, {:ok, select_extrema(function, selected, value)}}
        else
          {:halt, no_such_overload()}
        end
      end)
    else
      no_such_overload()
    end
  end

  defp select_extrema(function, selected, value) do
    case Number.compare(value, selected) do
      {:ok, :nan} -> Value.double(:nan)
      {:ok, :gt} when function == :greatest -> value
      {:ok, :lt} when function == :least -> value
      {:ok, _comparison} -> selected
    end
  end

  defp numeric_value?(value), do: match?({:ok, _comparison}, Number.compare(value, value))

  defp double_math(_function, {:double, value})
       when value in [:nan, :infinity, :negative_infinity] do
    {:ok, Value.double(value)}
  end

  defp double_math(:ceil, {:double, value}), do: {:ok, Value.double(Float.ceil(value))}
  defp double_math(:floor, {:double, value}), do: {:ok, Value.double(Float.floor(value))}
  defp double_math(:round, {:double, value}), do: {:ok, Value.double(Float.round(value))}

  defp double_math(:trunc, {:double, value}),
    do: {:ok, Value.double(Kernel.trunc(value) * 1.0)}

  defp double_math(_function, _value), do: no_such_overload()

  defp abs_value({:int, @min_int}), do: {:error, "overflow"}
  defp abs_value({:int, value}), do: {:ok, Value.int(Kernel.abs(value))}
  defp abs_value({:uint, value}), do: {:ok, Value.uint(value)}
  defp abs_value({:double, value}) when value in [:nan, :infinity], do: {:ok, Value.double(value)}
  defp abs_value({:double, :negative_infinity}), do: {:ok, Value.double(:infinity)}
  defp abs_value({:double, value}), do: {:ok, Value.double(Kernel.abs(value))}
  defp abs_value(_value), do: no_such_overload()

  defp sign_value({:uint, 0}), do: {:ok, Value.uint(0)}
  defp sign_value({:uint, _value}), do: {:ok, Value.uint(1)}
  defp sign_value({:int, value}) when value > 0, do: {:ok, Value.int(1)}
  defp sign_value({:int, value}) when value < 0, do: {:ok, Value.int(-1)}
  defp sign_value({:int, 0}), do: {:ok, Value.int(0)}
  defp sign_value({:double, :nan}), do: {:ok, Value.double(:nan)}
  defp sign_value({:double, :infinity}), do: {:ok, Value.double(1.0)}
  defp sign_value({:double, :negative_infinity}), do: {:ok, Value.double(-1.0)}
  defp sign_value({:double, value}) when value > 0.0, do: {:ok, Value.double(1.0)}
  defp sign_value({:double, value}) when value < 0.0, do: {:ok, Value.double(-1.0)}
  defp sign_value({:double, _value}), do: {:ok, Value.double(0.0)}
  defp sign_value(_value), do: no_such_overload()

  defp bit_binary(op, {:int, left}, {:int, right}) do
    {:ok, Value.int(apply_bit(op, left, right))}
  end

  defp bit_binary(op, {:uint, left}, {:uint, right}) do
    {:ok, Value.uint(apply_bit(op, left, right) &&& @max_uint)}
  end

  defp bit_binary(_op, _left, _right), do: no_such_overload()

  defp bit_not_value({:int, value}), do: {:ok, Value.int(bnot(value))}
  defp bit_not_value({:uint, value}), do: {:ok, Value.uint(bnot(value) &&& @max_uint)}
  defp bit_not_value(_value), do: no_such_overload()

  defp bit_shift(_direction, _value, {:int, offset}) when offset < 0,
    do: {:error, "negative offset"}

  defp bit_shift(:left, {:int, value}, {:int, offset}) do
    {:ok, Value.int(value |> unsigned_64() |> shift_left(offset) |> signed_64())}
  end

  defp bit_shift(:left, {:uint, value}, {:int, offset}) do
    {:ok, Value.uint(shift_left(value, offset))}
  end

  defp bit_shift(:right, {:int, value}, {:int, offset}) do
    {:ok, Value.int(value |> unsigned_64() |> shift_right(offset) |> signed_64())}
  end

  defp bit_shift(:right, {:uint, value}, {:int, offset}) do
    {:ok, Value.uint(shift_right(value, offset))}
  end

  defp bit_shift(_direction, _value, _offset), do: no_such_overload()

  defp apply_bit(:and, left, right), do: left &&& right
  defp apply_bit(:or, left, right), do: left ||| right
  defp apply_bit(:xor, left, right), do: bxor(left, right)

  defp shift_left(_value, offset) when offset >= 64, do: 0
  defp shift_left(value, offset), do: value <<< offset &&& @max_uint

  defp shift_right(_value, offset) when offset >= 64, do: 0
  defp shift_right(value, offset), do: value >>> offset

  defp unsigned_64(value), do: value &&& @max_uint

  defp signed_64(value) when value > @max_int, do: value - @max_uint - 1
  defp signed_64(value), do: value

  defp no_such_overload, do: {:error, "no such overload"}
end
