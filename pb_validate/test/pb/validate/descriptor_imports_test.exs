defmodule PB.Validate.DescriptorImportsTest do
  # A descriptor set built with `--include_imports` carries
  # `buf/validate/validate.proto`, whose extension definitions `PB.compile/2`
  # decodes the rules with. The `*_no_imports` fixtures are the same sets
  # without it (and the other files only it imports), as protoc writes them
  # without `--include_imports`: their rules stay unknown fields of the options
  # until `PB.Validate` decodes them with its bundled `validate.proto`.
  use ExUnit.Case, async: true

  @extensions :__extensions__
  @field_rules :"buf.validate.field"

  @structural "test/fixtures/schema/validate_structural.binpb"
  @structural_no_imports "test/fixtures/schema/validate_structural_no_imports.binpb"
  @custom_predefined "test/fixtures/schema/validate_custom_predefined.binpb"
  @custom_predefined_no_imports "test/fixtures/schema/validate_custom_predefined_no_imports.binpb"

  defp compile(path, opts \\ []),
    do: path |> File.read!() |> PB.decode_descriptor_set!() |> PB.compile(opts)

  defp required_value_options(schema) do
    schema.messages[:"validate_structural.StructuralRules"].fields_by_name.required_value.options
  end

  test "PB.compile/2 decodes the rules through the set's own validate.proto" do
    assert %{@extensions => %{@field_rules => %{required: true}}} =
             required_value_options(compile(@structural))
  end

  test "without validate.proto in the set, PB.compile/2 leaves the rules unknown fields" do
    options = required_value_options(compile(@structural_no_imports, allow_missing_imports: true))

    refute Map.has_key?(options, @extensions)
    assert [%PB.UnknownField{number: 1159}] = options[PB.UnknownField.key()]
  end

  test "without validate.proto in the set, PB.Validate compiles the same rules" do
    for {with_imports, without_imports} <- [
          {@structural, @structural_no_imports},
          {@custom_predefined, @custom_predefined_no_imports}
        ] do
      assert validate_data(compile(without_imports, plugins: [PB.Validate], allow_missing_imports: true)) ==
               validate_data(compile(with_imports, plugins: [PB.Validate]))
    end
  end

  test "without validate.proto in the set, messages validate as with it" do
    structural =
      compile(@structural_no_imports, plugins: [PB.Validate], allow_missing_imports: true)
    message = :"validate_structural.StructuralRules"

    assert :ok = PB.Validate.validate(%{required_value: "x", choice: {:id, 1}}, structural, message)

    assert {:error, %PB.Validate.Error{violations: violations}} =
             PB.Validate.validate(%{}, structural, message)

    assert Enum.map(violations, & &1.rule_id) == ["required", "required"]

    custom =
      compile(@custom_predefined_no_imports, plugins: [PB.Validate], allow_missing_imports: true)
    message = :"validate_custom_predefined.CustomPredefinedRules"

    assert :ok = PB.Validate.validate(%{value: "good", items: ["fine"], count: 2}, custom, message)

    assert {:error, %PB.Validate.Error{violations: [%{rule_id: "string.not_bad"}]}} =
             PB.Validate.validate(%{value: "bad", items: ["fine"], count: 2}, custom, message)

    assert {:error, %PB.Validate.Error{violations: [%{rule_id: "int64.abs_in"}]}} =
             PB.Validate.validate(%{value: "good", items: ["fine"], count: 3}, custom, message)
  end

  test "a schema module compiled from a set without validate.proto gets the rules" do
    mod = Module.concat(__MODULE__, "NoImports#{System.unique_integer([:positive])}")

    [{^mod, _bin}] =
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            use PB.Schema,
              descriptor: unquote(@structural_no_imports),
              plugins: [PB.Validate],
              allow_missing_imports: true
          end
        end
      )

    message = :"validate_structural.StructuralRules"

    assert :ok = mod.validate(%{required_value: "x", choice: {:id, 1}}, message)
    assert {:error, %PB.Validate.Error{}} = mod.validate(%{choice: {:id, 1}}, message)
  end

  # The validation data PB.Validate compiled into the schema's own messages.
  defp validate_data(schema) do
    for {fqn, message} <- schema.messages,
        not String.starts_with?(Atom.to_string(fqn), ["google.", "buf."]),
        into: %{} do
      fields = Map.new(message.fields_by_name, fn {name, field} -> {name, field[PB.Validate]} end)
      oneofs = Map.new(message.oneofs, fn {index, oneof} -> {index, oneof[PB.Validate]} end)
      {fqn, {message[PB.Validate], fields, oneofs}}
    end
  end
end
