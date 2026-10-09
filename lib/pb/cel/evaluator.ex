defmodule PB.CEL.Evaluator do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Runtime evaluator for checked CEL expressions.
  #
  # This module consumes `PB.CEL.Checked`, the same representation intended for
  # future compiled-code generation.
  @moduledoc false

  alias PB.CEL.Checked
  alias PB.CEL.Error
  alias PB.CEL.Runtime.Access
  alias PB.CEL.Runtime.Core
  alias PB.CEL.Runtime.Enum, as: RuntimeEnum
  alias PB.CEL.Runtime.NoMessageRuntime
  alias PB.CEL.Runtime.NoMessageSchema
  alias PB.CEL.Value
  alias PB.CEL.WellKnownTypes

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

  @type result :: {:ok, Value.t()} | {:error, Error.t()}

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

  # `@not_strictly_false` is the only non-strict call: comprehension loop
  # conditions use it so an error in one iteration does not stop the loop.
  defp eval_op(_id, {:call, %{name: "@not_strictly_false", arg_ids: [arg_id]}}, state) do
    {value, state} = eval_captured(arg_id, state)
    {:ok, Value.bool(value != Value.bool(false)), state}
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
    with {:ok, entries, state} <- eval_map_entries(entries, state) do
      {:ok, Value.map(Map.new(entries)), state}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> error(expr_ref(id), reason)
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
      {:ok, value} -> {:ok, value, state}
      :error -> error(expr, "missing value for #{inspect(name)}")
    end
  end

  defp eval_enum_constructor_call(expr, %{enum: enum_name, arg_ids: arg_ids}, state) do
    with {:ok, args, state} <- eval_ids(arg_ids, state) do
      apply_enum_constructor(expr, enum_name, args, state)
    end
  end

  defp eval_registered_call(expr, %{target_id: target_id, arg_ids: arg_ids} = op, state) do
    with {:ok, target, state} <- eval_target_id(target_id, state),
         {:ok, args, state} <- eval_ids(arg_ids, state) do
      apply_registered_call(expr, op, target, args, state)
    end
  end

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

      case eval_id(body_id, state) do
        {:ok, result, state} -> {:ok, result, pop_scope(state)}
        {:error, %Error{} = error} -> {:error, error}
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

  # `&&` and `||` are commutative over errors: `decisive` (false for `&&`,
  # true for `||`) on either side determines the result, otherwise the first
  # error wins.
  defp eval_logic(expr, left_id, right_id, decisive, state) do
    {left, state} = eval_logic_operand(left_id, expr, state)

    if left == Value.bool(decisive) do
      {:ok, left, state}
    else
      {right, state} = eval_logic_operand(right_id, expr, state)

      cond do
        right == Value.bool(decisive) -> {:ok, right, state}
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

  defp eval_ids(ids, state) do
    Enum.reduce_while(ids, {:ok, [], state}, fn id, {:ok, values, state} ->
      case eval_id(id, state) do
        {:ok, value, state} -> {:cont, {:ok, [value | values], state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values, state} -> {:ok, Enum.reverse(values), state}
      {:error, error} -> {:error, error}
    end
  end

  defp eval_map_entries(entries, state) do
    Enum.reduce_while(entries, {:ok, [], state}, fn entry, {:ok, entries, state} ->
      with {:ok, key, state} <- eval_id(entry.key_id, state),
           {:ok, value, state} <- eval_id(entry.value_id, state),
           {:ok, maybe_entry} <-
             optional_entry({key, value}, entry.optional?) do
        cond do
          is_nil(maybe_entry) ->
            {:cont, {:ok, entries, state}}

          repeated_key?(entries, elem(maybe_entry, 0)) ->
            {:halt, error(%{id: entry.value_id}, "repeated key")}

          true ->
            {:cont, {:ok, [maybe_entry | entries], state}}
        end
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries, state} -> {:ok, Enum.reverse(entries), state}
      {:error, error} -> {:error, error}
    end
  end

  defp eval_message_literal(expr, %{message: message_name, fields: fields} = op, state, mode) do
    with {:ok, fields, state} <- eval_message_fields(fields, state) do
      case message_value(mode, message_name, fields, state, Map.get(op, :wkt_unwrap?, true)) do
        {:error, reason} -> error(expr, reason)
        value -> {:ok, value, state}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp eval_message_fields(fields, state) do
    Enum.reduce_while(fields, {:ok, [], state}, fn field, {:ok, fields, state} ->
      with {:ok, value, state} <- eval_message_field_value(field, state),
           {:ok, maybe_entry} <- optional_entry({field.field, value}, field.optional?) do
        fields =
          case maybe_entry do
            nil -> fields
            {_key, value} -> [Map.put(field, :value, value) | fields]
          end

        {:cont, {:ok, fields, state}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, fields, state} -> {:ok, Enum.reverse(fields), state}
      {:error, error} -> {:error, error}
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
         %{eval: {:mfa, {PB.CEL.Runtime.Strings, :matches}}} = op,
         target,
         args,
         state
       ) do
    values = call_values(target, args)

    case Map.fetch(state.regexes, id) do
      {:ok, %Regex{} = regex} ->
        dispatch_precompiled_matches(expr, values, state, regex)

      :error ->
        dispatch_mfa_call(
          expr,
          PB.CEL.Runtime.Strings,
          :matches,
          values,
          state,
          op[:eval_context] || []
        )
    end
  end

  defp apply_registered_call(expr, %{eval: {:mfa, {mod, fun}}} = op, target, args, state) do
    dispatch_mfa_call(expr, mod, fun, call_values(target, args), state, op[:eval_context] || [])
  end

  # eval: nil is the check-only-declaration path used when proto type_env
  # registers declarations without executable targets (for example the
  # conformance harness).
  defp apply_registered_call(expr, %{eval: nil, name: name}, _target, _args, _state) do
    error(expr, "unsupported function #{name}")
  end

  defp dispatch_mfa_call(expr, mod, fun, values, state, eval_context) do
    args = [values | Enum.map(eval_context, &eval_context_value(&1, state))]

    case apply(mod, fun, args) do
      {:ok, value} -> {:ok, value, state}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp dispatch_precompiled_matches(expr, values, state, regex) do
    case PB.CEL.Runtime.Strings.matches(values, regex) do
      {:ok, value} -> {:ok, value, state}
      {:error, reason} -> error(expr, reason)
    end
  end

  defp eval_context_value(:schema, state), do: state.schema
  defp eval_context_value(:message_runtime, state), do: state.message_runtime

  defp call_values(nil, args), do: args
  defp call_values(target, args), do: [target | args]

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
        # The accumulator may hold an error: `exists` and `all` absorb it
        # when a later iteration decides the result.
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

  # Non-strict evaluation for the operators that may absorb an error: the
  # outcome is captured as a value instead of aborting evaluation. Strict
  # consumers never see these values, because reading a variable or local
  # that holds one returns the error.
  defp eval_captured(id, state) do
    case eval_id(id, state) do
      {:ok, value, state} -> {value, state}
      {:error, %Error{} = error} -> {error_value(error), state}
    end
  end

  defp eval_logic_operand(id, expr, state) do
    case eval_captured(id, state) do
      {{:bool, _value} = value, state} ->
        {value, state}

      {{:__cel_error__, %Error{}} = value, state} ->
        {value, state}

      {value, state} ->
        {:error, error} = error(expr, "expected bool, got #{value_kind(value)}")
        {error_value(error), state}
    end
  end

  defp error_value(%Error{} = error), do: {:__cel_error__, error}

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
            "expected :message_schema to implement PB.CEL.Message.Schema, got: #{inspect(message_schema)}"
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
    do: {:error, %Error{phase: :eval, message: message, expr_id: id}}
end
