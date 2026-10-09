defmodule PB.CEL.ExprTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Checked
  alias PB.CEL.Expr
  alias PB.CEL.Expr.Call
  alias PB.CEL.Expr.Comprehension
  alias PB.CEL.Expr.Const
  alias PB.CEL.Expr.Ident
  alias PB.CEL.Expr.ListLiteral
  alias PB.CEL.Expr.MapLiteral
  alias PB.CEL.Expr.Select
  alias PB.CEL.Function
  alias PB.CEL.Function.Overload
  alias PB.TestSupport.CELConformance

  defp env do
    default = %Function{
      name: "default",
      overloads: [%Overload{id: "default_int", args: [:int, :int], result: :int, strict: false}]
    }

    lookup = %Function{
      name: "lookup",
      overloads: [%Overload{id: "lookup_string", args: [:string], result: :int}]
    }

    CEL.Env.build(
      vars: [req: {:map, :string, :dyn}, user: {:map, :string, :string}, l: {:list, :int}],
      functions: [default, lookup]
    )
  end

  defp expr(source), do: source |> CEL.check!(env()) |> Checked.expr()

  test "represents operators, selects, identifiers and constants" do
    assert %Call{
             function: "_>_",
             type: :bool,
             target: nil,
             args: [
               %Select{
                 field: "id",
                 type: :dyn,
                 operand: %Select{
                   field: "user",
                   operand: %Ident{name: "req", scope: :var, type: {:map, :string, :dyn}}
                 }
               },
               %Const{value: {:int, 1}, type: :int}
             ]
           } = expr("req.user.id > 1")

    assert %Call{
             function: "_&&_",
             args: [%Select{field: "a", test_only: true}, %Select{field: "b", test_only: false}]
           } = expr("has(req.a) && req.b")

    assert %Select{field: "name", optional: true, type: {:optional, :string}} = expr("user.?name")
    assert %Ident{name: "int", scope: :type} = expr("type(1) == int").args |> List.last()
  end

  test "represents cel.bind and optMap as calls binding a local" do
    assert %Call{
             function: "cel.bind",
             args: [
               %Ident{name: "u", scope: :local, type: :dyn, id: var_id},
               %Select{field: "user"},
               %Call{
                 function: "_==_",
                 args: [%Select{operand: %Ident{name: "u", scope: :local}}, _one]
               }
             ]
           } = expr("cel.bind(u, req.user, u.id == 1)")

    assert is_integer(var_id)

    assert %Call{
             function: "optMap",
             target: %Select{field: "name", optional: true},
             args: [%Ident{name: "n", scope: :local, type: :string}, %Call{function: "_+_"}]
           } = expr("user.?name.optMap(n, n + '!')")
  end

  test "represents literals" do
    assert %ListLiteral{
             elements: [%Const{}, %Call{function: "optional.none"}],
             optional_indices: [1]
           } =
             expr("[1, ?optional.none()]")

    assert %MapLiteral{
             entries: [%{key: %Const{value: {:string, "a"}}, value: %Const{}, optional: false}]
           } =
             expr("{'a': 1}")
  end

  test "represents macros as comprehensions" do
    assert %Comprehension{
             iter_var: "i",
             iter_var2: nil,
             iter_range: %Ident{name: "l", scope: :var},
             accu_var: "__result__",
             loop_step: %Call{function: "_||_"},
             result: %Ident{name: "__result__", scope: :local}
           } = expr("l.exists(i, i > 1)")
  end

  test "children, reduce and filter visit nodes in evaluation order" do
    tree = expr(~s{default(lookup("risk"), 0) + 1})

    assert [%Call{function: "default", args: [first, %Const{value: {:int, 0}}]}] =
             Expr.filter(tree, &match?(%Call{function: "default"}, &1))

    assert %Call{function: "lookup", args: [%Const{value: {:string, "risk"}}]} = first

    assert tree |> Expr.reduce([], &[&1.__struct__ | &2]) |> Enum.reverse() ==
             [Call, Call, Call, Const, Const, Const]

    assert [%Call{function: "default"}, %Const{value: {:int, 1}}] = Expr.children(tree)
  end

  test "covers every checked operation of the conformance expressions" do
    for case <- CELConformance.supported_check_cases() do
      {:ok, parsed} = CEL.parse(case.expr, CELConformance.parse_opts(case))
      {:ok, env} = CELConformance.check_env(case)
      {:ok, checked} = CEL.check(parsed, env)

      tree = Checked.expr(checked)
      ids = Expr.reduce(tree, MapSet.new(), &MapSet.put(&2, &1.id))

      # `x.?field` parses as `_?._(x, "field")`; the field name constant is not
      # evaluated and appears only as `Select.field`.
      optional_fields =
        for %Select{optional: true, field: field} <- Expr.filter(tree, &match?(%Select{}, &1)),
            do: {:const, %{value: {:string, field}}}

      missing = checked.ops |> Map.drop(MapSet.to_list(ids)) |> Map.values()

      assert Enum.all?(missing, &(&1 in optional_fields)),
             "#{case.fixture}/#{case.section}/#{case.name}: #{case.expr}"

      assert %{vars: _vars, calls: _calls} = Checked.references(checked)
    end
  end
end
