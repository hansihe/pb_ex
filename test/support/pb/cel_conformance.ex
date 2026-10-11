defmodule PB.TestSupport.CELConformance do
  @moduledoc false

  alias PB.CEL.Call
  alias PB.CEL.Checker.NameResolution
  alias PB.CEL.Checker.TypePattern
  alias PB.CEL.Env
  alias PB.CEL.Library
  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Error
  alias PB.CEL.Value
  alias PB.Validate.CEL.MessageRuntime
  alias PB.Validate.CEL.MessageSchema, as: CELSchema

  @fixture_root Path.expand("../../fixtures/cel_conformance", __DIR__)
  @schema PB.TestSupport.TestSchema
  @cache_miss {__MODULE__, :cache_miss}

  def fixture_root, do: @fixture_root

  def manifest do
    cached(:manifest, fn ->
      @fixture_root
      |> Path.join("manifest.term")
      |> Code.eval_file()
      |> elem(0)
    end)
  end

  def fixtures do
    cached(:fixtures, fn -> manifest().fixtures end)
  end

  def simple_cases do
    cached(:simple_cases, fn ->
      for fixture <- fixtures(),
          case <- simple_cases(fixture.output) do
        case
      end
    end)
  end

  def in_scope_cases do
    cached(:in_scope_cases, fn ->
      Enum.reject(simple_cases(), &out_of_scope_case?/1)
    end)
  end

  def in_scope_cases(output) when is_binary(output) do
    cached({:in_scope_cases, output}, fn ->
      Enum.reject(simple_cases(output), &out_of_scope_case?/1)
    end)
  end

  def out_of_scope_cases do
    cached(:out_of_scope_cases, fn ->
      simple_cases()
      |> Enum.map(&put_out_of_scope_reason/1)
      |> Enum.reject(&is_nil(&1.out_of_scope_reason))
    end)
  end

  def out_of_scope_cases(output) when is_binary(output) do
    cached({:out_of_scope_cases, output}, fn ->
      simple_cases(output)
      |> Enum.map(&put_out_of_scope_reason/1)
      |> Enum.reject(&is_nil(&1.out_of_scope_reason))
    end)
  end

  def supported_parser_cases do
    cached(:supported_parser_cases, fn ->
      Enum.reject(in_scope_cases(), &unsupported_parser_case?/1)
    end)
  end

  def supported_parser_cases(output) when is_binary(output) do
    cached({:supported_parser_cases, output}, fn ->
      Enum.reject(in_scope_cases(output), &unsupported_parser_case?/1)
    end)
  end

  def supported_check_cases do
    cached(:supported_check_cases, fn ->
      check_cases_with_reasons()
      |> Enum.filter(&is_nil(&1.unsupported_reason))
      |> Enum.map(&Map.delete(&1, :unsupported_reason))
    end)
  end

  def supported_check_cases(output) when is_binary(output) do
    cached({:supported_check_cases, output}, fn ->
      output
      |> check_cases_with_reasons()
      |> Enum.filter(&is_nil(&1.unsupported_reason))
      |> Enum.map(&Map.delete(&1, :unsupported_reason))
    end)
  end

  def unsupported_check_cases do
    cached(:unsupported_check_cases, fn ->
      check_cases_with_reasons()
      |> Enum.reject(&is_nil(&1.unsupported_reason))
    end)
  end

  def unsupported_check_cases(output) when is_binary(output) do
    cached({:unsupported_check_cases, output}, fn ->
      output
      |> check_cases_with_reasons()
      |> Enum.reject(&is_nil(&1.unsupported_reason))
    end)
  end

  def supported_eval_cases do
    cached(:supported_eval_cases, fn ->
      eval_cases_with_reasons()
      |> Enum.filter(&is_nil(&1.unsupported_reason))
      |> Enum.map(&Map.delete(&1, :unsupported_reason))
    end)
  end

  def supported_eval_cases(output) when is_binary(output) do
    cached({:supported_eval_cases, output}, fn ->
      output
      |> eval_cases_with_reasons()
      |> Enum.filter(&is_nil(&1.unsupported_reason))
      |> Enum.map(&Map.delete(&1, :unsupported_reason))
    end)
  end

  def unsupported_eval_cases do
    cached(:unsupported_eval_cases, fn ->
      eval_cases_with_reasons()
      |> Enum.reject(&is_nil(&1.unsupported_reason))
    end)
  end

  def unsupported_eval_cases(output) when is_binary(output) do
    cached({:unsupported_eval_cases, output}, fn ->
      output
      |> eval_cases_with_reasons()
      |> Enum.reject(&is_nil(&1.unsupported_reason))
    end)
  end

  def unsupported_parser_cases do
    cached(:unsupported_parser_cases, fn ->
      Enum.filter(in_scope_cases(), &unsupported_parser_case?/1)
    end)
  end

  def unsupported_parser_cases(output) when is_binary(output) do
    cached({:unsupported_parser_cases, output}, fn ->
      Enum.filter(in_scope_cases(output), &unsupported_parser_case?/1)
    end)
  end

  def decode_fixture(fixture) when is_map(fixture) do
    cached({:fixture, fixture.output}, fn ->
      path = Path.join(@fixture_root, fixture.output)
      bin = File.read!(path)
      verify_sha256!(bin, fixture)

      PB.decode!(bin, @schema, String.to_atom(fixture.type))
    end)
  end

  @doc """
  The upstream text format source of a fixture, which decodes to the same
  value as its `.binpb` output.
  """
  def fixture_text(fixture) when is_map(fixture) do
    text = File.read!(Path.join(@fixture_root, fixture.text))
    verify_sha256!(text, fixture.text, fixture.text_sha256)
    text
  end

  def simple_cases(output) when is_binary(output) do
    cached({:simple_cases, output}, fn ->
      fixture = Enum.find(fixtures(), &(&1.output == output))

      unless fixture do
        raise ArgumentError, "unknown CEL conformance fixture #{inspect(output)}"
      end

      file = decode_fixture(fixture)

      for section <- Map.get(file, :section, []),
          test <- Map.get(section, :test, []) do
        %{
          fixture: fixture.output,
          file: file.name,
          section: section.name,
          name: test.name,
          expr: test.expr,
          description: Map.get(test, :description, ""),
          disable_macros: Map.get(test, :disable_macros, false),
          disable_check: Map.get(test, :disable_check, false),
          check_only: Map.get(test, :check_only, false),
          result_matcher: Map.get(test, :result_matcher),
          bindings: Map.get(test, :bindings, %{}),
          type_env: Map.get(test, :type_env, []),
          container: Map.get(test, :container, "")
        }
      end
    end)
  end

  def parse_opts(case), do: [disable_macros: case.disable_macros]

  def check_env(case) do
    with {:ok, binding_vars} <- binding_vars(case.bindings),
         {:ok, env_vars, functions} <- type_env_decls(case.type_env) do
      {:ok,
       PB.CEL.Env.build(
         vars: Map.merge(binding_vars, env_vars),
         functions: functions,
         container: case.container,
         schema: @schema,
         message_schema: CELSchema,
         message_runtime: MessageRuntime
       )}
    end
  end

  def eval_bindings(case) do
    case.bindings
    |> Enum.reduce_while({:ok, %{}}, fn {name, expr_value}, {:ok, acc} ->
      case expr_value_to_value(expr_value) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def expected_eval_result(%{result_matcher: {:value, value}}) do
    with {:ok, value} <- expr_value_to_value(value) do
      {:ok, {:value, value}}
    end
  end

  def expected_eval_result(%{result_matcher: {:typed_result, %{result: value}}}) do
    with {:ok, value} <- expr_value_to_value(value) do
      {:ok, {:value, value}}
    end
  end

  def expected_eval_result(%{result_matcher: {:eval_error, error}}),
    do: {:ok, {:eval_error, error}}

  def expected_eval_result(%{result_matcher: nil}), do: {:ok, {:value, Value.bool(true)}}

  def expected_eval_result(_case), do: {:error, :missing_result_matcher}

  def match_eval_result({:value, expected}, {:ok, actual}) do
    if actual == expected do
      :ok
    else
      {:error, {:value_mismatch, actual, expected}}
    end
  end

  def match_eval_result({:value, _expected}, {:error, %Error{phase: :eval} = error}) do
    {:error, {:unexpected_eval_error, error}}
  end

  def match_eval_result({:eval_error, _matcher}, {:error, %Error{phase: :eval}}), do: :ok

  def match_eval_result({:eval_error, _matcher}, {:ok, actual}) do
    {:error, {:expected_eval_error, actual}}
  end

  def match_eval_result(_expected, {:error, error}), do: {:error, {:unexpected_error, error}}

  def expected_check_type(%{result_matcher: {:typed_result, %{deduced_type: type}}}),
    do: {:ok, type}

  def expected_check_type(_case), do: :ignore

  def unsupported_reason_summary(cases) do
    cases
    |> Enum.map(& &1.unsupported_reason)
    |> Enum.frequencies()
  end

  def out_of_scope_reason_summary(cases) do
    cases
    |> Enum.map(& &1.out_of_scope_reason)
    |> Enum.frequencies()
  end

  def unsupported_call_summary(cases) do
    cases
    |> Enum.flat_map(&unsupported_calls/1)
    |> Enum.frequencies()
  end

  defp unsupported_parser_case?(_case), do: false

  defp out_of_scope_case?(case), do: out_of_scope_reason(case) != nil

  defp check_cases_with_reasons do
    cached(:check_cases_with_reasons, fn ->
      Enum.map(in_scope_cases(), &put_unsupported_check_reason/1)
    end)
  end

  defp check_cases_with_reasons(output) do
    cached({:check_cases_with_reasons, output}, fn ->
      Enum.map(in_scope_cases(output), &put_unsupported_check_reason/1)
    end)
  end

  defp eval_cases_with_reasons do
    cached(:eval_cases_with_reasons, fn ->
      Enum.map(in_scope_cases(), &put_unsupported_eval_reason/1)
    end)
  end

  defp eval_cases_with_reasons(output) do
    cached({:eval_cases_with_reasons, output}, fn ->
      Enum.map(in_scope_cases(output), &put_unsupported_eval_reason/1)
    end)
  end

  # The `proto.getExt`/`proto.hasExt` macro form (proto2_ext.binpb) is still out
  # of scope. The select form (`msg.`pkg.ext`` and `has(...)`, in proto2.binpb's
  # extensions_get/extensions_has sections) is supported.
  defp proto2_extension_case?(%{fixture: "simple/proto2_ext.binpb"}), do: true

  defp proto2_extension_case?(_case), do: false

  defp optimizer_block_case?(%{fixture: "simple/block_ext.binpb"}), do: true
  defp optimizer_block_case?(_case), do: false

  defp legacy_enum_semantics_case?(%{fixture: "simple/enums.binpb", section: section})
       when section in ["legacy_proto2", "legacy_proto3"],
       do: true

  defp legacy_enum_semantics_case?(_case), do: false

  defp strong_enum_type_case?(%{
         fixture: "simple/type_deduction.binpb",
         section: "field_access",
         name: name
       })
       when name in ["enum_field", "repeated_enum_field", "enum_map_field"],
       do: true

  defp strong_enum_type_case?(_case), do: false

  defp any_unpack_equality_case?(%{
         fixture: "simple/comparisons.binpb",
         section: section,
         name: name
       })
       when {section, name} in [
              {"eq_wrapper", "eq_proto2_any_unpack_equal"},
              {"eq_wrapper", "eq_proto3_any_unpack_equal"},
              {"ne_literal", "ne_proto2_any_unpack"},
              {"ne_literal", "ne_proto3_any_unpack"}
            ],
       do: true

  defp any_unpack_equality_case?(_case), do: false

  defp put_unsupported_check_reason(case),
    do: Map.put(case, :unsupported_reason, check_unsupported_reason(case))

  defp put_unsupported_eval_reason(case),
    do: Map.put(case, :unsupported_reason, eval_unsupported_reason(case))

  defp put_out_of_scope_reason(case),
    do: Map.put(case, :out_of_scope_reason, out_of_scope_reason(case))

  defp out_of_scope_reason(case) do
    cond do
      proto2_extension_case?(case) -> :proto2_extensions
      optimizer_block_case?(case) -> :optimizer_block
      true -> nil
    end
  end

  # TODO(CEL): Keep conformance exclusions policy-shaped. Deliberate choices
  # like upstream `disable_check`, legacy enum semantics, and optional extension
  # libraries should remain named buckets rather than being folded into generic
  # checker/evaluator unsupported failures. Product boundaries like proto2
  # extensions and optimizer-shaped test-only helpers should be modeled as
  # out-of-scope before layer support is counted.
  defp check_unsupported_reason(case) do
    cond do
      case.disable_check ->
        :disable_check

      unsupported_type_env?(case.type_env) ->
        :type_env

      legacy_enum_semantics_case?(case) and current_check_unsupported_reason(case) ->
        :legacy_enum_semantics

      strong_enum_type_case?(case) and current_check_unsupported_reason(case) ->
        :strong_enum_field_types

      unsupported_expected_check_type?(case) ->
        :expected_type

      case.container not in ["", nil] ->
        if current_check_unsupported_reason(case), do: :container, else: nil

      true ->
        nil
    end
  end

  defp eval_unsupported_reason(case) do
    cond do
      case.check_only ->
        :check_only

      case.disable_check ->
        :disable_check

      unsupported_type_env?(case.type_env) ->
        :type_env

      any_unpack_equality_case?(case) and current_eval_unsupported_reason(case) ->
        :any_unpack_equality

      legacy_enum_semantics_case?(case) and current_eval_unsupported_reason(case) ->
        :legacy_enum_semantics

      strong_enum_type_case?(case) and current_eval_unsupported_reason(case) ->
        :strong_enum_field_types

      not match?({:ok, _vars}, vars(case)) ->
        :bindings

      unsupported_expected_eval_result?(case) ->
        :expected_value

      case.container not in ["", nil] ->
        if current_eval_unsupported_reason(case), do: :container, else: nil

      true ->
        nil
    end
  end

  defp current_check_unsupported_reason(case) do
    with {:ok, parsed} <- PB.CEL.parse(case.expr, parse_opts(case)),
         {:ok, env} <- check_env(case),
         {:ok, checked} <- PB.CEL.check(parsed, env) do
      case expected_check_type(case) do
        {:ok, type} ->
          actual = PB.CEL.Checked.proto_type(checked, checked.expr.id)
          if actual == type, do: nil, else: :checker_type

        :ignore ->
          nil
      end
    else
      {:error, _error} -> :checker
    end
  end

  defp current_eval_unsupported_reason(case) do
    with {:ok, parsed} <- PB.CEL.parse(case.expr, parse_opts(case)),
         {:ok, env} <- check_env(case),
         {:ok, checked} <- PB.CEL.check(parsed, env),
         {:ok, bindings} <- eval_bindings(case),
         {:ok, expected} <- expected_eval_result(case) do
      case match_eval_result(expected, safe_eval(checked, bindings, env)) do
        :ok -> nil
        {:error, {:value_mismatch, _actual, _expected}} -> :evaluator_value
        {:error, {:expected_eval_error, _actual}} -> :evaluator_value
        {:error, _reason} -> :evaluator
      end
    else
      {:error, _error} -> :evaluator
    end
  end

  defp safe_eval(checked, bindings, env) do
    program = PB.CEL.Program.new(checked, env)
    PB.CEL.eval_program(program, bindings)
  rescue
    exception -> {:error, exception}
  end

  defp vars(case) do
    with {:ok, binding_vars} <- binding_vars(case.bindings),
         {:ok, env_vars, _functions} <- type_env_decls(case.type_env) do
      {:ok, Map.merge(binding_vars, env_vars)}
    end
  end

  defp binding_vars(bindings) do
    Enum.reduce_while(bindings, {:ok, %{}}, fn {name, expr_value}, {:ok, acc} ->
      case expr_value_to_value(expr_value) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, Value.type_of(value))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp type_env_decls(type_env) do
    Enum.reduce_while(type_env, {:ok, %{}, []}, fn decl, {:ok, vars, functions} ->
      case decl do
        %{name: name, decl_kind: {:ident, %{type: type}}} ->
          if supported_type?(type) do
            {:cont, {:ok, Map.put(vars, name, type), functions}}
          else
            {:halt, {:error, :unsupported_type}}
          end

        %{name: name, decl_kind: {:function, function}} ->
          case function_decl(name, function) do
            {:ok, function} -> {:cont, {:ok, vars, [function | functions]}}
            :error -> {:halt, {:error, :unsupported_decl}}
          end

        _other ->
          {:halt, {:error, :unsupported_decl}}
      end
    end)
  end

  defp unsupported_type_env?(type_env),
    do: not match?({:ok, _vars, _functions}, type_env_decls(type_env))

  defp unsupported_expected_check_type?(case) do
    case expected_check_type(case) do
      {:ok, type} -> not supported_type?(type)
      :ignore -> false
    end
  end

  defp unsupported_expected_eval_result?(case) do
    case expected_eval_result(case) do
      {:ok, _value_or_error} -> false
      {:error, _reason} -> true
    end
  end

  defp unsupported_calls(case) do
    case PB.CEL.parse(case.expr,
           disable_macros: case.disable_macros,
           macros: not case.disable_macros
         ) do
      {:ok, parsed} ->
        supported_calls = Library.supported_call_names()
        env = call_resolution_env(case)

        parsed.expr
        |> calls(Env.namespaces(env))
        |> Enum.reject(&supported_call?(&1, supported_calls, env))
        |> Enum.map(&Call.reference_name/1)

      {:error, _error} ->
        []
    end
  end

  defp call_resolution_env(case) do
    vars =
      case vars(case) do
        {:ok, vars} -> vars
        {:error, _reason} -> %{}
      end

    functions =
      case type_env_decls(case.type_env) do
        {:ok, _vars, functions} -> functions
        {:error, _reason} -> []
      end

    Env.from_options(
      vars: vars,
      functions: functions,
      container: case.container,
      schema: @schema,
      message_schema: CELSchema,
      message_runtime: MessageRuntime
    )
  end

  defp supported_call?(%Call{} = call, supported_calls, env) do
    call_name = Call.reference_name(call)
    env_supported_calls = env.functions |> Enum.flat_map(&Function.call_names/1) |> MapSet.new()

    MapSet.member?(supported_calls, call_name) or MapSet.member?(env_supported_calls, call_name) or
      match?({:ok, _enum}, NameResolution.resolve_enum_call(call, env, []))
  end

  defp calls(expr, namespaces), do: calls(expr, namespaces, [])

  defp calls(%{expr_kind: {:call_expr, call}}, namespaces, acc) do
    call = Call.classify(call, namespaces: namespaces)

    acc = [call | acc]
    acc = Enum.reduce(Map.get(call, :args, []), acc, &calls(&1, namespaces, &2))

    case Map.get(call, :target) do
      nil -> acc
      target -> calls(target, namespaces, acc)
    end
  end

  defp calls(%{expr_kind: {:select_expr, select}}, namespaces, acc),
    do: calls(select.operand, namespaces, acc)

  defp calls(%{expr_kind: {:list_expr, list}}, namespaces, acc) do
    Enum.reduce(Map.get(list, :elements, []), acc, &calls(&1, namespaces, &2))
  end

  defp calls(%{expr_kind: {:struct_expr, struct}}, namespaces, acc) do
    Enum.reduce(Map.get(struct, :entries, []), acc, fn entry, acc ->
      acc =
        case entry.key_kind do
          {:map_key, key} -> calls(key, namespaces, acc)
          {:field_key, _field} -> acc
        end

      calls(entry.value, namespaces, acc)
    end)
  end

  defp calls(%{expr_kind: {:comprehension_expr, comprehension}}, namespaces, acc) do
    [:iter_range, :accu_init, :loop_condition, :loop_step, :result]
    |> Enum.reduce(acc, fn key, acc -> calls(Map.fetch!(comprehension, key), namespaces, acc) end)
  end

  defp calls(%{expr_kind: {:const_expr, _constant}}, _namespaces, acc), do: acc
  defp calls(%{expr_kind: {:ident_expr, _ident}}, _namespaces, acc), do: acc

  defp function_decl(name, %{overloads: overloads}) when is_binary(name) do
    with {:ok, overloads} <- overload_decls(overloads) do
      {:ok, %Function{name: name, modes: [:global], overloads: overloads}}
    end
  end

  defp function_decl(_name, _function), do: :error

  defp overload_decls(overloads) when is_list(overloads) do
    overloads
    |> Enum.reduce_while({:ok, []}, fn overload, {:ok, overloads} ->
      case overload_decl(overload) do
        {:ok, overload} -> {:cont, {:ok, [overload | overloads]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, overloads} -> {:ok, Enum.reverse(overloads)}
      :error -> :error
    end
  end

  defp overload_decls(_overloads), do: :error

  defp overload_decl(%{overload_id: id, params: params, result_type: result})
       when is_binary(id) and is_list(params) do
    with {:ok, args} <- decl_types(params),
         {:ok, result} <- decl_type(result) do
      {:ok, %Overload{id: id, args: args, result: result}}
    end
  end

  defp overload_decl(_overload), do: :error

  defp decl_types(types) do
    types
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, types} ->
      case decl_type(type) do
        {:ok, type} -> {:cont, {:ok, [type | types]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, types} -> {:ok, Enum.reverse(types)}
      :error -> :error
    end
  end

  defp decl_type(%{type_kind: {:dyn, %{}}}), do: {:ok, :dyn}
  defp decl_type(%{type_kind: {:null, :NULL_VALUE}}), do: {:ok, :null}
  defp decl_type(%{type_kind: {:primitive, :BOOL}}), do: {:ok, :bool}
  defp decl_type(%{type_kind: {:primitive, :INT64}}), do: {:ok, :int}
  defp decl_type(%{type_kind: {:primitive, :UINT64}}), do: {:ok, :uint}
  defp decl_type(%{type_kind: {:primitive, :DOUBLE}}), do: {:ok, :double}
  defp decl_type(%{type_kind: {:primitive, :STRING}}), do: {:ok, :string}
  defp decl_type(%{type_kind: {:primitive, :BYTES}}), do: {:ok, :bytes}
  defp decl_type(%{type_kind: {:well_known, :TIMESTAMP}}), do: {:ok, :timestamp}
  defp decl_type(%{type_kind: {:well_known, :DURATION}}), do: {:ok, :duration}

  defp decl_type(%{type_kind: {:message_type, name}}) when is_binary(name),
    do: {:ok, {:message, name}}

  defp decl_type(%{type_kind: {:type_param, name}}) when is_binary(name),
    do: {:ok, TypePattern.param(String.to_atom(name))}

  defp decl_type(%{type_kind: {:type, type}}) do
    with {:ok, type} <- decl_type(type), do: {:ok, {:type, type}}
  end

  defp decl_type(%{type_kind: {:list_type, %{elem_type: elem_type}}}) do
    with {:ok, elem_type} <- decl_type(elem_type), do: {:ok, TypePattern.list(elem_type)}
  end

  defp decl_type(%{type_kind: {:map_type, %{key_type: key_type, value_type: value_type}}}) do
    with {:ok, key_type} <- decl_type(key_type),
         {:ok, value_type} <- decl_type(value_type) do
      {:ok, TypePattern.map(key_type, value_type)}
    end
  end

  defp decl_type(%{
         type_kind: {:abstract_type, %{name: "optional_type", parameter_types: [type]}}
       }) do
    with {:ok, type} <- decl_type(type), do: {:ok, TypePattern.optional(type)}
  end

  defp decl_type(%{type_kind: {:abstract_type, %{name: name, parameter_types: params}}})
       when is_binary(name) and is_list(params) do
    with {:ok, params} <- decl_types(params), do: {:ok, TypePattern.abstract(name, params)}
  end

  defp decl_type(_type), do: :error

  defp supported_type?(type), do: supported_type?(type, @schema.schema())

  defp supported_type?(%{type_kind: {:dyn, %{}}}, _schema), do: true
  defp supported_type?(%{type_kind: {:null, :NULL_VALUE}}, _schema), do: true

  defp supported_type?(%{type_kind: {:primitive, primitive}}, _schema),
    do: primitive in [:BOOL, :INT64, :UINT64, :DOUBLE, :STRING, :BYTES]

  defp supported_type?(%{type_kind: {:wrapper, primitive}}, _schema),
    do: primitive in [:BOOL, :INT64, :UINT64, :DOUBLE, :STRING, :BYTES]

  defp supported_type?(%{type_kind: {:well_known, well_known}}, _schema),
    do: well_known in [:TIMESTAMP, :DURATION]

  defp supported_type?(%{type_kind: {:message_type, name}}, schema) do
    name in ["google.protobuf.Timestamp", "google.protobuf.Duration"] or
      CELSchema.known_message?(schema, name) or CELSchema.known_enum?(schema, name)
  end

  defp supported_type?(%{type_kind: {:list_type, %{elem_type: elem_type}}}, schema),
    do: supported_type?(elem_type, schema)

  defp supported_type?(
         %{type_kind: {:map_type, %{key_type: key_type, value_type: value_type}}},
         schema
       ) do
    supported_type?(key_type, schema) and supported_type?(value_type, schema)
  end

  defp supported_type?(
         %{
           type_kind: {:abstract_type, %{name: "optional_type", parameter_types: [type]}}
         },
         schema
       ) do
    supported_type?(type, schema)
  end

  defp supported_type?(
         %{type_kind: {:abstract_type, %{name: name, parameter_types: params}}},
         schema
       )
       when is_binary(name) and is_list(params) do
    Enum.all?(params, &supported_type?(&1, schema))
  end

  defp supported_type?(%{type_kind: {:type, type}}, schema), do: supported_type?(type, schema)
  defp supported_type?(_type, _schema), do: false

  defp expr_value_to_value(expr_value),
    do:
      Value.from_expr_value(expr_value,
        schema: @schema,
        message_schema: CELSchema,
        message_runtime: MessageRuntime
      )

  defp verify_sha256!(bin, fixture), do: verify_sha256!(bin, fixture.output, fixture.sha256)

  defp verify_sha256!(bin, path, expected) do
    actual = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

    unless actual == expected do
      raise "CEL conformance fixture checksum mismatch for #{path}: " <>
              "expected #{expected}, got #{actual}"
    end
  end

  defp cached(key, fun) when is_function(fun, 0) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, @cache_miss) do
      @cache_miss ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
