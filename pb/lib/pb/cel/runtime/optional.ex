defmodule PB.CEL.Runtime.Optional do
  @moduledoc false

  alias PB.CEL.Value

  @type result :: {:ok, Value.t()} | {:error, String.t()}

  @spec none([Value.t()]) :: result
  def none([]), do: {:ok, Value.optional_none()}
  def none(_values), do: no_such_overload()

  @spec of([Value.t()]) :: result
  def of([value]), do: {:ok, Value.optional_some(value)}
  def of(_values), do: no_such_overload()

  @spec of_non_zero_value([Value.t()]) :: result
  def of_non_zero_value([value]), do: {:ok, optional_of_non_zero(value)}
  def of_non_zero_value(_values), do: no_such_overload()

  @spec unwrap([Value.t()]) :: result
  def unwrap([{:optional, {:some, value}}]), do: {:ok, value}
  def unwrap([{:optional, :none}]), do: {:error, "cannot unwrap empty optional"}
  def unwrap(_values), do: no_such_overload()

  @spec has_value([Value.t()]) :: result
  def has_value([target]), do: {:ok, Value.bool(match?({:optional, {:some, _}}, target))}
  def has_value(_values), do: no_such_overload()

  @spec value([Value.t()]) :: result
  def value([{:optional, {:some, value}}]), do: {:ok, value}
  def value([{:optional, :none}]), do: {:error, "cannot read value from empty optional"}
  def value(_values), do: no_such_overload()

  def unquote(:or)([{:optional, {:some, _value}} = target, _fallback]), do: {:ok, target}
  def unquote(:or)([{:optional, :none}, fallback]), do: {:ok, fallback}
  def unquote(:or)(_values), do: no_such_overload()

  @spec or_value([Value.t()]) :: result
  def or_value([{:optional, {:some, value}}, _fallback]), do: {:ok, value}
  def or_value([{:optional, :none}, fallback]), do: {:ok, fallback}
  def or_value(_values), do: no_such_overload()

  defp optional_of_non_zero(:null), do: Value.optional_none()
  defp optional_of_non_zero({:bool, false}), do: Value.optional_none()
  defp optional_of_non_zero({:int, 0}), do: Value.optional_none()
  defp optional_of_non_zero({:uint, 0}), do: Value.optional_none()
  defp optional_of_non_zero({:double, value}) when value == 0.0, do: Value.optional_none()
  defp optional_of_non_zero({:string, ""}), do: Value.optional_none()
  defp optional_of_non_zero({:bytes, ""}), do: Value.optional_none()
  defp optional_of_non_zero({:list, []}), do: Value.optional_none()
  defp optional_of_non_zero({:map, values}) when map_size(values) == 0, do: Value.optional_none()

  defp optional_of_non_zero({:message, _name, fields}) when map_size(fields) == 0,
    do: Value.optional_none()

  defp optional_of_non_zero({:optional, :none}), do: Value.optional_none()
  defp optional_of_non_zero({:optional, {:some, value}}), do: optional_of_non_zero(value)
  defp optional_of_non_zero(value), do: Value.optional_some(value)

  defp no_such_overload, do: {:error, "no such overload"}
end
