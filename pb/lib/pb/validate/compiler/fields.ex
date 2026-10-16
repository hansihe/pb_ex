defmodule PB.Validate.Compiler.Fields do
  @moduledoc false

  # Annotates a single field with its validation metadata. Dispatches a field's
  # buf.validate.field rules across the rule families: direct rules on the field
  # itself, and nested rules on repeated items and map keys/values. Each path
  # delegates structural/native/predefined/user-CEL compilation to the matching
  # compiler module and merges the results under the `PB.Validate` key.

  alias PB.CEL.Schema.Field
  alias PB.Validate.Compiler.CEL
  alias PB.Validate.Compiler.Context
  alias PB.Validate.Compiler.Extensions
  alias PB.Validate.Compiler.Native
  alias PB.Validate.Compiler.Predefined
  alias PB.Validate.Compiler.Targets
  alias PB.Validate.CompileError
  alias PB.Validate.Schema, as: ValidateSchema

  @field_rules :"buf.validate.field"
  @field_rules_message :"buf.validate.FieldRules"
  @repeated_rules_message :"buf.validate.RepeatedRules"
  @map_rules_message :"buf.validate.MapRules"

  @doc """
  Annotates a field with structural, native, predefined, and user-CEL validation.
  """
  def annotate(ctx, message_fqn, field) do
    rules = Extensions.extension_rules(field, @field_rules)
    cel_rules = Extensions.field_cel_rules(rules)
    cel_expression_rules = Extensions.field_cel_expression_rules(rules)

    field =
      field
      |> Extensions.add_predefined_definition()
      |> Extensions.add_structural_validation(Extensions.field_structural_rules(rules))

    target = Atom.to_string(message_fqn) <> "." <> Atom.to_string(field.name)

    field
    |> add_direct_field_validation(ctx, target, rules, cel_rules, cel_expression_rules)
    |> add_nested_field_validation(ctx, target, rules)
  end

  defp add_direct_field_validation(field, ctx, target, rules, cel_rules, cel_expression_rules) do
    if cel_rules == [] and cel_expression_rules == [] and
         not Targets.predefined_field_rules?(rules) and
         not Targets.native_field_rules?(rules) do
      field
    else
      Targets.validate_standard_rule_family_target!(target, field, rules)

      case Field.cel_type(ctx.user_schema, field) do
        {:ok, this_type} ->
          rule_schema = Context.rule_schema(ctx)

          field
          |> Native.add_native_ops(Native.native_ops(rule_schema, target, field, rules))
          |> CEL.add_cel_ops(Predefined.predefined_cel_ops(rule_schema, target, this_type, rules))
          |> CEL.add_user_cel_validation(
            cel_rules,
            ctx.user_schema,
            target,
            this_type,
            :field_cel
          )
          |> CEL.add_user_cel_validation(
            cel_expression_rules,
            ctx.user_schema,
            target,
            this_type,
            :field_cel,
            :field_cel_expression
          )

        {:error, reason} ->
          raise CompileError,
            target: target,
            constraint_id: CEL.first_rule_id(cel_rules ++ cel_expression_rules),
            stage: :type,
            cause: reason
      end
    end
  end

  defp add_nested_field_validation(field, ctx, target, rules) do
    field
    |> add_repeated_item_validation(ctx, target, rules)
    |> add_map_entry_validation(ctx, target, rules)
  end

  defp add_repeated_item_validation(%{cardinality: :repeated} = field, ctx, target, rules) do
    with {:ok, repeated_rules} <- field_rules_type_value(rules, :repeated),
         {:ok, item_rules} <- nested_field_rules(repeated_rules, :items) do
      rule_schema = Context.rule_schema(ctx)

      with {:ok, path_prefix} <-
             nested_rule_path_prefix(rule_schema, :repeated, @repeated_rules_message, :items),
           {:ok, this_type} <- Field.singular_cel_type(ctx.user_schema, field) do
        item_field = repeated_item_field(field)

        rule_set =
          compile_nested_rule_set(
            rule_schema,
            target <> ".repeated.items",
            item_field,
            this_type,
            item_rules,
            path_prefix
          )

        if ValidateSchema.empty_rule_set?(rule_set) do
          field
        else
          repeated = ValidateSchema.repeated_rules(%{items: rule_set})

          Map.update(field, PB.Validate, %{repeated: repeated}, fn validate ->
            Map.put(validate, :repeated, repeated)
          end)
        end
      else
        _other -> field
      end
    else
      _other -> field
    end
  end

  defp add_repeated_item_validation(field, _ctx, _target, _rules), do: field

  defp add_map_entry_validation(%{cardinality: :map} = field, ctx, target, rules) do
    with {:ok, map_rules} <- field_rules_type_value(rules, :map) do
      rule_schema = Context.rule_schema(ctx)

      keys =
        compile_map_nested_rule_set(
          rule_schema,
          target <> ".map.keys",
          map_rules,
          :keys,
          field.map_key
        )

      values =
        compile_map_nested_rule_set(
          rule_schema,
          target <> ".map.values",
          map_rules,
          :values,
          field.map_value
        )

      map_rules = ValidateSchema.map_rules(%{keys: keys, values: values})

      if ValidateSchema.empty_map_rules?(map_rules) do
        field
      else
        Map.update(field, PB.Validate, %{map: map_rules}, fn validate ->
          Map.put(validate, :map, map_rules)
        end)
      end
    else
      _other -> field
    end
  end

  defp add_map_entry_validation(field, _ctx, _target, _rules), do: field

  defp compile_map_nested_rule_set(schema, target, map_rules, key, field) do
    with {:ok, rules} <- nested_field_rules(map_rules, key),
         {:ok, path_prefix} <-
           nested_rule_path_prefix(schema, :map, @map_rules_message, key),
         {:ok, this_type} <- Field.singular_cel_type(schema, field) do
      compile_nested_rule_set(schema, target, field, this_type, rules, path_prefix)
    else
      _other -> nil
    end
  end

  defp compile_nested_rule_set(schema, target, field, this_type, rules, path_prefix) do
    rules = normalize_field_rules(rules)
    Targets.validate_standard_rule_family_target!(target, field, rules)

    attrs =
      rules
      |> Extensions.field_structural_rules()
      |> Map.take([:ignore])
      |> Map.put(:native, Native.native_ops(schema, target, field, rules, path_prefix))
      |> Map.put(
        :cel,
        Predefined.predefined_cel_ops(schema, target, this_type, rules, path_prefix) ++
          CEL.compile_user_cel_ops(
            Extensions.field_cel_rules(rules),
            schema,
            target,
            this_type,
            :field_cel,
            path_prefix,
            :field_cel
          ) ++
          CEL.compile_user_cel_ops(
            Extensions.field_cel_expression_rules(rules),
            schema,
            target,
            this_type,
            :field_cel,
            path_prefix,
            :field_cel_expression
          )
      )

    ValidateSchema.rule_set(attrs)
  end

  defp nested_rule_path_prefix(schema, field_rules_name, rules_message_name, nested_field_name) do
    with {:ok, field_rules_message} <- Context.fetch_message(schema, @field_rules_message),
         {:ok, field_rules_field} <- Context.fetch_field(field_rules_message, field_rules_name),
         {:ok, rules_message} <- Context.fetch_message(schema, rules_message_name),
         {:ok, nested_field} <- Context.fetch_field(rules_message, nested_field_name) do
      {:ok, [field_rules_field, nested_field]}
    end
  end

  defp field_rules_type_value(%{type: {name, value}}, name) when is_map(value), do: {:ok, value}
  defp field_rules_type_value(_rules, _name), do: :error

  defp nested_field_rules(rules, name) when is_map(rules) do
    case Map.fetch(rules, name) do
      {:ok, value} -> {:ok, normalize_field_rules(value)}
      :error -> :error
    end
  end

  defp normalize_field_rules({@field_rules_message, rules}) when is_map(rules), do: rules
  defp normalize_field_rules({_message_name, rules}) when is_map(rules), do: rules
  defp normalize_field_rules(rules) when is_map(rules), do: rules

  defp repeated_item_field(field), do: Map.put(field, :cardinality, :singular)
end
