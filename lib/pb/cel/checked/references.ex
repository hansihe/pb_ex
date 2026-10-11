defmodule PB.CEL.Checked.References do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Derives what a checked expression reads: variable field paths and function
  # calls with their constant arguments, built on the `PB.CEL.Expr` view. Use
  # it through `PB.CEL.Checked.references/1`.
  #
  # A variable read is the longest field selection rooted at a variable, so
  # `req.user.id` is one read with path `["user", "id"]`, not three. Locals are
  # resolved to what they stand for: a `cel.bind` or `optMap` variable to its
  # value, and a comprehension variable to its range followed by `"*"` for
  # "any element", so `l.exists(i, i.score > 1)` reads `l` and `l.*.score`.
  # Locals bound to anything other than a variable read are not reported.
  #
  # Operators (`_==_`, `@in`, ...), `cel.bind`, `optMap` and enum constructors
  # are not reported as calls.
  @moduledoc false

  alias PB.CEL.Checked
  alias PB.CEL.Expr
  alias PB.CEL.Expr.Call
  alias PB.CEL.Expr.Comprehension
  alias PB.CEL.Expr.Const
  alias PB.CEL.Expr.Ident
  alias PB.CEL.Expr.MacroCall
  alias PB.CEL.Expr.Select

  @type expr_id :: Checked.expr_id()
  @type var_read :: %{name: String.t(), path: [String.t()], expr_id: expr_id}
  @type arg :: {:const, PB.CEL.Value.t()} | {:var, String.t(), [String.t()]} | :dynamic
  @type call :: %{
          function: String.t(),
          overload_id: String.t(),
          expr_id: expr_id,
          target: arg | nil,
          args: [arg]
        }
  @type t :: %{vars: [var_read], calls: [call]}

  @spec collect(Checked.t()) :: t
  def collect(%Checked{} = checked) do
    %{vars: vars, calls: calls} = walk(Expr.from_checked(checked), %{}, %{vars: [], calls: []})
    %{vars: Enum.reverse(vars), calls: Enum.reverse(calls)}
  end

  defp walk(node, locals, acc) do
    case resolve(node, locals) do
      {:ok, name, path} -> add(acc, :vars, %{name: name, path: path, expr_id: node.id})
      :error -> walk_node(node, locals, acc)
    end
  end

  # A comprehension macro is walked as its expansion, which says what each
  # variable ranges over.
  defp walk_node(%MacroCall{expansion: %Comprehension{} = expansion}, locals, acc),
    do: walk_node(expansion, locals, acc)

  # `cel.bind(var, init, body)` and `target.optMap(var, body)` bind `var`
  # in `body` to the value before it.
  defp walk_node(%MacroCall{} = call, locals, acc) do
    {value, var, body} =
      case call do
        %MacroCall{target: nil, args: [var, init, body]} -> {init, var, body}
        %MacroCall{target: target, args: [var, body]} -> {target, var, body}
      end

    acc = walk(value, locals, acc)
    walk(body, bind_local(locals, var.name, resolve(value, locals)), acc)
  end

  defp walk_node(%Call{} = call, locals, acc) do
    acc =
      if PB.CEL.Call.intrinsic?(call.function) or call.overload_id == "enum_constructor" do
        acc
      else
        add(acc, :calls, %{
          function: call.function,
          overload_id: call.overload_id,
          expr_id: call.id,
          target: call.target && arg(call.target, locals),
          args: Enum.map(call.args, &arg(&1, locals))
        })
      end

    walk_all(Expr.children(call), locals, acc)
  end

  defp walk_node(%Comprehension{} = comprehension, locals, acc) do
    acc = walk(comprehension.iter_range, locals, acc)

    element =
      case resolve(comprehension.iter_range, locals) do
        {:ok, name, path} -> {:ok, name, path ++ ["*"]}
        :error -> :error
      end

    inner =
      locals
      |> bind_local(comprehension.iter_var, element)
      |> bind_local(comprehension.iter_var2, element)
      |> bind_local(comprehension.accu_var, :error)

    acc = walk(comprehension.accu_init, locals, acc)

    walk_all(
      [comprehension.loop_condition, comprehension.loop_step, comprehension.result],
      inner,
      acc
    )
  end

  defp walk_node(node, locals, acc), do: walk_all(Expr.children(node), locals, acc)

  defp walk_all(nodes, locals, acc), do: Enum.reduce(nodes, acc, &walk(&1, locals, &2))

  defp resolve(%Ident{scope: :var, name: name}, _locals), do: {:ok, name, []}
  defp resolve(%Ident{scope: :local, name: name}, locals), do: Map.get(locals, name, :error)

  defp resolve(%Select{operand: operand, field: field}, locals) do
    case resolve(operand, locals) do
      {:ok, name, path} -> {:ok, name, path ++ [field]}
      :error -> :error
    end
  end

  defp resolve(_node, _locals), do: :error

  defp arg(%Const{value: value}, _locals), do: {:const, value}

  defp arg(node, locals) do
    case resolve(node, locals) do
      {:ok, name, path} -> {:var, name, path}
      :error -> :dynamic
    end
  end

  defp bind_local(locals, nil, _resolved), do: locals
  defp bind_local(locals, name, resolved), do: Map.put(locals, name, resolved)

  defp add(acc, key, item), do: Map.update!(acc, key, &[item | &1])
end
