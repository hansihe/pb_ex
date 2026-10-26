defmodule PB.AdapterError do
  @moduledoc """
  An adapter `to_proto`/`from_proto` callback returned `{:error, reason}`,
  returned a non-tagged value, or raised. `:fqn` names the message,
  `:direction` is `:to_proto` or `:from_proto`, and `:reason` carries the
  callback's reason. See `PB.Error`.
  """

  @type t :: %__MODULE__{
          operation: PB.Error.operation() | nil,
          message_name: atom | nil,
          path: [PB.Error.path_element()],
          fqn: atom | nil,
          direction: :to_proto | :from_proto | nil,
          reason: term
        }

  defexception operation: nil,
               message_name: nil,
               path: [],
               fqn: nil,
               direction: nil,
               reason: nil

  @impl Exception
  def message(%__MODULE__{} = error) do
    base =
      "adapter #{inspect(error.fqn)} #{error.direction} failed" <>
        "#{PB.Error.format_location(error.path)}#{PB.Error.format_reason(error.reason)}"

    PB.Error.context(base, error.operation, error.message_name)
  end
end
