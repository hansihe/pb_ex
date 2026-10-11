defmodule PB.CEL.ConformanceTest do
  use ExUnit.Case, async: true

  alias PB.TestSupport.CELConformance

  @fixtures CELConformance.fixtures()

  test "loads converted simple conformance fixtures" do
    assert length(@fixtures) == 29

    for fixture <- @fixtures do
      decoded = CELConformance.decode_fixture(fixture)
      assert is_binary(decoded.name)
      assert decoded.name != ""
    end
  end

  test "tracks cases outside PB scope" do
    out_of_scope = CELConformance.out_of_scope_cases()

    assert length(CELConformance.in_scope_cases()) == 2289

    assert CELConformance.out_of_scope_reason_summary(out_of_scope) == %{
             optimizer_block: 37,
             proto2_extensions: 18
           }
  end

  test "tracks parser cases outside this slice" do
    unsupported = CELConformance.unsupported_parser_cases()

    assert length(CELConformance.supported_parser_cases()) == 2289
    assert unsupported == []
  end

  test "tracks checker cases outside this slice" do
    unsupported = CELConformance.unsupported_check_cases()

    assert length(CELConformance.supported_check_cases()) == 2141

    assert CELConformance.unsupported_reason_summary(unsupported) == %{
             disable_check: 141,
             legacy_enum_semantics: 4,
             strong_enum_field_types: 3
           }
  end

  test "tracks evaluator cases outside this slice" do
    unsupported = CELConformance.unsupported_eval_cases()

    assert length(CELConformance.supported_eval_cases()) == 2097

    assert CELConformance.unsupported_reason_summary(unsupported) == %{
             any_unpack_equality: 4,
             check_only: 25,
             disable_check: 141,
             legacy_enum_semantics: 21,
             strong_enum_field_types: 1
           }
  end

  for fixture <- @fixtures do
    @tag :cel_conformance
    @tag cel_fixture: fixture.output
    test "parser conformance #{fixture.output}" do
      fixture = unquote(Macro.escape(fixture))
      cases = CELConformance.supported_parser_cases(fixture.output)

      failures =
        for case <- cases,
            result = parse_case(case),
            not match?({:ok, _parsed}, result) do
          "#{case.fixture}/#{case.section}/#{case.name}: #{inspect(result)}"
        end

      assert failures == []
    end

    @tag :cel_conformance
    @tag cel_fixture: fixture.output
    test "checker conformance #{fixture.output}" do
      fixture = unquote(Macro.escape(fixture))
      cases = CELConformance.supported_check_cases(fixture.output)

      failures =
        for case <- cases,
            result = check_case(case),
            not match?({:ok, _checked}, result) do
          "#{case.fixture}/#{case.section}/#{case.name}: #{inspect(result)}"
        end

      assert failures == []
    end

    @tag :cel_conformance
    @tag cel_fixture: fixture.output
    test "evaluator conformance #{fixture.output}" do
      fixture = unquote(Macro.escape(fixture))
      cases = CELConformance.supported_eval_cases(fixture.output)

      failures =
        for case <- cases,
            result = eval_case(case),
            result != :ok do
          "#{case.fixture}/#{case.section}/#{case.name}: #{inspect(result)}"
        end

      assert failures == []
    end
  end

  defp parse_case(case) do
    case PB.CEL.parse(case.expr, macros: not case.disable_macros) do
      {:ok, parsed} when is_map(parsed.expr) and is_map(parsed.source_info) ->
        {:ok, parsed}

      other ->
        other
    end
  end

  defp check_case(case) do
    with {:ok, parsed} <- PB.CEL.parse(case.expr, CELConformance.parse_opts(case)),
         {:ok, env} <- CELConformance.check_env(case),
         {:ok, checked} <- PB.CEL.check(parsed, env),
         :ok <- assert_expected_check_type(case, checked) do
      {:ok, checked}
    end
  end

  defp eval_case(case) do
    with {:ok, parsed} <- PB.CEL.parse(case.expr, CELConformance.parse_opts(case)),
         {:ok, env} <- CELConformance.check_env(case),
         {:ok, checked} <- PB.CEL.check(parsed, env),
         {:ok, bindings} <- CELConformance.eval_bindings(case),
         {:ok, expected} <- CELConformance.expected_eval_result(case) do
      CELConformance.match_eval_result(expected, safe_eval(checked, bindings, env))
    end
  end

  defp assert_expected_check_type(case, checked) do
    case CELConformance.expected_check_type(case) do
      {:ok, type} ->
        actual = PB.CEL.Checked.proto_type(checked, checked.expr.id)

        if actual == type do
          :ok
        else
          {:error, {:type_mismatch, actual, type}}
        end

      :ignore ->
        :ok
    end
  end

  defp safe_eval(checked, bindings, env) do
    program = PB.CEL.Program.new(checked, env)
    PB.CEL.Program.eval(program, bindings)
  rescue
    exception -> {:error, exception}
  end
end
