defmodule CEL.Expr do
  @moduledoc """
  A read-only view of a checked CEL expression, in the spirit of cel-go's
  `common/ast`. Get one with `CEL.Checked.expr/1`.

  The view is a tree of node structs, each with the expression's `id` and its
  checked `type` (a `t:CEL.Type.t/0`, or `nil` for a node the checker did
  not type):

    * `CEL.Expr.Const` — a literal.
    * `CEL.Expr.Ident` — a variable, type or enum value, by full name.
    * `CEL.Expr.Select` — `operand.field`, `has(operand.field)` and
      `operand.?field`.
    * `CEL.Expr.Call` — a function call, operator or enum constructor.
    * `CEL.Expr.MacroCall` — a macro as written, such as `l.exists(x, p)`
      or `cel.bind(v, init, body)`.
    * `CEL.Expr.ListLiteral`, `CEL.Expr.MapLiteral` and
      `CEL.Expr.MessageLiteral`.
    * `CEL.Expr.Comprehension` — the loop a macro expands to.

  `id` is the one `CEL.Checked.type/2`, `CEL.Checked.position/2` and
  `CEL.Checked.references/1` use.

  Match on the structs to inspect the tree, and use `reduce/3`, `filter/2` or
  `children/1` to walk it. They visit what the author wrote: a `MacroCall`'s
  target and arguments, not its expansion.

      alias CEL.Expr.Call

      checked
      |> CEL.Checked.expr()
      |> CEL.Expr.filter(&match?(%Call{function: "lookup"}, &1))

  The view is derived from the checked expression; evaluation does not read
  it, so it stays stable as the evaluator changes.
  """

  alias CEL.Checked

  defmodule Const do
    @moduledoc """
    A literal: `1`, `2u`, `'a'`, `b'a'`, `true`, `null`, ....
    """
    defstruct [:id, :type, :value]

    @typedoc "`value` is the literal as a `t:CEL.Value.t/0`, such as `{:uint, 2}`."
    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            value: CEL.Value.t()
          }
  end

  defmodule Ident do
    @moduledoc """
    A name, resolved by the checker.

    `name` is the fully qualified name, after the container and abbreviations
    are applied, so a select chain such as `pkg.Enum.VALUE` that names one
    thing is a single `Ident`. `scope` says what it names:

      * `:var` — a variable declared in the `CEL.Env`.
      * `:local` — a variable a macro binds, such as `x` in `l.all(x, x > 0)`.
      * `:type` — a type, as in `type(x) == int` or `type(m) == pkg.Message`.
      * `:enum` — an enum value, such as `pkg.Enum.VALUE`.
    """
    defstruct [:id, :type, :name, :scope]

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            name: String.t(),
            scope: CEL.Expr.scope()
          }
  end

  defmodule Select do
    @moduledoc """
    A field selection: `operand.field`, or a map lookup written the same way.

    `test_only` is true for a presence test, `has(operand.field)`, whose type
    is `:bool`. `optional` is true for `operand.?field`, whose type is
    `{:optional, t}`.
    """
    defstruct [:id, :type, :operand, :field, test_only: false, optional: false]

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            operand: CEL.Expr.t(),
            field: String.t(),
            test_only: boolean,
            optional: boolean
          }
  end

  defmodule Call do
    @moduledoc """
    A function call, `f(args)` or `target.f(args)`.

    `function` is the name as written, or for a namespaced function such as
    `math.greatest(...)`, with its namespace; `target` is the receiver of a
    method call and `nil` otherwise.

    Operators are calls too, with CEL's internal names: `_+_`, `_==_`, `!_`,
    `-_`, `_&&_`, `_||_`, `_?_:_`, `_[_]`, `_[?_]`, `@in`, .... So is an enum
    constructor such as `pkg.Enum(1)`, with `function` the enum's full name
    and `overload_id` `"enum_constructor"`.

    `overload_id` is the overload the checker chose, such as `"add_int64"`.
    When that depends on types known only when evaluating, it names the
    dispatch instead, such as `"_+__dyn"` for `dyn_value + 1`.
    """
    defstruct [:id, :type, :function, :overload_id, :target, args: []]

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            function: String.t(),
            overload_id: String.t(),
            target: CEL.Expr.t() | nil,
            args: [CEL.Expr.t()]
          }
  end

  defmodule ListLiteral do
    @moduledoc """
    A list literal, `[a, b, ?c]`.

    `optional_indices` lists, in order, the positions of elements written
    with `?`, which are added only when their optional value is present.
    """
    defstruct [:id, :type, elements: [], optional_indices: []]

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            elements: [CEL.Expr.t()],
            optional_indices: [non_neg_integer]
          }
  end

  defmodule MapLiteral do
    @moduledoc """
    A map literal, `{k: v, ?k2: v2}`.

    Each entry has its `key` and `value` nodes; `optional` is true for an
    entry written with `?`, which is added only when its optional value is
    present.
    """
    defstruct [:id, :type, entries: []]

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            entries: [CEL.Expr.map_entry()]
          }
  end

  defmodule MessageLiteral do
    @moduledoc """
    A message literal, `pkg.Message{field: value, ?other: maybe}`.

    `message` is the message's type: its `CEL.TypeProvider`'s name for it,
    or a well-known type's full name, such as `"google.protobuf.Int64Value"`.
    Each field has its name and `value` node; `optional` is true for a field
    written with `?`, which is set only when its optional value is present.
    """
    defstruct [:id, :type, :message, fields: []]

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            message: CEL.TypeProvider.name(),
            fields: [CEL.Expr.message_field()]
          }
  end

  defmodule MacroCall do
    @moduledoc """
    A macro, as written: `l.all(x, p)`, `l.exists(x, p)`, `l.exists_one(x, p)`,
    `l.map(x, f)`, `l.map(x, p, f)`, `l.filter(x, p)`, the two-variable forms
    such as `m.all(k, v, p)`, `cel.bind(v, init, body)`, `o.optMap(v, f)` and
    `o.optFlatMap(v, f)`.

    `function` is the macro's name and `target` its receiver, or `nil` for
    `cel.bind`. `args` start with the variables the macro binds, as
    `CEL.Expr.Ident` nodes with `scope: :local` and their types, followed
    by the other arguments.

    For a comprehension macro, `expansion` is the `CEL.Expr.Comprehension`
    it expands to, which evaluation runs; its subexpressions include the
    nodes in `args`. It is `nil` for `cel.bind`, `optMap` and `optFlatMap`.
    `has(m.f)` is not a `MacroCall` but a `CEL.Expr.Select` with
    `test_only: true`.
    """
    defstruct [:id, :type, :function, :target, :expansion, args: []]

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            function: String.t(),
            target: CEL.Expr.t() | nil,
            args: [CEL.Expr.t()],
            expansion: CEL.Expr.Comprehension.t() | nil
          }
  end

  defmodule Comprehension do
    @moduledoc """
    CEL's loop, which comprehension macros expand to. It appears directly in
    the tree only for a parsed expression that has one without its macro,
    such as one from another CEL implementation.

    It binds `iter_var` (and `iter_var2`, for two-variable forms) to each
    element of `iter_range` in turn, and `accu_var` to an accumulator that
    starts as `accu_init`. While `loop_condition` holds, `loop_step` computes
    the next accumulator; `result` is evaluated last.
    """
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

    @type t :: %__MODULE__{
            id: CEL.Checked.expr_id(),
            type: CEL.Expr.type(),
            iter_var: String.t(),
            iter_var2: String.t() | nil,
            iter_range: CEL.Expr.t(),
            accu_var: String.t(),
            accu_init: CEL.Expr.t(),
            loop_condition: CEL.Expr.t(),
            loop_step: CEL.Expr.t(),
            result: CEL.Expr.t()
          }
  end

  @typedoc "A node's checked type, or `nil` for a node the checker did not type."
  @type type :: CEL.Type.t() | nil

  @typedoc "Any node."
  @type t ::
          Const.t()
          | Ident.t()
          | Select.t()
          | Call.t()
          | ListLiteral.t()
          | MapLiteral.t()
          | MessageLiteral.t()
          | MacroCall.t()
          | Comprehension.t()

  @typedoc "What `CEL.Expr.Ident`'s `scope` says a name is."
  @type scope :: :var | :local | :type | :enum

  @typedoc "An entry of a `CEL.Expr.MapLiteral`."
  @type map_entry :: %{key: t, value: t, optional: boolean}

  @typedoc "A field of a `CEL.Expr.MessageLiteral`."
  @type message_field :: %{field: String.t(), value: t, optional: boolean}

  @optional_selects [:optional_field, :optional_map_field, :optional_dyn_field]

  @doc false
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
  def children(%MacroCall{target: nil, args: args}), do: args
  def children(%MacroCall{target: target, args: args}), do: [target | args]
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
    op = Checked.op(checked, id)
    type = Checked.type(checked, id)

    case {op, checked.source_info |> Map.get(:macro_calls, %{}) |> Map.get(id)} do
      {{:comprehension, comprehension}, %{expr_kind: {:call_expr, call}}} ->
        macro_call(id, type, comprehension, call, build(id, op, type, checked), checked)

      _other ->
        build(id, op, type, checked)
    end
  end

  # A macro as written: the variables it binds, then its other arguments,
  # whose ids are those of the same expressions in the expansion.
  defp macro_call(id, type, comprehension, call, expansion, checked) do
    target = Map.get(call, :target)
    vars = if comprehension.iter_var2 in [nil, ""], do: 1, else: 2
    {var_exprs, arg_exprs} = Enum.split(call.args, vars)
    range_type = Checked.type(checked, comprehension.iter_range_id)

    var_nodes =
      var_exprs
      |> Enum.zip(iter_var_types(range_type, vars))
      |> Enum.map(fn {%{id: var_id, expr_kind: {:ident_expr, %{name: name}}}, var_type} ->
        %Ident{id: var_id, type: var_type, name: name, scope: :local}
      end)

    %MacroCall{
      id: id,
      type: type,
      function: call.function,
      target: target && node(target.id, checked),
      args: var_nodes ++ Enum.map(arg_exprs, &node(&1.id, checked)),
      expansion: expansion
    }
  end

  defp iter_var_types({:list, elem}, 1), do: [elem]
  defp iter_var_types({:list, elem}, 2), do: [:int, elem]
  defp iter_var_types({:map, key, _value}, 1), do: [key]
  defp iter_var_types({:map, key, value}, 2), do: [key, value]
  defp iter_var_types(_range, vars), do: List.duplicate(:dyn, vars)

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
    var = %Ident{id: op.var_id, type: Checked.type(checked, init_id), name: op.var, scope: :local}

    %MacroCall{
      id: id,
      type: type,
      function: "cel.bind",
      args: [var, node(init_id, checked), node(body_id, checked)]
    }
  end

  defp build(id, {:special, %{kind: kind} = op}, type, checked)
       when kind in [:optional_map, :optional_flat_map] do
    [var_id, body_id] = op.arg_ids

    var_type =
      case Checked.type(checked, op.target_id) do
        {:optional, value_type} -> value_type
        _type -> :dyn
      end

    var = %Ident{id: var_id, type: var_type, name: op.var, scope: :local}

    %MacroCall{
      id: id,
      type: type,
      function: op.name,
      target: node(op.target_id, checked),
      args: [var, node(body_id, checked)]
    }
  end

  defp build(id, {:special, op}, type, checked) do
    %Call{
      id: id,
      type: type,
      function: to_string(Map.get(op, :enum, op.name)),
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
          field: field.field,
          value: node(field.value_id, checked),
          optional: field.optional?
        }
      end)

    %MessageLiteral{id: id, type: type, message: op.message, fields: fields}
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

end
