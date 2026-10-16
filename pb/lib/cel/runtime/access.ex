defmodule CEL.Runtime.Access do
  @moduledoc false

  # Field selection, `x.f`, `has(x.f)` and `x.?f`, on maps and messages. A
  # field the checker found on a message type is read with its `CEL.Field`;
  # one selected from a `dyn` operand is looked up by the message's type first.
  # `has()` and optional selection test the field with `has_field?/3` before
  # reading it.

  alias CEL.Runtime.Core
  alias CEL.Value

  @type select_op :: %{
          required(:kind) =>
            :message_field
            | :map_field
            | :optional_field
            | :optional_map_field
            | :dyn_field
            | :optional_dyn_field
            | :presence_test,
          required(:field) => String.t(),
          required(:test_only) => boolean(),
          optional(:message) => CEL.TypeProvider.name(),
          optional(:cel_field) => CEL.Field.t(),
          optional(atom) => term
        }

  @type result :: {:ok, Value.t()} | {:error, term}

  @spec select(CEL.TypeProvider.t(), Value.t(), select_op()) :: result
  def select(
        {types, state},
        {:message, message, payload},
        %{kind: :message_field, message: message, cel_field: field}
      ) do
    types.get_field(state, payload, field)
  end

  def select(_types, operand, %{kind: :message_field, message: message}),
    do: unexpected_operand(operand, message)

  def select(types, operand, %{kind: :presence_test, message: message, cel_field: field}),
    do: message_has(types, operand, message, field)

  def select(types, operand, %{kind: :optional_field, message: message, cel_field: field}),
    do: optional_message_field(types, operand, message, field)

  def select(types, operand, %{kind: :presence_test, field: field}),
    do: dyn_select(types, operand, field, true)

  def select(types, operand, %{kind: :dyn_field, field: field, test_only: test_only?}),
    do: dyn_select(types, operand, field, test_only?)

  def select(types, operand, %{kind: :optional_dyn_field, field: field, test_only: test_only?}),
    do: optional_dyn_select(types, operand, field, test_only?)

  def select(_types, operand, %{kind: :map_field, field: field, test_only: test_only?}),
    do: map_select(operand, field, test_only?)

  def select(_types, operand, %{kind: :optional_map_field, field: field, test_only: test_only?}),
    do: optional_map_select(operand, field, test_only?)

  defp message_has(_types, {:optional, :none}, _message, _field), do: {:ok, Value.bool(false)}

  defp message_has(types, {:optional, {:some, operand}}, message, field),
    do: message_has(types, operand, message, field)

  defp message_has({types, state}, {:message, message, payload}, message, field),
    do: {:ok, Value.bool(types.has_field?(state, payload, field))}

  defp message_has(_types, operand, message, _field), do: unexpected_operand(operand, message)

  defp optional_message_field(_types, {:optional, :none}, _message, _field),
    do: {:ok, Value.optional_none()}

  defp optional_message_field(types, {:optional, {:some, operand}}, message, field),
    do: optional_message_field(types, operand, message, field)

  defp optional_message_field(types, {:message, message, payload}, message, field),
    do: optional_field_value(types, payload, field)

  defp optional_message_field(_types, operand, message, _field),
    do: unexpected_operand(operand, message)

  defp optional_field_value({types, state}, payload, field) do
    if types.has_field?(state, payload, field) do
      with {:ok, value} <- types.get_field(state, payload, field) do
        {:ok, Value.optional_some(value)}
      end
    else
      {:ok, Value.optional_none()}
    end
  end

  defp dyn_select(_types, {:map, _values} = map, field, test_only?),
    do: map_select(map, field, test_only?)

  defp dyn_select(types, {:optional, _value} = optional, field, test_only?),
    do: optional_dyn_select(types, optional, field, test_only?)

  defp dyn_select({types, state}, {:message, message, payload}, field, test_only?) do
    case types.find_field(state, message, field) do
      {:ok, field} when test_only? -> {:ok, Value.bool(types.has_field?(state, payload, field))}
      {:ok, field} -> types.get_field(state, payload, field)
      :error -> {:error, "no such field #{inspect(field)}"}
    end
  end

  defp dyn_select(_types, _operand, _field, _test_only?),
    do: {:error, "field selection requires map or message"}

  defp optional_dyn_select(_types, {:optional, :none}, _field, true),
    do: {:ok, Value.bool(false)}

  defp optional_dyn_select(_types, {:optional, :none}, _field, false),
    do: {:ok, Value.optional_none()}

  defp optional_dyn_select(types, {:optional, {:some, operand}}, field, test_only?),
    do: optional_dyn_select(types, operand, field, test_only?)

  defp optional_dyn_select(types, operand, field, true),
    do: dyn_select(types, operand, field, true)

  defp optional_dyn_select(provider, {:message, message, payload}, field, false) do
    {types, state} = provider

    case types.find_field(state, message, field) do
      {:ok, field} -> optional_field_value(provider, payload, field)
      :error -> {:ok, Value.optional_none()}
    end
  end

  defp optional_dyn_select(_types, operand, field, false),
    do: optional_select_core(operand, field)

  defp map_select({:map, values}, field, test_only?) do
    key = Value.string(field)

    cond do
      test_only? ->
        {:ok, Value.bool(Map.has_key?(values, key))}

      Map.has_key?(values, key) ->
        {:ok, Map.fetch!(values, key)}

      true ->
        {:error, "no such key #{inspect(field)}"}
    end
  end

  defp map_select(_operand, _field, _test_only?) do
    {:error, "field selection requires map"}
  end

  defp optional_map_select({:optional, :none}, _field, true) do
    {:ok, Value.bool(false)}
  end

  defp optional_map_select({:optional, :none}, _field, false) do
    {:ok, Value.optional_none()}
  end

  defp optional_map_select({:optional, {:some, operand}}, field, test_only?) do
    optional_map_select(operand, field, test_only?)
  end

  defp optional_map_select({:map, _values} = map, field, true) do
    map_select(map, field, true)
  end

  defp optional_map_select({:map, _values} = map, field, false) do
    optional_select_core(map, field)
  end

  defp optional_map_select(_operand, _field, _test_only?) do
    {:error, "field selection requires map"}
  end

  defp optional_select_core(container, field) do
    Core.optional_select([container, Value.string(field)])
  end

  defp unexpected_operand({:message, actual, _payload}, expected) do
    expected = inspect(to_string(expected))
    {:error, "expected message #{expected}, got #{inspect(to_string(actual))}"}
  end

  defp unexpected_operand(_operand, _expected), do: {:error, "field selection requires message"}
end
