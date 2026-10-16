defmodule PB.Validate.Compiler.Options do
  @moduledoc false

  # Decodes the buf.validate rules of a schema whose descriptor set does not
  # define the buf.validate extensions, as a set built without
  # `--include_imports` does not.
  #
  # `PB.compile/2` decodes custom options through the extensions the descriptor
  # set itself defines, so without `buf/validate/validate.proto` in the set the
  # rules stay unknown fields of the descriptor options. This decodes them
  # through the standard-rule schema, which merges in the bundled
  # `buf/validate/validate.proto` (and the set's own extensions of the rule
  # messages, for predefined rules), and writes them into the options as
  # `PB.compile/2` would have. A schema whose options carry no unknown
  # buf.validate fields, such as one compiled from a set built with
  # `--include_imports`, is returned as it is.

  alias PB.Schema.ExtensionMaterializer
  alias PB.Validate.Schema, as: ValidateSchema

  @unknowns PB.UnknownField.key()
  @field_options :"google.protobuf.FieldOptions"
  @message_options :"google.protobuf.MessageOptions"
  @oneof_options :"google.protobuf.OneofOptions"

  # The field numbers of the buf.validate extensions, by the options message
  # they extend.
  @rule_numbers PB.Validate.BundledSchema.schema().extensions_by_name
                |> Map.values()
                |> Enum.group_by(& &1.extendee, & &1.number)

  @doc """
  Returns `schema` with the buf.validate rules in its descriptor options
  decoded.
  """
  @spec materialize(PB.schema()) :: PB.schema()
  def materialize(schema) when is_map(schema) do
    if unknown_rules?(schema) do
      ExtensionMaterializer.materialize(schema, ValidateSchema.standard_rule_schema(schema))
    else
      schema
    end
  end

  defp unknown_rules?(schema) do
    Enum.any?(schema.extensions_by_name, fn {_name, extension} ->
      unknown_rules?(extension, @field_options)
    end) or
      Enum.any?(schema.messages, fn {_fqn, message} -> message_unknown_rules?(message) end)
  end

  defp message_unknown_rules?(%{fields_by_name: fields} = message) do
    unknown_rules?(message, @message_options) or
      Enum.any?(fields, fn {_name, field} -> unknown_rules?(field, @field_options) end) or
      Enum.any?(message.extensions_by_name, fn {_name, extension} ->
        unknown_rules?(extension, @field_options)
      end) or
      Enum.any?(message.oneofs, fn {_index, oneof} -> unknown_rules?(oneof, @oneof_options) end)
  end

  defp message_unknown_rules?(_message), do: false

  defp unknown_rules?(entry, options_message) do
    case entry do
      %{options: %{@unknowns => unknowns}} ->
        numbers = Map.fetch!(@rule_numbers, options_message)
        Enum.any?(unknowns, &(&1.number in numbers))

      _entry ->
        false
    end
  end
end
