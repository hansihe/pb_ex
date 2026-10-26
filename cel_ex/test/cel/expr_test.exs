defmodule CEL.ExprTest do
  use ExUnit.Case, async: true

  alias CEL.Checked
  alias CEL.Expr
  alias CEL.Expr.Call
  alias CEL.Expr.Comprehension
  alias CEL.Expr.Const
  alias CEL.Expr.Ident
  alias CEL.Expr.ListLiteral
  alias CEL.Expr.MacroCall
  alias CEL.Expr.MapLiteral
  alias CEL.Expr.Select
  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.TestSupport.StringTypes

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
      vars: [
        req: {:map, :string, :dyn},
        user: {:map, :string, :string},
        l: {:list, :int},
        m: {:map, :string, :int}
      ],
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

  test "represents an enum constructor as a call to the enum's full name" do
    env = CEL.Env.build(types: {StringTypes, nil}, container: "test")

    assert %Call{
             function: "test.E",
             overload_id: "enum_constructor",
             target: nil,
             args: [%Const{value: {:int, 1}}]
           } = "E(1)" |> CEL.check!(env) |> Checked.expr()
  end

  test "represents cel.bind and optMap as macro calls binding a local" do
    assert %MacroCall{
             expansion: nil,
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

    assert %MacroCall{
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

  test "represents macros as written, with their expansion alongside" do
    assert %MacroCall{
             function: "exists",
             type: :bool,
             target: %Ident{name: "l", scope: :var},
             args: [
               %Ident{name: "i", scope: :local, type: :int},
               %Call{function: "_>_", args: [%Ident{name: "i", scope: :local}, _one]}
             ],
             expansion: %Comprehension{
               iter_var: "i",
               iter_var2: nil,
               iter_range: %Ident{name: "l", scope: :var},
               accu_var: "__result__",
               loop_step: %Call{function: "_||_"},
               result: %Ident{name: "__result__", scope: :local}
             }
           } = expr("l.exists(i, i > 1)")

    assert %MacroCall{
             function: "all",
             args: [%Ident{name: "k", type: :string}, %Ident{name: "v", type: :int}, _pred]
           } = expr("m.all(k, v, v > 0)")

    assert %MacroCall{
             function: "map",
             args: [
               %Ident{name: "i"},
               %MacroCall{function: "exists", target: %Ident{name: "l"}},
               %Call{function: "_*_"}
             ]
           } = expr("l.map(i, l.exists(j, j == i), i * 2)")

    assert [%Call{function: "_>_"}] =
             Expr.filter(expr("l.exists(i, i > 1)"), &match?(%Call{}, &1))
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
end
