defmodule PB.Runtime.Errors do
  @moduledoc false

  alias PB.{AdapterError, DecodeError, OptionError, SchemaError, ValueError}

  def normalize_result({:error, reason}, operation, message_name) do
    {:error, to_error(reason, operation, message_name)}
  end

  def normalize_result(result, _operation, _message_name), do: result

  @doc """
  Converts an internal reason — a tagged tuple from the runtime vocabulary, or
  an already-built PB error struct — into the appropriate `PB.Error` struct,
  attaching `operation`/`message_name` context when not already set.

  Total by design: an unmapped reason raises `ArgumentError` so coverage gaps
  surface in tests rather than silently becoming an opaque error.
  """
  def to_error(reason, operation \\ nil, message_name \\ nil)

  def to_error(error, operation, message_name) when is_exception(error) do
    error
    |> maybe_put(:operation, operation)
    |> maybe_put(:message_name, message_name)
  end

  def to_error(:absent, operation, message_name) do
    %ValueError{kind: :absent, operation: operation, message_name: message_name}
  end

  def to_error({:unknown_message, name}, operation, message_name) do
    %SchemaError{
      kind: :unknown_message,
      operation: operation,
      message_name: message_name,
      name: name
    }
  end

  def to_error({:unknown_field, protobuf_message, path}, operation, message_name) do
    %ValueError{
      kind: :unknown_field,
      operation: operation,
      message_name: message_name,
      path: path,
      protobuf_message: protobuf_message
    }
  end

  def to_error({:invalid_value, path, expected, got}, operation, message_name) do
    %ValueError{
      kind: :invalid_value,
      operation: operation,
      message_name: message_name,
      path: path,
      expected: expected,
      got: got
    }
  end

  def to_error({:value_out_of_range, path, min, max, value}, operation, message_name) do
    %ValueError{
      kind: :value_out_of_range,
      operation: operation,
      message_name: message_name,
      path: path,
      min: min,
      max: max,
      value: value
    }
  end

  def to_error({:invalid_oneof, path, reason}, operation, message_name) do
    %ValueError{
      kind: :invalid_oneof,
      operation: operation,
      message_name: message_name,
      path: path,
      reason: reason
    }
  end

  def to_error({:message_name_mismatch, path, expected, got}, operation, message_name) do
    %ValueError{
      kind: :message_name_mismatch,
      operation: operation,
      message_name: message_name,
      path: path,
      expected: expected,
      got: got
    }
  end

  def to_error({:unknown_enum_value, path, type_name, value}, operation, message_name) do
    %ValueError{
      kind: :unknown_enum_value,
      operation: operation,
      message_name: message_name,
      path: path,
      value: value,
      enum: type_name
    }
  end

  def to_error({:missing_required, path}, operation, message_name) do
    %ValueError{
      kind: :missing_required,
      operation: operation,
      message_name: message_name,
      path: path
    }
  end

  def to_error({:invalid_unknown_field, value}, operation, message_name) do
    %ValueError{
      kind: :invalid_unknown_field,
      operation: operation,
      message_name: message_name,
      value: value
    }
  end

  def to_error({:invalid_unknown_fields, value}, operation, message_name) do
    %ValueError{
      kind: :invalid_unknown_fields,
      operation: operation,
      message_name: message_name,
      value: value
    }
  end

  def to_error({:unknown_wire_fields, path, unknowns}, operation, message_name) do
    %ValueError{
      kind: :unknown_wire_fields,
      operation: operation,
      message_name: message_name,
      path: path,
      unknowns: unknowns
    }
  end

  def to_error({:extensions_present, path, extensions}, operation, message_name) do
    %ValueError{
      kind: :extensions_present,
      operation: operation,
      message_name: message_name,
      path: path,
      extensions: extensions
    }
  end

  def to_error({:adapter_error, fqn, direction, path, reason}, operation, message_name) do
    %AdapterError{
      operation: operation,
      message_name: message_name,
      path: path,
      fqn: fqn,
      direction: direction,
      reason: reason
    }
  end

  def to_error(:malformed, operation, message_name) do
    to_error({:malformed, nil, %{}}, operation, message_name)
  end

  def to_error({:malformed, reason}, operation, message_name) do
    to_error({:malformed, reason, %{}}, operation, message_name)
  end

  def to_error({:malformed, reason, details}, operation, message_name) do
    %DecodeError{
      kind: :malformed,
      format: :wire,
      operation: operation,
      message_name: message_name,
      reason: reason,
      details: normalize_details(details)
    }
  end

  def to_error({:unknown_options, options}, operation, message_name) do
    %OptionError{
      kind: :unknown_options,
      operation: operation,
      message_name: message_name,
      options: options
    }
  end

  def to_error({:invalid_option, option, value}, operation, message_name) do
    %OptionError{
      kind: :invalid_option,
      operation: operation,
      message_name: message_name,
      option: option,
      value: value
    }
  end

  def to_error({:invalid_options, got}, operation, message_name) do
    %OptionError{
      kind: :invalid_options,
      operation: operation,
      message_name: message_name,
      reason: got
    }
  end

  def to_error({:unknown_enum, type_name}, operation, message_name) do
    to_error({:unknown_enum, [], type_name}, operation, message_name)
  end

  def to_error({:unknown_enum, path, type_name}, operation, message_name) do
    %SchemaError{
      kind: :unknown_enum,
      operation: operation,
      message_name: message_name,
      path: path,
      type_name: type_name
    }
  end

  def to_error({:invalid_schema, type_name, reason}, operation, message_name) do
    %SchemaError{
      kind: :invalid_schema,
      operation: operation,
      message_name: message_name,
      type_name: type_name,
      reason: reason
    }
  end

  def to_error(reason, _operation, _message_name) do
    raise ArgumentError, "unmapped PB error reason: #{inspect(reason)}"
  end

  def type_of(value) when is_binary(value), do: :binary
  def type_of(value) when is_boolean(value), do: :boolean
  def type_of(value) when is_integer(value), do: :integer
  def type_of(value) when is_float(value), do: :float
  def type_of(value) when is_atom(value), do: :atom
  def type_of(value) when is_list(value), do: :list
  def type_of(value) when is_map(value) and not is_struct(value), do: :map
  def type_of(%module{}), do: {:struct, module}
  def type_of(_value), do: :term

  defp maybe_put(error, key, value) do
    case Map.fetch(error, key) do
      {:ok, nil} -> Map.put(error, key, value)
      _present_or_absent -> error
    end
  end

  defp normalize_details(details) when is_map(details), do: details
  defp normalize_details(nil), do: %{}
  defp normalize_details(details), do: %{value: details}
end
