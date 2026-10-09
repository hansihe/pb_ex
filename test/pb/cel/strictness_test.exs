defmodule PB.CEL.StrictnessTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Error
  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Value

  defmodule Handlers do
    def twice([{:int, value}]) do
      send(self(), {:twice_called, value})
      {:ok, Value.int(value * 2)}
    end
  end

  @vars [x: :int, y: :int, s: :string, l: {:list, :int}, m: {:map, :string, :int}]

  # Error-valued bindings are the evaluator's internal representation of an
  # error that happened before evaluation.
  defp failed(name), do: {:__cel_error__, %Error{phase: :eval, message: "failed #{name}"}}

  defp eval(source) do
    bindings = Map.new(Keyword.keys(@vars), &{&1, failed(&1)})
    CEL.eval(source, bindings, env())
  end

  defp env do
    twice = %Function{
      name: "twice",
      overloads: [
        %Overload{id: "twice_int", args: [:int], result: :int, eval: {Handlers, :twice}}
      ]
    }

    CEL.Env.build(vars: @vars, functions: [twice])
  end

  test "logical operators still absorb an error input when the result is determined" do
    assert eval("x < 30 && false") == {:ok, Value.bool(false)}
    assert eval("x < 30 || true") == {:ok, Value.bool(true)}
    assert eval("false && x < 30") == {:ok, Value.bool(false)}
    assert eval("true || x < 30") == {:ok, Value.bool(true)}
  end

  test "calls with an error input return that error" do
    for source <- ["x == 1", "x != 1", "x in [1, 2]", "x < 30", "x + 1 > 0", "size(s) > 3"] do
      assert {:error, %Error{message: message}} = eval(source), source
      assert message =~ ~r/^failed [xs]$/, source
    end
  end

  test "custom functions are not run with an error input" do
    assert {:error, %Error{message: "failed x"}} = eval("twice(x) > 0")
    refute_received {:twice_called, _value}
  end

  test "selection and indexing of an error input return that error" do
    assert {:error, %Error{message: "failed m"}} = eval("m.a > 0")
    assert {:error, %Error{message: "failed m"}} = eval(~s|m["a"] > 0|)
    assert {:error, %Error{message: "failed m"}} = eval("has(m.a)")
    assert {:error, %Error{message: "failed l"}} = eval("l[0] > 0")
  end

  test "conditional with an error condition returns that error" do
    assert {:error, %Error{message: "failed x"}} = eval("x > 1 ? 1 : 2")
  end

  test "comprehensions over an error range return that error" do
    assert {:error, %Error{message: "failed l"}} = eval("l.exists(i, i > 5)")
    assert {:error, %Error{message: "failed l"}} = eval("l.map(i, i * 2) == []")
  end

  test "comprehensions propagate an error predicate unless absorbed" do
    assert {:error, %Error{message: "failed x"}} = eval("[1, 2].exists(i, i == x)")
    assert {:error, %Error{message: "failed x"}} = eval("[1, 2].all(i, i == x)")
    assert eval("[1, 2].exists(i, i == 1 || i == x)") == {:ok, Value.bool(true)}
  end

  test "comprehensions absorb an error from an earlier iteration" do
    assert CEL.eval("[0, 1].exists(i, 1 / i > 0)") == {:ok, Value.bool(true)}
    assert CEL.eval("[0, 1].all(i, 1 / i < 0)") == {:ok, Value.bool(false)}

    assert {:error, %Error{message: "division by zero"}} =
             CEL.eval("[1, 0].exists(i, 1 / i > 5)")
  end

  test "a non-iterable range is an evaluation error" do
    assert {:error, %Error{phase: :eval, message: "cannot iterate over int"}} =
             CEL.eval("dyn(1).exists(i, true)")
  end

  test "both operands of a logical operator in error report the left one" do
    assert {:error, %Error{message: "failed x"}} = eval("x < 30 && y > 1")
    assert {:error, %Error{message: "failed y"}} = eval("y > 1 || x < 30")
  end
end
