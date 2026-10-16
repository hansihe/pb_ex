defmodule PB.CEL.Runtime.Convert do
  @moduledoc false

  alias PB.CEL.Runtime.Time
  alias PB.CEL.Value

  @min_int -9_223_372_036_854_775_808
  @max_int 9_223_372_036_854_775_807
  @max_uint 18_446_744_073_709_551_615

  @type result :: {:ok, Value.t()} | {:error, String.t()}

  @spec to_bool([Value.t()]) :: result
  def to_bool([value]), do: convert(:bool, value)
  def to_bool(_values), do: no_such_overload()

  @spec to_bytes([Value.t()]) :: result
  def to_bytes([value]), do: convert(:bytes, value)
  def to_bytes(_values), do: no_such_overload()

  @spec to_double([Value.t()]) :: result
  def to_double([value]), do: convert(:double, value)
  def to_double(_values), do: no_such_overload()

  @spec to_int([Value.t()]) :: result
  def to_int([value]), do: convert(:int, value)
  def to_int(_values), do: no_such_overload()

  @spec to_string([Value.t()]) :: result
  def to_string([value]), do: convert(:string, value)
  def to_string(_values), do: no_such_overload()

  @spec to_timestamp([Value.t()]) :: result
  def to_timestamp([value]), do: convert(:timestamp, value)
  def to_timestamp(_values), do: no_such_overload()

  @spec to_duration([Value.t()]) :: result
  def to_duration([value]), do: convert(:duration, value)
  def to_duration(_values), do: no_such_overload()

  @spec to_uint([Value.t()]) :: result
  def to_uint([value]), do: convert(:uint, value)
  def to_uint(_values), do: no_such_overload()

  defp convert(:bool, {:bool, value}), do: {:ok, Value.bool(value)}

  defp convert(:bool, {:string, value})
       when value in ["1", "t", "T", "true", "TRUE", "True"],
       do: {:ok, Value.bool(true)}

  defp convert(:bool, {:string, value})
       when value in ["0", "f", "F", "false", "FALSE", "False"],
       do: {:ok, Value.bool(false)}

  defp convert(:bytes, {:bytes, value}), do: {:ok, Value.bytes(value)}
  defp convert(:bytes, {:string, value}), do: {:ok, Value.bytes(value)}
  defp convert(:double, {:double, value}), do: {:ok, Value.double(value)}
  defp convert(:double, {:int, value}), do: {:ok, Value.double(value * 1.0)}
  defp convert(:double, {:uint, value}), do: {:ok, Value.double(value * 1.0)}
  defp convert(:double, {:string, "NaN"}), do: {:ok, Value.double(:nan)}
  defp convert(:double, {:string, "Infinity"}), do: {:ok, Value.double(:infinity)}
  defp convert(:double, {:string, "-Infinity"}), do: {:ok, Value.double(:negative_infinity)}

  defp convert(:double, {:string, value}) do
    case Float.parse(value) do
      {double, ""} -> {:ok, Value.double(double)}
      _other -> {:error, "cannot convert string to double"}
    end
  end

  defp convert(:int, {:int, value}), do: {:ok, Value.int(value)}
  defp convert(:int, {:enum, _type, value}), do: {:ok, Value.int(value)}
  defp convert(:int, {:uint, value}) when value <= @max_int, do: {:ok, Value.int(value)}
  defp convert(:int, {:uint, _value}), do: {:error, "uint value is out of int range"}

  defp convert(:int, {:double, value}) when value > @min_int and value < @max_int do
    {:ok, Value.int(trunc(value))}
  end

  defp convert(:int, {:double, _value}), do: {:error, "double value is out of int range"}

  defp convert(:int, {:string, value}) do
    with {int, ""} <- Integer.parse(value),
         true <- int >= @min_int and int <= @max_int do
      {:ok, Value.int(int)}
    else
      _other -> {:error, "cannot convert string to int"}
    end
  end

  defp convert(:string, {:string, value}), do: {:ok, Value.string(value)}
  defp convert(:string, {:bool, value}), do: {:ok, Value.string(Kernel.to_string(value))}
  defp convert(:string, {:int, value}), do: {:ok, Value.string(Integer.to_string(value))}
  defp convert(:string, {:uint, value}), do: {:ok, Value.string(Integer.to_string(value))}
  defp convert(:string, {:double, :nan}), do: {:ok, Value.string("NaN")}
  defp convert(:string, {:double, :infinity}), do: {:ok, Value.string("Infinity")}
  defp convert(:string, {:double, :negative_infinity}), do: {:ok, Value.string("-Infinity")}

  defp convert(:string, {:double, value}) do
    {:ok, Value.string(:erlang.float_to_binary(value, [:short]))}
  end

  defp convert(:string, {:bytes, value}) do
    if String.valid?(value) do
      {:ok, Value.string(value)}
    else
      {:error, "bytes value is not valid UTF-8"}
    end
  end

  defp convert(:uint, {:uint, value}), do: {:ok, Value.uint(value)}
  defp convert(:uint, {:int, value}) when value >= 0, do: {:ok, Value.uint(value)}
  defp convert(:uint, {:int, _value}), do: {:error, "int value is out of uint range"}

  defp convert(:uint, {:double, value}) when value >= 0 and value < @max_uint do
    {:ok, Value.uint(trunc(value))}
  end

  defp convert(:uint, {:double, _value}), do: {:error, "double value is out of uint range"}

  defp convert(:uint, {:string, value}) do
    with {uint, ""} <- Integer.parse(value),
         true <- uint >= 0 and uint <= @max_uint do
      {:ok, Value.uint(uint)}
    else
      _other -> {:error, "cannot convert string to uint"}
    end
  end

  defp convert(target, value) when target in [:duration, :int, :string, :timestamp] do
    case Time.convert(target, value) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      :error -> {:error, "cannot convert #{value_kind(value)} to #{target}"}
    end
  end

  defp convert(target, value), do: {:error, "cannot convert #{value_kind(value)} to #{target}"}

  defp value_kind(:null), do: "null"
  defp value_kind({kind, _value}), do: Atom.to_string(kind)
  defp value_kind({:enum, name, _value}), do: name
  defp value_kind({:object, type_url, _value}), do: type_url
  defp value_kind({:message, name, _fields}), do: name
  defp value_kind(other), do: inspect(other)

  defp no_such_overload, do: {:error, "no such overload"}
end
