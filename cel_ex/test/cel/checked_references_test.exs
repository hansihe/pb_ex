defmodule CEL.CheckedReferencesTest do
  use ExUnit.Case, async: true

  alias CEL.Checked
  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.Value

  defp env do
    udf = %Function{
      name: "udf",
      overloads: [%Overload{id: "udf_string", args: [:string], result: :int}]
    }

    has_label = %Function{
      name: "hasLabel",
      modes: [:receiver],
      overloads: [%Overload{id: "has_label", args: [:dyn, :string], result: :bool}]
    }

    CEL.Env.build(
      vars: [
        req: {:map, :string, :dyn},
        user: {:map, :string, :string},
        l: {:list, {:map, :string, :int}},
        "a.b": :int
      ],
      functions: [udf, has_label]
    )
  end

  defp references(source), do: source |> CEL.check!(env()) |> Checked.references()

  defp reads(source) do
    for %{name: name, path: path} <- references(source).vars, do: {name, path}
  end

  test "reports the longest field selection rooted at a variable" do
    assert reads("req.user.id > 1 && a.b > 0") == [{"req", ["user", "id"]}, {"a.b", []}]
    assert reads("has(req.user.email)") == [{"req", ["user", "email"]}]

    assert reads("req.user.id + req.user.age > 0") == [
             {"req", ["user", "id"]},
             {"req", ["user", "age"]}
           ]
  end

  test "resolves comprehension variables to any element of their range" do
    assert reads("l.exists(i, i.score > 1)") == [{"l", []}, {"l", ["*", "score"]}]
    assert reads("[1, 2].map(x, x + req.n).size() > 0") == [{"req", ["n"]}]
  end

  test "resolves bound variables to their value" do
    assert reads("cel.bind(u, req.user, u.id == 1)") ==
             [{"req", ["user"]}, {"req", ["user", "id"]}]

    assert reads("user.?name.optMap(n, n + '!').orValue('') == ''") ==
             [{"user", ["name"]}, {"user", ["name"]}]
  end

  test "reports non-operator calls with constant and variable arguments" do
    assert [udf] = references(~s|udf("risk_score") > 50|).calls

    assert %{function: "udf", overload_id: "udf_string", target: nil} = udf
    assert udf.args == [{:const, Value.string("risk_score")}]
    assert is_integer(udf.expr_id)

    assert [%{args: [{:var, "user", ["kind"]}]}] = references("udf(user.kind) > 1").calls

    assert [%{function: "hasLabel", target: {:var, "req", ["user"]}, args: [{:const, _vip}]}] =
             references("req.user.hasLabel('vip')").calls

    assert [%{function: "size", target: :dynamic}] =
             references("[1, 2].map(x, x * 2).size() > 0").calls
  end
end
