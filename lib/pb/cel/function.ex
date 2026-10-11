defmodule PB.CEL.Function do
  @moduledoc """
  A custom CEL function, registered with `PB.CEL.Env.build/1`'s `:functions`
  option. See the "Custom CEL functions" guide.

    * `:name` — the name expressions call it by.
    * `:modes` — how it is called: `:global` (`f(x)`, the default),
      `:receiver` (`x.f(y)`, where `x` is the first argument), or
      `{:namespace, "ns"}` (`ns.f(x)`). A function may list several.
    * `:overloads` — one `PB.CEL.Function.Overload` per signature.

  Other fields are used by PB's built-in functions and may change.
  """

  alias PB.CEL.Call
  alias PB.CEL.Checker.TypePattern

  defstruct [:name, modes: [:global], overloads: [], dynamic_overloads: []]

  @typedoc "How expressions call a function; `:intrinsic` is for operators."
  @type mode :: :global | :receiver | :intrinsic | {:namespace, String.t()}

  @typedoc """
  An argument or result type: a `t:PB.CEL.Type.t/0`, or `{:param, name}` for a
  type parameter. PB's built-in functions use further forms.
  """
  @type pattern :: PB.CEL.Type.t() | {:param, String.t()} | builtin_pattern

  @typedoc false
  @type builtin_pattern :: term

  @type args :: [pattern]
  @type result :: pattern

  @typedoc "Used by PB's built-in functions."
  @type combine :: :assignable | :common
  @typedoc "Used by PB's built-in functions."
  @type on_dyn :: :match | :fallback
  @typedoc false
  @type mfa_target :: {module, atom}

  @typedoc "`{Module, function}`; the other forms are PB's own."
  @type eval :: nil | :intrinsic | {:mfa, mfa_target} | mfa_target

  @typedoc "`:vars` and `:call` are for custom functions; the rest are PB's own."
  @type eval_context :: :schema | :message_runtime | :vars | :call

  @type t :: %__MODULE__{
          name: String.t(),
          modes: [mode],
          overloads: [PB.CEL.Function.Overload.t()],
          dynamic_overloads: [PB.CEL.Function.Overload.t()]
        }

  defmodule Overload do
    @moduledoc """
    One signature of a `PB.CEL.Function`, and the code that evaluates it.

      * `:id` — a name for this overload, unique within the environment;
        checked expressions record which overload each call resolved to.
      * `:args` — the argument types, as `t:PB.CEL.Type.t/0`; for a
        `:receiver` call the receiver comes first. `{:param, "T"}` is a type
        parameter: every occurrence must have the same type.
      * `:result` — the result type, which may use the same parameters.
      * `:eval` — `{Module, function}`, called as
        `Module.function(args, ...context)` with the evaluated arguments as a
        list of `t:PB.CEL.Value.t/0`, and returning `{:ok, value}`,
        `{:error, reason}` or `{:unknown, reason}`. Without `:eval` the
        overload can be type-checked but not evaluated.
      * `:eval_context` — extra arguments appended after the argument list,
        in order: `:vars` for the variable bindings, keyed by string name, and
        `:call` for `%{function: name, overload_id: id, expr_id: id}`.
      * `:strict` — when `false`, the function is also called with error and
        unknown arguments, as `{:error, %PB.CEL.Error{}}` and
        `{:unknown, %PB.CEL.Unknown{}}`. Defaults to `true`.

    Other fields are used by PB's built-in functions and may change.
    """

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

  @doc false
  @spec arg(non_neg_integer) :: result
  def arg(index) when is_integer(index) and index >= 0, do: {:arg, index}

  @doc false
  @spec call_mode(Call.t()) :: mode
  def call_mode(%Call{shape: :intrinsic}), do: :intrinsic
  def call_mode(%Call{shape: {:namespace, namespace}}), do: {:namespace, namespace}
  def call_mode(%Call{shape: :receiver}), do: :receiver
  def call_mode(%Call{}), do: :global

  @doc false
  @spec call_types(term | nil, [term]) :: [term]
  def call_types(nil, args), do: args
  def call_types(target, args), do: [target | args]

  @doc false
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

  @doc false
  @spec call_names(t) :: [String.t()]
  def call_names(%__MODULE__{name: name, modes: modes}) do
    Enum.map(modes, &call_name(name, &1))
  end

  @doc false
  @spec overloads(t) :: [Overload.t()]
  def overloads(%__MODULE__{overloads: overloads, dynamic_overloads: dynamic_overloads}) do
    all_overloads(overloads, dynamic_overloads)
  end

  @doc false
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
