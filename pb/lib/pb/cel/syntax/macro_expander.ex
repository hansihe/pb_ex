defmodule PB.CEL.Syntax.MacroExpander do
  @moduledoc false

  alias PB.CEL.Error
  alias PB.CEL.Proto

  @accu_var "__result__"

  defmodule State do
    @moduledoc false
    defstruct [:location, next_id: 1, positions: %{}, macro_calls: %{}]
  end

  @spec expand(Proto.parsed_expr()) :: {:ok, Proto.parsed_expr()} | {:error, Error.t()}
  def expand(%{expr: expr, source_info: source_info} = parsed) when is_map(expr) do
    state = %State{
      location: Map.get(source_info, :location),
      next_id: next_id(source_info, expr),
      positions: Map.get(source_info, :positions, %{}),
      macro_calls: Map.get(source_info, :macro_calls, %{})
    }

    with {:ok, expr, state} <- expand_expr(expr, state) do
      source_info =
        source_info
        |> Map.put(:positions, state.positions)
        |> put_macro_calls(state.macro_calls)

      {:ok, %{parsed | expr: expr, source_info: source_info}}
    end
  end

  defp expand_expr(%{expr_kind: {:const_expr, _constant}} = expr, state), do: {:ok, expr, state}
  defp expand_expr(%{expr_kind: {:ident_expr, _ident}} = expr, state), do: {:ok, expr, state}

  defp expand_expr(%{expr_kind: {:select_expr, select}} = expr, state) do
    with {:ok, operand, state} <- expand_expr(select.operand, state) do
      {:ok, %{expr | expr_kind: {:select_expr, %{select | operand: operand}}}, state}
    end
  end

  defp expand_expr(%{expr_kind: {:call_expr, call}} = expr, state) do
    expand_call(expr, call, state)
  end

  defp expand_expr(%{expr_kind: {:list_expr, list}} = expr, state) do
    with {:ok, elements, state} <- expand_exprs(Map.get(list, :elements, []), state) do
      {:ok, %{expr | expr_kind: {:list_expr, %{list | elements: elements}}}, state}
    end
  end

  defp expand_expr(%{expr_kind: {:struct_expr, struct}} = expr, state) do
    with {:ok, entries, state} <- expand_entries(Map.get(struct, :entries, []), state) do
      {:ok, %{expr | expr_kind: {:struct_expr, %{struct | entries: entries}}}, state}
    end
  end

  defp expand_expr(%{expr_kind: {:comprehension_expr, comprehension}} = expr, state) do
    fields = [
      :iter_range,
      :accu_init,
      :loop_condition,
      :loop_step,
      :result
    ]

    with {:ok, comprehension, state} <- expand_named_fields(comprehension, fields, state) do
      {:ok, %{expr | expr_kind: {:comprehension_expr, comprehension}}, state}
    end
  end

  defp expand_call(%{id: id} = expr, %{function: "has", args: [arg]} = call, state)
       when not is_map_key(call, :target) do
    pos = pos(state, id)

    case arg do
      %{expr_kind: {:select_expr, select}} ->
        with {:ok, operand, state} <- expand_expr(select.operand, state) do
          select = %{select | operand: operand, test_only: true}
          expanded = %{expr | expr_kind: {:select_expr, select}}
          {:ok, expanded, record_macro_call(state, expanded, expr, pos)}
        end

      _other ->
        error(state, pos, "invalid has() macro argument")
    end
  end

  defp expand_call(%{id: id} = expr, %{function: function, target: target, args: args}, state) do
    pos = pos(state, id)

    case {function, args} do
      {"all", [var, predicate]} ->
        expand_quantifier(expr, target, :all, [var], predicate, state, pos)

      {"all", [var, var2, predicate]} ->
        expand_quantifier(expr, target, :all, [var, var2], predicate, state, pos)

      {"exists", [var, predicate]} ->
        expand_quantifier(expr, target, :exists, [var], predicate, state, pos)

      {"exists", [var, var2, predicate]} ->
        expand_quantifier(expr, target, :exists, [var, var2], predicate, state, pos)

      {"exists_one", [var, predicate]} ->
        expand_quantifier(expr, target, :exists_one, [var], predicate, state, pos)

      {"exists_one", [var, var2, predicate]} ->
        expand_quantifier(expr, target, :exists_one, [var, var2], predicate, state, pos)

      {"existsOne", [var, predicate]} ->
        expand_quantifier(expr, target, :exists_one, [var], predicate, state, pos)

      {"existsOne", [var, var2, predicate]} ->
        expand_quantifier(expr, target, :exists_one, [var, var2], predicate, state, pos)

      {"map", [var, transform]} ->
        expand_list_transform(expr, target, [var], nil, transform, state, pos)

      {"map", [var, predicate, transform]} ->
        expand_list_transform(expr, target, [var], predicate, transform, state, pos)

      {"filter", [var, predicate]} ->
        expand_filter(expr, target, [var], predicate, state, pos)

      {"transformList", [var, var2, transform]} ->
        expand_list_transform(expr, target, [var, var2], nil, transform, state, pos)

      {"transformList", [var, var2, predicate, transform]} ->
        expand_list_transform(expr, target, [var, var2], predicate, transform, state, pos)

      {"transformMap", [var, var2, transform]} ->
        expand_map_transform(expr, target, [var, var2], nil, transform, state, pos)

      {"transformMap", [var, var2, predicate, transform]} ->
        expand_map_transform(expr, target, [var, var2], predicate, transform, state, pos)

      _other ->
        expand_regular_call(expr, state)
    end
  end

  defp expand_call(expr, _call, state) do
    expand_regular_call(expr, state)
  end

  defp expand_regular_call(%{expr_kind: {:call_expr, call}} = expr, state) do
    with {:ok, target, state} <- expand_optional_expr(Map.get(call, :target), state),
         {:ok, args, state} <- expand_exprs(Map.get(call, :args, []), state) do
      call = %{call | args: args}
      call = if target, do: Map.put(call, :target, target), else: Map.delete(call, :target)
      {:ok, %{expr | expr_kind: {:call_expr, call}}, state}
    end
  end

  defp expand_quantifier(expr, target, kind, vars, predicate, state, pos) do
    case macro_vars(vars) do
      {:ok, var, var2} ->
        with {:ok, target, state} <- expand_expr(target, state),
             {:ok, predicate, state} <- expand_expr(predicate, state) do
          {comprehension, state} =
            case kind do
              :all -> all_comprehension(target, var, var2, predicate, state, pos)
              :exists -> exists_comprehension(target, var, var2, predicate, state, pos)
              :exists_one -> exists_one_comprehension(target, var, var2, predicate, state, pos)
            end

          finish_macro(expr, comprehension, state, pos)
        end

      :not_macro ->
        expand_regular_call(expr, state)
    end
  end

  defp expand_list_transform(expr, target, vars, predicate, transform, state, pos) do
    case macro_vars(vars) do
      {:ok, var, var2} ->
        with {:ok, target, state} <- expand_expr(target, state),
             {:ok, predicate, state} <- expand_optional_expr(predicate, state),
             {:ok, transform, state} <- expand_expr(transform, state) do
          {accu_init, state} = list(state, pos, [])
          {loop_condition, state} = bool(state, pos, true)
          {loop_step, state} = append_to_list_step(state, pos, transform, predicate)
          {result, state} = ident(state, pos, @accu_var)

          comprehension =
            comprehension(target, var, var2, accu_init, loop_condition, loop_step, result)

          finish_macro(expr, comprehension, state, pos)
        end

      :not_macro ->
        expand_regular_call(expr, state)
    end
  end

  defp expand_filter(expr, target, vars, predicate, state, pos) do
    case macro_vars(vars) do
      {:ok, var, var2} ->
        with {:ok, target, state} <- expand_expr(target, state),
             {:ok, predicate, state} <- expand_expr(predicate, state) do
          {accu_init, state} = list(state, pos, [])
          {loop_condition, state} = bool(state, pos, true)
          {element, state} = ident(state, pos, var)
          {loop_step, state} = append_to_list_step(state, pos, element, predicate)
          {result, state} = ident(state, pos, @accu_var)

          comprehension =
            comprehension(target, var, var2, accu_init, loop_condition, loop_step, result)

          finish_macro(expr, comprehension, state, pos)
        end

      :not_macro ->
        expand_regular_call(expr, state)
    end
  end

  defp expand_map_transform(expr, target, vars, predicate, transform, state, pos) do
    case macro_vars(vars) do
      {:ok, var, var2} ->
        with {:ok, target, state} <- expand_expr(target, state),
             {:ok, predicate, state} <- expand_optional_expr(predicate, state),
             {:ok, transform, state} <- expand_expr(transform, state) do
          {accu_init, state} = map(state, pos, [])
          {loop_condition, state} = bool(state, pos, true)
          {loop_step, state} = append_to_map_step(state, pos, var, transform, predicate)
          {result, state} = ident(state, pos, @accu_var)

          comprehension =
            comprehension(target, var, var2, accu_init, loop_condition, loop_step, result)

          finish_macro(expr, comprehension, state, pos)
        end

      :not_macro ->
        expand_regular_call(expr, state)
    end
  end

  defp all_comprehension(target, var, var2, predicate, state, pos) do
    {accu_init, state} = bool(state, pos, true)
    {accu_cond, state} = ident(state, pos, @accu_var)
    {loop_condition, state} = call(state, pos, "@not_strictly_false", [accu_cond])
    {accu_step, state} = ident(state, pos, @accu_var)
    {loop_step, state} = call(state, pos, "_&&_", [accu_step, predicate])
    {result, state} = ident(state, pos, @accu_var)

    {comprehension(target, var, var2, accu_init, loop_condition, loop_step, result), state}
  end

  defp exists_comprehension(target, var, var2, predicate, state, pos) do
    {accu_init, state} = bool(state, pos, false)
    {accu_cond, state} = ident(state, pos, @accu_var)
    {not_accu, state} = call(state, pos, "!_", [accu_cond])
    {loop_condition, state} = call(state, pos, "@not_strictly_false", [not_accu])
    {accu_step, state} = ident(state, pos, @accu_var)
    {loop_step, state} = call(state, pos, "_||_", [accu_step, predicate])
    {result, state} = ident(state, pos, @accu_var)

    {comprehension(target, var, var2, accu_init, loop_condition, loop_step, result), state}
  end

  defp exists_one_comprehension(target, var, var2, predicate, state, pos) do
    {accu_init, state} = int(state, pos, 0)
    {loop_condition, state} = bool(state, pos, true)
    {accu_inc, state} = ident(state, pos, @accu_var)
    {one, state} = int(state, pos, 1)
    {increment, state} = call(state, pos, "_+_", [accu_inc, one])
    {accu_keep, state} = ident(state, pos, @accu_var)
    {loop_step, state} = call(state, pos, "_?_:_", [predicate, increment, accu_keep])
    {accu_result, state} = ident(state, pos, @accu_var)
    {one_result, state} = int(state, pos, 1)
    {result, state} = call(state, pos, "_==_", [accu_result, one_result])

    {comprehension(target, var, var2, accu_init, loop_condition, loop_step, result), state}
  end

  defp append_to_list_step(state, pos, element, nil) do
    {accu, state} = ident(state, pos, @accu_var)
    {singleton, state} = list(state, pos, [element])
    call(state, pos, "_+_", [accu, singleton])
  end

  defp append_to_list_step(state, pos, element, predicate) do
    {append, state} = append_to_list_step(state, pos, element, nil)
    {accu, state} = ident(state, pos, @accu_var)
    call(state, pos, "_?_:_", [predicate, append, accu])
  end

  defp append_to_map_step(state, pos, key_var, value, nil) do
    {accu, state} = ident(state, pos, @accu_var)
    {key, state} = ident(state, pos, key_var)
    {singleton, state} = map(state, pos, [{key, value}])
    call(state, pos, "_+_", [accu, singleton])
  end

  defp append_to_map_step(state, pos, key_var, value, predicate) do
    {append, state} = append_to_map_step(state, pos, key_var, value, nil)
    {accu, state} = ident(state, pos, @accu_var)
    call(state, pos, "_?_:_", [predicate, append, accu])
  end

  defp finish_macro(%{id: id} = original, comprehension, state, pos) do
    expanded = %{id: id, expr_kind: {:comprehension_expr, comprehension}}
    {:ok, expanded, record_macro_call(state, expanded, original, pos)}
  end

  defp comprehension(target, var, nil, accu_init, loop_condition, loop_step, result) do
    %{
      iter_var: var,
      iter_var2: "",
      iter_range: target,
      accu_var: @accu_var,
      accu_init: accu_init,
      loop_condition: loop_condition,
      loop_step: loop_step,
      result: result
    }
  end

  defp comprehension(target, var, var2, accu_init, loop_condition, loop_step, result) do
    target
    |> comprehension(var, nil, accu_init, loop_condition, loop_step, result)
    |> Map.put(:iter_var2, var2)
  end

  defp macro_vars(vars) do
    case Enum.map(vars, &ident_name/1) do
      [var] when is_binary(var) -> {:ok, var, nil}
      [var, var2] when is_binary(var) and is_binary(var2) -> {:ok, var, var2}
      _other -> :not_macro
    end
  end

  defp ident_name(%{expr_kind: {:ident_expr, %{name: name}}}) when is_binary(name), do: name
  defp ident_name(_expr), do: nil

  defp expand_optional_expr(nil, state), do: {:ok, nil, state}
  defp expand_optional_expr(expr, state), do: expand_expr(expr, state)

  defp expand_exprs(exprs, state), do: expand_exprs(exprs, state, [])

  defp expand_exprs([], state, acc), do: {:ok, Enum.reverse(acc), state}

  defp expand_exprs([expr | rest], state, acc) do
    with {:ok, expr, state} <- expand_expr(expr, state) do
      expand_exprs(rest, state, [expr | acc])
    end
  end

  defp expand_entries(entries, state), do: expand_entries(entries, state, [])

  defp expand_entries([], state, acc), do: {:ok, Enum.reverse(acc), state}

  defp expand_entries([entry | rest], state, acc) do
    with {:ok, entry, state} <- expand_entry(entry, state) do
      expand_entries(rest, state, [entry | acc])
    end
  end

  defp expand_entry(%{key_kind: {:map_key, key}, value: value} = entry, state) do
    with {:ok, key, state} <- expand_expr(key, state),
         {:ok, value, state} <- expand_expr(value, state) do
      {:ok, %{entry | key_kind: {:map_key, key}, value: value}, state}
    end
  end

  defp expand_entry(%{value: value} = entry, state) do
    with {:ok, value, state} <- expand_expr(value, state) do
      {:ok, %{entry | value: value}, state}
    end
  end

  defp expand_named_fields(map, fields, state), do: expand_named_fields_loop(fields, map, state)

  defp expand_named_fields_loop([], map, state), do: {:ok, map, state}

  defp expand_named_fields_loop([field | rest], map, state) do
    with {:ok, value, state} <- expand_expr(Map.fetch!(map, field), state) do
      expand_named_fields_loop(rest, Map.put(map, field, value), state)
    end
  end

  defp bool(state, pos, value) do
    expr(state, pos, {:const_expr, %{constant_kind: {:bool_value, value}}})
  end

  defp int(state, pos, value) do
    expr(state, pos, {:const_expr, %{constant_kind: {:int64_value, value}}})
  end

  defp ident(state, pos, name) do
    expr(state, pos, {:ident_expr, %{name: name}})
  end

  defp call(state, pos, function, args, target \\ nil) do
    call = %{function: function, args: args}
    call = if target, do: Map.put(call, :target, target), else: call
    expr(state, pos, {:call_expr, call})
  end

  defp list(state, pos, elements) do
    expr(state, pos, {:list_expr, %{elements: elements, optional_indices: []}})
  end

  defp map(state, pos, entries) do
    {entries, state} =
      Enum.map_reduce(entries, state, fn {key, value}, state ->
        entry(state, pos, {:map_key, key}, value)
      end)

    expr(state, pos, {:struct_expr, %{message_name: "", entries: entries}})
  end

  defp expr(%State{} = state, pos, expr_kind) do
    id = state.next_id
    expr = %{id: id, expr_kind: expr_kind}
    state = %State{state | next_id: id + 1, positions: Map.put(state.positions, id, pos)}
    {expr, state}
  end

  defp entry(%State{} = state, pos, key_kind, value) do
    id = state.next_id
    entry = %{id: id, key_kind: key_kind, value: value, optional_entry: false}
    state = %State{state | next_id: id + 1, positions: Map.put(state.positions, id, pos)}
    {entry, state}
  end

  defp record_macro_call(%State{} = state, %{id: id}, original, pos) do
    %State{
      state
      | positions: Map.put_new(state.positions, id, pos),
        macro_calls: Map.put(state.macro_calls, id, original)
    }
  end

  defp put_macro_calls(source_info, macro_calls) when map_size(macro_calls) == 0 do
    source_info
  end

  defp put_macro_calls(source_info, macro_calls) do
    Map.put(source_info, :macro_calls, macro_calls)
  end

  defp next_id(source_info, expr) do
    source_info
    |> Map.get(:positions, %{})
    |> Map.keys()
    |> Kernel.++(collect_ids(expr))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp collect_ids(%{id: id, expr_kind: {_kind, body}}) do
    [id | collect_ids(body)]
  end

  defp collect_ids(%{id: id, key_kind: {:map_key, key}, value: value}) do
    [id | collect_ids(key) ++ collect_ids(value)]
  end

  defp collect_ids(%{id: id, value: value}) do
    [id | collect_ids(value)]
  end

  defp collect_ids(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.flat_map(&collect_ids/1)
  end

  defp collect_ids(list) when is_list(list), do: Enum.flat_map(list, &collect_ids/1)
  defp collect_ids(_other), do: []

  defp pos(%State{} = state, id), do: Map.get(state.positions, id, 0)

  defp error(%State{} = state, offset, message) do
    {:error,
     Error.exception(phase: :parse, message: message, offset: offset, location: state.location)}
  end
end
