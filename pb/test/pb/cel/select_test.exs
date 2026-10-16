defmodule CEL.SelectTest do
  use ExUnit.Case, async: true

  @msg "cel.expr.conformance.proto3.TestAllTypes"

  defp env do
    CEL.Env.build(
      schema: PB.TestSupport.TestSchema,
      vars: [msg: {:message, @msg}, req: {:map, :string, :dyn}]
    )
  end

  test "an unset field with presence is absent, a set one is its value" do
    set = %{single_int64_wrapper: %{value: 0}, standalone_message: %{bb: 7}}

    assert CEL.select(env(), %{msg: set}, "msg", ["single_int64_wrapper"]) == {:ok, {:int, 0}}
    assert CEL.select(env(), %{msg: %{}}, "msg", ["single_int64_wrapper"]) == :absent

    assert CEL.select(env(), %{msg: set}, "msg", ["standalone_message", "bb"]) == {:ok, {:int, 7}}
    assert CEL.select(env(), %{msg: %{}}, "msg", ["standalone_message", "bb"]) == :absent
  end

  test "a field without presence is absent when it holds its default" do
    assert CEL.select(env(), %{msg: %{single_int64: 3}}, "msg", ["single_int64"]) ==
             {:ok, {:int, 3}}

    assert CEL.select(env(), %{msg: %{single_int64: 0}}, "msg", ["single_int64"]) == :absent
  end

  test "map keys need not be identifiers, and a missing key is absent" do
    req = %{"x-id" => %{"n" => 1}}

    assert CEL.select(env(), %{req: req}, :req, ["x-id", "n"]) == {:ok, {:int, 1}}
    assert CEL.select(env(), %{req: req}, :req, ["x-id", "m"]) == :absent
  end

  test "unknown bindings, undeclared variables and unknown fields" do
    assert {:unknown, unknown} = CEL.select(env(), %{req: {:unknown, :timeout}}, "req", ["a"])
    assert [{{:var, "req"}, :timeout}] = CEL.Unknown.entries(unknown)

    assert {:error, %CEL.Error{phase: :check}} = CEL.select(env(), %{}, "nope", ["a"])
    assert {:error, %CEL.Error{phase: :check}} = CEL.select(env(), %{msg: %{}}, "msg", ["bogus"])
    assert CEL.select(env(), %{req: %{}}, "req", []) == {:ok, {:map, %{}}}
  end
end
