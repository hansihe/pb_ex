defmodule CEL.Checker do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # CEL static checker.
  #
  # The checker returns `CEL.Checked`, PB's native checked
  # representation. Standard `cel.expr.CheckedExpr` output is derived from that
  # representation only when explicitly requested.
  @moduledoc false

  alias CEL.Call
  alias CEL.Checked
  alias CEL.Checker.Literals
  alias CEL.Checker.NameResolution
  alias CEL.Checker.Signatures
  alias CEL.Checker.Solver
  alias CEL.Checker.Types, as: CType
  alias CEL.Env
  alias CEL.Error
  alias CEL.Proto
  alias CEL.Runtime.Convert, as: RuntimeConvert
  alias CEL.Runtime.Core, as: RuntimeCore
  alias CEL.Syntax.Source
  alias CEL.Value
  alias CEL.WellKnownTypes

  defmodule State do
    @moduledoc false
    defstruct [:env, :solver, scopes: [], types: %{}, ops: %{}]
  end

  @enum_constructor_overload_id "enum_constructor"
  @enum_to_int_overload_id "convert_enum_to_int"

  @type result :: {:ok, Checked.t()} | {:error, Error.t()}

  @spec check(Proto.parsed_expr(), keyword) :: result
  def check(%{expr: expr, source_info: source_info}, opts \\ []) when is_map(expr) do
    state = %State{env: Env.from_options(opts), solver: Solver.new()}

    with {:ok, _type, state} <- infer(expr, state),
         :ok <- Literals.validate(state.ops, state.env.validate_literals) do
      types = finalize_types(state)

      {:ok,
       Checked.new(
         expr: expr,
         source_info: source_info,
         types: types,
         ops: state.ops,
         enums: enum_names(types, state.env)
       )}
    else
      {:error, error} -> {:error, locate(error, source_info)}
    end
  end

  # Errors carry the id of the expression they are about; add its source
  # offset so callers need not look it up themselves.
  defp locate(%Error{expr_id: id} = error, source_info) do
    offset = source_info |> Map.get(:positions, %{}) |> Map.get(id)

    %{error | offset: offset, location: Map.get(source_info, :location)}
    |> Source.locate(Map.get(source_info, :line_offsets, []))
  end

  defp infer(%{expr_kind: {:const_expr, constant}} = expr, state) do
    type =
      case constant.constant_kind do
        {:null_value, :NULL_VALUE} -> CType.null()
        {:bool_value, _value} -> CType.bool()
        {:int64_value, _value} -> CType.int()
        {:uint64_value, _value} -> CType.uint()
        {:double_value, _value} -> CType.double()
        {:string_value, _value} -> CType.string()
        {:bytes_value, _value} -> CType.bytes()
      end

    state = put_op(state, expr, {:const, %{value: Value.from_constant(constant)}})

    ok(expr, type, state)
  end

  defp infer(%{expr_kind: {:ident_expr, %{name: name}}} = expr, state) do
    case NameResolution.resolve(expr, state.env, state.scopes) do
      {:ok, resolved} ->
        ok(expr, checker_type(resolved.type), put_resolved_ident_op(state, expr, resolved))

      :error ->
        error(expr, "undeclared identifier #{inspect(name)}")
    end
  end

  defp infer(%{expr_kind: {:select_expr, select}} = expr, state) do
    if Map.get(select, :test_only, false) do
      with {:ok, operand_type, state} <- infer(select.operand, state) do
        infer_presence_test_type(expr, operand_type, select.field, state)
      end
    else
      case NameResolution.resolve(expr, state.env, state.scopes) do
        {:ok, resolved} ->
          ok(
            expr,
            checker_type(resolved.type),
            put_resolved_ident_op(state, expr, resolved)
          )

        :error ->
          with {:ok, operand_type, state} <- infer(select.operand, state) do
            infer_select_type(expr, operand_type, select.field, state)
          end
      end
    end
  end

  defp infer(%{expr_kind: {:call_expr, call}} = expr, state) do
    call = Call.classify(call, namespaces: Env.namespaces(state.env))

    case try_infer_special(call, expr, state) do
      {:ok, type, state} -> ok(expr, type, state)
      {:error, error} -> {:error, error}
      :pass -> infer_call(expr, call, state)
    end
  end

  defp infer(%{expr_kind: {:list_expr, list}} = expr, state) do
    with {:ok, elem_types, state} <- infer_all(Map.get(list, :elements, []), state) do
      optional_indices = MapSet.new(Map.get(list, :optional_indices, []))

      elem_types =
        elem_types
        |> Enum.with_index()
        |> Enum.map(fn {type, index} ->
          if MapSet.member?(optional_indices, index), do: CType.unwrap_optional(type), else: type
        end)

      {elem_type, state} = common_or_fresh(elem_types, state)
      state = put_list_op(state, expr, list)
      ok(expr, CType.list(elem_type), state)
    end
  end

  defp infer(%{expr_kind: {:struct_expr, struct}} = expr, state) do
    with {:ok, key_types, value_types, state} <-
           infer_entries(Map.get(struct, :entries, []), state) do
      if Map.get(struct, :message_name, "") == "" do
        entries = Map.get(struct, :entries, [])

        if key_types == [] do
          {key_type, state} = fresh_type(state)
          {value_type, state} = fresh_type(state)
          state = put_map_op(state, expr, entries)
          ok(expr, CType.map(key_type, value_type), state)
        else
          {key_type, state} = common_types(key_types, state)
          {value_type, state} = common_types(value_types, state)

          if map_keys?(key_types, key_type) do
            state = put_map_op(state, expr, entries)
            ok(expr, CType.map(key_type, value_type), state)
          else
            error(expr, "map keys must be int, uint, bool, or string")
          end
        end
      else
        field_types = message_field_types(Map.get(struct, :entries, []), value_types)
        entries = Map.get(struct, :entries, [])

        with {:ok, message_name} <- message_literal_name(expr, struct.message_name, state),
             {:ok, op, state} <-
               message_literal_op(expr, message_name, entries, value_types, state) do
          state = put_op(state, expr, op)
          ok(expr, message_literal_type(message_name, field_types, state), state)
        end
      end
    end
  end

  defp infer(%{expr_kind: {:comprehension_expr, comprehension}} = expr, state) do
    with {:ok, range_type, state} <- infer(comprehension.iter_range, state),
         {:ok, iter_types} <- comprehension_iter_types(range_type, comprehension),
         {:ok, accu_type, state} <- infer(comprehension.accu_init, state) do
      state =
        state
        |> push_scope()
        |> put_local(comprehension.iter_var, elem(iter_types, 0))
        |> put_second_iter_var(Map.get(comprehension, :iter_var2, ""), elem(iter_types, 1))
        |> put_local(comprehension.accu_var, accu_type)

      with {:ok, condition_type, state} <- infer(comprehension.loop_condition, state),
           :ok <- expect_boolish(condition_type, expr, "comprehension loop condition"),
           {:ok, step_type, state} <- infer(comprehension.loop_step, state),
           {:ok, state} <-
             expect_assignable(accu_type, step_type, state, expr, "comprehension accumulator"),
           {:ok, result_type, state} <- infer(comprehension.result, state) do
        state = put_op(state, expr, comprehension_op(comprehension))
        ok(expr, result_type, pop_scope(state))
      end
    end
  end

  defp infer_all(exprs, state) do
    Enum.reduce_while(exprs, {:ok, [], state}, fn expr, {:ok, types, state} ->
      case infer(expr, state) do
        {:ok, type, state} -> {:cont, {:ok, [type | types], state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, types, state} -> {:ok, Enum.reverse(types), state}
      {:error, error} -> {:error, error}
    end
  end

  defp infer_entries(entries, state) do
    Enum.reduce_while(entries, {:ok, [], [], state}, fn entry,
                                                        {:ok, key_types, value_types, state} ->
      with {:ok, key_type, state} <- infer_entry_key(entry, state),
           {:ok, value_type, state} <- infer(entry.value, state) do
        value_type =
          if Map.get(entry, :optional_entry, false),
            do: CType.unwrap_optional(value_type),
            else: value_type

        {:cont, {:ok, [key_type | key_types], [value_type | value_types], state}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, key_types, value_types, state} ->
        {:ok, Enum.reverse(key_types), Enum.reverse(value_types), state}

      {:error, error} ->
        {:error, error}
    end
  end

  defp infer_entry_key(%{key_kind: {:map_key, key}}, state), do: infer(key, state)
  defp infer_entry_key(%{key_kind: {:field_key, _field}}, state), do: {:ok, CType.string(), state}

  # Dispatch for the five "specials" — call shapes that need bespoke type
  # inference (scope binding, schema-aware result types, or custom op metadata)
  # instead of going through ordinary overload resolution.
  defp try_infer_special(
         %Call{shape: :global, function: "dyn", args: [_arg]} = call,
         expr,
         state
       ) do
    with {:ok, [arg_type], state} <- infer_dyn_args(call.args, state) do
      type = state.solver |> Solver.resolve(arg_type) |> CType.dyn_erasure()

      state =
        put_op(state, expr, {
          :call,
          %{
            name: Call.reference_name(call),
            shape: call.shape,
            overload_id: "dyn",
            eval: {:mfa, {RuntimeCore, :dyn}},
            target_id: nil,
            arg_ids: expr_ids(call.args)
          }
        })

      {:ok, type, state}
    end
  end

  defp try_infer_special(
         %Call{shape: :global, function: "type", args: [_arg]} = call,
         expr,
         state
       ) do
    with {:ok, [arg_type], state} <- infer_all(call.args, state) do
      type = CType.type(Solver.resolve(state.solver, arg_type))

      state =
        put_op(state, expr, {
          :call,
          %{
            name: Call.reference_name(call),
            shape: call.shape,
            overload_id: "type",
            eval: {:mfa, {RuntimeCore, :type_of}},
            target_id: nil,
            arg_ids: expr_ids(call.args)
          }
        })

      {:ok, type, state}
    end
  end

  defp try_infer_special(
         %Call{shape: :receiver, function: "bind", target: target} = call,
         expr,
         state
       ) do
    if cel_namespace_target?(target) do
      infer_bind_call(call, expr, state)
    else
      :pass
    end
  end

  defp try_infer_special(
         %Call{shape: :receiver, function: fn_name, args: [var_expr, body]} = call,
         expr,
         state
       )
       when fn_name in ["optMap", "optFlatMap"] do
    with {:ok, target_type, state} <- infer(call.target, state),
         {:ok, value_type} <- optional_value_type(target_type, expr),
         {:ok, var_name} <- optional_map_var(var_expr, expr) do
      state =
        state
        |> push_scope()
        |> put_local(var_name, value_type)

      with {:ok, body_type, state} <- infer(body, state),
           {:ok, result_type, overload_id} <- optional_map_result(fn_name, body_type, expr) do
        state = pop_scope(state)

        state =
          put_op(state, expr, {
            :special,
            %{
              kind: optional_map_kind(fn_name),
              name: Call.reference_name(call),
              overload_id: overload_id,
              target_id: call.target.id,
              arg_ids: expr_ids(call.args),
              var: var_name
            }
          })

        {:ok, result_type, state}
      end
    end
  end

  defp try_infer_special(
         %Call{shape: :intrinsic, function: "_?._", args: [receiver, field_expr]} = call,
         expr,
         state
       ) do
    with {:ok, [receiver_type, _field_type], state} <- infer_all(call.args, state),
         {:ok, field} <- optional_select_field(field_expr, expr) do
      receiver_type = Solver.finalize_native(state.solver, checker_type(receiver_type))

      case optional_select_type(state, receiver_type, field) do
        {:ok, type, overload_id, field_ref} ->
          state =
            put_op(
              state,
              expr,
              {:select,
               optional_select_op(call, receiver, field, overload_id, receiver_type, field_ref)}
            )

          {:ok, type, state}

        {:error, reason} ->
          error(expr, reason)
      end
    end
  end

  defp try_infer_special(%Call{} = call, expr, state) do
    case NameResolution.resolve_enum_call(call, state.env, state.scopes) do
      {:ok, enum_name} ->
        with {:ok, arg_types, state} <- infer_call_args(call, state),
             :ok <- expect_enum_constructor_args(arg_types, expr) do
          state =
            put_op(state, expr, {
              :special,
              %{
                kind: :enum_constructor,
                name: Call.reference_name(call),
                enum: enum_name,
                overload_id: @enum_constructor_overload_id,
                target_id: nil,
                arg_ids: expr_ids(call.args)
              }
            })

          {:ok, CType.message(enum_name), state}
        end

      :error ->
        :pass
    end
  end

  defp infer_bind_call(%Call{args: [var_expr, init, body]} = call, expr, state) do
    with {:ok, var_name} <- bind_var(var_expr, expr),
         {:ok, init_type, state} <- infer(init, state) do
      state =
        state
        |> push_scope()
        |> put_local(var_name, init_type)

      with {:ok, body_type, state} <- infer(body, state) do
        state =
          state
          |> pop_scope()
          |> put_op(expr, {
            :special,
            %{
              kind: :bind,
              name: Call.reference_name(call),
              overload_id: "cel_bind",
              target_id: nil,
              arg_ids: [init.id, body.id],
              var: var_name,
              var_id: var_expr.id
            }
          })

        {:ok, body_type, state}
      end
    end
  end

  defp infer_bind_call(%Call{}, expr, _state) do
    error(expr, "cel.bind expects an identifier, init expression, and body expression")
  end

  defp infer_call(expr, %Call{} = call, state) do
    with {:ok, target_type, state} <- infer_call_target(call, state),
         {:ok, arg_types, state} <- infer_call_args(call, state) do
      case resolve_catalog_call(state, call, target_type, arg_types) do
        {:ok, resolved, state} ->
          state = put_call_op(state, expr, call, resolved)
          ok(expr, resolved.type, state)

        {:error, reason} ->
          error(expr, reason)
      end
    end
  end

  # Helpers used exclusively by the optMap/optFlatMap special clause.
  defp optional_value_type(type, expr) do
    cond do
      CType.dyn?(type) -> {:ok, CType.dyn()}
      CType.optional?(type) -> {:ok, non_strict_optional_value_type(CType.unwrap_optional(type))}
      true -> error(expr, "optional receiver requires optional value, got #{CType.format(type)}")
    end
  end

  defp non_strict_optional_value_type(type) do
    if CType.type_kind(type) == :null, do: CType.dyn(), else: type
  end

  defp optional_map_var(%{expr_kind: {:ident_expr, %{name: name}}}, _expr), do: {:ok, name}

  defp optional_map_var(_var_expr, expr),
    do: error(expr, "optional map variable must be an identifier")

  defp bind_var(%{expr_kind: {:ident_expr, %{name: name}}}, _expr), do: {:ok, name}

  defp bind_var(_var_expr, expr),
    do: error(expr, "cel.bind variable must be an identifier")

  defp cel_namespace_target?(%{expr_kind: {:ident_expr, %{name: "cel"}}}), do: true
  defp cel_namespace_target?(_target), do: false

  defp optional_map_result("optMap", body_type, _expr) do
    {:ok, CType.optional(body_type), "optional_opt_map"}
  end

  defp optional_map_result("optFlatMap", body_type, expr) do
    if CType.optional?(body_type) or CType.dyn?(body_type) do
      {:ok, body_type, "optional_opt_flat_map"}
    else
      error(expr, "optFlatMap body must produce an optional value")
    end
  end

  defp optional_map_kind("optMap"), do: :optional_map
  defp optional_map_kind("optFlatMap"), do: :optional_flat_map

  # Helper used exclusively by the optional select special clause.
  defp optional_select_field(
         %{expr_kind: {:const_expr, %{constant_kind: {:string_value, field}}}},
         _expr
       ) do
    {:ok, field}
  end

  defp optional_select_field(_field_expr, expr) do
    error(expr, "optional select field must be a string literal")
  end

  defp infer_call_target(%Call{shape: :receiver, target: target}, state), do: infer(target, state)
  defp infer_call_target(%Call{}, state), do: {:ok, nil, state}

  defp infer_call_args(%Call{shape: {:namespace, "math"}, function: function, args: args}, state) do
    infer_math_args(function, args, state)
  end

  defp infer_call_args(%Call{args: args}, state), do: infer_all(args, state)

  defp infer_dyn_args(args, state) do
    Enum.reduce_while(args, {:ok, [], state}, fn arg, {:ok, types, state} ->
      case infer_dyn_arg(arg, state) do
        {:ok, type, state} -> {:cont, {:ok, [type | types], state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, types, state} -> {:ok, Enum.reverse(types), state}
      {:error, error} -> {:error, error}
    end
  end

  defp infer_dyn_arg(%{expr_kind: {:list_expr, list}} = expr, state) do
    with {:ok, _elem_types, state} <- infer_all(Map.get(list, :elements, []), state) do
      state = put_list_op(state, expr, list)
      ok(expr, CType.list(CType.dyn()), state)
    end
  end

  defp infer_dyn_arg(%{expr_kind: {:struct_expr, %{message_name: ""} = struct}} = expr, state) do
    with {:ok, key_types, _value_types, state} <-
           infer_entries(Map.get(struct, :entries, []), state) do
      if key_types == [] do
        state = put_map_op(state, expr, Map.get(struct, :entries, []))
        ok(expr, CType.map(CType.dyn(), CType.dyn()), state)
      else
        {key_type, state} = common_types(key_types, state)

        if map_keys?(key_types, key_type) do
          state = put_map_op(state, expr, Map.get(struct, :entries, []))
          ok(expr, CType.map(key_type, CType.dyn()), state)
        else
          error(expr, "map keys must be int, uint, bool, or string")
        end
      end
    end
  end

  defp infer_dyn_arg(expr, state), do: infer(expr, state)

  defp infer_math_args(function, [arg], state) when function in ["greatest", "least"] do
    case arg do
      %{expr_kind: {:list_expr, list}} = expr ->
        with {:ok, elem_types, state} <- infer_all(Map.get(list, :elements, []), state),
             elem_types <- unwrap_optional_list_elements(list, elem_types),
             {:ok, elem_type} <- math_list_elem_type(elem_types) do
          state = put_list_op(state, expr, list)

          with {:ok, type, state} <- ok(expr, CType.list(elem_type), state) do
            {:ok, [type], state}
          end
        else
          :error -> error(expr, "math.#{function} list elements must be numeric")
          {:error, error} -> {:error, error}
        end

      _other ->
        infer_all([arg], state)
    end
  end

  defp infer_math_args(_function, args, state), do: infer_all(args, state)

  defp unwrap_optional_list_elements(list, elem_types) do
    optional_indices = MapSet.new(Map.get(list, :optional_indices, []))

    elem_types
    |> Enum.with_index()
    |> Enum.map(fn {type, index} ->
      if MapSet.member?(optional_indices, index), do: CType.unwrap_optional(type), else: type
    end)
  end

  defp math_list_elem_type([]), do: :error

  defp math_list_elem_type(types) do
    if Enum.all?(types, &(CType.numeric?(&1) or CType.dyn?(&1))) do
      cond do
        Enum.any?(types, &CType.dyn?/1) -> {:ok, CType.dyn()}
        Enum.uniq(types) |> length() == 1 -> {:ok, hd(types)}
        true -> {:ok, CType.dyn()}
      end
    else
      :error
    end
  end

  defp infer_select_type(expr, operand_type, field, state) do
    receiver_type = Solver.finalize_native(state.solver, checker_type(operand_type))

    case select_type(state, receiver_type, field) do
      {:ok, type, overload_id, field_ref} ->
        state =
          state
          |> put_select_op(expr, field, overload_id, operand_type, field_ref)

        ok(expr, type, state)

      {:error, reason} ->
        error(expr, reason)
    end
  end

  defp infer_presence_test_type(expr, operand_type, field, state) do
    receiver_type = Solver.finalize_native(state.solver, checker_type(operand_type))

    case select_type(state, receiver_type, field) do
      {:ok, _type, overload_id, field_ref} ->
        state =
          state
          |> put_presence_test_op(expr, field, overload_id, field_ref)

        ok(expr, CType.bool(), state)

      {:error, reason} ->
        error(expr, reason)
    end
  end

  defp select_type(_state, :dyn, _field), do: {:ok, CType.dyn(), "select_dyn", nil}

  defp select_type(state, {:message, message}, field) do
    case message_field(state, message, field) do
      {:ok, cel_field} ->
        {:ok, CType.from_input(cel_field.type), "select_message", {message, cel_field}}

      :unknown_message ->
        {:ok, CType.dyn(), "select_dyn", nil}

      :error ->
        {:error, "no such field #{inspect(field)}"}
    end
  end

  defp select_type(state, {:optional, type}, field) do
    optional_select_type(state, type, field)
  end

  defp select_type(_state, {:map, key_type, value_type}, _field)
       when key_type in [:string, :dyn] do
    {:ok, value_type, "select_map", nil}
  end

  defp select_type(_state, {:map, _key_type, _value_type}, _field) do
    {:error, "field selection on a map requires string keys"}
  end

  defp select_type(_state, type, _field) do
    {:error, "field selection is not defined for #{CType.format(type)}"}
  end

  # A message type the provider does not know, such as one declared without a
  # provider, or a well-known type, is selected from as `dyn`. A
  # backtick-quoted, fully-qualified selector (`msg.`pkg.ext_name``) names a
  # proto2 extension, which the provider finds by that name.
  defp message_field(state, message, field) do
    with false <- WellKnownTypes.literal_message?(message),
         :error <- Env.find_field(state.env, message, field),
         {:ok, :message, ^message} <- Env.find_type(state.env, to_string(message)) do
      :error
    else
      {:ok, %CEL.Field{}} = found -> found
      _unknown -> :unknown_message
    end
  end

  defp optional_select_type(_state, type, _field) when type in [:dyn, :null] do
    {:ok, CType.optional(CType.dyn()), "optional_select", nil}
  end

  defp optional_select_type(state, {:optional, type}, field) do
    optional_select_type(state, non_strict_optional_value_type(type), field)
  end

  defp optional_select_type(state, {:message, message}, field) do
    case message_field(state, message, field) do
      {:ok, cel_field} ->
        type = CType.optional(CType.from_input(cel_field.type))
        {:ok, type, "optional_select", {message, cel_field}}

      :unknown_message ->
        {:ok, CType.optional(CType.dyn()), "optional_select", nil}

      :error ->
        {:error, "no such field #{inspect(field)}"}
    end
  end

  defp optional_select_type(_state, {:map, key_type, value_type}, _field)
       when key_type in [:string, :dyn] do
    {:ok, CType.optional(value_type), "optional_select", nil}
  end

  defp optional_select_type(_state, {:map, _key_type, _value_type}, _field) do
    {:error, "field selection on a map requires string keys"}
  end

  defp optional_select_type(_state, type, _field) do
    {:error, "field selection is not defined for #{CType.format(type)}"}
  end

  defp message_field_types(entries, value_types) do
    entries
    |> Enum.zip(value_types)
    |> Enum.flat_map(fn
      {%{key_kind: {:field_key, field}}, type} -> [{field, type}]
      {_entry, _type} -> []
    end)
    |> Map.new()
  end

  defp message_literal_name(expr, name, state) do
    case NameResolution.resolve_message_name(name, state.env) do
      {:ok, message_name} -> {:ok, message_name}
      {:error, name} -> error(expr, "unknown message type #{name}")
    end
  end

  # Literals of the well-known types are CEL's own, whatever the provider says.
  defp message_literal_op(expr, message_name, entries, value_types, state) do
    if WellKnownTypes.literal_message?(message_name) do
      with {:ok, fields, state} <-
             well_known_literal_fields(message_name, entries, value_types, state) do
        {:ok, {:message_literal, %{message: message_name, fields: fields}}, state}
      end
    else
      with {:ok, fields, state} <-
             message_literal_fields(message_name, entries, value_types, state),
           :ok <-
             validate_required_literal_fields(
               expr,
               Env.required_fields(state.env, message_name),
               fields
             ) do
        {:ok, {:message_literal, %{message: message_name, fields: fields}}, state}
      end
    end
  end

  defp well_known_literal_fields(message_name, entries, value_types, state) do
    entries
    |> Enum.zip(value_types)
    |> Enum.reduce_while({:ok, [], state}, fn
      {%{key_kind: {:field_key, field}, value: %{id: value_id} = value} = entry, type},
      {:ok, fields, state} ->
        with {:ok, field_type} <- well_known_literal_field_type(message_name, field, value),
             {:ok, state} <-
               expect_assignable(
                 CType.from_input(field_type),
                 type,
                 state,
                 value,
                 "message field #{inspect(field)}"
               ) do
          optional? = Map.get(entry, :optional_entry, false)
          field = %{field: field, value_id: value_id, optional?: optional?}
          {:cont, {:ok, [field | fields], state}}
        else
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {_entry, _type}, {:ok, fields, state} ->
        {:cont, {:ok, fields, state}}
    end)
    |> case do
      {:ok, fields, state} -> {:ok, Enum.reverse(fields), state}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp well_known_literal_field_type(message_name, field, value) do
    case WellKnownTypes.literal_field_type(message_name, field) do
      {:ok, type} -> {:ok, type}
      :error -> error(value, "no such field #{inspect(field)}")
    end
  end

  defp message_literal_fields(message, entries, value_types, state) do
    entries
    |> Enum.zip(value_types)
    |> Enum.reduce_while({:ok, [], state}, fn
      {%{key_kind: {:field_key, field}, value: %{id: value_id} = value} = entry, type},
      {:ok, fields, state} ->
        with {:ok, cel_field} <- literal_field(state, message, field, value),
             {:ok, state} <-
               expect_literal_field_assignable(cel_field.type, type, state, value, field) do
          field = %{
            field: field,
            cel_field: cel_field,
            value_id: value_id,
            optional?: Map.get(entry, :optional_entry, false)
          }

          {:cont, {:ok, [field | fields], state}}
        else
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {_entry, _type}, {:ok, fields, state} ->
        {:cont, {:ok, fields, state}}
    end)
    |> case do
      {:ok, fields, state} -> {:ok, Enum.reverse(fields), state}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp literal_field(state, message, field, value) do
    case Env.find_field(state.env, message, field) do
      {:ok, cel_field} -> {:ok, cel_field}
      :error -> error(value, "no such field #{inspect(field)}")
    end
  end

  # An int may be assigned to an enum field.
  defp expect_literal_field_assignable({:enum, _name}, :int, state, _expr, _field),
    do: {:ok, state}

  defp expect_literal_field_assignable(expected, actual, state, expr, field) do
    expect_assignable(
      CType.from_input(expected),
      actual,
      state,
      expr,
      "message field #{inspect(field)}"
    )
  end

  defp validate_required_literal_fields(expr, required, fields) do
    present = MapSet.new(fields, & &1.field)

    case Enum.find(required, &(not MapSet.member?(present, &1))) do
      nil -> :ok
      field -> error(expr, "missing required field #{inspect(field)}")
    end
  end

  defp message_literal_type(message_name, fields, state) do
    fields = Map.new(fields, fn {field, type} -> {field, cel_type(state, type)} end)

    case WellKnownTypes.literal_type(message_name, fields) do
      {:ok, type} -> CType.from_cel(type)
      :error -> CType.message(message_name)
    end
  end

  defp comprehension_iter_types(range_type, comprehension) do
    iter_var2 = Map.get(comprehension, :iter_var2, "")

    cond do
      CType.dyn?(range_type) ->
        {:ok, {CType.dyn(), CType.dyn()}}

      true ->
        case CType.list_elem(range_type) do
          {:ok, elem_type} ->
            second = if iter_var2 == "", do: CType.dyn(), else: elem_type
            first = if iter_var2 == "", do: elem_type, else: CType.int()
            {:ok, {first, second}}

          :error ->
            case CType.map_types(range_type) do
              {:ok, key_type, value_type} ->
                second = if iter_var2 == "", do: CType.dyn(), else: value_type
                {:ok, {key_type, second}}

              :error ->
                error(
                  comprehension.iter_range,
                  "comprehension range must be list, map, or dyn; got #{CType.format(range_type)}"
                )
            end
        end
    end
  end

  defp expect_boolish(type, expr, context) do
    if CType.primitive?(type, :BOOL) or CType.dyn?(type) do
      :ok
    else
      error(expr, "#{context} requires bool, got #{CType.format(type)}")
    end
  end

  defp expect_assignable(expected, actual, state, expr, context) do
    case Solver.assignable(state.solver, expected, actual) do
      {:ok, solver} ->
        {:ok, %{state | solver: solver}}

      :error ->
        error(expr, "#{context} expects #{CType.format(expected)}, got #{CType.format(actual)}")
    end
  end

  defp push_scope(%State{} = state), do: %{state | scopes: [%{} | state.scopes]}

  defp pop_scope(%State{scopes: [_scope | scopes]} = state), do: %{state | scopes: scopes}

  defp put_local(%State{} = state, "", _type), do: state

  defp put_local(%State{scopes: [scope | scopes]} = state, name, type) do
    %{state | scopes: [Map.put(scope, name, checker_type(type)) | scopes]}
  end

  defp put_second_iter_var(state, "", _type), do: state
  defp put_second_iter_var(state, name, type), do: put_local(state, name, type)

  defp common_or_fresh([], state), do: fresh_type(state)
  defp common_or_fresh(types, state), do: common_types(types, state)

  defp common_types(types, state) do
    {type, solver} = Solver.common(state.solver, types)
    {type, %{state | solver: solver}}
  end

  defp map_keys?(key_types, key_type),
    do: Enum.all?(key_types, &CType.map_key?/1) and CType.map_key?(key_type)

  defp fresh_type(state) do
    {type, solver} = Solver.fresh(state.solver)
    {type, %{state | solver: solver}}
  end

  defp checker_type(%{type_kind: {_kind, _value}} = type), do: CType.from_cel(type)
  defp checker_type(type), do: CType.from_input(type)

  defp cel_type(%State{} = state, type), do: Solver.finalize(state.solver, checker_type(type))

  defp resolve_catalog_call(state, call, target_type, arg_types) do
    with :unknown <- resolve_enum_to_int_call(state, call, arg_types),
         :unknown <-
           resolve_enum_int_equality_call(state, call, checker_call_types(target_type, arg_types)),
         :unknown <-
           resolve_enum_int_membership_call(
             state,
             call,
             checker_call_types(target_type, arg_types)
           ),
         :unknown <- Signatures.resolve(call, target_type, arg_types, state.solver, state.env) do
      {:error, no_matching_overload(state, call, target_type, arg_types)}
    else
      {:ok, resolved, solver} -> {:ok, resolved, %{state | solver: solver}}
    end
  end

  # `int(enum)` emits a plain `:call` op dispatched through the standard MFA
  # path like any other conversion overload, not a special op kind. The
  # overload id is still tagged with `@enum_to_int_overload_id`; this helper
  # exists because enum-to-int needs schema-aware resolution at catalog time.
  defp resolve_enum_to_int_call(%State{} = state, %Call{shape: :global, function: "int"}, [type]) do
    resolved_type = Solver.resolve(state.solver, type)

    if schema_enum_type?(state.env, resolved_type) do
      {:ok,
       %{
         type: CType.int(),
         overload_id: @enum_to_int_overload_id,
         eval: {:mfa, {RuntimeConvert, :to_int}}
       }, state.solver}
    else
      :unknown
    end
  end

  defp resolve_enum_to_int_call(%State{}, %Call{}, _arg_types), do: :unknown

  defp resolve_enum_int_equality_call(
         %State{} = state,
         %Call{shape: :intrinsic, function: function},
         [left, right]
       )
       when function in ["_==_", "_!=_"] do
    left = Solver.resolve(state.solver, left)
    right = Solver.resolve(state.solver, right)

    if enum_int_pair?(state.env, left, right) do
      runtime = if function == "_==_", do: :equals, else: :not_equals
      overload_id = if function == "_==_", do: "_equals_enum_int", else: "_not_equals_enum_int"

      {:ok,
       %{
         type: CType.bool(),
         overload_id: overload_id,
         eval: {:mfa, {RuntimeCore, runtime}},
         eval_context: [:types]
       }, state.solver}
    else
      :unknown
    end
  end

  defp resolve_enum_int_equality_call(%State{}, %Call{}, _arg_types), do: :unknown

  defp resolve_enum_int_membership_call(
         %State{} = state,
         %Call{shape: :intrinsic, function: "@in"},
         [left, right]
       ) do
    left = Solver.resolve(state.solver, left)
    right = Solver.resolve(state.solver, right)

    if enum_int_membership_pair?(state.env, left, right) do
      {:ok,
       %{
         type: CType.bool(),
         overload_id: "in_list",
         eval: {:mfa, {RuntimeCore, :contains}}
       }, state.solver}
    else
      :unknown
    end
  end

  defp resolve_enum_int_membership_call(%State{}, %Call{}, _arg_types), do: :unknown

  defp enum_int_pair?(env, left, right) do
    (schema_enum_type?(env, left) and right == CType.int()) or
      (left == CType.int() and schema_enum_type?(env, right))
  end

  defp enum_int_membership_pair?(env, enum_type, {:list, elem_type}) do
    schema_enum_type?(env, enum_type) and elem_type == CType.int()
  end

  defp enum_int_membership_pair?(_env, _enum_type, _list_type), do: false

  defp expect_enum_constructor_args([type], expr) do
    if enum_constructor_arg_type?(type) do
      :ok
    else
      error(expr, "enum constructor requires int, string, or dyn")
    end
  end

  defp expect_enum_constructor_args(_arg_types, expr) do
    error(expr, "enum constructor requires exactly one argument")
  end

  defp enum_constructor_arg_type?(type) do
    type in [CType.int(), CType.string(), CType.dyn()]
  end

  defp schema_enum_type?(%Env{} = env, {:message, name}), do: Env.enum?(env, name)

  defp schema_enum_type?(_env, _type), do: false

  defp no_matching_overload(%State{} = state, %Call{} = call, target_type, arg_types) do
    types =
      target_type
      |> checker_call_types(arg_types)
      |> Enum.map(fn type ->
        type = Solver.resolve(state.solver, type)
        CType.format(type)
      end)
      |> Enum.join(", ")

    "no matching overload for #{Call.reference_name(call)}(#{types})"
  end

  defp checker_call_types(nil, args), do: args
  defp checker_call_types(target, args), do: [target | args]

  # The checker types enums as messages of the enum's name; record which
  # names are enums so the public view can tell them apart.
  defp enum_names(types, env) do
    for {_id, type} <- types,
        name <- CType.message_names(type),
        Env.enum?(env, name),
        into: MapSet.new(),
        do: name
  end

  defp finalize_types(%State{} = state) do
    Map.new(state.types, fn {id, type} -> {id, Solver.finalize_native(state.solver, type)} end)
  end

  defp ok(expr, type, state), do: {:ok, type, put_type(state, expr, type)}

  defp put_type(%State{} = state, %{id: id}, type) do
    %{state | types: Map.put(state.types, id, checker_type(type))}
  end

  defp put_op(%State{} = state, %{id: id}, op) do
    %{state | ops: Map.put(state.ops, id, op)}
  end

  defp put_call_op(%State{} = state, expr, %Call{} = call, resolved) do
    put_op(state, expr, call_op(call, resolved))
  end

  defp put_list_op(%State{} = state, expr, list) do
    put_op(state, expr, {
      :list,
      %{
        elem_ids: expr_ids(Map.get(list, :elements, [])),
        optional_indices: MapSet.new(Map.get(list, :optional_indices, []))
      }
    })
  end

  defp put_map_op(%State{} = state, expr, entries) do
    put_op(state, expr, {
      :map,
      %{
        entries: Enum.map(entries, &map_entry_op/1)
      }
    })
  end

  defp map_entry_op(%{key_kind: {:map_key, %{id: key_id}}, value: %{id: value_id}} = entry) do
    %{
      key_id: key_id,
      value_id: value_id,
      optional?: Map.get(entry, :optional_entry, false)
    }
  end

  defp call_op(%Call{} = call, resolved) do
    base =
      %{
        name: Call.reference_name(call),
        shape: call.shape,
        overload_id: resolved.overload_id,
        eval: Map.get(resolved, :eval),
        target_id: expr_id(call.target),
        arg_ids: expr_ids(call.args)
      }
      |> maybe_put_eval_context(Map.get(resolved, :eval_context, []))
      |> maybe_put_non_strict(Map.get(resolved, :strict, true))

    case call_special_kind(call, resolved.overload_id) do
      nil ->
        {:call, base}

      kind ->
        {:special,
         base
         |> Map.take([:name, :overload_id, :eval, :eval_context, :target_id, :arg_ids])
         |> Map.put(:kind, kind)}
    end
  end

  defp call_special_kind(%Call{function: "_&&_"}, _overload_id), do: :and
  defp call_special_kind(%Call{function: "_||_"}, _overload_id), do: :or
  defp call_special_kind(%Call{function: "_?_:_"}, _overload_id), do: :conditional

  defp call_special_kind(%Call{}, _overload_id), do: nil

  defp maybe_put_eval_context(map, []), do: map
  defp maybe_put_eval_context(map, eval_context), do: Map.put(map, :eval_context, eval_context)

  defp maybe_put_non_strict(map, true), do: map
  defp maybe_put_non_strict(map, false), do: Map.put(map, :strict, false)

  defp put_select_op(%State{} = state, expr, field, overload_id, operand_type, field_ref) do
    op =
      %{
        kind: select_kind(state, overload_id, operand_type, field_ref),
        field: field,
        receiver_id: select_receiver_id(expr),
        test_only: false,
        overload_id: overload_id
      }
      |> maybe_put_field_ref(field_ref)

    put_op(state, expr, {:select, op})
  end

  defp put_presence_test_op(%State{} = state, expr, field, overload_id, field_ref) do
    op =
      %{
        kind: :presence_test,
        field: field,
        receiver_id: select_receiver_id(expr),
        test_only: true,
        overload_id: overload_id
      }
      |> maybe_put_field_ref(field_ref)

    put_op(state, expr, {:select, op})
  end

  defp select_kind(_state, "select_message", _operand_type, {_message, _field}),
    do: :message_field

  defp select_kind(_state, "select_message", _operand_type, nil), do: :dyn_field
  defp select_kind(_state, "select_map", _operand_type, _field_ref), do: :map_field
  defp select_kind(_state, "select_dyn", _operand_type, _field_ref), do: :dyn_field

  defp select_kind(_state, "optional_select", _operand_type, {_message, _field}),
    do: :optional_field

  defp select_kind(%State{} = state, "optional_select", operand_type, nil) do
    operand_type = Solver.finalize_native(state.solver, checker_type(operand_type))

    if optional_map_type?(operand_type) do
      :optional_map_field
    else
      :optional_dyn_field
    end
  end

  defp optional_map_type?({:map, _key_type, _value_type}), do: true
  defp optional_map_type?({:optional, type}), do: optional_map_type?(type)
  defp optional_map_type?(_type), do: false

  defp select_receiver_id(%{expr_kind: {:select_expr, %{operand: %{id: id}}}}), do: id

  # A field the checker found carries the message type it was found on, which
  # evaluation expects the operand to be.
  defp maybe_put_field_ref(op, nil), do: op

  defp maybe_put_field_ref(op, {message, cel_field}),
    do: Map.merge(op, %{message: message, cel_field: cel_field})

  defp optional_select_op(call, receiver, field, overload_id, receiver_type, field_ref) do
    %{
      kind: optional_select_kind(receiver_type, field_ref),
      name: Call.reference_name(call),
      field: field,
      receiver_id: receiver.id,
      test_only: false,
      overload_id: overload_id
    }
    |> maybe_put_field_ref(field_ref)
  end

  defp optional_select_kind(_receiver_type, {_message, _field}), do: :optional_field

  defp optional_select_kind(receiver_type, nil) do
    if optional_map_type?(receiver_type) do
      :optional_map_field
    else
      :optional_dyn_field
    end
  end

  defp expr_ids(exprs), do: Enum.map(exprs, & &1.id)
  defp expr_id(nil), do: nil
  defp expr_id(%{id: id}), do: id

  defp comprehension_op(comprehension) do
    op = %{
      iter_var: comprehension.iter_var,
      accu_var: comprehension.accu_var,
      iter_range_id: comprehension.iter_range.id,
      accu_init_id: comprehension.accu_init.id,
      loop_condition_id: comprehension.loop_condition.id,
      loop_step_id: comprehension.loop_step.id,
      result_id: comprehension.result.id,
      iter_var2: Map.get(comprehension, :iter_var2, "")
    }

    {:comprehension, op}
  end

  defp put_resolved_ident_op(%State{} = state, expr, resolved) do
    put_op(state, expr, {:ident, resolved_ident_op(state, resolved)})
  end

  defp resolved_ident_op(_state, %{kind: :type, denotation: denotation} = resolved) do
    %{kind: :type, name: resolved.name, denotation: denotation}
  end

  defp resolved_ident_op(_state, %{kind: :enum_value, value: value} = resolved) do
    %{kind: :enum_value, name: resolved.name, value: value}
  end

  defp resolved_ident_op(%State{} = state, %{kind: :var} = resolved) do
    %{
      kind: :var,
      name: resolved.name,
      type: Solver.finalize_native(state.solver, checker_type(resolved.type))
    }
  end

  defp resolved_ident_op(_state, %{kind: kind} = resolved) when kind in [:local] do
    %{kind: kind, name: resolved.name}
  end

  defp error(%{id: id}, message),
    do: {:error, Error.exception(phase: :check, message: message, expr_id: id)}
end
