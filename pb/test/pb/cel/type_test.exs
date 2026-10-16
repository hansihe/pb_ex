defmodule CEL.TypeTest do
  use ExUnit.Case, async: true

  alias CEL.Expr

  doctest CEL.Type

  test "the same shorthand declares variables and comes back from checking" do
    env =
      CEL.Env.build(
        vars: [at: :timestamp, ttl: :duration, tags: {:map, :string, {:list, :int}}]
      )

    checked = CEL.check!("at + ttl", env)
    assert CEL.Checked.type(checked) == :timestamp

    assert %Expr.Call{args: [%Expr.Ident{type: :timestamp}, %Expr.Ident{type: :duration}]} =
             CEL.Checked.expr(checked)

    checked = CEL.check!("tags.?a", env)
    assert CEL.Checked.type(checked) == {:optional, {:list, :int}}
    assert CEL.Type.format(CEL.Checked.type(checked)) == "optional_type(list(int))"
  end

  test "time values bind from DateTime and PB's decoded seconds/nanos maps" do
    env = CEL.Env.build(vars: [at: :timestamp, ttl: :duration, any: :dyn])

    for at <- [~U[1970-01-01 00:00:05Z], %{seconds: 5}, CEL.Value.timestamp(5_000_000_000)] do
      assert CEL.eval("at", %{at: at}, env) == {:ok, {:timestamp, 5_000_000_000}}
    end

    assert CEL.eval("ttl", %{ttl: %{seconds: 1, nanos: 5}}, env) ==
             {:ok, {:duration, 1_000_000_005}}
    assert CEL.eval("any", %{any: ~U[1970-01-01 00:00:05Z]}, env) ==
             {:ok, {:timestamp, 5_000_000_000}}
    assert {:error, %CEL.Error{}} = CEL.eval("at", %{at: %{bogus: 1}}, env)
  end

  test "enum types are told apart from messages" do
    env =
      CEL.Env.build(
        schema: PB.TestSupport.TestSchema,
        container: "cel.expr.conformance.proto3",
        vars: [m: {:message, "cel.expr.conformance.proto3.TestAllTypes"}]
      )

    enum = "cel.expr.conformance.proto3.TestAllTypes.NestedEnum"
    assert CEL.Checked.type(CEL.check!("m.standalone_enum", env)) == {:enum, enum}
    global = "cel.expr.conformance.proto3.GlobalEnum"
    assert CEL.Checked.type(CEL.check!("GlobalEnum", env)) == {:type, {:enum, global}}
    assert CEL.Type.format({:enum, enum}) == enum

    env = CEL.Env.build(schema: PB.TestSupport.TestSchema, vars: [e: {:enum, enum}])
    assert CEL.Checked.type(CEL.check!("e", env)) == {:enum, enum}
  end

  test "enum values bind from PB's decoded atoms and numbers" do
    enum = "cel.expr.conformance.proto3.GlobalEnum"
    env = CEL.Env.build(schema: PB.TestSupport.TestSchema, vars: [e: {:enum, enum}])

    assert CEL.eval("e", %{e: :GAZ}, env) == {:ok, {:enum, enum, 2}}
    assert CEL.eval("e", %{e: 2}, env) == {:ok, {:enum, enum, 2}}
    assert CEL.eval("e", %{e: 42}, env) == {:ok, {:enum, enum, 42}}
    assert CEL.eval("e", %{e: {:enum, enum, 1}}, env) == {:ok, {:enum, enum, 1}}

    assert {:error, %CEL.Error{message: "unknown enum value \"NOPE\"" <> _}} =
             CEL.eval("e", %{e: :NOPE}, env)

    assert {:error, %CEL.Error{message: "enum value is out of int32 range"}} =
             CEL.eval("e", %{e: 3_000_000_000}, env)

    assert {:error, %CEL.Error{}} = CEL.eval("e", %{e: true}, env)
  end

  test "an id the checker did not type has no type" do
    checked = CEL.check!("[1].all(x, x > 0)")
    assert CEL.Checked.type(checked, 999_999) == nil
  end
end
