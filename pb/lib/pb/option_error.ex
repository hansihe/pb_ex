defmodule PB.OptionError do
  @moduledoc """
  Option failure: the caller passed options the API does not accept, a known
  option carried an invalid value, or options were not a keyword list. See
  `PB.Error` for the error model.
  """

  @typedoc "Which option failure this is."
  @type kind :: :unknown_options | :invalid_option | :invalid_options

  @type t :: %__MODULE__{
          kind: kind | nil,
          operation: PB.Error.operation() | nil,
          message_name: atom | nil,
          options: term,
          option: term,
          value: term,
          reason: term
        }

  defexception kind: nil,
               operation: nil,
               message_name: nil,
               options: nil,
               option: nil,
               value: nil,
               reason: nil

  @impl Exception
  def message(%__MODULE__{} = error),
    do: PB.Error.context(format(error), error.operation, error.message_name)

  defp format(%__MODULE__{kind: :unknown_options, options: options}),
    do: "unknown option(s): #{inspect(options)}"

  defp format(%__MODULE__{kind: :invalid_option, option: option, reason: reason})
       when is_binary(reason),
       do: "invalid value for #{inspect(option)}: #{reason}"

  defp format(%__MODULE__{kind: :invalid_option, option: option, value: value}),
    do: "invalid value for #{inspect(option)}: #{inspect(value)}"

  defp format(%__MODULE__{kind: :invalid_options, reason: got}),
    do: "invalid options: expected keyword list, got #{inspect(got)}"
end
