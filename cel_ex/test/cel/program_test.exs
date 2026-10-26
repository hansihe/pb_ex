defmodule CEL.ProgramTest do
  use ExUnit.Case, async: true

  alias CEL.Env
  alias CEL.Program
  alias CEL.TestSupport.StringTypes
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
          {[types: {Enum, nil}], ~r/:types: Enum does not implement CEL.TypeProvider/}
        ] do
      assert_raise CEL.OptionError, pattern, fn -> Env.build(opts) end
    end
  end

  test "Env.build/1 rejects message and enum types it cannot resolve, with or without :types" do
    args = [{:list, {:enum, "pkg.E"}}]
    overload = %CEL.Function.Overload{id: "f_list", args: args, result: :int}
    function = %CEL.Function{name: "f", overloads: [overload]}

    for types <- [[], [types: {StringTypes, nil}]] do
      for {opts, pattern} <- [
            {[vars: [x: {:message, "pkg.Nope"}]],
             ~r/:vars: unknown message or enum type pkg.Nope in variable "x"/},
            {[vars: %{"m" => {:map, :string, {:message, :"pkg.M"}}}],
             ~r/:vars: unknown message or enum type pkg.M in variable "m"/},
            {[functions: [function]],
             ~r/:functions: unknown message or enum type pkg.E in "f" overload "f_list"/}
          ] do
        assert_raise CEL.OptionError, pattern, fn -> Env.build(types ++ opts) end
      end
    end

    vars = [t: {:message, "google.protobuf.Timestamp"}, s: {:message, :"google.protobuf.Struct"}]
    builtins = [t: :timestamp, s: {:map, :string, :dyn}]
    assert Env.build(vars: vars).vars == Env.build(vars: builtins).vars
  end

  test "Env.empty/0 returns a default environment" do
    assert %Env{} = env = Env.empty()
    assert env.vars == %{}
    assert env.functions == []
    assert env.container == ""
    assert {CEL.TypeProvider.Empty, nil} = env.types
  end
end
