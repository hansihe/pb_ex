defmodule PB.Validate.Compiler.Options do
  @moduledoc false

  # Rejects a schema whose buf.validate rules `PB.compile/2` left undecoded.
  #
  # `PB.compile/2` decodes custom options through the extensions the descriptor
  # set defines, and rejects a set without the files its files import, such as
  # `buf/validate/validate.proto`. Compiled with `allow_missing_imports: true`
  # instead, or missing the file because it was imported with `import option`
  # (which `PB.compile/2` allows, and `buf build` never includes), such a set
  # keeps its rules as unknown fields of the descriptor options, where they
  # would silently compile to no rules.

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
  Returns `schema`, raising `PB.SchemaError` when its descriptor options hold
  undecoded buf.validate rules.
  """
  @spec check_decoded!(PB.schema()) :: PB.schema()
  def check_decoded!(schema) when is_map(schema) do
    case undecoded_target(schema) do
      nil ->
        schema

      target ->
        raise PB.SchemaError,
          kind: :invalid_schema,
          operation: :compile,
          type_name: target,
          reason:
            "its buf.validate rules can't be read, as the descriptor set lacks " <>
              "buf/validate/validate.proto. Import it with a regular `import`, which " <>
              "`buf build` includes by default (it never includes `import option` files), " <>
              "or build the set with `protoc --include_imports`"
    end
  end

  # The name of an extension or message with undecoded rules, if any.
  defp undecoded_target(schema) do
    Enum.find_value(schema.extensions_by_name, fn {name, extension} ->
      if unknown_rules?(extension, @field_options), do: name
    end) ||
      Enum.find_value(schema.messages, fn {fqn, message} ->
        if message_unknown_rules?(message), do: fqn
      end)
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
