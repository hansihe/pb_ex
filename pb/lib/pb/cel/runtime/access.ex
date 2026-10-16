defmodule PB.CEL.Runtime.Access do
  @moduledoc false

  alias PB.CEL.Message.Schema
  alias PB.CEL.Runtime.Core
  alias PB.CEL.Value

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
          optional(:field_ref) => Schema.field_ref(),
          optional(atom) => term
        }

  @type result :: {:ok, Value.t()} | {:error, term}

  @spec select(module(), Schema.schema(), Value.t(), select_op()) :: result
  def select(message_runtime, schema, operand, %{
        kind: :presence_test,
        field_ref: field_ref,
        test_only: true
      }) do
    optional_select_ref(message_runtime, schema, operand, field_ref, true)
  end

  def select(message_runtime, schema, operand, %{
        kind: :presence_test,
        field: field,
        test_only: true
      }) do
    runtime_select(message_runtime, schema, operand, field, true)
  end

  def select(message_runtime, schema, operand, %{
        kind: :dyn_field,
        field: field,
        test_only: test_only?
      }) do
    runtime_select(message_runtime, schema, operand, field, test_only?)
  end

  def select(message_runtime, schema, operand, %{
        kind: :optional_dyn_field,
        field: field,
        test_only: test_only?
      }) do
    optional_select(message_runtime, schema, operand, field, test_only?)
  end

  def select(_message_runtime, _schema, operand, %{
        kind: :map_field,
        field: field,
        test_only: test_only?
      }) do
    map_select(operand, field, test_only?)
  end

  def select(_message_runtime, _schema, operand, %{
        kind: :optional_map_field,
        field: field,
        test_only: test_only?
      }) do
    optional_map_select(operand, field, test_only?)
  end

  def select(
        message_runtime,
        schema,
        operand,
        %{kind: :message_field, field_ref: field_ref, test_only: test_only?}
      ) do
    message_select_ref(message_runtime, schema, operand, field_ref, test_only?)
  end

  def select(_message_runtime, _schema, _operand, %{kind: :message_field}) do
    {:error, "checked message field selection requires field_ref"}
  end

  def select(
        message_runtime,
        schema,
        operand,
        %{kind: :optional_field, field_ref: field_ref, test_only: test_only?}
      ) do
    optional_select_ref(message_runtime, schema, operand, field_ref, test_only?)
  end

  def select(_message_runtime, _schema, _operand, %{kind: :optional_field}) do
    {:error, "checked optional field selection requires field_ref"}
  end

  defp runtime_select(_message_runtime, _schema, {:map, _values} = map, field, test_only?) do
    map_select(map, field, test_only?)
  end

  defp runtime_select(message_runtime, schema, {:optional, _value} = optional, field, test_only?) do
    optional_select(message_runtime, schema, optional, field, test_only?)
  end

  defp runtime_select(
         message_runtime,
         schema,
         {:message, _name, _fields} = message,
         field,
         test_only?
       ) do
    message_select(message_runtime, schema, message, field, test_only?)
  end

  defp runtime_select(_message_runtime, _schema, _operand, _field, _test_only?) do
    {:error, "field selection requires map or message"}
  end

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

  defp optional_select(_message_runtime, _schema, {:optional, :none}, _field, true) do
    {:ok, Value.bool(false)}
  end

  defp optional_select(_message_runtime, _schema, {:optional, :none}, _field, false) do
    {:ok, Value.optional_none()}
  end

  defp optional_select(message_runtime, schema, {:optional, {:some, operand}}, field, true) do
    runtime_select(message_runtime, schema, operand, field, true)
  end

  defp optional_select(message_runtime, schema, {:optional, {:some, operand}}, field, false) do
    optional_select_value(message_runtime, schema, operand, field)
  end

  defp optional_select(message_runtime, schema, operand, field, true) do
    runtime_select(message_runtime, schema, operand, field, true)
  end

  defp optional_select(message_runtime, schema, operand, field, false) do
    optional_select_value(message_runtime, schema, operand, field)
  end

  defp message_select(
         message_runtime,
         schema,
         {:message, name, fields} = message,
         field,
         test_only?
       ) do
    case message_runtime.select(schema, message, field, test_only?) do
      {:ok, value} ->
        {:ok, value}

      :not_applicable ->
        literal_message_select(name, fields, field, test_only?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message_select_ref(
         message_runtime,
         schema,
         {:message, _name, _fields} = message,
         field_ref,
         test_only?
       ) do
    case message_runtime.select_ref(schema, message, field_ref, test_only?) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, reason}

      :not_applicable ->
        {:error, "field selection requires schema-backed message"}
    end
  end

  defp message_select_ref(_message_runtime, _schema, _operand, _field_ref, _test_only?) do
    {:error, "field selection requires message"}
  end

  defp literal_message_select(_name, fields, field, test_only?) do
    cond do
      test_only? ->
        {:ok, Value.bool(Map.has_key?(fields, field))}

      Map.has_key?(fields, field) ->
        {:ok, Map.fetch!(fields, field)}

      true ->
        {:error, "no such field #{inspect(field)}"}
    end
  end

  defp optional_select_value(message_runtime, schema, container, field) do
    case message_runtime.optional_select(schema, container, field) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      :not_applicable -> optional_select_core(container, field)
    end
  end

  defp optional_select_ref(_message_runtime, _schema, {:optional, :none}, _field_ref, true) do
    {:ok, Value.bool(false)}
  end

  defp optional_select_ref(_message_runtime, _schema, {:optional, :none}, _field_ref, false) do
    {:ok, Value.optional_none()}
  end

  defp optional_select_ref(
         message_runtime,
         schema,
         {:optional, {:some, operand}},
         field_ref,
         true
       ) do
    message_select_ref(message_runtime, schema, operand, field_ref, true)
  end

  defp optional_select_ref(
         message_runtime,
         schema,
         {:optional, {:some, operand}},
         field_ref,
         false
       ) do
    optional_select_value_ref(message_runtime, schema, operand, field_ref)
  end

  defp optional_select_ref(message_runtime, schema, operand, field_ref, true) do
    message_select_ref(message_runtime, schema, operand, field_ref, true)
  end

  defp optional_select_ref(message_runtime, schema, operand, field_ref, false) do
    optional_select_value_ref(message_runtime, schema, operand, field_ref)
  end

  defp optional_select_value_ref(
         message_runtime,
         schema,
         {:message, _name, _fields} = message,
         field_ref
       ) do
    case message_runtime.optional_select_ref(schema, message, field_ref) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      :not_applicable -> {:error, "field selection requires schema-backed message"}
    end
  end

  defp optional_select_value_ref(_message_runtime, _schema, _operand, _field_ref) do
    {:error, "field selection requires message"}
  end

  defp optional_select_core(container, field) do
    Core.optional_select([container, Value.string(field)])
  end
end
