defmodule CEL.Evaluator do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Runtime evaluator for checked CEL expressions.
  #
  # This module consumes `CEL.Checked`, the same representation intended for
  # future compiled-code generation.
  @moduledoc false

  alias CEL.Checked
  alias CEL.Error
  alias CEL.Runtime.Access
  alias CEL.Runtime.Core
  alias CEL.Runtime.Enum, as: RuntimeEnum
  alias CEL.Runtime.NoMessageRuntime
  alias CEL.Runtime.NoMessageSchema
  alias CEL.Unknown
  alias CEL.Value
  alias CEL.WellKnownTypes

  defmodule State do
    @moduledoc false
    defstruct [
      :checked,
      :schema,
      :message_schema,
      :message_runtime,
      regexes: %{},
      vars: %{},
      var_cache: %{},
      scopes: []
    ]
  end

  @type result :: {:ok, Value.t()} | {:unknown, Unknown.t()} | {:error, Error.t()}

  @spec eval(Checked.t(), keyword | map, keyword) :: result
  def eval(%Checked{expr: expr} = checked, vars \\ %{}, opts \\ []) do
    message_schema = eval_message_schema(opts)

    state = %State{
      checked: checked,
      vars: normalize_vars(vars),
      regexes: Keyword.get(opts, :regexes, %{}),
      schema: eval_schema(checked, opts, message_schema),
      message_schema: message_schema,
      message_runtime: eval_message_runtime(opts)
    }

    case eval_id(expr.id, state) do
      {:ok, value, _state} -> {:ok, value}
      {:unknown, %Unknown{} = unknown} -> {:unknown, unknown}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp eval_id(id, %State{} = state) when is_integer(id) do
    case Checked.op(state.checked, id) do
      nil -> {:error, %Error{phase: :eval, message: "missing checked operation", expr_id: id}}
      op -> eval_op(id, op, state)
    end
  end

  defp eval_op(_id, {:const, %{value: value}}, state) do
    {:ok, value, state}
  end

  defp eval_op(id, {:ident, ident}, state) do
    eval_ident_op(expr_ref(id), ident, state)
  end

  defp eval_op(id, {:select, %{receiver_id: receiver_id} = op}, state) do
    with {:ok, operand, state} <- eval_id(receiver_id, state) do
      eval_select(expr_ref(id), operand, op, state)
    end
  end

  defp eval_op(id, {:special, %{kind: :and, arg_ids: [left_id, right_id]}}, state) do
    eval_and(expr_ref(id), left_id, right_id, state)
  end

  defp eval_op(id, {:special, %{kind: :or, arg_ids: [left_id, right_id]}}, state) do
    eval_or(expr_ref(id), left_id, right_id, state)
  end

  defp eval_op(
         id,
         {:special, %{kind: :conditional, arg_ids: [condition_id, true_id, false_id]}},
         state
       ) do
    eval_conditional(expr_ref(id), condition_id, true_id, false_id, state)
  end

  defp eval_op(id, {:special, %{kind: :bind, arg_ids: [init_id, body_id], var: var}}, state) do
    eval_bind(expr_ref(id), init_id, body_id, var, state)
  end

  defp eval_op(id, {:special, %{kind: kind} = op}, state)
       when kind in [:optional_map, :optional_flat_map] do
    eval_optional_map_call(expr_ref(id), op, state)
  end

  defp eval_op(id, {:special, %{kind: :enum_constructor} = op}, state) do
    eval_enum_constructor_call(expr_ref(id), op, state)
  end

  # `or` and `orValue` evaluate their alternative only when the receiver is
  # empty, as in cel-go.
  defp eval_op(id, {:call, %{overload_id: overload_id, target_id: target_id} = op}, state)
       when overload_id in ["optional_or", "optional_or_value"] and is_integer(target_id) do
    eval_optional_or(expr_ref(id), op, state)
  end

  defp eval_op(id, {:call, op}, state) do
    eval_registered_call(expr_ref(id), op, state)
  end

  defp eval_op(_id, {:list, %{elem_ids: elem_ids, optional_indices: optional_indices}}, state) do
    with {:ok, values, state} <- eval_ids(elem_ids, state) do
      values = maybe_apply_optional_list_entries(optional_indices, values)
      {:ok, Value.list(values), state}
    end
  end

  defp eval_op(id, {:map, %{entries: entries}}, state) do
    case eval_map_entries(entries, [], nil, state) do
      {:ok, entries, state} -> {:ok, Value.map(Map.new(entries)), state}
      {:error, reason} when is_binary(reason) -> error(expr_ref(id), reason)
      other -> other
    end
  end

  defp eval_op(id, {:message_literal, op}, state) do
    eval_message_literal(expr_ref(id), op, state, :normal)
  end

  defp eval_op(id, {:comprehension, op}, state) do
    eval_comprehension(expr_ref(id), op, state)
  end

  defp eval_op(id, _op, _state), do: error(expr_ref(id), "unsupported checked operation")

  defp eval_comprehension(expr, op, state) do
    with {:ok, range, state} <- eval_id(op.iter_range_id, state),
         {:ok, items} <- iteration_items(expr, range),
         {:ok, accu, state} <- eval_id(op.accu_init_id, state) do
      state =
        state
        |> push_scope()
        |> put_local(op.accu_var, accu)

      with {:ok, state} <- eval_loop(expr, op, items, state),
           {:ok, result, state} <- eval_id(op.result_id, state) do
        {:ok, result, pop_scope(state)}
      end
    end
  end

  defp eval_ident_op(expr, %{kind: :enum_value, value: value}, state) do
    eval_reference_value(expr, value, state)
  end

  defp eval_ident_op(_expr, %{kind: :type, denotation: denotation}, state) do
    {:ok, {:type, denotation}, state}
  end

  defp eval_ident_op(expr, %{kind: :var, name: name, type: type}, state) do
    eval_root_var(expr, name, type, state)
  end

  defp eval_ident_op(expr, %{kind: :local, name: name}, state) do
    eval_local(expr, name, state)
  end

  defp eval_root_var(expr, name, type, state) do
    case Map.fetch(state.var_cache, name) do
      {:ok, value} ->
        {:ok, value, state}

      :error ->
        fetch_and_coerce_root_var(expr, name, type, state)
    end
  end

  defp fetch_and_coerce_root_var(expr, name, type, state) do
    case Map.fetch(state.vars, name) do
      {:ok, {:__cel_error__, %Error{} = error}} ->
        {:error, error}

      {:ok, {:unknown, reason}} ->
        {:unknown, Unknown.new({:var, name}, reason)}

      {:ok, %Unknown{} = unknown} ->
        {:unknown, unknown}

      {:ok, value} ->
        case coerce_runtime_value(value, type, state) do
          {:ok, value} -> {:ok, value, put_cached_root_var(state, name, value)}
          {:error, reason} -> error(expr, reason)
        end

      :error ->
        error(expr, "missing value for #{inspect(name)}")
    end
  end

  defp eval_local(expr, name, state) do
    case fetch_local(state.scopes, name) do
      {:ok, {:__cel_error__, %Error{} = error}} -> {:error, error}
      {:ok, {:__cel_unknown__, %Unknown{} = unknown}} -> {:unknown, unknown}
      {:ok, value} -> {:ok, value, state}
      :error -> error(expr, "missing value for #{inspect(name)}")
    end
  end

  defp eval_enum_constructor_call(expr, %{enum: enum_name, arg_ids: arg_ids}, state) do
    with {:ok, args, state} <- eval_ids(arg_ids, state) do
      apply_enum_constructor(expr, enum_name, args, state)
    end
  end

  # A non-strict overload is called even when arguments are errors or
  # unknowns, and receives them as `{:error, %Error{}}` and
  # `{:unknown, %Unknown{}}`. `@not_strictly_false` is one: comprehension loop
  # conditions use it so an error or unknown in one iteration does not stop
  # the loop.
  defp eval_registered_call(expr, %{strict: false} = op, state) do
    {values, state} =
      Enum.map_reduce(List.wrap(op.target_id) ++ op.arg_ids, state, fn id, state ->
        {value, state} = eval_captured(id, state)
        {non_strict_arg(value), state}
      end)

    apply_registered_call(expr, op, values, state)
  end

  defp eval_registered_call(expr, %{target_id: target_id, arg_ids: arg_ids} = op, state) do
    with {:ok, values, state} <- eval_ids(List.wrap(target_id) ++ arg_ids, state) do
      apply_registered_call(expr, op, values, state)
    end
  end

  defp non_strict_arg({:__cel_error__, %Error{} = error}), do: {:error, error}
  defp non_strict_arg({:__cel_unknown__, %Unknown{} = unknown}), do: {:unknown, unknown}
  defp non_strict_arg(value), do: value

  defp eval_optional_map_call(
         expr,
         %{target_id: target_id, arg_ids: [_var_id, body_id], var: var_name, kind: kind},
         state
       ) do
    with {:ok, target, state} <- eval_target_id(target_id, state) do
      case target do
        {:optional, :none} ->
          {:ok, Value.optional_none(), state}

        {:optional, {:some, value}} ->
          state =
            state
            |> push_scope()
            |> put_local(var_name, value)

          with {:ok, result, state} <- eval_id(body_id, state),
               {:ok, result} <- optional_map_result(expr, kind, result) do
            {:ok, result, pop_scope(state)}
          end

        _other ->
          error(expr, "optional map requires optional receiver")
      end
    end
  end

  defp eval_optional_or(expr, %{target_id: target_id, arg_ids: [alternative_id]} = op, state) do
    with {:ok, target, state} <- eval_id(target_id, state) do
      case {op.overload_id, target} do
        {"optional_or", {:optional, {:some, _value}}} ->
          {:ok, target, state}

        {"optional_or_value", {:optional, {:some, value}}} ->
          {:ok, value, state}

        {_overload_id, {:optional, :none}} ->
          with {:ok, alternative, state} <- eval_id(alternative_id, state) do
            apply_registered_call(expr, op, [target, alternative], state)
          end

        _other ->
          error(expr, "no such overload")
      end
    end
  end

  defp optional_map_result(_expr, :optional_map, value), do: {:ok, Value.optional_some(value)}

  defp optional_map_result(_expr, :optional_flat_map, {:optional, _value} = optional),
    do: {:ok, optional}

  defp optional_map_result(expr, :optional_flat_map, _value),
    do: error(expr, "optFlatMap body must produce an optional value")

  defp eval_bind(_expr, init_id, body_id, var, state) do
    with {:ok, init, state} <- eval_id(init_id, state) do
      state =
        state
        |> push_scope()
        |> put_local(var, init)

      with {:ok, result, state} <- eval_id(body_id, state) do
        {:ok, result, pop_scope(state)}
      end
    end
  end

  defp eval_target_id(nil, state), do: {:ok, nil, state}
  defp eval_target_id(id, state), do: eval_id(id, state)

  defp eval_and(expr, left_id, right_id, state) do
    eval_logic(expr, left_id, right_id, false, state)
  end

  defp eval_or(expr, left_id, right_id, state) do
    eval_logic(expr, left_id, right_id, true, state)
  end

  # `&&` and `||` are commutative: `decisive` (false for `&&`, true for `||`)
  # on either side determines the result. Otherwise unknowns win over errors,
  # because a known value for them could still decide the result.
  defp eval_logic(expr, left_id, right_id, decisive, state) do
    {left, state} = eval_logic_operand(left_id, expr, state)

    if left == Value.bool(decisive) do
      {:ok, left, state}
    else
      {right, state} = eval_logic_operand(right_id, expr, state)

      cond do
        right == Value.bool(decisive) -> {:ok, right, state}
        unknown = captured_unknown([left, right]) -> {:unknown, unknown}
        match?({:__cel_error__, _error}, left) -> {:error, elem(left, 1)}
        match?({:__cel_error__, _error}, right) -> {:error, elem(right, 1)}
        true -> {:ok, Value.bool(not decisive), state}
      end
    end
  end

  defp eval_conditional(expr, condition_id, true_id, false_id, state) do
    with {:ok, condition, state} <- eval_id(condition_id, state),
         {:ok, condition} <- expect_bool(condition, expr) do
      if condition, do: eval_id(true_id, state), else: eval_id(false_id, state)
    end
  end

  # Strict operands are evaluated left to right. The first error wins, as the
  # result no longer depends on any unknown operand; otherwise the unknowns of
  # all operands are merged.
  defp eval_ids(ids, state), do: eval_ids(ids, [], nil, state)

  defp eval_ids([], values, nil, state), do: {:ok, Enum.reverse(values), state}
  defp eval_ids([], _values, %Unknown{} = unknown, _state), do: {:unknown, unknown}

  defp eval_ids([id | ids], values, unknown, state) do
    case eval_id(id, state) do
      {:ok, value, state} -> eval_ids(ids, [value | values], unknown, state)
      {:unknown, other} -> eval_ids(ids, values, merge_unknown(unknown, other), state)
      {:error, %Error{}} = error -> error
    end
  end

  defp eval_map_entries([], entries, nil, state), do: {:ok, Enum.reverse(entries), state}
  defp eval_map_entries([], _entries, %Unknown{} = unknown, _state), do: {:unknown, unknown}

  defp eval_map_entries([entry | rest], entries, unknown, state) do
    case eval_ids([entry.key_id, entry.value_id], state) do
      {:ok, [key, value], state} ->
        case optional_entry({key, value}, entry.optional?) do
          {:ok, nil} ->
            eval_map_entries(rest, entries, unknown, state)

          {:ok, {key, _value} = entry_value} ->
            if repeated_key?(entries, key) do
              error(%{id: entry.value_id}, "repeated key")
            else
              eval_map_entries(rest, [entry_value | entries], unknown, state)
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:unknown, other} ->
        eval_map_entries(rest, entries, merge_unknown(unknown, other), state)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp eval_message_literal(expr, %{message: message_name, fields: fields} = op, state, mode) do
    case eval_message_fields(fields, [], nil, state) do
      {:ok, fields, state} ->
        case message_value(mode, message_name, fields, state, Map.get(op, :wkt_unwrap?, true)) do
          {:error, reason} -> error(expr, reason)
          value -> {:ok, value, state}
        end

      {:error, reason} when is_binary(reason) ->
        error(expr, reason)

      other ->
        other
    end
  end

  defp eval_message_fields([], fields, nil, state), do: {:ok, Enum.reverse(fields), state}
  defp eval_message_fields([], _fields, %Unknown{} = unknown, _state), do: {:unknown, unknown}

  defp eval_message_fields([field | rest], fields, unknown, state) do
    case eval_message_field_value(field, state) do
      {:ok, value, state} ->
        case optional_entry({field.field, value}, field.optional?) do
          {:ok, nil} ->
            eval_message_fields(rest, fields, unknown, state)

          {:ok, {_key, value}} ->
            eval_message_fields(rest, [Map.put(field, :value, value) | fields], unknown, state)

          {:error, reason} ->
            {:error, reason}
        end

      {:unknown, other} ->
        eval_message_fields(rest, fields, merge_unknown(unknown, other), state)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp eval_message_field_value(%{assignment: :raw_message_literal, value_id: value_id}, state) do
    eval_raw_message_literal_id(value_id, state)
  end

  defp eval_message_field_value(%{value_id: value_id}, state), do: eval_id(value_id, state)

  defp eval_raw_message_literal_id(value_id, state) do
    case Checked.op(state.checked, value_id) do
      {:message_literal, op} ->
        eval_message_literal(expr_ref(value_id), op, state, :raw)

      _op ->
        error(expr_ref(value_id), "raw assignment requires message literal")
    end
  end

  defp optional_entry({_key, {:optional, :none}}, true), do: {:ok, nil}
  defp optional_entry({key, {:optional, {:some, value}}}, true), do: {:ok, {key, value}}

  defp optional_entry({_key, value}, true),
    do: {:error, "optional entry requires optional value, got #{inspect(value)}"}

  defp optional_entry(entry, false), do: {:ok, entry}

  defp maybe_apply_optional_list_entries(optional_indices, values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:optional, :none}, index} ->
        if MapSet.member?(optional_indices, index), do: [], else: [{:optional, :none}]

      {{:optional, {:some, value}}, index} ->
        if MapSet.member?(optional_indices, index),
          do: [value],
          else: [{:optional, {:some, value}}]

      {value, _index} ->
        [value]
    end)
  end

  defp eval_select(expr, operand, op, state) do
    case Access.select(state.message_runtime, state.schema, operand, op) do
      {:ok, value} -> {:ok, value, state}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp apply_registered_call(
         %{id: id} = expr,
         %{eval: {:mfa, {CEL.Runtime.Strings, :matches}}} = op,
         values,
         state
       ) do
    case Map.fetch(state.regexes, id) do
      {:ok, %Regex{} = regex} ->
        dispatch_precompiled_matches(expr, values, state, regex)

      :error ->
        dispatch_mfa_call(expr, op, CEL.Runtime.Strings, :matches, values, state)
    end
  end

  defp apply_registered_call(expr, %{eval: {:mfa, {mod, fun}}} = op, values, state) do
    dispatch_mfa_call(expr, op, mod, fun, values, state)
  end

  # eval: nil is the check-only-declaration path used when proto type_env
  # registers declarations without executable targets (for example the
  # conformance harness).
  defp apply_registered_call(expr, %{eval: nil, name: name}, _values, _state) do
    error(expr, "unsupported function #{name}")
  end

  defp dispatch_mfa_call(expr, op, mod, fun, values, state) do
    eval_context = Map.get(op, :eval_context, [])
    args = [values | Enum.map(eval_context, &eval_context_value(&1, expr, op, state))]

    case apply(mod, fun, args) do
      {:ok, value} -> {:ok, value, state}
      {:unknown, %Unknown{} = unknown} -> {:unknown, unknown}
      {:unknown, reason} -> {:unknown, Unknown.new({:call, op.name, expr.id}, reason)}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp dispatch_precompiled_matches(expr, values, state, regex) do
    case CEL.Runtime.Strings.matches(values, regex) do
      {:ok, value} -> {:ok, value, state}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp eval_context_value(:schema, _expr, _op, state), do: state.schema
  defp eval_context_value(:message_runtime, _expr, _op, state), do: state.message_runtime
  defp eval_context_value(:vars, _expr, _op, state), do: state.vars

  defp eval_context_value(:call, expr, op, _state),
    do: %{function: op.name, overload_id: op.overload_id, expr_id: expr.id}

  defp apply_enum_constructor(expr, enum_name, [value], state) do
    case RuntimeEnum.construct(state.message_schema, state.schema, enum_name, value) do
      {:ok, value} -> {:ok, value, state}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp apply_enum_constructor(expr, _enum_name, _args, _state) do
    error(expr, "enum constructor requires exactly one argument")
  end

  defp message_value(:normal, message_name, fields, state, wkt_unwrap?) do
    case state.message_runtime.from_literal(state.schema, message_name, fields, wkt_unwrap?) do
      {:ok, value} ->
        value

      :unknown ->
        well_known_message_value(message_name, message_field_values(fields), wkt_unwrap?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message_value(:raw, message_name, fields, state, _wkt_unwrap?) do
    case state.message_runtime.from_literal_message(state.schema, message_name, fields) do
      {:ok, value} -> value
      :unknown -> {:error, "unknown message #{inspect(message_name)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp well_known_message_value(message_name, fields, false), do: {:message, message_name, fields}

  defp well_known_message_value(message_name, fields, true) do
    message_name = if is_atom(message_name), do: Atom.to_string(message_name), else: message_name

    case WellKnownTypes.literal_value(message_name, fields) do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
      :error -> {:message, message_name, fields}
    end
  end

  defp message_field_values(fields) do
    Map.new(fields, fn field -> {field.field, field.value} end)
  end

  defp eval_loop(_expr, _op, [], state), do: {:ok, state}

  defp eval_loop(expr, op, [item | rest], state) do
    {first, second} = iter_values(item, op.iter_var2)

    state =
      state
      |> put_local(op.iter_var, first)
      |> put_second_iter_var(op.iter_var2, second)

    with {:ok, condition, state} <- eval_id(op.loop_condition_id, state),
         {:ok, condition} <- expect_bool(condition, expr) do
      if condition do
        # The accumulator may hold an error or unknown: `exists` and `all`
        # absorb it when a later iteration decides the result.
        {accu, state} = eval_captured(op.loop_step_id, state)

        state
        |> put_local(op.accu_var, accu)
        |> then(&eval_loop(expr, op, rest, &1))
      else
        {:ok, state}
      end
    end
  end

  defp iteration_items(_expr, {:list, values}) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> {:list, Value.int(index), value} end)
    |> then(&{:ok, &1})
  end

  defp iteration_items(_expr, {:map, values}) do
    values
    |> Enum.map(fn {key, value} -> {:map, key, value} end)
    |> then(&{:ok, &1})
  end

  defp iteration_items(expr, value), do: error(expr, "cannot iterate over #{value_kind(value)}")

  defp iter_values({:list, _index, value}, ""), do: {value, Value.null()}
  defp iter_values({:list, index, value}, _iter_var2), do: {index, value}
  defp iter_values({:map, key, _value}, ""), do: {key, Value.null()}
  defp iter_values({:map, key, value}, _iter_var2), do: {key, value}

  defp repeated_key?(entries, key) do
    Enum.any?(entries, fn {existing_key, _value} -> Core.equal?(existing_key, key) end)
  end

  defp expect_bool({:bool, value}, _expr), do: {:ok, value}
  defp expect_bool(value, expr), do: error(expr, "expected bool, got #{value_kind(value)}")

  # Non-strict evaluation for the operators that may absorb an error or
  # unknown: the outcome is captured as a value instead of aborting
  # evaluation. Strict consumers never see these values, because reading a
  # variable or local that holds one returns the error or unknown.
  defp eval_captured(id, state) do
    case eval_id(id, state) do
      {:ok, value, state} -> {value, state}
      {:unknown, %Unknown{} = unknown} -> {{:__cel_unknown__, unknown}, state}
      {:error, %Error{} = error} -> {error_value(error), state}
    end
  end

  defp eval_logic_operand(id, expr, state) do
    case eval_captured(id, state) do
      {{:bool, _value} = value, state} ->
        {value, state}

      {{:__cel_error__, %Error{}} = value, state} ->
        {value, state}

      {{:__cel_unknown__, %Unknown{}} = value, state} ->
        {value, state}

      {value, state} ->
        {:error, error} = error(expr, "expected bool, got #{value_kind(value)}")
        {error_value(error), state}
    end
  end

  defp error_value(%Error{} = error), do: {:__cel_error__, error}

  defp captured_unknown(values) do
    Enum.reduce(values, nil, fn
      {:__cel_unknown__, %Unknown{} = unknown}, acc -> merge_unknown(acc, unknown)
      _value, acc -> acc
    end)
  end

  defp merge_unknown(nil, %Unknown{} = unknown), do: unknown
  defp merge_unknown(%Unknown{} = acc, %Unknown{} = unknown), do: Unknown.merge(acc, unknown)

  # An enum variable takes what `PB.decode/4` gives an enum field: a value's
  # name as an atom, or its number.
  defp coerce_runtime_value(value, {:message, name} = type, %State{} = state)
       when is_integer(value) or (is_atom(value) and value not in [nil, true, false]) do
    if state.message_schema.known_enum?(state.schema, name) do
      arg = if is_integer(value), do: Value.int(value), else: Value.string(Atom.to_string(value))
      RuntimeEnum.construct(state.message_schema, state.schema, name, arg)
    else
      coerce_value(value, type)
    end
  end

  defp coerce_runtime_value(value, {:message, name} = type, %State{} = state) do
    if cel_value?(value) do
      coerce_value(value, type)
    else
      case state.message_schema.resolve_message(state.schema, name) do
        {:ok, message} ->
          with {:ok, value} <- state.message_runtime.from_decoded(state.schema, message, value) do
            coerce_value(value, type)
          end

        :error ->
          coerce_value(value, type)
      end
    end
  end

  defp coerce_runtime_value(value, type, _state), do: coerce_value(value, type)

  defp coerce_value(value, type), do: Value.coerce(value, type)

  defp eval_reference_value(expr, value, state) do
    case Value.from_expr_value(value,
           schema: state.schema,
           message_schema: state.message_schema,
           message_runtime: state.message_runtime
         ) do
      {:ok, value} -> {:ok, value, state}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp fetch_local(scopes, name) do
    Enum.find_value(scopes, :error, fn scope ->
      case Map.fetch(scope, name) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  defp put_cached_root_var(%State{} = state, name, value) do
    %{state | var_cache: Map.put(state.var_cache, name, value)}
  end

  defp push_scope(%State{} = state), do: %{state | scopes: [%{} | state.scopes]}

  defp pop_scope(%State{scopes: [_scope | scopes]} = state), do: %{state | scopes: scopes}

  defp put_local(%State{} = state, "", _value), do: state

  defp put_local(%State{scopes: []} = state, name, value) do
    state
    |> push_scope()
    |> put_local(name, value)
  end

  defp put_local(%State{scopes: [scope | scopes]} = state, name, value) do
    %{state | scopes: [Map.put(scope, name, value) | scopes]}
  end

  defp put_second_iter_var(state, "", _value), do: state
  defp put_second_iter_var(state, name, value), do: put_local(state, name, value)

  defp eval_schema(%Checked{}, opts, message_schema) do
    case Keyword.fetch(opts, :schema) do
      {:ok, schema} -> message_schema.normalize(schema)
      :error -> nil
    end
  end

  defp eval_message_schema(opts) do
    message_schema = Keyword.get(opts, :message_schema, NoMessageSchema)

    unless is_atom(message_schema) do
      raise ArgumentError,
            "expected :message_schema to be a module, got: #{inspect(message_schema)}"
    end

    Code.ensure_loaded(message_schema)

    unless function_exported?(message_schema, :normalize, 1) do
      raise ArgumentError,
            "expected :message_schema to implement CEL.Message.Schema, got: #{inspect(message_schema)}"
    end

    message_schema
  end

  defp eval_message_runtime(opts) do
    runtime = Keyword.get(opts, :message_runtime, NoMessageRuntime)

    unless is_atom(runtime) do
      raise ArgumentError, "expected :message_runtime to be a module, got: #{inspect(runtime)}"
    end

    runtime
  end

  defp normalize_vars(vars) when is_list(vars) or is_map(vars) do
    Map.new(vars, fn {name, value} -> {normalize_name(name), value} end)
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp value_kind(:null), do: "null"
  defp value_kind({kind, _value}), do: Atom.to_string(kind)
  defp value_kind({:enum, name, _value}), do: name
  defp value_kind({:object, type_url, _value}), do: type_url
  defp value_kind({:message, name, _fields}) when is_atom(name), do: Atom.to_string(name)
  defp value_kind({:message, name, _fields}), do: name
  defp value_kind(other), do: inspect(other)

  defp cel_value?(:null), do: true

  defp cel_value?(value) when is_tuple(value) and tuple_size(value) >= 1 do
    elem(value, 0) in [
      :bool,
      :int,
      :uint,
      :double,
      :string,
      :bytes,
      :timestamp,
      :duration,
      :enum,
      :object,
      :list,
      :map,
      :message,
      :optional,
      :type
    ]
  end

  defp cel_value?(_value), do: false

  defp expr_ref(id), do: %{id: id}

  defp error(%{id: id}, message),
    do: {:error, Error.exception(phase: :eval, message: message, expr_id: id)}
end
