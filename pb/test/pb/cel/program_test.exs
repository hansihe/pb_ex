defmodule CEL.ProgramTest do
  use ExUnit.Case, async: true

  alias CEL.Env
  alias CEL.Program
  alias CEL.Value

  test "check accepts an Env positionally" do
    env = Env.build(vars: %{"name" => :string})
    assert {:ok, _checked} = CEL.check(~s|"hello, " + name|, env)
  end

  test "eval accepts an Env positionally" do
    env = Env.build(vars: %{"name" => :string})
    assert {:ok, value} = CEL.eval(~s|"hello, " + name|, %{"name" => "world"}, env)
    assert value == Value.string("hello, world")
  end

  test "compile bundles a checked expression with its env" do
    env = Env.build(vars: %{"name" => :string})
    assert {:ok, %Program{} = program} = CEL.compile(~s|"hello, " + name|, env)
    assert {:ok, value} = Program.eval(program, %{"name" => "alice"})
    assert value == Value.string("hello, alice")
  end

  test "Program.eval runs a compiled program" do
    env = Env.build(vars: %{"n" => :int})
    {:ok, program} = CEL.compile("n + 1", env)
    assert CEL.Program.eval!(program, %{"n" => 4}) == Value.int(5)
  end

  test "parse validates its options" do
    assert {:ok, %{source_info: %{macro_calls: calls}}} = CEL.parse("[1].all(x, x > 0)")
    assert map_size(calls) == 1
    assert {:ok, %{source_info: %{macro_calls: %{}}}} = CEL.parse("f(x)", macros: false)

    assert_raise CEL.OptionError, ~r/unknown option/, fn ->
      CEL.parse("1", disable_macros: true)
    end
  end

  test "Env.build/1 validates its options" do
    for {opts, pattern} <- [
          {[bogus: 1], ~r/unknown option\(s\): \[:bogus\]/},
          {[vars: [x: :nope]], ~r/:vars: :x has no CEL.Type: :nope/},
          {[vars: :nope], ~r/:vars: expected a keyword list or map/},
          {[functions: [:nope]], ~r/:functions: expected a %CEL.Function\{\}/},
          {[container: :pkg], ~r/:container: expected a string/},
          {[schema: PB.TestSupport.TestSchema], ~r/unknown option\(s\): \[:schema\]/},
          {[types: PB.TestSupport.TestSchema], ~r/:types: expected a \{module, state\}/},
          {[types: {Enum, nil}], ~r/:types: Enum does not implement CEL.TypeProvider/},
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

  test "Env.empty/0 returns a default environment" do
    assert %Env{} = env = Env.empty()
    assert env.vars == %{}
    assert env.functions == []
    assert env.container == ""
    assert {CEL.TypeProvider.Empty, nil} = env.types
  end
end
