defmodule PB.DecodeError do
  @moduledoc """
  Structurally invalid serialized input: protobuf wire bytes that are truncated
  or malformed, or JSON or text format input that is not well-formed for the
  target. The `:format` field discriminates `:wire`, `:json` and `:text`.

  Text format errors carry the 1-based `:line` and `:column` of the problem.
  See `PB.Error`.
  """

  @typedoc "Which structural-decode failure this is."
  @type kind :: :malformed | :malformed_json | :malformed_text | :duplicate_field

  @type t :: %__MODULE__{
          kind: kind | nil,
          format: :wire | :json | :text | nil,
          operation: PB.Error.operation() | nil,
          message_name: atom | nil,
          path: [PB.Error.path_element()],
          reason: term,
          line: pos_integer | nil,
          column: pos_integer | nil,
          details: map
        }

  defexception kind: nil,
               format: nil,
               operation: nil,
               message_name: nil,
               path: [],
               reason: nil,
               line: nil,
               column: nil,
               details: %{}

  @impl Exception
  def message(%__MODULE__{} = error),
    do: PB.Error.context(format(error), error.operation, error.message_name)

  defp format(%__MODULE__{kind: :malformed, path: path, reason: reason}) do
    "malformed protobuf input#{PB.Error.format_location(path)}#{PB.Error.format_reason(reason)}"
  end

  defp format(%__MODULE__{kind: :malformed_text} = error),
    do: "malformed text format input#{text_location(error)}"

  defp format(%__MODULE__{kind: :duplicate_field, format: :text} = error),
    do: "duplicate field#{text_location(error)}"

  defp format(%__MODULE__{kind: :duplicate_field, path: path, reason: reason}) do
    "duplicate field#{PB.Error.format_location(path)}#{PB.Error.format_reason(reason)}"
  end

  defp format(%__MODULE__{path: path, reason: reason}) do
    "malformed JSON input#{PB.Error.format_location(path)}#{PB.Error.format_reason(reason)}"
  end

  # " at line 3, column 7 (field a.b): reason"
  defp text_location(%__MODULE__{} = error) do
    position = PB.Error.format_position(error.line, error.column)
    field = if error.path == [], do: "", else: " (field #{PB.Error.format_path(error.path)})"

    reason =
      if is_binary(error.reason),
        do: ": #{error.reason}",
        else: PB.Error.format_reason(error.reason)

    position <> field <> reason
  end
end
