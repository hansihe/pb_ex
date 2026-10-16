defmodule CEL.Runtime.Enum do
  @moduledoc false

  # Enum constructors, `pkg.Enum(1)` and `pkg.Enum('VALUE')`, against the
  # provider's enum type.

  alias CEL.Value

  @min_int32 -2_147_483_648
  @max_int32 2_147_483_647

  @spec construct(CEL.TypeProvider.t(), CEL.TypeProvider.name(), Value.t()) ::
          {:ok, Value.t()} | {:error, String.t()}
  def construct(_types, enum, {:int, value}) when value >= @min_int32 and value <= @max_int32 do
    {:ok, Value.enum(enum, value)}
  end

  def construct(_types, _enum, {:int, _value}) do
    {:error, "enum value is out of int32 range"}
  end

  def construct({types, state}, enum, {:string, value}) do
    case types.enum_value(state, enum, value) do
      {:ok, number} ->
        {:ok, Value.enum(enum, number)}

      :error ->
        {:error, "unknown enum value #{inspect(value)} for #{inspect(to_string(enum))}"}
    end
  end

  def construct(_types, enum, value) do
    {:error, "cannot construct #{enum} from #{value_kind(value)}"}
  end

  defp value_kind({kind, _value}) when is_atom(kind), do: Atom.to_string(kind)
  defp value_kind({:enum, name, _value}), do: to_string(name)
  defp value_kind(:null), do: "null_type"
  defp value_kind(value), do: inspect(value)
end
