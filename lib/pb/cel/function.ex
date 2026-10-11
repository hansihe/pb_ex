defmodule PB.CEL.Function do
  @moduledoc false

  alias PB.CEL.Call
  alias PB.CEL.Checker.TypePattern

  defstruct [:name, modes: [:global], overloads: [], dynamic_overloads: []]

  @type mode :: :global | :receiver | :intrinsic | {:namespace, String.t()}
  @type args :: [TypePattern.t()]
  @type result :: TypePattern.t() | {:arg, non_neg_integer}

  @type combine :: :assignable | :common
  @type on_dyn :: :match | :fallback
  @type mfa_target :: {module, atom}
  @type eval :: nil | :intrinsic | {:mfa, mfa_target} | mfa_target
  @type eval_context :: :schema | :message_runtime | :vars | :call

  @type t :: %__MODULE__{
          name: String.t(),
          modes: [mode],
          overloads: [Overload.t()],
          dynamic_overloads: [Overload.t()]
        }

  defmodule Overload do
    @moduledoc false

    defstruct [
      :id,
      :args,
      :result,
      eval: nil,
      eval_context: [],
      strict: true,
      combine: :assignable,
      on_dyn: :match
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            args: PB.CEL.Function.args(),
            result: PB.CEL.Function.result(),
            eval: PB.CEL.Function.eval(),
            eval_context: [PB.CEL.Function.eval_context()],
            strict: boolean,
            combine: PB.CEL.Function.combine(),
            on_dyn: PB.CEL.Function.on_dyn()
          }
  end

  @spec arg(non_neg_integer) :: result
  def arg(index) when is_integer(index) and index >= 0, do: {:arg, index}

  @spec call_mode(Call.t()) :: mode
  def call_mode(%Call{shape: :intrinsic}), do: :intrinsic
  def call_mode(%Call{shape: {:namespace, namespace}}), do: {:namespace, namespace}
  def call_mode(%Call{shape: :receiver}), do: :receiver
  def call_mode(%Call{}), do: :global

  @spec call_types(term | nil, [term]) :: [term]
  def call_types(nil, args), do: args
  def call_types(target, args), do: [target | args]

  @spec applicable?(t, Call.t(), term | nil, [term]) :: boolean
  def applicable?(
        %__MODULE__{
          name: name,
          modes: modes,
          overloads: overloads,
          dynamic_overloads: dynamic_overloads
        },
        %Call{} = call,
        target,
        args
      ) do
    name == call.function and call_mode(call) in modes and
      Enum.any?(all_overloads(overloads, dynamic_overloads), &overload_arity?(&1, target, args))
  end

  @spec call_names(t) :: [String.t()]
  def call_names(%__MODULE__{name: name, modes: modes}) do
    Enum.map(modes, &call_name(name, &1))
  end

  @spec overloads(t) :: [Overload.t()]
  def overloads(%__MODULE__{overloads: overloads, dynamic_overloads: dynamic_overloads}) do
    all_overloads(overloads, dynamic_overloads)
  end

  @spec generic_overload?(Overload.t()) :: boolean
  def generic_overload?(%Overload{args: args, result: result}) do
    Enum.any?([result | args], &TypePattern.generic?/1)
  end

  defp overload_arity?(%Overload{args: args}, target, call_args) do
    match?({:ok, _args}, TypePattern.expand_args(args, call_types(target, call_args)))
  end

  defp call_name(name, {:namespace, namespace}), do: namespace <> "." <> name
  defp call_name(name, _mode), do: name

  defp all_overloads(overloads, dynamic_overloads), do: overloads ++ dynamic_overloads
end
