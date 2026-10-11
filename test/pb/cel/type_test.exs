defmodule PB.CEL.TypeTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Expr

  doctest PB.CEL.Type

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

  test "an id the checker did not type has no type" do
    checked = CEL.check!("[1].all(x, x > 0)")
    assert CEL.Checked.type(checked, 999_999) == nil
  end
end
