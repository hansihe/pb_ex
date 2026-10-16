defmodule PB.CEL.ExprTest do
  # CEL.Expr over the conformance expressions, which need PB's schemas; the
  # rest of CEL's expression view tests are cel_ex's.
  use ExUnit.Case, async: true

  alias CEL.Checked
  alias CEL.Expr
  alias CEL.Expr.Comprehension
  alias CEL.Expr.MacroCall
  alias CEL.Expr.Select
  alias PB.TestSupport.CELConformance

  test "covers every checked operation of the conformance expressions" do
    for case <- CELConformance.supported_check_cases() do
      {:ok, parsed} = CEL.parse(case.expr, CELConformance.parse_opts(case))
      {:ok, env} = CELConformance.check_env(case)
      {:ok, checked} = CEL.check(parsed, env)

      tree = Checked.expr(checked)
      ids = node_ids(tree)

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

  # Every id in the tree, including those only in macro expansions.
  defp node_ids(tree) do
    Expr.reduce(tree, MapSet.new(), fn
      %MacroCall{id: id, expansion: %Comprehension{} = expansion}, ids ->
        ids |> MapSet.put(id) |> MapSet.union(node_ids(expansion))

      node, ids ->
        MapSet.put(ids, node.id)
    end)
  end
end
