defmodule PB.Validate.BundledSchemaTest do
  use ExUnit.Case, async: true

  alias PB.Validate.BundledSchema

  @extensions :__extensions__
  @predefined :"buf.validate.predefined"

  test "compiling the bundled descriptor set decodes the predefined rules of the standard rules" do
    descriptor_set = "priv/validate.binpb" |> File.read!() |> PB.decode_descriptor_set!()

    validate_file = Enum.find(descriptor_set.file, &(&1.name == "buf/validate/validate.proto"))
    string_rules = Enum.find(validate_file.message_type, &(&1.name == "StringRules"))
    email = Enum.find(string_rules.field, &(&1.name == "email"))

    # pb knows no buf.validate extensions; the set's own definitions decode them.
    refute Map.has_key?(email.options, @extensions)

    schema = PB.compile(descriptor_set)
    email = get_in(schema, [:messages, :"buf.validate.StringRules", :fields_by_name, :email])

    assert predefined = email.options[@extensions][@predefined]
    assert Enum.map(predefined.cel, & &1.id) == ["string.email", "string.email_empty"]
  end

  test "compiled bundled schema keeps the predefined rule options and runs no plugins" do
    schema = BundledSchema.schema()
    email = get_in(schema, [:messages, :"buf.validate.StringRules", :fields_by_name, :email])

    assert schema.plugins == []

    assert %{cel: [%{id: "string.email"}, %{id: "string.email_empty"}]} =
             email.options[@extensions][@predefined]
  end
end
