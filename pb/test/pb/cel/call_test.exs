defmodule PB.CEL.CallTest do
  use ExUnit.Case, async: true

  alias PB.CEL.Call
  alias PB.CEL.Env

  test "classifies namespace calls without treating the namespace as a value target" do
    call =
      %{
        function: "quote",
        target: %{expr_kind: {:ident_expr, %{name: "strings"}}},
        args: [%{id: 1}]
      }
      |> classify()

    assert call.shape == {:namespace, "strings"}
    assert call.function == "quote"
    assert call.target == nil
    assert call.args == [%{id: 1}]
    assert Call.reference_name(call) == "strings.quote"
  end

  test "classifies receiver calls separately from ordinary global calls" do
    target = %{expr_kind: {:ident_expr, %{name: "value"}}}

    receiver =
      %{
        function: "startsWith",
        target: target,
        args: [%{id: 1}]
      }
      |> classify()

    global = classify(%{function: "matches", args: [%{id: 1}, %{id: 2}]})

    assert receiver.shape == :receiver
    assert receiver.target == target
    assert Call.receiver?(receiver)

    assert global.shape == :global
    refute Call.receiver?(global)
  end

  test "classifies operators as intrinsics" do
    call = classify(%{function: "_&&_", args: [%{id: 1}, %{id: 2}]})

    assert call.shape == :intrinsic
    assert Call.reference_name(call) == "_&&_"
  end

  defp classify(call), do: Call.classify(call, namespaces: Env.namespaces(Env.from_options([])))
end
