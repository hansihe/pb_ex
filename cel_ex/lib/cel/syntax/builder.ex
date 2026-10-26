defmodule CEL.Syntax.Builder do
  @moduledoc false

  alias CEL.Proto
  alias CEL.Syntax.Source

  defstruct [:source, :location, :line_offsets, next_id: 1, positions: %{}]

  @type t :: %__MODULE__{
          source: String.t(),
          location: String.t(),
          line_offsets: [non_neg_integer()],
          next_id: pos_integer(),
          positions: %{integer() => non_neg_integer()}
        }

  @spec new(String.t(), keyword) :: t
  def new(source, opts \\ []) when is_binary(source) and is_list(opts) do
    %__MODULE__{
      source: source,
      location: Keyword.get(opts, :location, "<input>"),
      line_offsets: Source.line_offsets(source)
    }
  end

  @spec parsed(t, Proto.expr()) :: Proto.parsed_expr()
  def parsed(%__MODULE__{} = builder, expr) when is_map(expr) do
    %{
      expr: expr,
      source_info: %{
        syntax_version: "cel1",
        location: builder.location,
        line_offsets: builder.line_offsets,
        positions: builder.positions,
        macro_calls: %{},
        extensions: []
      }
    }
  end

  @spec constant(t, non_neg_integer(), Proto.constant()) :: {Proto.expr(), t}
  def constant(builder, pos, constant) when is_map(constant) do
    expr(builder, pos, {:const_expr, constant})
  end

  @spec bool(t, non_neg_integer(), boolean()) :: {Proto.expr(), t}
  def bool(builder, pos, value) when is_boolean(value) do
    constant(builder, pos, %{constant_kind: {:bool_value, value}})
  end

  @spec null(t, non_neg_integer()) :: {Proto.expr(), t}
  def null(builder, pos) do
    constant(builder, pos, %{constant_kind: {:null_value, :NULL_VALUE}})
  end

  @spec int(t, non_neg_integer(), integer()) :: {Proto.expr(), t}
  def int(builder, pos, value) when is_integer(value) do
    constant(builder, pos, %{constant_kind: {:int64_value, value}})
  end

  @spec uint(t, non_neg_integer(), non_neg_integer()) :: {Proto.expr(), t}
  def uint(builder, pos, value) when is_integer(value) and value >= 0 do
    constant(builder, pos, %{constant_kind: {:uint64_value, value}})
  end

  @spec double(t, non_neg_integer(), float()) :: {Proto.expr(), t}
  def double(builder, pos, value) when is_float(value) do
    constant(builder, pos, %{constant_kind: {:double_value, value}})
  end

  @spec string(t, non_neg_integer(), String.t()) :: {Proto.expr(), t}
  def string(builder, pos, value) when is_binary(value) do
    constant(builder, pos, %{constant_kind: {:string_value, value}})
  end

  @spec bytes(t, non_neg_integer(), binary()) :: {Proto.expr(), t}
  def bytes(builder, pos, value) when is_binary(value) do
    constant(builder, pos, %{constant_kind: {:bytes_value, value}})
  end

  @spec ident(t, non_neg_integer(), String.t()) :: {Proto.expr(), t}
  def ident(builder, pos, name) when is_binary(name) do
    expr(builder, pos, {:ident_expr, %{name: name}})
  end

  @spec select(t, non_neg_integer(), Proto.expr(), String.t(), boolean) :: {Proto.expr(), t}
  def select(builder, pos, operand, field, test_only \\ false)
      when is_map(operand) and is_binary(field) and is_boolean(test_only) do
    expr(builder, pos, {:select_expr, %{operand: operand, field: field, test_only: test_only}})
  end

  @spec call(t, non_neg_integer(), String.t(), [Proto.expr()], Proto.expr() | nil) ::
          {Proto.expr(), t}
  def call(builder, pos, function, args, target \\ nil)
      when is_binary(function) and is_list(args) and (is_map(target) or is_nil(target)) do
    call = %{function: function, args: args}
    call = if target, do: Map.put(call, :target, target), else: call
    expr(builder, pos, {:call_expr, call})
  end

  @spec list(t, non_neg_integer(), [Proto.expr()], [non_neg_integer()]) :: {Proto.expr(), t}
  def list(builder, pos, elements, optional_indices \\ [])
      when is_list(elements) and is_list(optional_indices) do
    expr(
      builder,
      pos,
      {:list_expr, %{elements: elements, optional_indices: optional_indices}}
    )
  end

  @spec map(
          t,
          non_neg_integer(),
          [
            {Proto.expr(), Proto.expr(), non_neg_integer()}
            | {Proto.expr(), Proto.expr(), non_neg_integer(), boolean()}
          ]
        ) ::
          {Proto.expr(), t}
  def map(builder, pos, entries) when is_list(entries) do
    {entries, builder} =
      Enum.map_reduce(entries, builder, fn entry, builder ->
        {key, value, entry_pos, optional?} = normalize_map_entry(entry)
        entry(builder, entry_pos, {:map_key, key}, value, optional?)
      end)

    expr(builder, pos, {:struct_expr, %{message_name: "", entries: entries}})
  end

  @spec message(
          t,
          non_neg_integer(),
          String.t(),
          [
            {String.t(), Proto.expr(), non_neg_integer()}
            | {String.t(), Proto.expr(), non_neg_integer(), boolean()}
          ]
        ) ::
          {Proto.expr(), t}
  def message(builder, pos, message_name, fields)
      when is_binary(message_name) and is_list(fields) do
    {entries, builder} =
      Enum.map_reduce(fields, builder, fn field, builder ->
        {field, value, entry_pos, optional?} = normalize_message_field(field)
        entry(builder, entry_pos, {:field_key, field}, value, optional?)
      end)

    expr(builder, pos, {:struct_expr, %{message_name: message_name, entries: entries}})
  end

  defp expr(%__MODULE__{} = builder, pos, expr_kind) do
    {id, builder} = id(builder, pos)
    {%{id: id, expr_kind: expr_kind}, builder}
  end

  defp entry(%__MODULE__{} = builder, pos, key_kind, value, optional?) do
    {id, builder} = id(builder, pos)
    {%{id: id, key_kind: key_kind, value: value, optional_entry: optional?}, builder}
  end

  defp normalize_map_entry({key, value, pos}), do: {key, value, pos, false}
  defp normalize_map_entry({key, value, pos, optional?}), do: {key, value, pos, optional?}

  defp normalize_message_field({field, value, pos}), do: {field, value, pos, false}
  defp normalize_message_field({field, value, pos, optional?}), do: {field, value, pos, optional?}

  defp id(%__MODULE__{} = builder, pos) when is_integer(pos) and pos >= 0 do
    id = builder.next_id

    {id,
     %__MODULE__{
       builder
       | next_id: id + 1,
         positions: Map.put(builder.positions, id, pos)
     }}
  end
end
