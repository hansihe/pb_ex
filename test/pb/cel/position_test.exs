defmodule PB.CEL.PositionTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Checked
  alias PB.CEL.Env
  alias PB.CEL.Error
  alias PB.CEL.Expr

  defp env, do: Env.build(vars: [x: :int, l: {:list, :int}])

  test "line_offsets follow cel-go and cel-cpp: line starts, then length plus one" do
    # cel-go's TestStringSource_LocationOffset
    source = "c.d &&\n\t b.c.arg(10) &&\n\t test(10)"

    assert CEL.parse!(source).source_info.line_offsets == [7, 24, 35]
    assert CEL.parse!("x").source_info.line_offsets == [2]
  end

  test "position/2 counts code points and gives 1-based lines and columns" do
    checked = CEL.check!(~s|"é" + "€"\n  + string(x)|, env())

    assert %Expr.Call{function: "_+_", args: [concat, call]} = Checked.expr(checked)
    assert %Expr.Call{args: [_e_acute, euro]} = concat

    assert Checked.position(checked, euro.id) == %{offset: 6, line: 1, column: 7}
    assert Checked.position(checked, call.id) == %{offset: 14, line: 2, column: 5}
    assert Checked.position(checked, checked.expr.id) == %{offset: 12, line: 2, column: 3}
  end

  test "a macro's expansion shares its position" do
    checked = CEL.check!("1 == 1 &&\n l.exists(i, i > 0)", env())

    assert %Expr.Call{args: [_eq, %Expr.MacroCall{} = macro]} = Checked.expr(checked)
    assert Checked.position(checked, macro.id) == %{offset: 12, line: 2, column: 3}
    %Expr.Comprehension{accu_init: init, loop_step: step} = macro.expansion

    for node <- [init, step] do
      assert Checked.position(checked, node.id) == Checked.position(checked, macro.id)
    end
  end

  test "position/2 is nil for an expression without one" do
    checked = CEL.check!("x", env())
    assert Checked.position(checked, 999) == nil
  end

  test "parse errors carry line, column and location" do
    assert {:error, %Error{phase: :parse} = error} =
             CEL.parse(~s|"é" +\n )|, location: "rules/a.cel")

    assert %{offset: 7, line: 2, column: 2, location: "rules/a.cel"} = error
    assert Exception.message(error) == "expected expression at line 2, column 2"

    assert {:error, %Error{line: 2, column: 2, location: "<input>"}} = CEL.parse(~s|1 +\n "|)
  end
end
