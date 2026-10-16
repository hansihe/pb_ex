defmodule PB.CEL.Runtime.Number do
  @moduledoc false

  alias PB.CEL.Value

  @min_int -9_223_372_036_854_775_808
  @max_int 9_223_372_036_854_775_807
  @max_uint 18_446_744_073_709_551_615

  @type comparison :: :lt | :eq | :gt | :nan
  @type result :: {:ok, Value.t()} | {:error, String.t()} | :error

  @spec negate(Value.t()) :: result
  def negate({:int, value}), do: checked_int(-value)
  def negate({:double, value}), do: {:ok, Value.double(negate_double(value))}
  def negate(_value), do: :error

  @spec add(Value.t(), Value.t()) :: result
  def add({:int, left}, {:int, right}), do: checked_int(left + right)
  def add({:uint, left}, {:uint, right}), do: checked_uint(left + right)

  def add({:double, left}, {:double, right}),
    do: {:ok, Value.double(apply_double(:+, left, right))}

  def add(_left, _right), do: :error

  @spec arithmetic(:- | :* | :/, Value.t(), Value.t()) :: result
  def arithmetic(:/, {:int, _left}, {:int, 0}), do: {:error, "division by zero"}

  def arithmetic(op, {:int, left}, {:int, right}) when op in [:-, :*, :/] do
    checked_int(apply_int(op, left, right))
  end

  def arithmetic(:/, {:uint, _left}, {:uint, 0}), do: {:error, "division by zero"}

  def arithmetic(op, {:uint, left}, {:uint, right}) when op in [:-, :*, :/] do
    checked_uint(apply_int(op, left, right))
  end

  def arithmetic(op, {:double, left}, {:double, right}) when op in [:-, :*, :/] do
    {:ok, Value.double(apply_double(op, left, right))}
  end

  def arithmetic(_op, _left, _right), do: :error

  @spec modulo(Value.t(), Value.t()) :: result
  def modulo({:int, _left}, {:int, 0}), do: {:error, "modulus by zero"}
  def modulo({:int, left}, {:int, right}), do: {:ok, Value.int(rem(left, right))}
  def modulo({:uint, _left}, {:uint, 0}), do: {:error, "modulus by zero"}
  def modulo({:uint, left}, {:uint, right}), do: {:ok, Value.uint(rem(left, right))}
  def modulo(_left, _right), do: :error

  @spec equal?(Value.t(), Value.t()) :: {:ok, boolean} | :error
  def equal?(left, right) do
    case compare(left, right) do
      {:ok, comparison} -> {:ok, comparison == :eq}
      :error -> :error
    end
  end

  @spec compare(Value.t(), Value.t()) :: {:ok, comparison} | :error
  def compare(left, right) do
    compare_numeric(left, right)
  end

  defp checked_int(value) when value >= @min_int and value <= @max_int do
    {:ok, Value.int(value)}
  end

  defp checked_int(_value), do: {:error, "integer overflow"}

  defp checked_uint(value) when value >= 0 and value <= @max_uint do
    {:ok, Value.uint(value)}
  end

  defp checked_uint(_value), do: {:error, "unsigned integer overflow"}

  defp apply_int(:-, left, right), do: left - right
  defp apply_int(:*, left, right), do: left * right
  defp apply_int(:/, left, right), do: div(left, right)

  defp compare_numeric({:int, left}, {:int, right}), do: {:ok, compare_integers(left, right)}
  defp compare_numeric({:uint, left}, {:uint, right}), do: {:ok, compare_integers(left, right)}
  defp compare_numeric({:int, left}, {:uint, right}), do: {:ok, compare_integers(left, right)}
  defp compare_numeric({:uint, left}, {:int, right}), do: {:ok, compare_integers(left, right)}

  defp compare_numeric({:double, left}, {:double, right}),
    do: {:ok, compare_numbers(left, right)}

  defp compare_numeric({:double, left}, right) do
    with {:ok, right} <- integer_as_double(right) do
      {:ok, compare_numbers(left, right)}
    end
  end

  defp compare_numeric(left, {:double, right}) do
    with {:ok, left} <- integer_as_double(left) do
      {:ok, compare_numbers(left, right)}
    end
  end

  defp compare_numeric(_left, _right), do: :error

  defp integer_as_double({:int, value}), do: {:ok, value * 1.0}
  defp integer_as_double({:uint, value}), do: {:ok, value * 1.0}
  defp integer_as_double(_value), do: :error

  defp compare_integers(left, right) when left < right, do: :lt
  defp compare_integers(left, right) when left > right, do: :gt
  defp compare_integers(_left, _right), do: :eq

  defp compare_numbers(:nan, _right), do: :nan
  defp compare_numbers(_left, :nan), do: :nan
  defp compare_numbers(:negative_infinity, :negative_infinity), do: :eq
  defp compare_numbers(:negative_infinity, _right), do: :lt
  defp compare_numbers(_left, :negative_infinity), do: :gt
  defp compare_numbers(:infinity, :infinity), do: :eq
  defp compare_numbers(:infinity, _right), do: :gt
  defp compare_numbers(_left, :infinity), do: :lt
  defp compare_numbers(left, right) when left < right, do: :lt
  defp compare_numbers(left, right) when left > right, do: :gt
  defp compare_numbers(_left, _right), do: :eq

  defp negate_double(:nan), do: :nan
  defp negate_double(:infinity), do: :negative_infinity
  defp negate_double(:negative_infinity), do: :infinity
  defp negate_double(value), do: -value

  defp apply_double(:+, left, right), do: add_double(left, right)
  defp apply_double(:-, left, right), do: add_double(left, negate_double(right))
  defp apply_double(:*, left, right), do: multiply_double(left, right)
  defp apply_double(:/, left, right), do: divide_double(left, right)

  defp add_double(:nan, _right), do: :nan
  defp add_double(_left, :nan), do: :nan
  defp add_double(:infinity, :negative_infinity), do: :nan
  defp add_double(:negative_infinity, :infinity), do: :nan
  defp add_double(:infinity, _right), do: :infinity
  defp add_double(_left, :infinity), do: :infinity
  defp add_double(:negative_infinity, _right), do: :negative_infinity
  defp add_double(_left, :negative_infinity), do: :negative_infinity

  defp add_double(left, right) do
    safe_double(fn -> left + right end, add_overflow_sign(left, right))
  end

  defp multiply_double(:nan, _right), do: :nan
  defp multiply_double(_left, :nan), do: :nan

  defp multiply_double(left, right) when left in [:infinity, :negative_infinity] do
    if zero_double?(right),
      do: :nan,
      else: signed_infinity(combine_signs(double_sign(left), double_sign(right)))
  end

  defp multiply_double(left, right) when right in [:infinity, :negative_infinity] do
    if zero_double?(left),
      do: :nan,
      else: signed_infinity(combine_signs(double_sign(left), double_sign(right)))
  end

  defp multiply_double(left, right) do
    sign = combine_signs(double_sign(left), double_sign(right))
    safe_double(fn -> left * right end, sign)
  end

  defp divide_double(:nan, _right), do: :nan
  defp divide_double(_left, :nan), do: :nan

  defp divide_double(left, right)
       when left in [:infinity, :negative_infinity] and right in [:infinity, :negative_infinity],
       do: :nan

  defp divide_double(left, right) when left in [:infinity, :negative_infinity] do
    signed_infinity(combine_signs(double_sign(left), double_sign(right)))
  end

  defp divide_double(left, right) when right in [:infinity, :negative_infinity] do
    signed_zero(combine_signs(double_sign(left), double_sign(right)))
  end

  defp divide_double(left, right) when right == 0.0 do
    if left == 0.0,
      do: :nan,
      else: signed_infinity(combine_signs(double_sign(left), double_sign(right)))
  end

  defp divide_double(left, right) do
    sign = combine_signs(double_sign(left), double_sign(right))
    safe_double(fn -> left / right end, sign)
  end

  defp safe_double(fun, overflow_sign) do
    fun.()
  rescue
    ArithmeticError -> signed_infinity(overflow_sign)
  end

  defp add_overflow_sign(left, right) do
    left_sign = double_sign(left)
    right_sign = double_sign(right)

    if left_sign == right_sign do
      left_sign
    else
      :positive
    end
  end

  defp zero_double?(value) when is_float(value), do: value == 0.0
  defp zero_double?(_value), do: false

  defp double_sign(:infinity), do: :positive
  defp double_sign(:negative_infinity), do: :negative
  defp double_sign(value) when value < 0.0, do: :negative
  defp double_sign(value) when value == 0.0, do: zero_sign(value)
  defp double_sign(_value), do: :positive

  defp zero_sign(value) do
    if :erlang.term_to_binary(value) == :erlang.term_to_binary(-0.0) do
      :negative
    else
      :positive
    end
  end

  defp combine_signs(:negative, :positive), do: :negative
  defp combine_signs(:positive, :negative), do: :negative
  defp combine_signs(_left, _right), do: :positive

  defp signed_infinity(:negative), do: :negative_infinity
  defp signed_infinity(:positive), do: :infinity

  defp signed_zero(:negative), do: -0.0
  defp signed_zero(:positive), do: 0.0
end
