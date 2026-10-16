defmodule PB.Validate.Compiler.Predefined do
  @moduledoc false

  # Expands protovalidate's predefined standard rules into CEL ops. For each rule
  # field set on a field's standard rules, it binds `rules`/`rule` variables to
  # the configured values and compiles the rule field's predefined CEL sources.
  # All schema lookups run against the merged standard-rule schema.

  alias PB.CEL.Schema.Field
  alias PB.CEL.ProtoType
  alias PB.Validate.CEL.FieldReader
  alias PB.Validate.CEL.MessageRuntime, as: CELMessage
  alias PB.Validate.Compiler.CEL
  alias PB.Validate.Compiler.Context
  alias PB.Validate.CompileError
  alias PB.Validate.Schema, as: ValidateSchema

  require Field

  @extensions :__extensions__
  @field_rules_message :"buf.validate.FieldRules"

  @doc """
  Returns the predefined-rule CEL ops for a field's standard rules.
  """
  def predefined_cel_ops(rule_schema, target, this_type, rules, path_prefix \\ [])

  def predefined_cel_ops(
        rule_schema,
        target,
        this_type,
        %{type: {rules_name, rules_value}},
        path_prefix
      )
      when is_atom(rules_name) and is_map(rules_value) do
    with {:ok, field_rules_message} <- Context.fetch_message(rule_schema, @field_rules_message),
         {:ok, field_rules_field} <- Context.fetch_field(field_rules_message, rules_name),
         {:ok, rules_message_name} <- rules_message_name(field_rules_field),
         {:ok, rules_message} <- Context.fetch_message(rule_schema, rules_message_name) do
      rules_type = ProtoType.message(Atom.to_string(rules_message_name))

      rules_message
      |> sorted_rule_fields()
      |> Enum.flat_map(fn rule_field ->
        compile_predefined_rule_field(
          rule_schema,
          target,
          this_type,
          rules_type,
          rules_value,
          rules_message,
          path_prefix ++ [field_rules_field],
          rule_field
        )
      end)
    else
      :error -> []
    end
  end

  def predefined_cel_ops(_rule_schema, _target, _this_type, _rules, _path_prefix), do: []

  defp compile_predefined_rule_field(
         schema,
         target,
         this_type,
         rules_type,
         rules_value,
         rules_message,
         rule_path_prefix,
         rule_field
       ) do
    sources =
      case Map.get(rule_field, :validate, %{}) do
        %{predefined: %{cel: sources}} -> sources
        _other -> []
      end

    with false <- sources == [],
         {:ok, rule_value, runtime_rules_value} <-
           fetch_rule_value(schema, rules_message, rules_value, rule_field),
         {:ok, rule_type} <- Field.cel_type(schema, rule_field) do
      rule_path = ValidateSchema.rule_path(rule_path_prefix ++ [rule_field])

      Enum.map(sources, fn source ->
        CEL.compile_cel_rule(
          source,
          schema,
          target,
          %{"this" => this_type, "rules" => rules_type, "rule" => rule_type},
          kind: :predefined,
          vars: %{
            "rules" => runtime_rules_value,
            "rule" => runtime_rule_value(schema, rule_field, rule_value)
          },
          rule_path: rule_path,
          proto_rule_path: rule_path
        )
      end)
    else
      {:error, reason} ->
        raise CompileError,
          target: target,
          constraint_id: CEL.first_rule_id(sources),
          stage: :type,
          cause: reason

      _other ->
        []
    end
  end

  defp fetch_rule_value(schema, rules_message, rules_value, rule_field) do
    case FieldReader.fetch(schema, rules_message, rules_value, rule_field.name, rule_field) do
      {:ok, value} ->
        {:ok, value, rules_value}

      :error ->
        fetch_extension_rule_value(rules_value, rule_field)
    end
  end

  defp fetch_extension_rule_value(rules_value, %{kind: :extension} = rule_field) do
    case fetch_materialized_extension_rule_value(rules_value, rule_field) do
      {:ok, value} ->
        {:ok, value, rules_value}

      :error ->
        :error
    end
  end

  defp fetch_extension_rule_value(_rules_value, _rule_field), do: :error

  defp fetch_materialized_extension_rule_value(rules_value, rule_field) do
    with {:ok, extensions} when is_map(extensions) <- Map.fetch(rules_value, @extensions),
         {:ok, value} <- Map.fetch(extensions, rule_field.name) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp runtime_rule_value(schema, %{type: type} = rule_field, rule_value)
       when Field.message_type?(type) do
    case CELMessage.field_value(schema, rule_field, rule_value) do
      {:ok, value} -> value
      {:error, _reason} -> rule_value
    end
  end

  defp runtime_rule_value(_schema, _rule_field, rule_value), do: rule_value

  defp rules_message_name(%{type: type, type_name: type_name}) when Field.message_type?(type),
    do: {:ok, type_name}

  defp rules_message_name(_field), do: :error

  defp sorted_rule_fields(message) do
    sorted_fields(message) ++ sorted_extensions(message)
  end

  defp sorted_fields(%{fields_by_name: fields}) do
    fields
    |> Map.values()
    |> Enum.sort_by(& &1.number)
  end

  defp sorted_extensions(%{extensions_by_name: extensions}) do
    extensions
    |> Map.values()
    |> Enum.sort_by(& &1.number)
  end

  defp sorted_extensions(_message), do: []
end
