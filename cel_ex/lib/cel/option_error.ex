defmodule CEL.OptionError do
  @moduledoc """
  Option failure in a `CEL` entry point: the caller passed options it does not
  accept, a known option carried an invalid value, or options were not a
  keyword list.
  """

  @typedoc "Which option failure this is."
  @type kind :: :unknown_options | :invalid_option | :invalid_options

  @type t :: %__MODULE__{
          kind: kind | nil,
          options: term,
          option: term,
          value: term,
          reason: term
        }

  defexception kind: nil, options: nil, option: nil, value: nil, reason: nil

  @impl Exception
  def message(%__MODULE__{kind: :unknown_options, options: options}),
    do: "unknown option(s): #{inspect(options)}"

  def message(%__MODULE__{kind: :invalid_option, option: option, reason: reason})
      when is_binary(reason),
      do: "invalid value for #{inspect(option)}: #{reason}"

  def message(%__MODULE__{kind: :invalid_option, option: option, value: value}),
    do: "invalid value for #{inspect(option)}: #{inspect(value)}"

  def message(%__MODULE__{kind: :invalid_options, reason: got}),
    do: "invalid options: expected keyword list, got #{inspect(got)}"
end
