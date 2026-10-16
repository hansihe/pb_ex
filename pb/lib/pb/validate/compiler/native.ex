defmodule PB.Validate.Compiler.Native do
  @moduledoc false

  # Compiles the standard rules that `PB.Validate` evaluates without CEL: Any
  # `in`/`not_in` type-URL checks and enum `defined_only`. Resolves their rule
  # paths against the merged standard-rule schema. Owns the `:validate` native-op
  # merge helper.

  alias PB.Validate.Compiler.Context
  alias PB.Validate.Compiler.Targets
  alias PB.Validate.CompileError
  alias PB.Validate.Schema, as: ValidateSchema

  @field_rules_message :"buf.validate.FieldRules"
  @any_rules_message :"buf.validate.AnyRules"
  @enum_rules_message :"buf.validate.EnumRules"

  @doc """
  Merges native ops into an entry's `:validate`, leaving it untouched when empty.
  """
  def add_native_ops(entry, []), do: entry

  def add_native_ops(entry, ops) do
    Map.update(entry, :validate, %{native: ops}, fn validate ->
      Map.update(validate, :native, ops, &(&1 ++ ops))
    end)
  end

  @doc """
  Returns the native ops for a field's rules against `rule_schema`.
  """
  def native_ops(rule_schema, target, field, rules, path_prefix \\ [])

  def native_ops(rule_schema, _target, _field, %{type: {:any, rules}}, path_prefix)
      when is_map(rules) do
    if Targets.native_field_rules?(%{type: {:any, rules}}) do
      with {:ok, field_rules_message} <- Context.fetch_message(rule_schema, @field_rules_message),
           {:ok, field_rules_field} <- Context.fetch_field(field_rules_message, :any),
           {:ok, any_rules_message} <- Context.fetch_message(rule_schema, @any_rules_message) do
        rule_path_prefix = path_prefix ++ [field_rules_field]

        [
          native_any_op(any_rules_message, rule_path_prefix, :in, rules),
          native_any_op(any_rules_message, rule_path_prefix, :not_in, rules)
        ]
        |> Enum.reject(&is_nil/1)
      else
        :error -> []
      end
    else
      []
    end
  end

  def native_ops(rule_schema, target, field, %{type: {:enum, rules}}, path_prefix)
      when is_map(rules) do
    if Targets.native_field_rules?(%{type: {:enum, rules}}) do
      with {:ok, field_rules_message} <- Context.fetch_message(rule_schema, @field_rules_message),
           {:ok, field_rules_field} <- Context.fetch_field(field_rules_message, :enum),
           {:ok, enum_rules_message} <- Context.fetch_message(rule_schema, @enum_rules_message),
           {:ok, enum} <- Context.fetch_enum(rule_schema, field) do
        [
          native_enum_defined_only_op(
            enum_rules_message,
            path_prefix ++ [field_rules_field],
            enum
          )
        ]
      else
        :error ->
          raise CompileError,
            target: target,
            constraint_id: "enum.defined_only",
            stage: :type,
            cause: "unknown enum #{inspect(field.type_name)}"
      end
    else
      []
    end
  end

  def native_ops(_rule_schema, _target, _field, _rules, _path_prefix), do: []

  defp native_any_op(any_rules_message, rule_path_prefix, field_name, rules) do
    values = Targets.any_rule_values(rules, field_name)

    if values == [] do
      nil
    else
      {:ok, rule_field} = Context.fetch_field(any_rules_message, field_name)
      rule_path = ValidateSchema.rule_path(rule_path_prefix ++ [rule_field])

      ValidateSchema.native_op(%{
        kind: any_native_kind(field_name),
        id: any_rule_id(field_name),
        message: any_rule_message(field_name),
        values: values,
        rule_path: rule_path,
        proto_rule_path: rule_path
      })
    end
  end

  defp any_native_kind(:in), do: :any_in
  defp any_native_kind(:not_in), do: :any_not_in

  defp any_rule_id(:in), do: "any.in"
  defp any_rule_id(:not_in), do: "any.not_in"

  defp any_rule_message(:in), do: "type URL must be in the allow list"
  defp any_rule_message(:not_in), do: "type URL must not be in the block list"

  defp native_enum_defined_only_op(enum_rules_message, rule_path_prefix, enum) do
    {:ok, rule_field} = Context.fetch_field(enum_rules_message, :defined_only)
    rule_path = ValidateSchema.rule_path(rule_path_prefix ++ [rule_field])

    ValidateSchema.native_op(%{
      kind: :enum_defined_only,
      id: "enum.defined_only",
      message: "value must be one of the defined enum values",
      values: enum_defined_only_values(enum),
      rule_path: rule_path,
      proto_rule_path: rule_path
    })
  end

  defp enum_defined_only_values(enum) do
    Enum.sort(Map.keys(enum.by_number)) ++ Enum.sort(Map.keys(enum.by_name))
  end
end
