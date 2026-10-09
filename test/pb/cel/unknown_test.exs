defmodule PB.CEL.UnknownTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Error
  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.CEL.Unknown
  alias PB.CEL.Value

  defmodule Handlers do
    def lookup([{:string, "missing"}]), do: {:unknown, :not_fetched}
    def lookup([{:string, key}]), do: {:ok, Value.int(String.length(key))}

    def twice([{:int, value}]) do
      send(self(), {:twice_called, value})
      {:ok, Value.int(value * 2)}
    end
  end

  @vars [x: :int, y: :int, s: :string, l: {:list, :int}, p: :bool]

  defp env do
    lookup = %Function{
      name: "lookup",
      overloads: [
        %Overload{id: "lookup_string", args: [:string], result: :int, eval: {Handlers, :lookup}}
      ]
    }

    twice = %Function{
      name: "twice",
      overloads: [
        %Overload{id: "twice_int", args: [:int], result: :int, eval: {Handlers, :twice}}
      ]
    }

    CEL.Env.build(vars: @vars, functions: [lookup, twice])
  end

  defp eval(source, bindings \\ %{}) do
    unknowns = %{
      x: {:unknown, :timeout},
      y: {:unknown, :missing},
      s: {:unknown, :s},
      l: {:unknown, :l}
    }

    CEL.eval(source, Map.merge(unknowns, Map.new(bindings)), env())
  end

  defp unknown_entries(source, bindings \\ %{}) do
    assert {:unknown, %Unknown{} = unknown} = eval(source, bindings), source
    Unknown.entries(unknown)
  end

  describe "table from the partial evaluation brief" do
    test "logical operators decide without the unknown input" do
      assert eval("x < 30 && false") == {:ok, Value.bool(false)}
      assert eval("x < 30 || true") == {:ok, Value.bool(true)}
    end

    test "strict operations return the unknown with its reason" do
      for source <- ["x == 1", "x != 1", "x in [1, 2]", "x < 30"] do
        assert unknown_entries(source) == [{{:var, "x"}, :timeout}], source
      end

      assert unknown_entries("size(s) > 3") == [{{:var, "s"}, :s}]
    end

    test "comprehensions return the unknown" do
      assert unknown_entries("[1, 2].exists(i, i == x)") == [{{:var, "x"}, :timeout}]
      assert unknown_entries("l.exists(i, i > 5)") == [{{:var, "l"}, :l}]
    end

    test "logical operators merge the unknowns of both operands" do
      assert unknown_entries("x < 30 && y > 1") ==
               [{{:var, "x"}, :timeout}, {{:var, "y"}, :missing}]
    end
  end

  test "strict operations propagate unknowns" do
    assert unknown_entries("x > 1 ? 1 : 2") == [{{:var, "x"}, :timeout}]
    assert unknown_entries("l[0] > 1") == [{{:var, "l"}, :l}]
    assert unknown_entries("has({'a': x}.a)") == [{{:var, "x"}, :timeout}]
    assert unknown_entries("[1, 2].map(i, i + x) == []") == [{{:var, "x"}, :timeout}]
    assert unknown_entries("[1, 2, 3].exists_one(i, i == x)") == [{{:var, "x"}, :timeout}]
    assert unknown_entries("[1, 2].all(i, i < x)") == [{{:var, "x"}, :timeout}]
  end

  test "strict operations merge the unknowns of all operands" do
    expected = [{{:var, "x"}, :timeout}, {{:var, "y"}, :missing}]

    assert unknown_entries("x + y > 0") == expected
    assert unknown_entries("[x, y].size() > 0") == expected
    assert unknown_entries("{x: y}.size() > 0") == expected
  end

  test "a known value decides comprehensions despite unknown iterations" do
    assert eval("[1, 2].exists(i, i == x || i == 2)") == {:ok, Value.bool(true)}
    assert eval("[1, 2].all(i, i < x && i > 1)") == {:ok, Value.bool(false)}
  end

  describe "errors and unknowns together" do
    test "an error wins in strict operations" do
      assert {:error, %Error{message: "division by zero"}} = eval("x + 1 / 0 > 1")
      assert {:error, %Error{message: "division by zero"}} = eval("[x, 1 / 0].size() > 0")
    end

    test "an unknown wins in logical operators" do
      assert unknown_entries("x > 1 && 1 / 0 > 1") == [{{:var, "x"}, :timeout}]
      assert unknown_entries("1 / 0 > 1 || y > 1") == [{{:var, "y"}, :missing}]
      assert unknown_entries("[0, 1].exists(i, 1 / i > 1 || i == x)") == [{{:var, "x"}, :timeout}]
    end
  end

  describe "custom functions" do
    test "may return an unknown attributed to the call" do
      assert {:unknown, unknown} = eval(~s|lookup("missing") > 1|)
      assert [{{:call, "lookup", expr_id}, :not_fetched}] = Unknown.entries(unknown)
      assert is_integer(expr_id)

      assert eval(~s{lookup("missing") > 1 || lookup("abc") == 3}) == {:ok, Value.bool(true)}
    end

    test "are not run with an unknown argument" do
      assert unknown_entries("twice(x) > 0") == [{{:var, "x"}, :timeout}]
      refute_received {:twice_called, _value}
    end
  end

  test "optional or and orValue evaluate the alternative only for an empty receiver" do
    assert eval("optional.of(1).orValue(x)") == {:ok, Value.int(1)}
    assert eval("optional.of(1).or(optional.of(x)).value()") == {:ok, Value.int(1)}
    assert eval("optional.of(1).orValue(1 / 0)") == {:ok, Value.int(1)}

    assert unknown_entries("optional.none().orValue(x)") == [{{:var, "x"}, :timeout}]

    assert unknown_entries("optional.none().or(optional.of(x)).value()") == [
             {{:var, "x"}, :timeout}
           ]

    assert {:error, %Error{message: "division by zero"}} = eval("optional.none().orValue(1 / 0)")
    assert {:error, %Error{message: "no such overload"}} = eval("dyn(1).orValue(2)")
  end

  test "an unknown result can be bound as an input" do
    assert {:unknown, unknown} = eval("x < 30 && y > 1")

    assert {:unknown, ^unknown} = CEL.eval("p || false", %{p: unknown}, env())
  end

  test "eval! raises on an unknown result" do
    assert_raise Error, "result is unknown", fn ->
      CEL.eval!("x > 1", %{x: {:unknown, :t}}, env())
    end

    error = catch_error(CEL.eval!("x > 1", %{x: {:unknown, :t}}, env()))
    assert %Error{phase: :eval, details: %{unknown: %Unknown{}}} = error
  end

  test "unknown sets merge independently of operand order" do
    operands = ["x > 0", "y > 0", "1 / 0 > 0", "true", "false"]

    for left <- operands, right <- operands, template <- ["(~l) && (~r)", "(~l) || (~r)"] do
      forward = eval(template |> String.replace("~l", left) |> String.replace("~r", right))
      backward = eval(template |> String.replace("~l", right) |> String.replace("~r", left))

      case forward do
        {:error, _error} -> assert match?({:error, _error}, backward)
        result -> assert result == backward, "#{left} / #{right} in #{template}"
      end
    end

    for left <- ["x", "y", "1"], right <- ["x", "y", "2"] do
      forward = eval("[#{left}, #{right}].size() == 2")
      backward = eval("[#{right}, #{left}].size() == 2")
      assert forward == backward
    end
  end
end
