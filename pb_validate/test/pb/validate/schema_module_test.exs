defmodule PB.Validate.SchemaModuleTest.Fixtures do
  def descriptor_set do
    %{
      file: [
        %{
          name: "schema_test.proto",
          package: "schema_test",
          syntax: "proto3",
          message_type: [
            %{
              name: "Greeting",
              field: [
                %{name: "text", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_STRING},
                %{name: "count", number: 2, label: :LABEL_OPTIONAL, type: :TYPE_INT32}
              ]
            }
          ]
        }
      ]
    }
  end
end

defmodule PB.Validate.SchemaModuleTest.LiteralSchema do
  use PB.Schema, descriptor_set: PB.Validate.SchemaModuleTest.Fixtures.descriptor_set()
end

defmodule PB.Validate.SchemaModuleTest.ValidatedSchema do
  use PB.Schema,
    descriptor_set: PB.Validate.SchemaModuleTest.Fixtures.descriptor_set(),
    plugins: [PB.Validate]
end

defmodule PB.Validate.SchemaModuleTest do
  # `use PB.Schema, plugins: [PB.Validate]` in a project that depends on
  # pb_validate.
  use ExUnit.Case, async: true

  alias PB.TestSupport.ValidatedSchema, as: ProjectSchema
  alias PB.Validate.SchemaModuleTest.Fixtures
  alias PB.Validate.SchemaModuleTest.LiteralSchema
  alias PB.Validate.SchemaModuleTest.ValidatedSchema

  @message :"schema_test.Greeting"

  test "returns the same schema term on every call, also when it holds regexes" do
    mod = Module.concat(__MODULE__, "WithRegexes#{System.unique_integer([:positive])}")

    [{^mod, _bin}] =
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            use PB.Schema,
              descriptor: "test/fixtures/schema/validate_predefined.binpb",
              plugins: [PB.Validate]
          end
        end
      )

    assert :erts_debug.same(mod.schema(), mod.schema())
  end

  describe "schema module dispatch" do
    test "PB.Validate.validate accepts a schema module compiled with the plugin" do
      assert :ok = PB.Validate.validate(%{text: "hi"}, ValidatedSchema, @message)
      assert ValidatedSchema.schema() == PB.compile(Fixtures.descriptor_set(), plugins: [PB.Validate])
    end

    test "PB.Validate.validate rejects a schema compiled without the plugin" do
      assert_raise ArgumentError, ~r/compile it with `plugins: \[PB.Validate\]`/, fn ->
        PB.Validate.validate(%{text: "hi"}, LiteralSchema, @message)
      end

      assert_raise ArgumentError, ~r/compile it with `plugins: \[PB.Validate\]`/, fn ->
        PB.Validate.validate(%{text: "hi"}, PB.compile(Fixtures.descriptor_set()), @message)
      end
    end

    test "generated validate/2,3 dispatches to PB.Validate" do
      assert :ok = ValidatedSchema.validate(%{text: "hi"}, @message)
      assert :ok = ValidatedSchema.validate!(%{text: "hi"}, @message)
    end

    test "only schema modules compiled with PB.Validate get validate/2,3" do
      Code.ensure_loaded!(LiteralSchema)
      refute function_exported?(LiteralSchema, :validate, 2)
      refute function_exported?(LiteralSchema, :validate!, 3)
      assert function_exported?(ValidatedSchema, :validate, 3)
    end

  end

  test "a schema module compiled with the project gets validate/2,3" do
    message = :"validate_structural.StructuralRules"

    Code.ensure_loaded!(ProjectSchema)
    assert function_exported?(ProjectSchema, :validate, 3)
    assert :ok = ProjectSchema.validate(%{required_value: "x", choice: {:id, 1}}, message)

    assert {:error, %PB.Validate.Error{violations: [%{rule_id: "required"}]}} =
             ProjectSchema.validate(%{choice: {:id, 1}}, message)
  end
end
