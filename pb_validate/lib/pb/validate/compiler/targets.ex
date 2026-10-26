defmodule PB.Validate.Compiler.Targets do
  @moduledoc false

  # Rule-family target registry for `PB.Validate.Compiler`.
  #
  # protovalidate's standard rules are grouped into families (scalar, wrapper,
  # message, repeated, map, enum). This module owns the family → field-type
  # mapping and answers two questions the field compiler asks: does a field carry
  # standard/native rules, and is a given rule family valid for the field's type.

  alias PB.CEL.Schema.Field
  alias PB.Validate.CompileError

  require Field

  @extensions :__extensions__

  @scalar_rule_targets %{
    float: :TYPE_FLOAT,
    double: :TYPE_DOUBLE,
    int32: :TYPE_INT32,
    int64: :TYPE_INT64,
    uint32: :TYPE_UINT32,
    uint64: :TYPE_UINT64,
    sint32: :TYPE_SINT32,
    sint64: :TYPE_SINT64,
    fixed32: :TYPE_FIXED32,
    fixed64: :TYPE_FIXED64,
    sfixed32: :TYPE_SFIXED32,
    sfixed64: :TYPE_SFIXED64,
    bool: :TYPE_BOOL,
    string: :TYPE_STRING,
    bytes: :TYPE_BYTES
  }

  @wrapper_rule_targets %{
    float: :"google.protobuf.FloatValue",
    double: :"google.protobuf.DoubleValue",
    int32: :"google.protobuf.Int32Value",
    int64: :"google.protobuf.Int64Value",
    uint32: :"google.protobuf.UInt32Value",
    uint64: :"google.protobuf.UInt64Value",
    bool: :"google.protobuf.BoolValue",
    string: :"google.protobuf.StringValue",
    bytes: :"google.protobuf.BytesValue"
  }

  @message_rule_targets %{
    any: :"google.protobuf.Any",
    duration: :"google.protobuf.Duration",
    field_mask: :"google.protobuf.FieldMask",
    timestamp: :"google.protobuf.Timestamp"
  }

  @doc """
  Raises when a field carries standard rules of a family its type does not allow.
  """
  def validate_standard_rule_family_target!(
        target,
        field,
        %{type: {family, rules_value}}
      )
      when is_atom(family) and is_map(rules_value) do
    unless standard_rule_family_target?(family, field) do
      raise CompileError,
        target: target,
        constraint_id: first_standard_rule_id(family, rules_value),
        stage: :type,
        cause: "mismatched rule type and field type"
    end
  end

  def validate_standard_rule_family_target!(_target, _field, _rules), do: :ok

  @doc """
  Returns true when the field's buf.validate.field rules set a typed rule family.
  """
  def predefined_field_rules?(%{type: {_rules_name, rules_value}}) when is_map(rules_value),
    do: true

  def predefined_field_rules?(_rules), do: false

  @doc """
  Returns true when the field's rules need a non-CEL (native) op.
  """
  def native_field_rules?(%{type: {:any, rules}}) when is_map(rules) do
    any_rule_values(rules, :in) != [] or any_rule_values(rules, :not_in) != []
  end

  def native_field_rules?(%{type: {:enum, rules}}) when is_map(rules) do
    Map.get(rules, :defined_only) == true
  end

  def native_field_rules?(_rules), do: false

  @doc """
  Returns the values of an Any in/not_in rule, normalized to a list.
  """
  def any_rule_values(rules, field_name) do
    case Map.get(rules, field_name, []) do
      values when is_list(values) -> values
      value -> [value]
    end
  end

  defp standard_rule_family_target?(family, field)
       when is_map_key(@scalar_rule_targets, family) do
    scalar_rule_target?(field, Map.fetch!(@scalar_rule_targets, family)) or
      wrapper_rule_target?(field, Map.get(@wrapper_rule_targets, family))
  end

  defp standard_rule_family_target?(:enum, field), do: scalar_rule_target?(field, :TYPE_ENUM)
  defp standard_rule_family_target?(:repeated, %{cardinality: :repeated}), do: true
  defp standard_rule_family_target?(:repeated, _field), do: false
  defp standard_rule_family_target?(:map, %{cardinality: :map}), do: true
  defp standard_rule_family_target?(:map, _field), do: false

  defp standard_rule_family_target?(family, field)
       when is_map_key(@message_rule_targets, family) do
    message_rule_target?(field, Map.fetch!(@message_rule_targets, family))
  end

  defp standard_rule_family_target?(_family, _field), do: true

  defp scalar_rule_target?(%{cardinality: :singular, type: type}, type), do: true
  defp scalar_rule_target?(_field, _type), do: false

  defp wrapper_rule_target?(_field, nil), do: false
  defp wrapper_rule_target?(field, type_name), do: message_rule_target?(field, type_name)

  defp message_rule_target?(
         %{cardinality: :singular, type: type, type_name: type_name},
         type_name
       ) do
    Field.message_type?(type)
  end

  defp message_rule_target?(_field, _type_name), do: false

  defp first_standard_rule_id(family, rules_value) do
    case first_standard_rule_field(rules_value) do
      nil -> Atom.to_string(family)
      field -> Atom.to_string(family) <> "." <> Atom.to_string(field)
    end
  end

  defp first_standard_rule_field(rules_value) do
    rules_value
    |> Enum.map(fn {field, value} -> concrete_rule_field(field, value) end)
    |> Enum.reject(&(&1 == @extensions))
    |> Enum.sort()
    |> List.first()
  end

  defp concrete_rule_field(_field, {oneof_field, _value}) when is_atom(oneof_field),
    do: oneof_field

  defp concrete_rule_field(field, _value), do: field
end
