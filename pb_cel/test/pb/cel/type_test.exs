defmodule PB.CEL.TypeTest do
  # CEL enum types over a PB schema; the rest of CEL's type tests are cel_ex's.
  use ExUnit.Case, async: true

  test "enum types are told apart from messages" do
    env =
      CEL.Env.build(
        types: PB.CEL.types(PB.TestSupport.TestSchema),
        container: "cel.expr.conformance.proto3",
        vars: [m: {:message, "cel.expr.conformance.proto3.TestAllTypes"}]
      )

    enum = :"cel.expr.conformance.proto3.TestAllTypes.NestedEnum"
    assert CEL.Checked.type(CEL.check!("m.standalone_enum", env)) == {:enum, enum}
    global = :"cel.expr.conformance.proto3.GlobalEnum"
    assert CEL.Checked.type(CEL.check!("GlobalEnum", env)) == {:type, {:enum, global}}
    assert CEL.Type.format({:enum, enum}) == Atom.to_string(enum)

    # A declaration may name the enum by string or atom; types carry the
    # provider's name.
    for declared <- [enum, Atom.to_string(enum)] do
      env =
        CEL.Env.build(
          types: PB.CEL.types(PB.TestSupport.TestSchema),
          vars: [e: {:enum, declared}]
        )

      assert CEL.Checked.type(CEL.check!("e", env)) == {:enum, enum}
    end
  end

  test "enum values bind from PB's decoded atoms and numbers" do
    enum = :"cel.expr.conformance.proto3.GlobalEnum"
    env = CEL.Env.build(types: PB.CEL.types(PB.TestSupport.TestSchema), vars: [e: {:enum, enum}])

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
end
