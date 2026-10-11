defmodule PB.CEL.Program do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Pre-compiled CEL expression bundled with its checking environment.
  #
  # A `Program` is produced by `PB.CEL.compile/2` and carries both the
  # checked expression and the `PB.CEL.Env` it was checked against. Eval
  # callers pass only the runtime variable bindings — schema, function
  # registry, and container do not need to be re-passed at each call.
  #
  #     env =
  #       PB.CEL.Env.build(
  #         schema: schema,
  #         vars: [name: :string]
  #       )
  #
  #     {:ok, program} = PB.CEL.compile(~s|"hello, " + name|, env)
  #     {:ok, value}   = PB.CEL.Program.eval(program, %{"name" => "world"})
  @moduledoc false

  alias PB.CEL.Checked
  alias PB.CEL.Env
  alias PB.CEL.Error
  alias PB.CEL.Evaluator
  alias PB.CEL.Regexes
  alias PB.CEL.Unknown
  alias PB.CEL.Value

  @enforce_keys [:checked, :env]
  defstruct [:checked, :env, regexes: %{}]

  @type t :: %__MODULE__{
          checked: Checked.t(),
          env: Env.t(),
          regexes: %{Checked.expr_id() => Regex.t()}
        }

  @doc """
  Bundles a previously checked expression with the environment it was checked
  against, returning a `Program` ready for `eval/2`.

  Most callers should use `PB.CEL.compile/2`, which parses, checks, and
  bundles in one call. Use this constructor when you already hold a
  `PB.CEL.Checked` and the matching `PB.CEL.Env` — for example, to
  cache the check phase and re-bundle programs with different runtime
  bindings.
  """
  @spec new(Checked.t(), Env.t()) :: t
  def new(%Checked{} = checked, %Env{} = env) do
    # Literal patterns compile once here. An invalid one is left to fail
    # when evaluated, as CEL reports it.
    regexes =
      case Regexes.precompile(checked, %{}) do
        {:ok, regexes} -> regexes
        {:error, _reason} -> %{}
      end

    %__MODULE__{checked: checked, env: env, regexes: regexes}
  end

  @doc """
  Evaluates a compiled program with the supplied variable bindings.
  """
  @spec eval(t, map | keyword) :: {:ok, Value.t()} | {:unknown, Unknown.t()} | {:error, Error.t()}
  def eval(%__MODULE__{checked: checked, env: env, regexes: regexes}, values \\ %{}) do
    Evaluator.eval(checked, values, [regexes: regexes] ++ evaluator_opts(env))
  end

  @doc """
  Evaluates a compiled program, raising on errors and unknown results.
  """
  @spec eval!(t, map | keyword) :: Value.t()
  def eval!(%__MODULE__{} = program, values \\ %{}) do
    program |> eval(values) |> unwrap!()
  end

  @doc false
  @spec unwrap!({:ok, Value.t()} | {:unknown, Unknown.t()} | {:error, Error.t()}) :: Value.t()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %Error{} = error}), do: raise(error)

  def unwrap!({:unknown, %Unknown{} = unknown}) do
    raise Error, phase: :eval, message: "result is unknown", details: %{unknown: unknown}
  end

  defp evaluator_opts(%Env{} = env) do
    opts = [message_schema: env.message_schema, message_runtime: env.message_runtime]

    if is_nil(env.schema) do
      opts
    else
      Keyword.put(opts, :schema, env.schema)
    end
  end
end
