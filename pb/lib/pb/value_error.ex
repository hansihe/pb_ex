defmodule PB.ValueError do
  @moduledoc """
  Input value or shape failure: a caller-supplied term does not fit the field's
  declared type, presence, or message structure.

  The relevant data is carried in typed fields (`:expected`, `:got`, `:min`,
  `:max`, `:value`, `:enum`, `:protobuf_message`, `:unknowns`, `:extensions`),
  and `:path` locates the offending field. Errors from `PB.TextFormat` also
  carry the 1-based `:line` and `:column` of the offending text. See
  `PB.Error` for the error model.
  """

  @typedoc "Which value/shape failure this is."
  @type kind ::
          :unknown_field
          | :invalid_value
          | :value_out_of_range
          | :invalid_oneof
          | :unknown_enum_value
          | :missing_required
          | :message_name_mismatch
          | :invalid_unknown_field
          | :invalid_unknown_fields
          | :absent
          | :unknown_wire_fields
          | :extensions_present

  @type t :: %__MODULE__{
          kind: kind | nil,
          operation: PB.Error.operation() | nil,
          message_name: atom | nil,
          path: [PB.Error.path_element()],
          expected: term,
          got: term,
          min: term,
          max: term,
          value: term,
          enum: atom | nil,
          protobuf_message: atom | nil,
          unknowns: term,
          extensions: term,
          reason: term,
          line: pos_integer | nil,
          column: pos_integer | nil
        }

  defexception kind: nil,
               operation: nil,
               message_name: nil,
               path: [],
               expected: nil,
               got: nil,
               min: nil,
               max: nil,
               value: nil,
               enum: nil,
               protobuf_message: nil,
               unknowns: nil,
               extensions: nil,
               reason: nil,
               line: nil,
               column: nil

  @impl Exception
  def message(%__MODULE__{} = error) do
    position = PB.Error.format_position(error.line, error.column)
    PB.Error.context(format(error) <> position, error.operation, error.message_name)
  end

  defp format(%__MODULE__{kind: :absent}), do: "absent value"

  defp format(%__MODULE__{kind: :unknown_field, path: path, protobuf_message: msg}) do
    suffix = if msg, do: " for #{inspect(msg)}", else: ""
    "unknown field #{PB.Error.format_path(path)}#{suffix}"
  end

  defp format(%__MODULE__{kind: :invalid_value} = error) do
    detail =
      cond do
        not is_nil(error.expected) ->
          ": expected #{inspect(error.expected)}, got #{inspect(error.got)}"

        not is_nil(error.reason) and not is_nil(error.got) ->
          ": #{error.reason} (got #{inspect(error.got)})"

        not is_nil(error.reason) ->
          ": #{error.reason}"

        not is_nil(error.got) ->
          ": got #{inspect(error.got)}"

        true ->
          ""
      end

    "invalid value at #{PB.Error.format_path(error.path)}#{detail}"
  end

  defp format(%__MODULE__{
         kind: :value_out_of_range,
         path: path,
         min: min,
         max: max,
         value: value
       }) do
    "value out of range at #{PB.Error.format_path(path)}: #{inspect(value)} not in #{min}..#{max}"
  end

  defp format(%__MODULE__{kind: :invalid_oneof, path: path, reason: reason}),
    do: "invalid oneof at #{PB.Error.format_path(path)}: #{inspect(reason)}"

  defp format(%__MODULE__{kind: :unknown_enum_value, path: path, value: value, enum: enum}),
    do:
      "unknown enum value at #{PB.Error.format_path(path)}: #{inspect(value)} for #{inspect(enum)}"

  defp format(%__MODULE__{kind: :message_name_mismatch, path: path, expected: expected, got: got}) do
    "message name mismatch at #{PB.Error.format_path(path)}: expected " <>
      "#{inspect(expected)}, got #{inspect(got)}"
  end

  defp format(%__MODULE__{kind: :missing_required, path: path}),
    do: "missing required field #{PB.Error.format_path(path)}"

  defp format(%__MODULE__{kind: :invalid_unknown_field, value: value}),
    do: "invalid unknown field: #{inspect(value)}"

  defp format(%__MODULE__{kind: :invalid_unknown_fields, value: value}),
    do: "invalid unknown fields: #{inspect(value)}"

  defp format(%__MODULE__{kind: :unknown_wire_fields, path: path}),
    do: "unknown wire fields at #{PB.Error.format_path(path)}"

  defp format(%__MODULE__{kind: :extensions_present, path: path}),
    do: "extensions present at #{PB.Error.format_path(path)}"
end
