defmodule PB.Validate.Compiler.CEL do
  @moduledoc false

  # Compiles CEL rule sources into checked `CELOp`s for `PB.Validate.Compiler`.
  # Owns parsing, type-checking against a compile-time env, rule-path assignment
  # for user `cel`/`cel_expression` rules, and the `:validate` cel-op merge helper.

  alias PB.CEL
  alias PB.CEL.Checker.Types, as: CType
  alias PB.CEL.Checked
  alias PB.CEL.Regexes
  alias PB.Validate.CELExtensions
  alias PB.Validate.CompileError
  alias PB.Validate.Schema, as: ValidateSchema

  @doc """
  Merges compiled CEL ops into an entry's `:validate`, leaving it untouched when
  there are none.
  """
  def add_cel_ops(entry, []), do: entry

  def add_cel_ops(entry, ops) do
    Map.update(entry, :validate, %{cel: ops}, fn validate ->
      Map.update(validate, :cel, ops, &(&1 ++ ops))
    end)
  end

  @doc """
  Compiles user `cel`/`cel_expression` rules on an entry and merges the ops in.
  """
  def add_user_cel_validation(
        entry,
        rules,
        schema,
        target,
        this_type,
        kind,
        rule_path_kind \\ nil
      )

  def add_user_cel_validation(entry, [], _schema, _target, _this_type, _kind, _rule_path_kind),
    do: entry

  def add_user_cel_validation(entry, rules, schema, target, this_type, kind, rule_path_kind) do
    rule_path_kind = rule_path_kind || kind

    add_cel_ops(
      entry,
      compile_user_cel_ops(rules, schema, target, this_type, kind, [], rule_path_kind)
    )
  end

  @doc """
  Compiles a list of user CEL rules into ops, assigning each a rule path.
  """
  def compile_user_cel_ops(
        rules,
        schema,
        target,
        this_type,
        kind,
        path_prefix,
        rule_path_kind
      ) do
    rules
    |> Enum.with_index()
    |> Enum.map(fn {rule, index} ->
      rule_path =
        case rule_path_kind do
          :message_cel ->
            ValidateSchema.message_cel_rule_path(index)

          :message_cel_expression ->
            ValidateSchema.message_cel_expression_rule_path(index)

          :field_cel ->
            ValidateSchema.field_cel_rule_path(index, path_prefix)

          :field_cel_expression ->
            ValidateSchema.field_cel_expression_rule_path(index, path_prefix)
        end

      proto_rule_path = if kind == :message_cel, do: nil, else: rule_path

      compile_cel_rule(rule, schema, target, %{"this" => this_type},
        kind: kind,
        rule_path: rule_path,
        proto_rule_path: proto_rule_path
      )
    end)
  end

  @doc """
  Parses, type-checks, and wraps a single CEL rule into a `CELOp`.
  """
  def compile_cel_rule(rule, schema, target, vars, attrs) do
    attrs = Map.new(attrs)
    id = Map.get(rule, :id) || ""
    message = Map.get(rule, :message) || ""
    source = rule_expression(rule)

    env =
      CEL.Env.build(
        schema: schema,
        vars: Map.put_new(vars, "now", :timestamp),
        functions: CELExtensions.functions()
      )

    parsed =
      case CEL.parse(source, location: target <> "#" <> id) do
        {:ok, parsed} ->
          parsed

        {:error, error} ->
          raise CompileError, target: target, constraint_id: id, stage: :parse, cause: error
      end

    checked =
      case CEL.check(parsed, env) do
        {:ok, checked} ->
          checked

        {:error, error} ->
          raise CompileError, target: target, constraint_id: id, stage: :check, cause: error
      end

    if valid_result_type?(checked.root_type) do
      regexes = compile_static_regexes!(checked, Map.get(attrs, :vars, %{}), target, id)

      ValidateSchema.cel_op(
        %{
          id: id,
          message: message,
          checked: checked,
          source: source,
          regexes: regexes
        }
        |> Map.merge(attrs)
      )
    else
      raise CompileError,
        target: target,
        constraint_id: id,
        stage: :type,
        cause:
          "CEL result type #{CType.format(checked.root_type)} is not assignable to bool or string"
    end
  end

  @doc "The constraint id of the first rule in a list, or an empty string."
  def first_rule_id([rule | _rules]), do: Map.get(rule, :id) || ""
  def first_rule_id([]), do: ""

  defp rule_expression(%{expression: expression}), do: expression || ""

  defp compile_static_regexes!(%Checked{} = checked, vars, target, id) do
    case Regexes.precompile(checked, vars) do
      {:ok, regexes} ->
        regexes

      {:error, reason} ->
        raise CompileError,
          target: target,
          constraint_id: id,
          stage: :regex,
          cause: reason
    end
  end

  defp valid_result_type?(type) do
    CType.assignable?(:bool, type) or CType.assignable?(:string, type)
  end
end
