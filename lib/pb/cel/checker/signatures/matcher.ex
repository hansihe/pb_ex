defmodule PB.CEL.Checker.Signatures.Matcher do
  @moduledoc false

  alias PB.CEL.Checker.Solver
  alias PB.CEL.Checker.TypePattern
  alias PB.CEL.Checker.Types, as: CType
  alias PB.CEL.Function
  alias PB.CEL.Function.Overload

  @spec overload_applicable?(Overload.t(), [CType.t()], boolean, Solver.t()) :: boolean
  def overload_applicable?(%Overload{args: args}, types, true, solver) do
    match?({:ok, _args}, TypePattern.expand_args(args, types)) and
      dynamic_overload_applicable?(types, solver)
  end

  def overload_applicable?(%Overload{args: args}, types, false, _solver) do
    match?({:ok, _args}, TypePattern.expand_args(args, types))
  end

  @spec match(Overload.t(), [CType.t()], Solver.t()) ::
          {:ok, PB.CEL.Checker.Signatures.resolved(), Solver.t()} | :unknown
  def match(%Overload{} = overload, types, solver) do
    cond do
      fallback_on_dyn?(overload, types, solver) ->
        :unknown

      Function.generic_overload?(overload) ->
        match_generic_overload(overload, types, solver)

      true ->
        match_concrete_overload(overload, types, solver)
    end
  end

  defp match_generic_overload(%Overload{combine: :assignable} = overload, types, solver) do
    with {:ok, params, solver} <- match_assignable(overload.args, types, %{}, solver),
         {:ok, type, _params, solver} <-
           instantiate_result(overload.result, types, params, solver) do
      ok(type, overload, solver)
    else
      :error -> :unknown
    end
  end

  defp match_generic_overload(%Overload{combine: :common} = overload, types, solver) do
    with {:ok, constraints, solver} <- collect_common(overload.args, types, %{}, solver),
         {:ok, params, solver} <- common_params(constraints, solver),
         {:ok, type, _params, solver} <-
           instantiate_result(overload.result, types, params, solver) do
      ok(type, overload, solver)
    else
      :error -> :unknown
    end
  end

  defp match_concrete_overload(%Overload{} = overload, types, solver) do
    with {:ok, patterns} <- TypePattern.expand_args(overload.args, types),
         {:ok, solver} <- match_concrete(patterns, types, solver),
         {:ok, type, _params, solver} <-
           instantiate_result(overload.result, types, %{}, solver) do
      ok(type, overload, solver)
    else
      :error -> :unknown
    end
  end

  defp match_concrete(patterns, types, solver) do
    bind_top_level? = Enum.any?(types, &(not CType.var?(Solver.resolve(solver, &1))))

    patterns
    |> Enum.zip(types)
    |> Enum.reduce_while({:ok, solver}, fn {pattern, actual}, {:ok, solver} ->
      case match_concrete_type(pattern, actual, solver, bind_top_level?) do
        {:ok, solver} -> {:cont, {:ok, solver}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp match_concrete_type(:any, _actual, solver, _nested?), do: {:ok, solver}

  defp match_concrete_type(:dyn, actual, solver, nested?),
    do: match_exact(CType.dyn(), actual, solver, nested?)

  defp match_concrete_type(:null, actual, solver, nested?),
    do: match_exact(CType.null(), actual, solver, nested?)

  defp match_concrete_type(:bool, actual, solver, nested?),
    do: match_exact(CType.bool(), actual, solver, nested?)

  defp match_concrete_type(:int, actual, solver, nested?),
    do: match_exact(CType.int(), actual, solver, nested?)

  defp match_concrete_type(:uint, actual, solver, nested?),
    do: match_exact(CType.uint(), actual, solver, nested?)

  defp match_concrete_type(:double, actual, solver, nested?),
    do: match_exact(CType.double(), actual, solver, nested?)

  defp match_concrete_type(:string, actual, solver, nested?),
    do: match_exact(CType.string(), actual, solver, nested?)

  defp match_concrete_type(:bytes, actual, solver, nested?),
    do: match_exact(CType.bytes(), actual, solver, nested?)

  defp match_concrete_type(:timestamp, actual, solver, nested?),
    do: match_exact(CType.timestamp(), actual, solver, nested?)

  defp match_concrete_type(:duration, actual, solver, nested?),
    do: match_exact(CType.duration(), actual, solver, nested?)

  defp match_concrete_type(:dynamic, actual, solver, _nested?) do
    if solver |> Solver.resolve(actual) |> CType.dynamic?(), do: {:ok, solver}, else: :error
  end

  defp match_concrete_type(:numeric, actual, solver, _nested?) do
    if solver |> Solver.resolve(actual) |> CType.numeric?(), do: {:ok, solver}, else: :error
  end

  defp match_concrete_type(:integral, actual, solver, _nested?) do
    if solver |> Solver.resolve(actual) |> CType.integral?(), do: {:ok, solver}, else: :error
  end

  defp match_concrete_type(:list, actual, solver, nested?) do
    case Solver.resolve(solver, actual) do
      {:list, _elem_type} -> {:ok, solver}
      {:var, _id} = var when nested? -> bind_exact(solver, var, CType.list(CType.dyn()))
      _type -> :error
    end
  end

  defp match_concrete_type(:map, actual, solver, nested?) do
    case Solver.resolve(solver, actual) do
      {:map, _key_type, _value_type} ->
        {:ok, solver}

      {:var, _id} = var when nested? ->
        bind_exact(solver, var, CType.map(CType.dyn(), CType.dyn()))

      _type ->
        :error
    end
  end

  defp match_concrete_type(:message, actual, solver, _nested?) do
    case Solver.resolve(solver, actual) do
      {:message, _name} -> {:ok, solver}
      _type -> :error
    end
  end

  defp match_concrete_type({:message, name}, actual, solver, nested?) do
    match_exact(CType.message(name), actual, solver, nested?)
  end

  defp match_concrete_type({:type, type_pattern}, actual, solver, _nested?) do
    case Solver.resolve(solver, actual) do
      {:type, actual_type} -> match_concrete_type(type_pattern, actual_type, solver, true)
      _type -> :error
    end
  end

  defp match_concrete_type({:list, elem_pattern}, actual, solver, _nested?) do
    case CType.list_elem(Solver.resolve(solver, actual)) do
      {:ok, elem_type} -> match_concrete_type(elem_pattern, elem_type, solver, true)
      :error -> :error
    end
  end

  defp match_concrete_type({:map, key_pattern, value_pattern}, actual, solver, _nested?) do
    case CType.map_types(Solver.resolve(solver, actual)) do
      {:ok, key_type, value_type} ->
        with {:ok, solver} <- match_concrete_type(key_pattern, key_type, solver, true) do
          match_concrete_type(value_pattern, value_type, solver, true)
        end

      :error ->
        :error
    end
  end

  defp match_concrete_type({:optional, value_pattern}, actual, solver, _nested?) do
    actual = Solver.resolve(solver, actual)

    if CType.optional?(actual) do
      match_concrete_type(value_pattern, CType.unwrap_optional(actual), solver, true)
    else
      :error
    end
  end

  defp match_concrete_type({:abstract, name, param_patterns}, actual, solver, _nested?) do
    case Solver.resolve(solver, actual) do
      {:abstract, ^name, actual_params} when length(param_patterns) == length(actual_params) ->
        param_patterns
        |> Enum.zip(actual_params)
        |> Enum.reduce_while({:ok, solver}, fn {pattern, actual}, {:ok, solver} ->
          case match_concrete_type(pattern, actual, solver, true) do
            {:ok, solver} -> {:cont, {:ok, solver}}
            :error -> {:halt, :error}
          end
        end)

      _type ->
        :error
    end
  end

  defp match_concrete_type({:one_of, matchers}, actual, solver, nested?) do
    Enum.reduce_while(matchers, :error, fn matcher, :error ->
      case match_concrete_type(matcher, actual, solver, nested?) do
        {:ok, _solver} = result -> {:halt, result}
        :error -> {:cont, :error}
      end
    end)
  end

  defp match_exact(expected, actual, solver, nested?) do
    case Solver.resolve(solver, actual) do
      ^expected ->
        {:ok, solver}

      actual ->
        if scalar_match?(expected, actual),
          do: {:ok, solver},
          else: match_exact_var(expected, actual, solver, nested?)
    end
  end

  defp match_exact_var(expected, actual, solver, nested?) do
    case actual do
      {:var, _id} = var when nested? -> maybe_bind_exact(solver, var, expected)
      _type -> :error
    end
  end

  defp scalar_match?(expected, actual) do
    scalar_type?(expected) and scalar_type?(actual) and
      match?({:ok, _solver}, Solver.assignable(Solver.new(), expected, actual))
  end

  defp scalar_type?(type), do: CType.primitive_kind(type) != nil

  defp maybe_bind_exact(_solver, _var, :null), do: :error
  defp maybe_bind_exact(solver, var, expected), do: bind_exact(solver, var, expected)

  defp bind_exact(solver, var, expected) do
    case Solver.unify(solver, var, expected) do
      {:ok, _type, solver} -> {:ok, solver}
      :error -> :error
    end
  end

  defp match_assignable(patterns, types, params, solver) do
    with {:ok, patterns} <- TypePattern.expand_args(patterns, types) do
      patterns
      |> Enum.zip(types)
      |> Enum.reduce_while({:ok, params, solver}, fn {pattern, actual}, {:ok, params, solver} ->
        with {:ok, params, solver} <- match_assignable_type(pattern, actual, params, solver) do
          {:cont, {:ok, params, solver}}
        else
          _other -> {:halt, :error}
        end
      end)
    end
  end

  defp match_assignable_type(:any, _actual, params, solver), do: {:ok, params, solver}

  defp match_assignable_type({:param, name}, actual, params, solver) do
    actual = Solver.resolve(solver, actual)

    case Map.fetch(params, name) do
      {:ok, expected} ->
        expected = Solver.resolve(solver, expected)

        case assign_param(solver, expected, actual) do
          {:ok, solver} -> {:ok, params, solver}
          :error -> :error
        end

      :error ->
        {:ok, Map.put(params, name, actual), solver}
    end
  end

  defp match_assignable_type({:type, type_pattern}, actual, params, solver) do
    case Solver.resolve(solver, actual) do
      {:type, actual_type} -> match_assignable_type(type_pattern, actual_type, params, solver)
      {:var, _id} -> match_assignable_expected({:type, type_pattern}, actual, params, solver)
      _type -> :error
    end
  end

  defp match_assignable_type({:list, elem_pattern}, actual, params, solver) do
    case Solver.resolve(solver, actual) do
      {:var, _id} ->
        match_assignable_expected({:list, elem_pattern}, actual, params, solver)

      actual ->
        case CType.list_elem(actual) do
          {:ok, elem_type} -> match_assignable_type(elem_pattern, elem_type, params, solver)
          :error -> :error
        end
    end
  end

  defp match_assignable_type({:map, key_pattern, value_pattern}, actual, params, solver) do
    case Solver.resolve(solver, actual) do
      {:var, _id} ->
        match_assignable_expected({:map, key_pattern, value_pattern}, actual, params, solver)

      actual ->
        case CType.map_types(actual) do
          {:ok, key_type, value_type} ->
            with {:ok, params, solver} <-
                   match_assignable_type(key_pattern, key_type, params, solver) do
              match_assignable_type(value_pattern, value_type, params, solver)
            end

          :error ->
            :error
        end
    end
  end

  defp match_assignable_type({:optional, value_pattern}, actual, params, solver) do
    case Solver.resolve(solver, actual) do
      {:var, _id} ->
        match_assignable_expected({:optional, value_pattern}, actual, params, solver)

      actual ->
        if CType.optional?(actual) do
          match_assignable_type(value_pattern, CType.unwrap_optional(actual), params, solver)
        else
          :error
        end
    end
  end

  defp match_assignable_type({:abstract, name, param_patterns}, actual, params, solver) do
    case Solver.resolve(solver, actual) do
      {:var, _id} ->
        match_assignable_expected({:abstract, name, param_patterns}, actual, params, solver)

      {:abstract, ^name, actual_params} when length(param_patterns) == length(actual_params) ->
        param_patterns
        |> Enum.zip(actual_params)
        |> Enum.reduce_while({:ok, params, solver}, fn {pattern, actual}, {:ok, params, solver} ->
          case match_assignable_type(pattern, actual, params, solver) do
            {:ok, params, solver} -> {:cont, {:ok, params, solver}}
            :error -> {:halt, :error}
          end
        end)

      _type ->
        :error
    end
  end

  defp match_assignable_type(:dyn, actual, params, solver) do
    if Solver.resolve(solver, actual) == CType.dyn() do
      {:ok, params, solver}
    else
      :error
    end
  end

  defp match_assignable_type(:dynamic, actual, params, solver) do
    if solver |> Solver.resolve(actual) |> CType.dynamic?() do
      {:ok, params, solver}
    else
      :error
    end
  end

  defp match_assignable_type(:numeric, actual, params, solver) do
    if solver |> Solver.resolve(actual) |> CType.numeric?() do
      {:ok, params, solver}
    else
      :error
    end
  end

  defp match_assignable_type(:integral, actual, params, solver) do
    if solver |> Solver.resolve(actual) |> CType.integral?() do
      {:ok, params, solver}
    else
      :error
    end
  end

  defp match_assignable_type({:one_of, matchers}, actual, params, solver) do
    Enum.reduce_while(matchers, :error, fn matcher, :error ->
      case match_assignable_type(matcher, actual, params, solver) do
        {:ok, _params, _solver} = result -> {:halt, result}
        :error -> {:cont, :error}
      end
    end)
  end

  defp match_assignable_type(pattern, actual, params, solver) do
    match_assignable_expected(pattern, actual, params, solver)
  end

  defp match_assignable_expected(pattern, actual, params, solver) do
    with {:ok, expected, params, solver} <- instantiate(pattern, params, solver),
         {:ok, solver} <- Solver.assignable(solver, expected, actual) do
      {:ok, params, solver}
    else
      _other -> :error
    end
  end

  defp assign_param(solver, {:var, _id} = expected, actual) do
    case Solver.unify(solver, expected, actual) do
      {:ok, _type, solver} -> {:ok, solver}
      :error -> :error
    end
  end

  defp assign_param(solver, expected, actual), do: Solver.assignable(solver, expected, actual)

  defp collect_common(patterns, types, constraints, solver) do
    with {:ok, patterns} <- TypePattern.expand_args(patterns, types) do
      patterns
      |> Enum.zip(types)
      |> Enum.reduce_while({:ok, constraints, solver}, fn {pattern, actual},
                                                          {:ok, constraints, solver} ->
        case collect_common_type(pattern, actual, constraints, solver) do
          {:ok, constraints, solver} -> {:cont, {:ok, constraints, solver}}
          :error -> {:halt, :error}
        end
      end)
    end
  end

  defp collect_common_type(:any, _actual, constraints, solver), do: {:ok, constraints, solver}

  defp collect_common_type({:param, name}, actual, constraints, solver) do
    actual = Solver.resolve(solver, actual)
    {:ok, Map.update(constraints, name, [actual], &[actual | &1]), solver}
  end

  defp collect_common_type({:list, elem_pattern}, actual, constraints, solver) do
    case CType.list_elem(Solver.resolve(solver, actual)) do
      {:ok, elem_type} -> collect_common_type(elem_pattern, elem_type, constraints, solver)
      :error -> :error
    end
  end

  defp collect_common_type({:map, key_pattern, value_pattern}, actual, constraints, solver) do
    case CType.map_types(Solver.resolve(solver, actual)) do
      {:ok, key_type, value_type} ->
        with {:ok, constraints, solver} <-
               collect_common_type(key_pattern, key_type, constraints, solver) do
          collect_common_type(value_pattern, value_type, constraints, solver)
        end

      :error ->
        :error
    end
  end

  defp collect_common_type({:optional, value_pattern}, actual, constraints, solver) do
    actual = Solver.resolve(solver, actual)

    if CType.optional?(actual) do
      collect_common_type(value_pattern, CType.unwrap_optional(actual), constraints, solver)
    else
      :error
    end
  end

  defp collect_common_type({:abstract, name, param_patterns}, actual, constraints, solver) do
    case Solver.resolve(solver, actual) do
      {:abstract, ^name, actual_params} when length(param_patterns) == length(actual_params) ->
        param_patterns
        |> Enum.zip(actual_params)
        |> Enum.reduce_while({:ok, constraints, solver}, fn {pattern, actual},
                                                            {:ok, constraints, solver} ->
          case collect_common_type(pattern, actual, constraints, solver) do
            {:ok, constraints, solver} -> {:cont, {:ok, constraints, solver}}
            :error -> {:halt, :error}
          end
        end)

      _type ->
        :error
    end
  end

  defp collect_common_type(:dyn, actual, constraints, solver) do
    if Solver.resolve(solver, actual) == CType.dyn() do
      {:ok, constraints, solver}
    else
      :error
    end
  end

  defp collect_common_type(:dynamic, actual, constraints, solver) do
    if solver |> Solver.resolve(actual) |> CType.dynamic?() do
      {:ok, constraints, solver}
    else
      :error
    end
  end

  defp collect_common_type(:numeric, actual, constraints, solver) do
    if solver |> Solver.resolve(actual) |> CType.numeric?() do
      {:ok, constraints, solver}
    else
      :error
    end
  end

  defp collect_common_type(:integral, actual, constraints, solver) do
    if solver |> Solver.resolve(actual) |> CType.integral?() do
      {:ok, constraints, solver}
    else
      :error
    end
  end

  defp collect_common_type({:one_of, matchers}, actual, constraints, solver) do
    Enum.reduce_while(matchers, :error, fn matcher, :error ->
      case collect_common_type(matcher, actual, constraints, solver) do
        {:ok, _constraints, _solver} = result -> {:halt, result}
        :error -> {:cont, :error}
      end
    end)
  end

  defp collect_common_type(pattern, actual, constraints, solver) do
    with {:ok, expected, _params, solver} <- instantiate(pattern, %{}, solver),
         {:ok, solver} <- Solver.assignable(solver, expected, actual) do
      {:ok, constraints, solver}
    else
      _other -> :error
    end
  end

  defp common_params(constraints, solver) do
    {params, solver} =
      Enum.reduce(constraints, {%{}, solver}, fn {name, types}, {params, solver} ->
        {type, solver} = Solver.common(solver, Enum.reverse(types))
        {Map.put(params, name, type), solver}
      end)

    {:ok, params, solver}
  end

  defp instantiate({:param, name}, params, solver) do
    case Map.fetch(params, name) do
      {:ok, type} ->
        {:ok, type, params, solver}

      :error ->
        {type, solver} = Solver.fresh(solver)
        {:ok, type, Map.put(params, name, type), solver}
    end
  end

  defp instantiate({:type, type}, params, solver) do
    with {:ok, type, params, solver} <- instantiate(type, params, solver) do
      {:ok, CType.type(type), params, solver}
    end
  end

  defp instantiate({:list, elem_type}, params, solver) do
    with {:ok, elem_type, params, solver} <- instantiate(elem_type, params, solver) do
      {:ok, CType.list(elem_type), params, solver}
    end
  end

  defp instantiate({:map, key_type, value_type}, params, solver) do
    with {:ok, key_type, params, solver} <- instantiate(key_type, params, solver),
         {:ok, value_type, params, solver} <- instantiate(value_type, params, solver) do
      {:ok, CType.map(key_type, value_type), params, solver}
    end
  end

  defp instantiate({:message, name}, params, solver) do
    {:ok, CType.message(name), params, solver}
  end

  defp instantiate({:optional, value_type}, params, solver) do
    with {:ok, value_type, params, solver} <- instantiate(value_type, params, solver) do
      {:ok, CType.optional(value_type), params, solver}
    end
  end

  defp instantiate({:abstract, name, param_types}, params, solver) do
    with {:ok, param_types, params, solver} <- instantiate_list(param_types, params, solver) do
      {:ok, {:abstract, name, param_types}, params, solver}
    end
  end

  defp instantiate(:dyn, params, solver), do: {:ok, CType.dyn(), params, solver}
  defp instantiate(:null, params, solver), do: {:ok, CType.null(), params, solver}
  defp instantiate(:bool, params, solver), do: {:ok, CType.bool(), params, solver}
  defp instantiate(:int, params, solver), do: {:ok, CType.int(), params, solver}
  defp instantiate(:uint, params, solver), do: {:ok, CType.uint(), params, solver}
  defp instantiate(:double, params, solver), do: {:ok, CType.double(), params, solver}
  defp instantiate(:string, params, solver), do: {:ok, CType.string(), params, solver}
  defp instantiate(:bytes, params, solver), do: {:ok, CType.bytes(), params, solver}
  defp instantiate(:timestamp, params, solver), do: {:ok, CType.timestamp(), params, solver}
  defp instantiate(:duration, params, solver), do: {:ok, CType.duration(), params, solver}
  defp instantiate(:dynamic, params, solver), do: {:ok, CType.dyn(), params, solver}

  defp instantiate_list(types, params, solver) do
    Enum.reduce_while(types, {:ok, [], params, solver}, fn type, {:ok, types, params, solver} ->
      case instantiate(type, params, solver) do
        {:ok, type, params, solver} -> {:cont, {:ok, [type | types], params, solver}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, types, params, solver} -> {:ok, Enum.reverse(types), params, solver}
      :error -> :error
    end
  end

  defp instantiate_result({:arg, index}, types, params, solver) do
    case Enum.fetch(types, index) do
      {:ok, type} -> {:ok, type, params, solver}
      :error -> :error
    end
  end

  defp instantiate_result(result, _types, params, solver), do: instantiate(result, params, solver)

  defp fallback_on_dyn?(%Overload{on_dyn: :fallback}, types, solver) do
    Enum.any?(types, &(Solver.resolve(solver, &1) == CType.dyn()))
  end

  defp fallback_on_dyn?(%Overload{}, _types, _solver), do: false

  defp dynamic_overload_applicable?(types, solver) do
    Enum.any?(types, &(dynamic_type?(&1, solver) or unresolved_var?(&1, solver)))
  end

  defp unresolved_var?(type, solver), do: match?({:var, _id}, Solver.resolve(solver, type))

  defp dynamic_type?(type, solver), do: solver |> Solver.resolve(type) |> CType.dynamic?()

  defp ok(type, %Overload{} = overload, solver) do
    {:ok,
     %{
       type: Solver.resolve(solver, type),
       overload_id: overload.id,
       eval: overload.eval,
       eval_context: overload.eval_context,
       strict: overload.strict
     }, solver}
  end
end
