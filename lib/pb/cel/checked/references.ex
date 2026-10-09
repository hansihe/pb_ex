defmodule PB.CEL.Checked.References do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # Derives what a checked expression reads: variable field paths and function
  # calls with their constant arguments. Use it through
  # `PB.CEL.Checked.references/1`.
  #
  # A variable read is the longest field selection rooted at a variable, so
  # `req.user.id` is one read with path `["user", "id"]`, not three. Locals are
  # resolved to what they stand for: a `cel.bind` variable to its value, and a
  # comprehension variable to its range followed by `"*"` for "any element",
  # so `l.exists(i, i.score > 1)` reads `l` and `l.*.score`. Locals bound to
  # anything other than a variable read are not reported.
  #
  # Operators (`_==_`, `@in`, ...) are not reported as calls.
  @moduledoc false

  alias PB.CEL.Call
  alias PB.CEL.Checked

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
  def collect(%Checked{expr: expr} = checked) do
    %{vars: vars, calls: calls} = walk(expr.id, %{}, checked, %{vars: [], calls: []})
    %{vars: Enum.reverse(vars), calls: Enum.reverse(calls)}
  end

  defp walk(nil, _locals, _checked, acc), do: acc

  defp walk(id, locals, checked, acc) do
    case resolve(id, locals, checked) do
      {:ok, name, path} -> add(acc, :vars, %{name: name, path: path, expr_id: id})
      :error -> walk_op(id, Checked.op(checked, id), locals, checked, acc)
    end
  end

  defp walk_op(_id, {:select, %{receiver_id: receiver_id}}, locals, checked, acc) do
    walk(receiver_id, locals, checked, acc)
  end

  defp walk_op(id, {:call, %{name: name} = op}, locals, checked, acc) do
    acc =
      if Call.intrinsic?(name) do
        acc
      else
        add(acc, :calls, %{
          function: name,
          overload_id: op.overload_id,
          expr_id: id,
          target: op.target_id && arg(op.target_id, locals, checked),
          args: Enum.map(op.arg_ids, &arg(&1, locals, checked))
        })
      end

    walk_all([op.target_id | op.arg_ids], locals, checked, acc)
  end

  defp walk_op(
         _id,
         {:special, %{kind: :bind, arg_ids: [init_id, body_id], var: var}},
         locals,
         checked,
         acc
       ) do
    acc = walk(init_id, locals, checked, acc)
    walk(body_id, bind_local(locals, var, resolve(init_id, locals, checked)), checked, acc)
  end

  defp walk_op(_id, {:special, %{kind: kind} = op}, locals, checked, acc)
       when kind in [:optional_map, :optional_flat_map] do
    %{target_id: target_id, arg_ids: [_var_id, body_id], var: var} = op
    acc = walk(target_id, locals, checked, acc)
    walk(body_id, bind_local(locals, var, resolve(target_id, locals, checked)), checked, acc)
  end

  defp walk_op(_id, {:special, op}, locals, checked, acc) do
    walk_all([Map.get(op, :target_id) | op.arg_ids], locals, checked, acc)
  end

  defp walk_op(_id, {:comprehension, op}, locals, checked, acc) do
    acc = walk(op.iter_range_id, locals, checked, acc)

    element =
      case resolve(op.iter_range_id, locals, checked) do
        {:ok, name, path} -> {:ok, name, path ++ ["*"]}
        :error -> :error
      end

    inner =
      locals
      |> bind_local(op.iter_var, element)
      |> bind_local(op.iter_var2, element)
      |> bind_local(op.accu_var, :error)

    acc = walk(op.accu_init_id, locals, checked, acc)
    walk_all([op.loop_condition_id, op.loop_step_id, op.result_id], inner, checked, acc)
  end

  defp walk_op(_id, {:list, %{elem_ids: elem_ids}}, locals, checked, acc) do
    walk_all(elem_ids, locals, checked, acc)
  end

  defp walk_op(_id, {:map, %{entries: entries}}, locals, checked, acc) do
    ids = Enum.flat_map(entries, &[&1.key_id, &1.value_id])
    walk_all(ids, locals, checked, acc)
  end

  defp walk_op(_id, {:message_literal, %{fields: fields}}, locals, checked, acc) do
    walk_all(Enum.map(fields, & &1.value_id), locals, checked, acc)
  end

  defp walk_op(_id, _op, _locals, _checked, acc), do: acc

  defp walk_all(ids, locals, checked, acc) do
    Enum.reduce(ids, acc, &walk(&1, locals, checked, &2))
  end

  defp resolve(id, locals, checked) do
    case Checked.op(checked, id) do
      {:ident, %{kind: :var, name: name}} ->
        {:ok, name, []}

      {:ident, %{kind: :local, name: name}} ->
        Map.get(locals, name, :error)

      {:select, %{receiver_id: receiver_id, field: field}} ->
        case resolve(receiver_id, locals, checked) do
          {:ok, name, path} -> {:ok, name, path ++ [field]}
          :error -> :error
        end

      _op ->
        :error
    end
  end

  defp arg(id, locals, checked) do
    case {Checked.op(checked, id), resolve(id, locals, checked)} do
      {{:const, %{value: value}}, _resolved} -> {:const, value}
      {_op, {:ok, name, path}} -> {:var, name, path}
      {_op, :error} -> :dynamic
    end
  end

  defp bind_local(locals, "", _resolved), do: locals
  defp bind_local(locals, name, resolved), do: Map.put(locals, name, resolved)

  defp add(acc, key, item), do: Map.update!(acc, key, &[item | &1])
end
