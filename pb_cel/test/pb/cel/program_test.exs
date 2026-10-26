defmodule PB.CEL.ProgramTest do
  # CEL environments over a PB schema; the rest of CEL's environment and
  # program tests are cel_ex's.
  use ExUnit.Case, async: true

  alias CEL.Env

  test "Env.build/1 rejects a PB schema where it takes a types provider" do
    for {opts, pattern} <- [
          {[schema: PB.TestSupport.TestSchema], ~r/unknown option\(s\): \[:schema\]/},
          {[types: PB.TestSupport.TestSchema], ~r/:types: expected a \{module, state\}/},
          {[types: PB.CEL.types(PB.TestSupport.TestSchema), vars: [x: {:message, "pkg.Nope"}]],
           ~r/:vars: unknown message or enum type pkg.Nope/}
        ] do
      assert_raise CEL.OptionError, pattern, fn -> Env.build(opts) end
    end
  end

  test "Env.build/1 with only :types reads PB messages" do
    env =
      Env.build(
        types: PB.CEL.types(PB.TestSupport.TestSchema),
        container: "cel.expr.conformance.proto3",
        vars: [n: :int]
      )

    assert {:ok, {:bool, true}} = CEL.eval("n == 1", %{n: 1}, env)

    {:ok, value} =
      CEL.eval("TestAllTypes{single_int64: 3}.single_int64", %{}, env)

    assert value == {:int, 3}
  end
end
