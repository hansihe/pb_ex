defmodule PB.Validate.DescriptorImportsTest do
  # A descriptor set built with `--include_imports` carries
  # `buf/validate/validate.proto`, whose extension definitions `PB.compile/2`
  # decodes the rules with. The `*_no_imports` fixtures are the same sets
  # without it (and the other files only it imports), as protoc writes them
  # without `--include_imports`: `PB.compile/2` rejects them, and compiled with
  # `allow_missing_imports: true` their rules stay unknown fields of the
  # options, which `PB.Validate` rejects.
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

  test "PB.compile/2 rejects a set without validate.proto" do
    error =
      assert_raise PB.SchemaError, fn ->
        compile(@structural_no_imports, plugins: [PB.Validate])
      end

    assert error.kind == :missing_imports
    assert error.reason == [{"proto/validate_structural.proto", ["buf/validate/validate.proto"]}]
  end

  test "allowed to miss validate.proto, PB.compile/2 leaves the rules unknown fields" do
    options = required_value_options(compile(@structural_no_imports, allow_missing_imports: true))

    refute Map.has_key?(options, @extensions)
    assert [%PB.UnknownField{number: 1159}] = options[PB.UnknownField.key()]
  end

  test "allowed to miss validate.proto, PB.Validate rejects the set's undecoded rules" do
    for {path, target} <- [
          {@structural_no_imports, ":\"validate_structural.StructuralRules\""},
          {@custom_predefined_no_imports, ":\"validate_custom_predefined."}
        ] do
      error =
        assert_raise PB.SchemaError, fn ->
          compile(path, plugins: [PB.Validate], allow_missing_imports: true)
        end

      assert error.kind == :invalid_schema
      message = Exception.message(error)
      assert message =~ "PB failed to compile: invalid schema for #{target}"

      assert message =~
               "its buf.validate rules can't be read, as the descriptor set lacks " <>
                 "buf/validate/validate.proto. Build the set with its imports"
    end
  end

  test "with validate.proto in the set, messages validate" do
    structural = compile(@structural, plugins: [PB.Validate])
    message = :"validate_structural.StructuralRules"

    assert :ok = PB.Validate.validate(%{required_value: "x", choice: {:id, 1}}, structural, message)

    assert {:error, %PB.Validate.Error{violations: violations}} =
             PB.Validate.validate(%{}, structural, message)

    assert Enum.map(violations, & &1.rule_id) == ["required", "required"]

    custom = compile(@custom_predefined, plugins: [PB.Validate])
    message = :"validate_custom_predefined.CustomPredefinedRules"

    assert :ok = PB.Validate.validate(%{value: "good", items: ["fine"], count: 2}, custom, message)

    assert {:error, %PB.Validate.Error{violations: [%{rule_id: "string.not_bad"}]}} =
             PB.Validate.validate(%{value: "bad", items: ["fine"], count: 2}, custom, message)

    assert {:error, %PB.Validate.Error{violations: [%{rule_id: "int64.abs_in"}]}} =
             PB.Validate.validate(%{value: "good", items: ["fine"], count: 3}, custom, message)
  end
end
