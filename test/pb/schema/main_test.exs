defmodule PB.Schema.MainTest do
  use ExUnit.Case, async: true

  alias PB.Schema.Main
  alias PB.Validate.Schema.CELSource
  alias PB.Validate.Schema.Predefined

  @extensions :__extensions__
  @predefined :"buf.validate.predefined"

  test "embeds the bundled main descriptor set as a normal schema provider" do
    schema = Main.schema()

    assert Map.has_key?(schema.messages, :"google.protobuf.FileDescriptorSet")
    assert Map.has_key?(schema.messages, :"google.protobuf.Int32Value")
    assert Map.has_key?(schema.messages, :"google.protobuf.Value")
    assert Map.has_key?(schema.messages, :"google.protobuf.ListValue")
    assert Map.has_key?(schema.messages, :"google.protobuf.Struct")
    assert Map.has_key?(schema.messages, :"buf.validate.FieldRules")
    assert Map.has_key?(schema.enums, :"buf.validate.KnownRegex")
  end

  test "decodes the bundled main descriptor set through its schema wrapper" do
    binary = File.read!("priv/main.binpb")

    assert {:ok, %{file: files}} = Main.decode(binary, :"google.protobuf.FileDescriptorSet")

    file_names = MapSet.new(files, & &1.name)

    assert MapSet.member?(file_names, "google/protobuf/descriptor.proto")
    assert MapSet.member?(file_names, "google/protobuf/struct.proto")
    assert MapSet.member?(file_names, "google/protobuf/wrappers.proto")
    assert MapSet.member?(file_names, "buf/validate/validate.proto")
    assert MapSet.member?(file_names, "proto/main.proto")
  end

  test "bootstrap descriptor schema decodes bundled validate predefined rules" do
    descriptor_set =
      "priv/main.binpb"
      |> File.read!()
      |> PB.__decode_descriptor_set_with_schema__!(PB.Bootstrap.descriptor_schema())

    validate_file = Enum.find(descriptor_set.file, &(&1.name == "buf/validate/validate.proto"))
    string_rules = Enum.find(validate_file.message_type, &(&1.name == "StringRules"))
    email = Enum.find(string_rules.field, &(&1.name == "email"))

    assert predefined = email.options[@extensions][@predefined]
    assert Enum.map(predefined.cel, & &1.id) == ["string.email", "string.email_empty"]
  end

  test "compiled main schema preserves predefined rule metadata" do
    email =
      get_in(Main.schema(), [:messages, :"buf.validate.StringRules", :fields_by_name, :email])

    assert %{validate: %{predefined: %Predefined{cel: rules}}} = email
    assert [%CELSource{id: "string.email"}, %CELSource{id: "string.email_empty"}] = rules
  end
end
