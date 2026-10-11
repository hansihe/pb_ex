defmodule PB.CEL.Checked do
  # Internal. Not part of the published API yet; may be exposed in a
  # later release. Original module doc retained below as reference.
  #
  # PB-native checked CEL representation.
  #
  # This is the primary checker output and the input expected by the evaluator.
  # The standard `cel.expr.CheckedExpr` shape is derived with `to_proto/1` when we
  # need to serialize or compare against CEL conformance fixtures.
  #
  # `types` holds checker-native semantic types (`Checker.Types`) and `ops`
  # carries the execution plan that evaluator dispatch reads directly — field
  # refs, message-literal field plans, WKT-unwrap context, MFA targets, etc. —
  # so the evaluator does not need to re-derive decisions from AST shape plus
  # schema lookups. Standard CEL `Reference` data is derived from `ops` only for
  # `to_proto/1` and conformance comparison. Schema reflection stays outside
  # this struct; ops store stable names/atoms and later phases receive the schema
  # they need to query.
  @moduledoc false

  alias PB.CEL.Call
  alias PB.CEL.Checked.References
  alias PB.CEL.Checker.Types, as: CType
  alias PB.CEL.Function
  alias PB.CEL.Proto
  alias PB.CEL.ProtoType
  alias PB.CEL.Value

  defstruct [
    :expr,
    :source_info,
    :root_type,
    expr_version: "cel1",
    types: %{},
    ops: %{}
  ]

  @type expr_id :: non_neg_integer
  @type ref :: %{
          optional(:name) => String.t(),
          optional(:overload_id) => [String.t()],
          optional(:value) => term
        }

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

  @type const_op :: {:const, %{required(:value) => Value.t()}}

  @type list_op ::
          {:list,
           %{
             required(:elem_ids) => [expr_id],
             required(:optional_indices) => MapSet.t(non_neg_integer)
           }}

  @type map_entry :: %{
          required(:key_id) => expr_id,
          required(:value_id) => expr_id,
          required(:optional?) => boolean()
        }

  @type map_op :: {:map, %{required(:entries) => [map_entry]}}

  @type select_kind ::
          :message_field
          | :map_field
          | :optional_field
          | :optional_map_field
          | :dyn_field
          | :optional_dyn_field
          | :presence_test
  @type select_op ::
          {:select,
           %{
             required(:kind) => select_kind(),
             required(:field) => String.t(),
             required(:receiver_id) => expr_id,
             required(:test_only) => boolean(),
             optional(:name) => String.t(),
             optional(:message) => atom | String.t(),
             optional(:field_ref) => PB.CEL.Message.Schema.field_ref(),
             optional(:overload_id) => String.t()
           }}

  @type special_kind ::
          :and
          | :bind
          | :or
          | :conditional
          | :optional_map
          | :optional_flat_map
          | :enum_constructor

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

  @type ident_kind :: :var | :local | :type | :enum_value
  @type ident_op ::
          {:ident,
           %{
             required(:kind) => ident_kind(),
             required(:name) => String.t(),
             optional(:type) => CType.t(),
             optional(:denotation) => ProtoType.t(),
             optional(:value) => term
           }}

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

  @type message_literal_field_assignment :: :eval | :raw_message_literal
  @type message_literal_field_cardinality :: :singular | :repeated | :map | :oneof
  @type message_literal_field :: %{
          required(:field) => atom() | String.t(),
          required(:value_id) => expr_id,
          required(:optional?) => boolean(),
          required(:assignment) => message_literal_field_assignment(),
          optional(:field_ref) => PB.CEL.Message.Schema.field_ref(),
          optional(:cardinality) => message_literal_field_cardinality(),
          optional(:oneof_name) => atom()
        }

  @type message_literal_op ::
          {:message_literal,
           %{
             required(:message) => atom() | String.t(),
             required(:wkt_unwrap?) => boolean(),
             required(:fields) => [message_literal_field()]
           }}

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

  @type t :: %__MODULE__{
          expr: Proto.expr(),
          source_info: Proto.source_info(),
          root_type: CType.t(),
          expr_version: String.t(),
          types: %{expr_id => CType.t()},
          ops: %{expr_id => op}
        }

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
  @spec type(t) :: PB.CEL.Type.t()
  def type(%__MODULE__{expr: expr} = checked), do: type(checked, expr.id)

  @doc """
  The type of the expression with the given id, or `nil` if the checker did
  not type it (such as a comprehension's variable name).
  """
  @spec type(t, expr_id) :: PB.CEL.Type.t() | nil
  def type(%__MODULE__{types: types}, id) when is_integer(id) do
    case Map.fetch(types, id) do
      {:ok, type} -> type |> CType.finalize() |> PB.CEL.Type.from_checker()
      :error -> nil
    end
  end

  @spec proto_type(t, Proto.expr() | expr_id) :: ProtoType.t()
  def proto_type(%__MODULE__{} = checked, %{id: id}), do: proto_type(checked, id)

  def proto_type(%__MODULE__{types: types}, id) when is_integer(id),
    do: types |> Map.fetch!(id) |> CType.to_cel()

  @spec ref(t, Proto.expr() | expr_id) :: ref | nil
  def ref(%__MODULE__{} = checked, %{id: id}), do: ref(checked, id)

  def ref(%__MODULE__{} = checked, id) when is_integer(id) do
    checked
    |> reference_map()
    |> Map.get(id)
  end

  @spec op(t, Proto.expr() | expr_id) :: op | nil
  def op(%__MODULE__{} = checked, %{id: id}), do: op(checked, id)
  def op(%__MODULE__{ops: ops}, id) when is_integer(id), do: Map.get(ops, id)

  @doc """
  Returns a read-only view of the expression as a tree of `PB.CEL.Expr`
  nodes.
  """
  @spec expr(t) :: PB.CEL.Expr.t()
  def expr(%__MODULE__{} = checked), do: PB.CEL.Expr.from_checked(checked)

  @doc """
  Returns what the expression reads: variable field paths and non-operator
  function calls with their constant arguments, in evaluation order. See
  `PB.CEL.Checked.References` for how locals are resolved.
  """
  @spec references(t) :: References.t()
  def references(%__MODULE__{} = checked), do: References.collect(checked)

  @spec to_proto(t) :: Proto.checked_expr()
  def to_proto(%__MODULE__{} = checked) do
    %{
      expr: checked.expr,
      source_info: checked.source_info,
      expr_version: checked.expr_version,
      type_map: proto_types(checked.types),
      reference_map: reference_map(checked)
    }
  end

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

  defp maybe_put_value(reference, %{value: value}), do: Map.put(reference, :value, value)
  defp maybe_put_value(reference, _op), do: reference
end
