defmodule PB.Validate.CompileError do
  @moduledoc """
  Error raised when protovalidate rules fail to compile.
  """

  defexception [:target, :constraint_id, :stage, :cause, :message]

  @type t :: %__MODULE__{
          target: String.t(),
          constraint_id: String.t(),
          stage: atom,
          cause: Exception.t() | String.t() | term,
          message: String.t()
        }

  @impl Exception
  def exception(opts) when is_list(opts) do
    target = Keyword.fetch!(opts, :target)
    constraint_id = Keyword.fetch!(opts, :constraint_id)
    stage = Keyword.fetch!(opts, :stage)
    cause = Keyword.fetch!(opts, :cause)

    %__MODULE__{
      target: target,
      constraint_id: constraint_id,
      stage: stage,
      cause: cause,
      message:
        "#{target} constraint #{inspect(constraint_id)} #{stage_message(stage)}: #{cause_message(cause)}"
    }
  end

  @impl Exception
  def message(%__MODULE__{message: message}), do: message

  defp stage_message(:parse), do: "CEL parse error"
  defp stage_message(:check), do: "CEL check error"
  defp stage_message(:type), do: "CEL type error"
  defp stage_message(stage), do: "#{stage} error"

  defp cause_message(%{__exception__: true} = cause), do: Exception.message(cause)
  defp cause_message(cause) when is_binary(cause), do: cause
  defp cause_message(cause), do: inspect(cause)
end
