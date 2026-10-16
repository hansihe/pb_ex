defmodule PB.SchemaError do
  @moduledoc """
  Schema-resolution and introspection failure.

  Raised or returned when a name cannot be resolved in the supplied schema, or
  a schema-level invariant is violated. See `PB.Error` for the full error model.
  """

  @typedoc "Which schema-resolution failure this is."
  @type kind ::
          :unknown_message
          | :unknown_enum
          | :unknown_service
          | :unknown_extension
          | :unsupported_edition
          | :invalid_schema

  @type t :: %__MODULE__{
          kind: kind | nil,
          operation: PB.Error.operation() | nil,
          message_name: atom | nil,
          path: [PB.Error.path_element()],
          name: term,
          type_name: atom | nil,
          reason: term
        }

  defexception kind: nil,
               operation: nil,
               message_name: nil,
               path: [],
               name: nil,
               type_name: nil,
               reason: nil

  @impl Exception
  def message(%__MODULE__{} = error),
    do: PB.Error.context(format(error), error.operation, error.message_name)

  defp format(%__MODULE__{kind: :unknown_message, name: name}),
    do: "unknown message #{inspect(name)}"

  defp format(%__MODULE__{kind: :unknown_service, name: name}),
    do: "unknown service #{inspect(name)}"

  defp format(%__MODULE__{kind: :unknown_extension, name: name}),
    do: "unknown extension #{inspect(name)}"

  defp format(%__MODULE__{kind: :unknown_enum, path: [], type_name: type_name}),
    do: "unknown enum #{inspect(type_name)}"

  defp format(%__MODULE__{kind: :unknown_enum, path: path, type_name: type_name}),
    do: "unknown enum #{inspect(type_name)} at #{PB.Error.format_path(path)}"

  defp format(%__MODULE__{kind: :unsupported_edition, type_name: edition}),
    do: "unsupported protobuf edition #{inspect(edition)}"

  defp format(%__MODULE__{kind: :invalid_schema, type_name: type_name, reason: reason})
       when is_binary(reason),
       do: "invalid schema for #{inspect(type_name)}: #{reason}"

  defp format(%__MODULE__{kind: :invalid_schema, type_name: type_name, reason: reason}),
    do: "invalid schema for #{inspect(type_name)}: #{inspect(reason)}"
end
