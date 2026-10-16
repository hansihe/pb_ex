defmodule PB.Validate.Compiler.Extensions do
  @moduledoc false

  # Reads materialized buf.validate descriptor options into plain rule data for
  # `PB.Validate.Compiler`, and builds the structural (non-CEL) validation that
  # comes straight off those options: required/disabled/ignore flags, message
  # oneof rules, and predefined-rule definitions on extensions. Also owns the
  # small `:validate` merge helpers shared with the field compiler.

  alias PB.Validate.CompileError
  alias PB.Validate.Schema, as: ValidateSchema

  @extensions :__extensions__
  @message_rules :"buf.validate.message"
  @oneof_rules :"buf.validate.oneof"
  @predefined_rules :"buf.validate.predefined"

  @doc """
  Returns the materialized rules for an extension on an entry, or an empty map.
  """
  def extension_rules(entry, extension_name) do
    entry
    |> Map.get(:options, %{})
    |> Map.get(@extensions, %{})
    |> Map.get(extension_name, %{})
  end

  @doc "Message-level `cel` rules."
  def message_cel_rules(message), do: cel_rules(message, @message_rules)

  @doc "Message-level `cel_expression` rules, normalized to rule maps."
  def message_cel_expression_rules(message) do
    message
    |> extension_rules(@message_rules)
    |> cel_expression_rules()
  end

  @doc "Field-level `cel` rules from already-extracted field rules."
  def field_cel_rules(rules) when is_map(rules), do: rules |> Map.get(:cel) |> List.wrap()
  def field_cel_rules(_rules), do: []

  @doc "Field-level `cel_expression` rules, normalized to rule maps."
  def field_cel_expression_rules(rules), do: cel_expression_rules(rules)

  @doc "Structural (non-CEL) field rules: required + ignore."
  def field_structural_rules(field) do
    %{}
    |> bool_rule(field, :required)
    |> enum_rule(field, :ignore, [:IGNORE_IF_ZERO_VALUE, :IGNORE_ALWAYS])
  end

  @doc "Structural message rules: disabled + message oneof rules."
  def message_structural_rules(message, fqn) do
    rules = extension_rules(message, @message_rules)

    %{}
    |> bool_rule(rules, :disabled)
    |> message_oneof_rules(rules, message, fqn)
  end

  @doc "Structural oneof rules: required."
  def oneof_structural_rules(oneof) do
    rules = extension_rules(oneof, @oneof_rules)

    %{}
    |> bool_rule(rules, :required)
  end

  @doc """
  Merges structural rules into an entry's `:validate`, leaving it untouched when
  there are none.
  """
  def add_structural_validation(entry, rules) when map_size(rules) == 0, do: entry

  def add_structural_validation(entry, rules) do
    Map.update(entry, :validate, rules, &Map.merge(&1, rules))
  end

  @doc """
  Attaches a predefined-rule definition (its CEL sources) to an extension entry.
  """
  def add_predefined_definition(entry) do
    case predefined_sources(entry) do
      [] ->
        entry

      rules ->
        predefined = ValidateSchema.predefined(rules)

        Map.update(entry, :validate, %{predefined: predefined}, fn validate ->
          Map.put(validate, :predefined, predefined)
        end)
    end
  end

  @doc "Annotates every extension in a map with its predefined definition."
  def annotate_extensions(extensions) when is_map(extensions) do
    Map.new(extensions, fn {name, extension} ->
      {name, add_predefined_definition(extension)}
    end)
  end

  defp cel_rules(entry, extension_name) do
    entry
    |> extension_rules(extension_name)
    |> Map.get(:cel)
    |> List.wrap()
  end

  defp cel_expression_rules(rules) when is_map(rules) do
    rules
    |> Map.get(:cel_expression)
    |> List.wrap()
    |> Enum.map(&cel_expression_rule/1)
  end

  defp cel_expression_rules(_rules), do: []

  defp cel_expression_rule(expression) when is_binary(expression) do
    %{
      id: expression,
      message: ~s("#{expression}" returned false),
      expression: expression
    }
  end

  defp predefined_sources(entry) do
    entry
    |> extension_rules(@predefined_rules)
    |> Map.get(:cel)
    |> List.wrap()
  end

  defp bool_rule(validate, rules, field) do
    rule = if Map.get(rules, field) == true, do: %{field => true}, else: %{}
    Map.merge(validate, rule)
  end

  defp enum_rule(validate, rules, field, allowed) do
    value = Map.get(rules, field)

    if value in allowed do
      Map.put(validate, field, value)
    else
      validate
    end
  end

  defp message_oneof_rules(validate, rules, message, fqn) do
    oneofs =
      rules
      |> Map.get(:oneof)
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {rule, index} -> compile_message_oneof_rule(rule, index, message, fqn) end)

    if oneofs == [] do
      validate
    else
      Map.put(validate, :message_oneofs, oneofs)
    end
  end

  defp compile_message_oneof_rule(rule, index, message, fqn) do
    raw_fields = rule |> Map.get(:fields, []) |> List.wrap()
    validate_message_oneof_fields!(raw_fields, index, fqn)

    fields =
      raw_fields
      |> Enum.map(&message_oneof_field!(&1, index, message, fqn))

    %{fields: fields, required: Map.get(rule, :required) == true, index: index}
  end

  defp validate_message_oneof_fields!([], index, fqn) do
    raise CompileError,
      target: Atom.to_string(fqn),
      constraint_id: "message.oneof",
      stage: :type,
      cause: "message oneof rule #{index} must reference at least one field"
  end

  defp validate_message_oneof_fields!(fields, index, fqn) do
    duplicate =
      fields
      |> Enum.frequencies()
      |> Enum.find(fn {_field, count} -> count > 1 end)

    case duplicate do
      {field, _count} ->
        raise CompileError,
          target: Atom.to_string(fqn),
          constraint_id: "message.oneof",
          stage: :type,
          cause: "message oneof rule #{index} references duplicate field #{inspect(field)}"

      nil ->
        :ok
    end
  end

  defp message_oneof_field!(name, index, message, fqn) when is_binary(name) do
    field = String.to_existing_atom(name)

    if Map.has_key?(message.fields_by_name, field) do
      field
    else
      raise CompileError,
        target: Atom.to_string(fqn),
        constraint_id: "message.oneof",
        stage: :type,
        cause: "message oneof rule #{index} references unknown field #{inspect(name)}"
    end
  rescue
    ArgumentError ->
      raise CompileError,
        target: Atom.to_string(fqn),
        constraint_id: "message.oneof",
        stage: :type,
        cause: "message oneof rule #{index} references unknown field #{inspect(name)}"
  end
end
