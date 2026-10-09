defmodule PB.CEL.Expr do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # A read-only view of a checked CEL expression, in the spirit of cel-go's
  # `common/ast`. Get one with `PB.CEL.Checked.expr/1`.
  #
  # The view is a tree of node structs, each with the expression `id` and its
  # checked `type`:
  #
  #   * `Const` — a literal value.
  #   * `Ident` — a name; `scope` is `:var` for a declared variable, `:local`
  #     for a comprehension or `cel.bind` variable, `:type` for a type name and
  #     `:enum` for an enum value.
  #   * `Select` — `operand.field`; `test_only` for `has(...)`, `optional` for
  #     `operand.?field`.
  #   * `Call` — a function call, including operators (`_==_`, `_&&_`,
  #     `_?_:_`, `@in`, ...), `cel.bind(var, init, body)` and
  #     `target.optMap(var, body)`.
  #   * `ListLiteral`, `MapLiteral` and `MessageLiteral`.
  #   * `Comprehension` — the expansion of a macro such as `exists` or `map`.
  #
  # Types use the same shorthand as `PB.CEL.Env.build/1` variables (`:int`,
  # `{:list, :string}`, `{:message, name}`, ...), plus `{:wrapper, primitive}`,
  # `{:type, type}` and `{:abstract, name, params}`. A node the checker did not
  # type, such as a bound variable name, has type `nil`.
  #
  # Match on the structs to inspect the tree, and use `reduce/3` or `filter/2`
  # to search it:
  #
  #     checked |> PB.CEL.Checked.expr() |> PB.CEL.Expr.filter(&match?(%Call{function: "default"}, &1))
  #
  # The view is derived from the checked expression; evaluation does not read
  # it, so it stays stable as the evaluator changes.
  @moduledoc false

  alias PB.CEL.Checked
  alias PB.CEL.Checker.Types, as: CType

  defmodule Const do
    @moduledoc false
    defstruct [:id, :type, :value]
  end

  defmodule Ident do
    @moduledoc false
    defstruct [:id, :type, :name, :scope]
  end

  defmodule Select do
    @moduledoc false
    defstruct [:id, :type, :operand, :field, test_only: false, optional: false]
  end

  defmodule Call do
    @moduledoc false
    defstruct [:id, :type, :function, :overload_id, :target, args: []]
  end

  defmodule ListLiteral do
    @moduledoc false
    defstruct [:id, :type, elements: [], optional_indices: []]
  end

  defmodule MapLiteral do
    @moduledoc false
    defstruct [:id, :type, entries: []]
  end

  defmodule MessageLiteral do
    @moduledoc false
    defstruct [:id, :type, :message, fields: []]
  end

  defmodule Comprehension do
    @moduledoc false
    defstruct [
      :id,
      :type,
      :iter_var,
      :iter_var2,
      :iter_range,
      :accu_var,
      :accu_init,
      :loop_condition,
      :loop_step,
      :result
    ]
  end

  @type type :: CType.t() | nil
  @type t ::
          %Const{id: Checked.expr_id(), type: type, value: PB.CEL.Value.t()}
          | %Ident{id: Checked.expr_id(), type: type, name: String.t(), scope: scope}
          | %Select{
              id: Checked.expr_id(),
              type: type,
              operand: t,
              field: String.t(),
              test_only: boolean,
              optional: boolean
            }
          | %Call{
              id: Checked.expr_id(),
              type: type,
              function: String.t(),
              overload_id: String.t() | nil,
              target: t | nil,
              args: [t]
            }
          | %ListLiteral{
              id: Checked.expr_id(),
              type: type,
              elements: [t],
              optional_indices: [non_neg_integer]
            }
          | %MapLiteral{id: Checked.expr_id(), type: type, entries: [map_entry]}
          | %MessageLiteral{
              id: Checked.expr_id(),
              type: type,
              message: String.t(),
              fields: [message_field]
            }
          | %Comprehension{
              id: Checked.expr_id(),
              type: type,
              iter_var: String.t(),
              iter_var2: String.t() | nil,
              iter_range: t,
              accu_var: String.t(),
              accu_init: t,
              loop_condition: t,
              loop_step: t,
              result: t
            }
  @type scope :: :var | :local | :type | :enum
  @type map_entry :: %{key: t, value: t, optional: boolean}
  @type message_field :: %{field: String.t(), value: t, optional: boolean}

  @optional_selects [:optional_field, :optional_map_field, :optional_dyn_field]

  @doc """
  Builds the view of a checked expression.
  """
  @spec from_checked(Checked.t()) :: t
  def from_checked(%Checked{expr: expr} = checked), do: node(expr.id, checked)

  @doc """
  Returns the direct children of a node in evaluation order.
  """
  @spec children(t) :: [t]
  def children(%Const{}), do: []
  def children(%Ident{}), do: []
  def children(%Select{operand: operand}), do: [operand]
  def children(%Call{target: nil, args: args}), do: args
  def children(%Call{target: target, args: args}), do: [target | args]
  def children(%ListLiteral{elements: elements}), do: elements
  def children(%MapLiteral{entries: entries}), do: Enum.flat_map(entries, &[&1.key, &1.value])
  def children(%MessageLiteral{fields: fields}), do: Enum.map(fields, & &1.value)

  def children(%Comprehension{} = comprehension) do
    [
      comprehension.iter_range,
      comprehension.accu_init,
      comprehension.loop_condition,
      comprehension.loop_step,
      comprehension.result
    ]
  end

  @doc """
  Folds `fun` over a node and its descendants, visiting each node before its
  children.
  """
  @spec reduce(t, acc, (t, acc -> acc)) :: acc when acc: term
  def reduce(node, acc, fun) do
    node |> children() |> Enum.reduce(fun.(node, acc), &reduce(&1, &2, fun))
  end

  @doc """
  Returns the nodes, in visiting order, for which `fun` returns a truthy value.
  """
  @spec filter(t, (t -> as_boolean(term))) :: [t]
  def filter(node, fun) do
    node
    |> reduce([], fn node, acc -> if fun.(node), do: [node | acc], else: acc end)
    |> Enum.reverse()
  end

  defp node(id, checked) do
    build(id, Checked.op(checked, id), node_type(id, checked), checked)
  end

  defp build(id, {:const, %{value: value}}, type, _checked) do
    %Const{id: id, type: type, value: value}
  end

  defp build(id, {:ident, %{kind: kind, name: name}}, type, _checked) do
    %Ident{id: id, type: type, name: name, scope: ident_scope(kind)}
  end

  defp build(id, {:select, op}, type, checked) do
    %Select{
      id: id,
      type: type,
      operand: node(op.receiver_id, checked),
      field: op.field,
      test_only: op.test_only,
      optional: op.kind in @optional_selects
    }
  end

  defp build(id, {:call, op}, type, checked) do
    %Call{
      id: id,
      type: type,
      function: op.name,
      overload_id: op.overload_id,
      target: op.target_id && node(op.target_id, checked),
      args: Enum.map(op.arg_ids, &node(&1, checked))
    }
  end

  defp build(id, {:special, %{kind: :bind} = op}, type, checked) do
    [init_id, body_id] = op.arg_ids
    var = %Ident{id: op.var_id, type: node_type(init_id, checked), name: op.var, scope: :local}

    %Call{
      id: id,
      type: type,
      function: "cel.bind",
      overload_id: op.overload_id,
      args: [var, node(init_id, checked), node(body_id, checked)]
    }
  end

  defp build(id, {:special, %{kind: kind} = op}, type, checked)
       when kind in [:optional_map, :optional_flat_map] do
    [var_id, body_id] = op.arg_ids

    var_type =
      case node_type(op.target_id, checked) do
        {:optional, value_type} -> value_type
        _type -> :dyn
      end

    var = %Ident{id: var_id, type: var_type, name: op.var, scope: :local}

    %Call{
      id: id,
      type: type,
      function: op.name,
      overload_id: op.overload_id,
      target: node(op.target_id, checked),
      args: [var, node(body_id, checked)]
    }
  end

  defp build(id, {:special, op}, type, checked) do
    %Call{
      id: id,
      type: type,
      function: op.name,
      overload_id: op.overload_id,
      target: op.target_id && node(op.target_id, checked),
      args: Enum.map(op.arg_ids, &node(&1, checked))
    }
  end

  defp build(id, {:list, op}, type, checked) do
    %ListLiteral{
      id: id,
      type: type,
      elements: Enum.map(op.elem_ids, &node(&1, checked)),
      optional_indices: op.optional_indices |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp build(id, {:map, %{entries: entries}}, type, checked) do
    entries =
      Enum.map(entries, fn entry ->
        %{
          key: node(entry.key_id, checked),
          value: node(entry.value_id, checked),
          optional: entry.optional?
        }
      end)

    %MapLiteral{id: id, type: type, entries: entries}
  end

  defp build(id, {:message_literal, op}, type, checked) do
    fields =
      Enum.map(op.fields, fn field ->
        %{
          field: to_string(field.field),
          value: node(field.value_id, checked),
          optional: field.optional?
        }
      end)

    %MessageLiteral{id: id, type: type, message: to_string(op.message), fields: fields}
  end

  defp build(id, {:comprehension, op}, type, checked) do
    %Comprehension{
      id: id,
      type: type,
      iter_var: op.iter_var,
      iter_var2: if(op.iter_var2 == "", do: nil, else: op.iter_var2),
      iter_range: node(op.iter_range_id, checked),
      accu_var: op.accu_var,
      accu_init: node(op.accu_init_id, checked),
      loop_condition: node(op.loop_condition_id, checked),
      loop_step: node(op.loop_step_id, checked),
      result: node(op.result_id, checked)
    }
  end

  defp ident_scope(:var), do: :var
  defp ident_scope(:local), do: :local
  defp ident_scope(:type), do: :type
  defp ident_scope(:enum_value), do: :enum

  defp node_type(id, %Checked{types: types}) do
    case Map.fetch(types, id) do
      {:ok, type} -> CType.finalize(type)
      :error -> nil
    end
  end
end
