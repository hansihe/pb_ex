defmodule CEL.Checked do
  @moduledoc """
  A type-checked CEL expression, from `CEL.check/2`.

  The struct is opaque. Inspect it with:

    * `type/1` and `type/2` — the type of the expression, or of one
      subexpression by id, as a `t:CEL.Type.t/0`.
    * `position/2` — where a subexpression is in the source.
    * `expr/1` — the expression as a tree of `CEL.Expr` nodes.
    * `references/1` — the variable paths it reads and the custom functions it
      calls, with their arguments when they are constants or variable paths.
    * `to_proto/1` — the standard `cel.expr.CheckedExpr` map, for exchange with
      other CEL implementations.

  Evaluate it by bundling it with its environment: `CEL.Program.new/2`.
  """

  alias CEL.Call
  alias CEL.Checked.References
  alias CEL.Checker.Types, as: CType
  alias CEL.Function
  alias CEL.Proto
  alias CEL.ProtoType
  alias CEL.Syntax.Source
  alias CEL.Value

  defstruct [
    :expr,
    :source_info,
    :root_type,
    expr_version: "cel1",
    types: %{},
    ops: %{},
    enums: MapSet.new()
  ]

  @typedoc "The id of a subexpression, as in `CEL.Expr` nodes."
  @type expr_id :: non_neg_integer
  @typedoc false
  @type ref :: %{
          optional(:name) => String.t(),
          optional(:overload_id) => [String.t()],
          optional(:value) => term
        }

  @typedoc false
  @type call_op ::
          {:call,
           %{
             required(:name) => String.t(),
             required(:shape) => Call.shape(),
             required(:overload_id) => String.t(),
             required(:eval) => Function.eval(),
             optional(:eval_context) => [Function.eval_context()],
             optional(:strict) => false,
             required(:target_id) => expr_id | nil,
             required(:arg_ids) => [expr_id]
           }}

  @typedoc false
  @type const_op :: {:const, %{required(:value) => Value.t()}}

  @typedoc false
  @type list_op ::
          {:list,
           %{
             required(:elem_ids) => [expr_id],
             required(:optional_indices) => MapSet.t(non_neg_integer)
           }}

  @typedoc false
  @type map_entry :: %{
          required(:key_id) => expr_id,
          required(:value_id) => expr_id,
          required(:optional?) => boolean()
        }

  @typedoc false
  @type map_op :: {:map, %{required(:entries) => [map_entry]}}

  @typedoc false
  @type select_kind ::
          :message_field
          | :map_field
          | :optional_field
          | :optional_map_field
          | :dyn_field
          | :optional_dyn_field
          | :presence_test
  @typedoc false
  @type select_op ::
          {:select,
           %{
             required(:kind) => select_kind(),
             required(:field) => String.t(),
             required(:receiver_id) => expr_id,
             required(:test_only) => boolean(),
             optional(:name) => String.t(),
             optional(:message) => atom | String.t(),
             optional(:field_ref) => CEL.Message.Schema.field_ref(),
             optional(:overload_id) => String.t()
           }}

  @typedoc false
  @type special_kind ::
          :and
          | :bind
          | :or
          | :conditional
          | :optional_map
          | :optional_flat_map
          | :enum_constructor

  @typedoc false
  @type special_op ::
          {:special,
           %{
             required(:kind) => special_kind(),
             required(:target_id) => expr_id | nil,
             required(:arg_ids) => [expr_id],
             optional(:name) => String.t(),
             optional(:overload_id) => String.t(),
             optional(:eval) => Function.eval(),
             optional(:eval_context) => [Function.eval_context()],
             optional(:var) => String.t(),
             optional(:var_id) => expr_id,
             optional(:enum) => String.t()
           }}

  @typedoc false
  @type ident_kind :: :var | :local | :type | :enum_value
  @typedoc false
  @type ident_op ::
          {:ident,
           %{
             required(:kind) => ident_kind(),
             required(:name) => String.t(),
             optional(:type) => CType.t(),
             optional(:denotation) => ProtoType.t(),
             optional(:value) => Value.t()
           }}

  @typedoc false
  @type comprehension_op ::
          {:comprehension,
           %{
             required(:iter_var) => String.t(),
             required(:accu_var) => String.t(),
             required(:iter_range_id) => expr_id,
             required(:accu_init_id) => expr_id,
             required(:loop_condition_id) => expr_id,
             required(:loop_step_id) => expr_id,
             required(:result_id) => expr_id,
             required(:iter_var2) => String.t()
           }}

  @typedoc false
  @type message_literal_field_cardinality :: :singular | :repeated | :map | :oneof
  @typedoc false
  @type message_literal_field :: %{
          required(:field) => atom() | String.t(),
          required(:value_id) => expr_id,
          required(:optional?) => boolean(),
          optional(:field_ref) => CEL.Message.Schema.field_ref(),
          optional(:cardinality) => message_literal_field_cardinality(),
          optional(:oneof_name) => atom()
        }

  @typedoc false
  @type message_literal_op ::
          {:message_literal,
           %{
             required(:message) => atom() | String.t(),
             required(:fields) => [message_literal_field()]
           }}

  @typedoc false
  @type op ::
          const_op
          | list_op
          | map_op
          | call_op
          | select_op
          | special_op
          | ident_op
          | comprehension_op
          | message_literal_op

  @typedoc "A type-checked expression; see the module docs."
  @type t :: %__MODULE__{}

  @typedoc """
  A place in the source: `offset` counts code points from the start, `line`
  and `column` are 1-based and count code points too.
  """
  @type position :: %{offset: non_neg_integer, line: pos_integer, column: pos_integer}

  @typedoc "A variable path an expression reads, such as `req.user.id`."
  @type var_read :: %{name: String.t(), path: [String.t()], expr_id: expr_id}

  @typedoc """
  A call's argument: a constant, a variable path, or anything else.
  """
  @type arg :: {:const, Value.t()} | {:var, String.t(), [String.t()]} | :dynamic

  @typedoc "A call to a non-operator function."
  @type call :: %{
          function: String.t(),
          overload_id: String.t(),
          expr_id: expr_id,
          target: arg | nil,
          args: [arg]
        }

  @typedoc "What `references/1` returns."
  @type references :: %{vars: [var_read], calls: [call]}

  @doc false
  @spec new(keyword) :: t
  def new(attrs) when is_list(attrs) do
    expr = Keyword.fetch!(attrs, :expr)
    types = Keyword.get(attrs, :types, %{})

    struct!(
      __MODULE__,
      Keyword.put_new(attrs, :root_type, Map.fetch!(types, expr.id))
    )
  end

  @doc """
  The type of the whole expression.
  """
  @spec type(t) :: CEL.Type.t()
  def type(%__MODULE__{expr: expr} = checked), do: type(checked, expr.id)

  @doc """
  The type of the expression with the given id, or `nil` if the checker did
  not type it (such as a comprehension's variable name).
  """
  @spec type(t, expr_id) :: CEL.Type.t() | nil
  def type(%__MODULE__{types: types} = checked, id) when is_integer(id) do
    case Map.fetch(types, id) do
      {:ok, type} -> type |> CType.finalize() |> CEL.Type.from_checker(checked.enums)
      :error -> nil
    end
  end

  @doc """
  Where the expression with the given id is in the source, or `nil` if the
  parser recorded no position for it.

  The position is the start of a literal, name, function call or message
  literal; the operator of an operator such as `a + b` or `a[0]`; and the
  `.` of a field selection or method call. Expressions a macro expands to
  share the macro's position.

      checked = CEL.check!("1 +\n  x", CEL.Env.build(vars: [x: :int]))
      [_one, x] = CEL.Checked.expr(checked).args

      CEL.Checked.position(checked, x.id)
      #=> %{offset: 6, line: 2, column: 3}
  """
  @spec position(t, expr_id) :: position | nil
  def position(%__MODULE__{source_info: source_info}, id) when is_integer(id) do
    case source_info |> Map.get(:positions, %{}) |> Map.fetch(id) do
      {:ok, offset} ->
        {line, column} = Source.position(Map.get(source_info, :line_offsets, []), offset)
        %{offset: offset, line: line, column: column}

      :error ->
        nil
    end
  end

  @doc false
  @spec proto_type(t, Proto.expr() | expr_id) :: ProtoType.t()
  def proto_type(%__MODULE__{} = checked, %{id: id}), do: proto_type(checked, id)

  def proto_type(%__MODULE__{types: types}, id) when is_integer(id),
    do: types |> Map.fetch!(id) |> CType.to_cel()

  @doc false
  @spec ref(t, Proto.expr() | expr_id) :: ref | nil
  def ref(%__MODULE__{} = checked, %{id: id}), do: ref(checked, id)

  def ref(%__MODULE__{} = checked, id) when is_integer(id) do
    checked
    |> reference_map()
    |> Map.get(id)
  end

  @doc false
  @spec op(t, Proto.expr() | expr_id) :: op | nil
  def op(%__MODULE__{} = checked, %{id: id}), do: op(checked, id)
  def op(%__MODULE__{ops: ops}, id) when is_integer(id), do: Map.get(ops, id)

  @doc """
  Returns a read-only view of the expression as a tree of `CEL.Expr`
  nodes.
  """
  @spec expr(t) :: CEL.Expr.t()
  def expr(%__MODULE__{} = checked), do: CEL.Expr.from_checked(checked)

  @doc """
  Returns what the expression reads: variable field paths and non-operator
  function calls with their arguments, in evaluation order.

  A variable read is the longest field selection rooted at a variable, so
  `req.user.id` is one read with path `["user", "id"]`, not three. Variables
  a macro binds are resolved to what they stand for: a `cel.bind` or `optMap`
  variable to its value, and a comprehension variable to its range followed
  by `"*"` for "any element", so `l.exists(i, i.score > 1)` reads `l` and
  `l.*.score`. Locals bound to anything other than a variable read are not
  reported.

  Operators (`_==_`, `@in`, ...), macros and enum constructors are not
  reported as calls. A call's `expr_id` is the one a custom function receives
  through `eval_context: [:call]`.
  """
  @spec references(t) :: references()
  def references(%__MODULE__{} = checked), do: References.collect(checked)

  @doc """
  The expression as a standard `cel.expr.CheckedExpr` map (the generated
  protobuf shape), for exchange with other CEL implementations.
  """
  @spec to_proto(t) :: map()
  def to_proto(%__MODULE__{} = checked) do
    %{
      expr: checked.expr,
      source_info: checked.source_info,
      expr_version: checked.expr_version,
      type_map: proto_types(checked.types),
      reference_map: reference_map(checked)
    }
  end

  @doc false
  @spec reference_map(t) :: %{expr_id => ref}
  def reference_map(%__MODULE__{ops: ops}) do
    Enum.reduce(ops, %{}, fn {id, op}, acc ->
      case reference(op) do
        nil -> acc
        reference -> Map.put(acc, id, reference)
      end
    end)
  end

  defp proto_types(types) do
    Map.new(types, fn {id, type} -> {id, CType.to_cel(type)} end)
  end

  defp reference({:ident, %{name: name} = op}) do
    %{name: name, overload_id: []}
    |> maybe_put_value(op)
  end

  defp reference({:call, %{name: name, overload_id: overload_id}}) do
    %{name: name, overload_id: List.wrap(overload_id)}
  end

  defp reference({:select, %{name: name, overload_id: overload_id}}) do
    %{name: name, overload_id: List.wrap(overload_id)}
  end

  defp reference({:special, %{kind: :enum_constructor, enum: enum, overload_id: overload_id}}) do
    %{name: enum, overload_id: List.wrap(overload_id)}
  end

  defp reference({:special, %{name: name, overload_id: overload_id}}) do
    %{name: name, overload_id: List.wrap(overload_id)}
  end

  defp reference({:select, %{field: field, overload_id: overload_id}}) do
    %{name: field, overload_id: List.wrap(overload_id)}
  end

  defp reference({:message_literal, %{message: message}}) when is_atom(message) do
    %{name: Atom.to_string(message), overload_id: []}
  end

  defp reference({:message_literal, %{message: message}}) do
    %{name: message, overload_id: []}
  end

  defp reference(_op), do: nil

  # The value an enum or type name stands for, as a `cel.expr.Value`.
  defp maybe_put_value(reference, %{kind: :enum_value, value: {:enum, type, number}}),
    do: Map.put(reference, :value, %{kind: {:enum_value, %{type: type, value: number}}})

  defp maybe_put_value(reference, %{kind: :type, denotation: denotation}),
    do: Map.put(reference, :value, %{kind: {:type_value, Value.type_name({:type, denotation})}})

  defp maybe_put_value(reference, _op), do: reference
end
