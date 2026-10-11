defmodule PB.CEL.ProgramTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Env
  alias PB.CEL.Program
  alias PB.CEL.Value

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

  test "eval_program runs a pre-compiled program" do
    env = Env.build(vars: %{"n" => :int})
    {:ok, program} = CEL.compile("n + 1", env)
    assert CEL.eval_program!(program, %{"n" => 4}) == Value.int(5)
  end

  test "Env.build/1 validates its options" do
    for {opts, pattern} <- [
          {[bogus: 1], ~r/unknown option\(s\): \[:bogus\]/},
          {[vars: [x: :nope]], ~r/:vars: :x has no PB.CEL.Type: :nope/},
          {[vars: :nope], ~r/:vars: expected a keyword list or map/},
          {[functions: [:nope]], ~r/:functions: expected a %PB.CEL.Function\{\}/},
          {[container: :pkg], ~r/:container: expected a string/},
          {[message_schema: Enum], ~r/:message_schema: expected a provider module/}
        ] do
      assert_raise PB.OptionError, pattern, fn -> Env.build(opts) end
    end
  end

  test "Env.build/1 with only :schema reads PB messages" do
    env =
      Env.build(
        schema: PB.TestSupport.TestSchema,
        container: "cel.expr.conformance.proto3",
        vars: [n: :int]
      )
    assert {:ok, {:bool, true}} = PB.CEL.eval("n == 1", %{n: 1}, env)

    {:ok, value} =
      PB.CEL.eval("TestAllTypes{single_int64: 3}.single_int64", %{}, env)

    assert value == {:int, 3}
  end

  test "Env.empty/0 returns a default environment" do
    assert %Env{} = env = Env.empty()
    assert env.vars == %{}
    assert env.functions == []
    assert env.container == ""
    assert env.schema == nil
  end
end
