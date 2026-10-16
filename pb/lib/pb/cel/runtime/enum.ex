defmodule PB.CEL.Runtime.Enum do
  @moduledoc false

  alias PB.CEL.Value

  @min_int32 -2_147_483_648
  @max_int32 2_147_483_647

  @spec construct(module(), term(), String.t(), Value.t()) ::
          {:ok, Value.t()} | {:error, String.t()}
  def construct(message_schema, schema, enum_name, value) when is_binary(enum_name) do
    with {:ok, enum} <- message_schema.resolve_enum(schema, enum_name) do
      do_construct(message_schema, schema, enum, value)
    else
      :error -> {:error, "unknown enum #{inspect(enum_name)}"}
    end
  end

  defp do_construct(_message_schema, _schema, enum, {:int, value})
       when value >= @min_int32 and value <= @max_int32 do
    {:ok, Value.enum(Atom.to_string(enum), value)}
  end

  defp do_construct(_message_schema, _schema, _enum, {:int, _value}) do
    {:error, "enum value is out of int32 range"}
  end

  defp do_construct(message_schema, schema, enum, {:string, value}) do
    with {:ok, info} <- message_schema.fetch_enum(schema, enum),
         {:ok, atom} <- existing_atom(value),
         {:ok, number} <- enum_number(info, atom) do
      {:ok, Value.enum(Atom.to_string(enum), number)}
    else
      :error ->
        {:error, "unknown enum value #{inspect(value)} for #{inspect(Atom.to_string(enum))}"}
    end
  end

  defp do_construct(_message_schema, _schema, enum, value) do
    {:error, "cannot construct #{Atom.to_string(enum)} from #{value_kind(value)}"}
  end

  defp enum_number(%{by_name: by_name}, atom) do
    case Map.fetch(by_name, atom) do
      {:ok, number} -> {:ok, number}
      :error -> :error
    end
  end

  defp existing_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp value_kind({kind, _value}) when is_atom(kind), do: Atom.to_string(kind)
  defp value_kind({:enum, name, _value}), do: name
  defp value_kind(:null), do: "null_type"
  defp value_kind(value), do: inspect(value)
end
