defmodule CEL.Runtime.Core do
  @moduledoc false

  alias CEL.Checker.Types, as: CType
  alias CEL.Runtime.Number
  alias CEL.Runtime.Time
  alias CEL.Value

  @type result :: {:ok, Value.t()} | {:error, String.t()}

  @spec logical_not([Value.t()]) :: result
  def logical_not([value]), do: logical_not_value(value)
  def logical_not(_values), do: no_such_overload()

  @spec not_strictly_false([Value.t()]) :: result
  def not_strictly_false([value]), do: not_strictly_false_value(value)
  def not_strictly_false(_values), do: no_such_overload()

  @spec negate([Value.t()]) :: result
  def negate([value]), do: negate_value(value)
  def negate(_values), do: no_such_overload()

  @spec equals([Value.t()]) :: result
  def equals([left, right]), do: {:ok, Value.bool(equal?(left, right))}
  def equals(_values), do: no_such_overload()

  @spec equals([Value.t()], CEL.TypeProvider.t()) :: result
  def equals([left, right], types), do: {:ok, Value.bool(equal?(left, right, types))}
  def equals(_values, _types), do: no_such_overload()

  @spec not_equals([Value.t()]) :: result
  def not_equals([left, right]), do: {:ok, Value.bool(not equal?(left, right))}
  def not_equals(_values), do: no_such_overload()

  @spec not_equals([Value.t()], CEL.TypeProvider.t()) :: result
  def not_equals([left, right], types), do: {:ok, Value.bool(not equal?(left, right, types))}
  def not_equals(_values, _types), do: no_such_overload()

  @spec less([Value.t()]) :: result
  def less([left, right]), do: compare(left, right, :<)
  def less(_values), do: no_such_overload()

  @spec less_equals([Value.t()]) :: result
  def less_equals([left, right]), do: compare(left, right, :<=)
  def less_equals(_values), do: no_such_overload()

  @spec greater([Value.t()]) :: result
  def greater([left, right]), do: compare(left, right, :>)
  def greater(_values), do: no_such_overload()

  @spec greater_equals([Value.t()]) :: result
  def greater_equals([left, right]), do: compare(left, right, :>=)
  def greater_equals(_values), do: no_such_overload()

  @spec contains([Value.t()]) :: result
  def contains([needle, haystack]), do: contains(needle, haystack)
  def contains(_values), do: no_such_overload()

  @spec index([Value.t()]) :: result
  def index([container, key]), do: index(container, key)
  def index(_values), do: no_such_overload()

  @spec optional_index([Value.t()]) :: result
  def optional_index([container, key]), do: optional_index(container, key)
  def optional_index(_values), do: no_such_overload()

  @spec optional_select([Value.t()]) :: result
  def optional_select([container, {:string, field}]), do: optional_select(container, field)
  def optional_select([_container, _field]), do: no_such_overload()
  def optional_select(_values), do: no_such_overload()

  @spec add([Value.t()]) :: result
  def add([left, right]), do: add(left, right)
  def add(_values), do: no_such_overload()

  @spec subtract([Value.t()]) :: result
  def subtract([left, right]), do: arithmetic(left, right, :-)
  def subtract(_values), do: no_such_overload()

  @spec multiply([Value.t()]) :: result
  def multiply([left, right]), do: arithmetic(left, right, :*)
  def multiply(_values), do: no_such_overload()

  @spec divide([Value.t()]) :: result
  def divide([left, right]), do: arithmetic(left, right, :/)
  def divide(_values), do: no_such_overload()

  @spec modulo([Value.t()]) :: result
  def modulo([left, right]), do: modulo(left, right)
  def modulo(_values), do: no_such_overload()

  @spec size([Value.t()]) :: result
  def size([value]), do: size_value(value)
  def size(_values), do: no_such_overload()

  @spec dyn([Value.t()]) :: result
  def dyn([value]), do: {:ok, value}
  def dyn(_values), do: no_such_overload()

  @spec type_of([Value.t()]) :: result
  def type_of([value]),
    do: {:ok, {:type, value |> Value.type_of() |> runtime_type() |> CType.to_cel()}}

  def type_of(_values), do: no_such_overload()

  # Without a provider, messages of the same type are equal when their payloads
  # are.
  @spec equal?(Value.t(), Value.t(), CEL.TypeProvider.t() | nil) :: boolean
  def equal?(left, right, types \\ nil) do
    case Number.equal?(left, right) do
      {:ok, equal?} -> equal?
      :error -> equal_non_numeric?(left, right, types)
    end
  end

  @spec fetch_equal_key(%{Value.t() => Value.t()}, Value.t(), CEL.TypeProvider.t() | nil) ::
          {:ok, Value.t()} | :error
  def fetch_equal_key(values, key, types \\ nil) do
    Enum.find_value(values, :error, fn {candidate, value} ->
      if equal?(candidate, key, types), do: {:ok, value}, else: false
    end)
  end

  defp contains(needle, {:list, values}) do
    {:ok, Value.bool(Enum.any?(values, &equal?(&1, needle)))}
  end

  defp contains(needle, {:map, values}) do
    {:ok, Value.bool(match?({:ok, _value}, fetch_equal_key(values, needle)))}
  end

  defp contains(_needle, _haystack), do: {:error, "@in requires list or map"}

  defp logical_not_value({:bool, value}), do: {:ok, Value.bool(not value)}
  defp logical_not_value(value), do: {:error, "expected bool, got #{value_kind(value)}"}

  defp not_strictly_false_value({:bool, false}), do: {:ok, Value.bool(false)}
  defp not_strictly_false_value(_value), do: {:ok, Value.bool(true)}

  defp index({:list, values}, key) do
    with {:ok, index} <- list_index(key),
         true <- index >= 0 and index < length(values) do
      {:ok, Enum.at(values, index)}
    else
      _other -> {:error, "index not found"}
    end
  end

  defp index({:map, values}, key) do
    case fetch_equal_key(values, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "index not found"}
    end
  end

  defp index({:optional, _value} = container, key), do: optional_index(container, key)
  defp index(_container, _key), do: {:error, "index not found"}

  defp optional_index({:optional, :none}, _key), do: {:ok, Value.optional_none()}

  defp optional_index({:optional, {:some, container}}, key) do
    optional_index(container, key)
  end

  defp optional_index({:list, values}, key) do
    with {:ok, index} <- list_index(key),
         true <- index >= 0 and index < length(values) do
      {:ok, Value.optional_some(Enum.at(values, index))}
    else
      _other -> {:ok, Value.optional_none()}
    end
  end

  defp optional_index({:map, values}, key) do
    case fetch_equal_key(values, key) do
      {:ok, value} -> {:ok, Value.optional_some(value)}
      :error -> {:ok, Value.optional_none()}
    end
  end

  defp optional_index(_container, _key), do: {:ok, Value.optional_none()}

  defp optional_select({:map, values}, field) do
    key = Value.string(field)

    case Map.fetch(values, key) do
      {:ok, value} -> {:ok, maybe_optional_some(value)}
      :error -> {:ok, Value.optional_none()}
    end
  end

  defp optional_select({:optional, :none}, _field), do: {:ok, Value.optional_none()}
  defp optional_select({:optional, {:some, operand}}, field), do: optional_select(operand, field)

  defp optional_select(container, field) do
    {:error, "no such key #{inspect(field)} on #{value_kind(container)}"}
  end

  defp maybe_optional_some({:optional, _value} = optional), do: optional
  defp maybe_optional_some(value), do: Value.optional_some(value)

  defp negate_value(value) do
    case Number.negate(value) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      :error -> {:error, "cannot negate #{inspect(value)}"}
    end
  end

  defp add(left, right) do
    case Number.add(left, right) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      :error -> add_time(left, right)
    end
  end

  defp add_time(left, right) do
    case Time.add(left, right) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      :error -> add_non_numeric(left, right)
    end
  end

  defp add_non_numeric({:string, left}, {:string, right}), do: {:ok, Value.string(left <> right)}
  defp add_non_numeric({:bytes, left}, {:bytes, right}), do: {:ok, Value.bytes(left <> right)}
  defp add_non_numeric({:list, left}, {:list, right}), do: {:ok, Value.list(left ++ right)}
  defp add_non_numeric({:map, left}, {:map, right}), do: {:ok, Value.map(Map.merge(left, right))}

  defp add_non_numeric(left, right) do
    {:error, "no runtime overload for _+_(#{value_kind(left)}, #{value_kind(right)})"}
  end

  defp arithmetic(left, right, op) do
    case Number.arithmetic(op, left, right) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, reason}

      :error ->
        arithmetic_time(left, right, op)
    end
  end

  defp arithmetic_time(left, right, :-) do
    case Time.subtract(left, right) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, "no runtime overload for -(#{value_kind(left)}, #{value_kind(right)})"}
    end
  end

  defp arithmetic_time(left, right, op) do
    {:error, "no runtime overload for #{op}(#{value_kind(left)}, #{value_kind(right)})"}
  end

  defp modulo(left, right) do
    case Number.modulo(left, right) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, "no runtime overload for _%_(#{value_kind(left)}, #{value_kind(right)})"}
    end
  end

  defp size_value({:list, values}), do: {:ok, Value.int(length(values))}
  defp size_value({:map, values}), do: {:ok, Value.int(map_size(values))}
  defp size_value({:bytes, value}), do: {:ok, Value.int(byte_size(value))}

  defp size_value({:string, value}) do
    {:ok, Value.int(value |> String.codepoints() |> length())}
  end

  defp size_value(value), do: {:error, "size is not defined for #{value_kind(value)}"}

  defp runtime_type({:list, _elem_type}), do: CType.list(CType.dyn())
  defp runtime_type({:map, _key_type, _value_type}), do: CType.map(CType.dyn(), CType.dyn())
  defp runtime_type(type), do: type

  defp compare(left, right, op) do
    case compare_values(left, right) do
      {:ok, comparison} ->
        {:ok, Value.bool(apply_comparison(op, comparison))}

      :error ->
        {:error, "values are not comparable: #{value_kind(left)}, #{value_kind(right)}"}
    end
  end

  defp equal_non_numeric?({:list, left}, {:list, right}, types)
       when length(left) == length(right) do
    left
    |> Enum.zip(right)
    |> Enum.all?(fn {left, right} -> equal?(left, right, types) end)
  end

  defp equal_non_numeric?({:list, _left}, {:list, _right}, _types), do: false

  defp equal_non_numeric?({:map, left}, {:map, right}, types)
       when map_size(left) == map_size(right) do
    Enum.all?(left, fn {left_key, left_value} ->
      case fetch_equal_key(right, left_key, types) do
        {:ok, right_value} -> equal?(left_value, right_value, types)
        :error -> false
      end
    end)
  end

  defp equal_non_numeric?({:map, _left}, {:map, _right}, _types), do: false

  defp equal_non_numeric?({:enum, _name, value}, {:int, value}, _types), do: true
  defp equal_non_numeric?({:int, value}, {:enum, _name, value}, _types), do: true
  defp equal_non_numeric?({:enum, _name, _left}, {:int, _right}, _types), do: false
  defp equal_non_numeric?({:int, _left}, {:enum, _name, _right}, _types), do: false

  defp equal_non_numeric?({:message, name, left}, {:message, name, right}, {types, state}),
    do: types.equal?(state, name, left, right)

  # Type values are equal when their names are, as in cel-go: the type of
  # `optional.of(1)` is `optional_type`.
  defp equal_non_numeric?({:type, _left} = left, {:type, _right} = right, _types),
    do: Value.type_name(left) == Value.type_name(right)

  defp equal_non_numeric?(left, right, _types), do: left == right

  defp compare_values(left, right) do
    case Number.compare(left, right) do
      {:ok, comparison} -> {:ok, comparison}
      :error -> compare_time(left, right)
    end
  end

  defp compare_time(left, right) do
    case Time.compare(left, right) do
      {:ok, comparison} -> {:ok, comparison}
      :error -> compare_same_kind(left, right)
    end
  end

  defp compare_same_kind({:string, left}, {:string, right}), do: {:ok, compare_terms(left, right)}
  defp compare_same_kind({:bytes, left}, {:bytes, right}), do: {:ok, compare_terms(left, right)}
  defp compare_same_kind({:bool, left}, {:bool, right}), do: {:ok, compare_bools(left, right)}
  defp compare_same_kind(_left, _right), do: :error

  defp compare_bools(false, true), do: :lt
  defp compare_bools(true, false), do: :gt
  defp compare_bools(_left, _right), do: :eq

  defp compare_terms(left, right) when left < right, do: :lt
  defp compare_terms(left, right) when left > right, do: :gt
  defp compare_terms(_left, _right), do: :eq

  defp apply_comparison(:<, :lt), do: true
  defp apply_comparison(:<, _comparison), do: false
  defp apply_comparison(:<=, comparison), do: comparison in [:lt, :eq]
  defp apply_comparison(:>, :gt), do: true
  defp apply_comparison(:>, _comparison), do: false
  defp apply_comparison(:>=, comparison), do: comparison in [:gt, :eq]

  defp list_index({:int, index}), do: {:ok, index}
  defp list_index({:uint, index}), do: {:ok, index}

  defp list_index({:double, index}) when is_float(index) do
    truncated = trunc(index)

    if index == truncated * 1.0 do
      {:ok, truncated}
    else
      :error
    end
  end

  defp list_index(_key), do: :error

  defp value_kind(:null), do: "null"
  defp value_kind({kind, _value}), do: Atom.to_string(kind)
  defp value_kind({:enum, name, _value}), do: to_string(name)
  defp value_kind({:object, type_url, _value}), do: type_url
  defp value_kind({:message, name, _fields}), do: to_string(name)
  defp value_kind(other), do: inspect(other)

  defp no_such_overload, do: {:error, "no such overload"}
end
