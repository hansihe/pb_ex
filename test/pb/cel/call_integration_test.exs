defmodule PB.CEL.CallIntegrationTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Checked
  alias PB.CEL.Error
  alias PB.CEL.Library
  alias PB.CEL.Function
  alias PB.CEL.Checker.Types, as: CType
  alias PB.CEL.Value

  test "checker treats namespace call targets as namespaces, not value identifiers" do
    assert_namespace_call(
      CEL.check!("strings.quote(value)", env(vars: %{value: :string})),
      "strings",
      "strings.quote",
      "strings_quote",
      CType.string()
    )

    assert_namespace_call(
      CEL.check!("math.isFinite(value)", env(vars: %{value: :double})),
      "math",
      "math.isFinite",
      "math_is_finite",
      CType.bool()
    )

    assert_namespace_call(
      CEL.check!("optional.of(value)", env(vars: %{value: :int})),
      "optional",
      "optional.of",
      "optional_of",
      CType.optional(CType.int())
    )
  end

  test "checker treats receiver call targets as checked values" do
    checked = CEL.check!("value.startsWith('he')", env(vars: %{value: :string}))
    %{expr_kind: {:call_expr, call}} = checked.expr

    assert checked.types[checked.expr.id] == CType.bool()

    assert ref(checked, checked.expr.id) == %{
             name: "startsWith",
             overload_id: ["starts_with"]
           }

    assert checked.types[call.target.id] == CType.string()
    assert ref(checked, call.target.id) == %{name: "value", overload_id: []}
  end

  test "evaluator does not require runtime bindings for namespace identifiers" do
    assert CEL.eval!("strings.quote(value)", %{value: "bell\a"}, env(vars: %{value: :string})) ==
             Value.string(~S|"bell\a"|)

    assert CEL.eval!("math.isFinite(value)", %{value: 1.5}, env(vars: %{value: :double})) ==
             Value.bool(true)

    assert CEL.eval!(
             "optional.unwrap(optional.of(value))",
             %{value: 7},
             env(vars: %{value: :int})
           ) ==
             Value.int(7)
  end

  test "math catalog carries simple overload metadata" do
    checked = CEL.check!("math.abs(value)", env(vars: %{value: :uint}))

    assert checked.types[checked.expr.id] == CType.uint()

    assert ref(checked, checked.expr.id) == %{
             name: "math.abs",
             overload_id: ["math_abs"]
           }

    checked = CEL.check!("math.ceil(value)", env(vars: %{value: :dyn}))
    assert checked.types[checked.expr.id] == CType.double()

    assert {:error, %Error{phase: :check, message: "no matching overload for math.greatest()"}} =
             CEL.check("math.greatest()")
  end

  test "string catalog keeps static and dynamic overloads distinct" do
    checked = CEL.check!(~S|["a"].join()|)
    assert checked.types[checked.expr.id] == CType.string()
    assert ref(checked, checked.expr.id).overload_id == ["join"]

    checked = CEL.check!(~S|[dyn("a")].join()|)
    assert checked.types[checked.expr.id] == CType.string()
    assert ref(checked, checked.expr.id).overload_id == ["join_dyn"]

    checked = CEL.check!(~S|"a,b".split(",")|)
    assert checked.types[checked.expr.id] == CType.list(CType.string())

    assert {:error, %Error{phase: :check, message: "no matching overload for join(list(int))"}} =
             CEL.check("[1].join()")
  end

  test "normal catalog overloads do not accept dynamic matcher args" do
    offenders =
      for function <- Library.functions(),
          overload <- function.overloads,
          dynamic_matcher_args?(overload.args),
          do: {Function.call_names(function), overload.id, overload.args}

    assert offenders == []
  end

  defp assert_namespace_call(checked, namespace, reference_name, overload_id, type) do
    %{expr_kind: {:call_expr, call}} = checked.expr
    %{expr_kind: {:ident_expr, %{name: ^namespace}}} = call.target
    [arg] = call.args

    assert checked.types[checked.expr.id] == type

    assert ref(checked, checked.expr.id) == %{
             name: reference_name,
             overload_id: [overload_id]
           }

    refute Map.has_key?(checked.types, call.target.id)
    refute Map.has_key?(Checked.reference_map(checked), call.target.id)

    assert ref(checked, arg.id) == %{name: "value", overload_id: []}
    arg_id = arg.id

    assert {:call,
            %{
              name: ^reference_name,
              shape: {:namespace, ^namespace},
              overload_id: ^overload_id,
              target_id: nil,
              arg_ids: [^arg_id]
            }} = Checked.op(checked, checked.expr)
  end

  defp dynamic_matcher_args?(args) do
    Enum.any?(args, &dynamic_matcher?/1)
  end

  defp dynamic_matcher?(:dyn), do: true
  defp dynamic_matcher?(:dynamic), do: true
  defp dynamic_matcher?({:type, matcher}), do: dynamic_matcher?(matcher)
  defp dynamic_matcher?({:list, matcher}), do: dynamic_matcher?(matcher)
  defp dynamic_matcher?({:map, key, value}), do: dynamic_matcher?(key) or dynamic_matcher?(value)
  defp dynamic_matcher?({:one_of, matchers}), do: Enum.any?(matchers, &dynamic_matcher?/1)
  defp dynamic_matcher?({:optional, matcher}), do: dynamic_matcher?(matcher)
  defp dynamic_matcher?({:repeat, matcher, _min}), do: dynamic_matcher?(matcher)
  defp dynamic_matcher?(_matcher), do: false

  defp ref(checked, expr_or_id), do: Checked.ref(checked, expr_or_id)
  defp env(opts), do: CEL.Env.build(opts)
end
