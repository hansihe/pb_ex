defmodule CEL.Checker.Signatures do
  @moduledoc false

  alias CEL.Call
  alias CEL.Env
  alias CEL.Checker.Signatures.Matcher
  alias CEL.Checker.Solver
  alias CEL.Checker.Types, as: CType
  alias CEL.Function

  @type resolved :: %{
          required(:type) => CType.t(),
          required(:overload_id) => String.t(),
          required(:eval) => Function.eval(),
          required(:eval_context) => [Function.eval_context()],
          optional(:strict) => boolean
        }

  @spec resolve(Call.t(), CType.t() | nil, [CType.t()], Solver.t(), Env.t()) ::
          {:ok, resolved, Solver.t()} | :unknown
  def resolve(%Call{} = call, target, args, %Solver{} = solver, %Env{} = env) do
    call
    |> functions_for_call(target, args, env)
    |> Enum.reduce_while(:unknown, fn {%Function{} = function, call_types}, :unknown ->
      case resolve_function(function, call_types, solver) do
        {:ok, _resolved, _solver} = result -> {:halt, result}
        :unknown -> {:cont, :unknown}
      end
    end)
  end

  defp functions_for_call(%Call{} = call, target, args, %Env{} = env) do
    types = Function.call_types(target, args)

    env.functions
    |> Enum.reverse()
    |> Enum.filter(&Function.applicable?(&1, call, target, args))
    |> Enum.map(&{&1, types})
  end

  defp resolve_function(%Function{} = function, types, solver) do
    with :unknown <- resolve_overloads(function.overloads, types, solver, false),
         :unknown <- resolve_overloads(function.dynamic_overloads, types, solver, true) do
      :unknown
    end
  end

  defp resolve_overloads(overloads, types, solver, dynamic?) do
    overloads
    |> Enum.filter(&Matcher.overload_applicable?(&1, types, dynamic?, solver))
    |> Enum.reduce_while(:unknown, fn overload, :unknown ->
      case Matcher.match(overload, types, solver) do
        {:ok, _resolved, _solver} = result -> {:halt, result}
        :unknown -> {:cont, :unknown}
      end
    end)
  end
end
