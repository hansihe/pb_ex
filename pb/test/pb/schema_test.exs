defmodule PB.SchemaTest.Fixtures do
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

  def descriptor_binary do
    {:ok, iodata} =
      PB.encode(
        descriptor_set(),
        PB.Bootstrap.descriptor_schema(),
        :"google.protobuf.FileDescriptorSet"
      )

    IO.iodata_to_binary(iodata)
  end
end

defmodule PB.SchemaTest.LiteralSchema do
  use PB.Schema, descriptor_set: PB.SchemaTest.Fixtures.descriptor_set()
end

defmodule PB.SchemaTest.ValidatedSchema do
  use PB.Schema, descriptor_set: PB.SchemaTest.Fixtures.descriptor_set(), plugins: [PB.Validate]
end

defmodule PB.SchemaTest do
  use ExUnit.Case, async: true

  alias PB.SchemaTest.Fixtures
  alias PB.SchemaTest.LiteralSchema
  alias PB.SchemaTest.ValidatedSchema

  @message :"schema_test.Greeting"

  defp assert_error(result, attrs) do
    assert {:error, %{__exception__: true} = error} = result

    Enum.each(attrs, fn {key, expected} ->
      assert Map.fetch!(error, key) == expected
    end)

    error
  end

  test "embeds a descriptor set map as a compiled schema" do
    expected = PB.compile(Fixtures.descriptor_set())

    assert LiteralSchema.__pb_schema__() == expected
    assert LiteralSchema.schema() == expected
  end

  test "descriptor compiler returns draft schema before runtime preparation" do
    draft = PB.Schema.Compiler.compile(Fixtures.descriptor_set())
    msg = draft.messages[@message]
    field = msg.fields_by_name[:text]

    refute Map.has_key?(msg, :fields_by_number)
    refute Map.has_key?(msg, :required_fields)
    refute Map.has_key?(field, :tag)

    prepared = PB.Schema.Prepare.prepare(draft)
    prepared_msg = prepared.messages[@message]

    assert prepared_msg.fields_by_number[1].name == :text
    assert prepared_msg.fields_by_name[:text].tag == <<10>>
  end

  test "bootstrap schema carries prepared runtime metadata" do
    schema = PB.Bootstrap.minimal_schema()
    msg = schema.messages[:"google.protobuf.FieldDescriptorProto"]
    field = msg.fields_by_name[:type]

    assert msg.kind == :message
    assert msg.fields_by_number[5] == field
    assert field.tag == <<40>>
    assert field.enum.by_name[:TYPE_MESSAGE] == 11
    assert Enum.any?(msg.default_fields, &(&1.name == :type))
  end

  test "generated encode and decode wrappers use the embedded schema" do
    {:ok, iodata} = LiteralSchema.encode(%{text: "hi", count: 7}, @message)

    assert {:ok, %{text: "hi", count: 7}} =
             LiteralSchema.decode(IO.iodata_to_binary(iodata), @message)
  end

  test "generated encode wrapper forwards encoder options" do
    assert_error(LiteralSchema.encode(%{bogus: 1}, @message),
      operation: :encode,
      kind: :unknown_field,
      message_name: @message,
      path: [:bogus],
      protobuf_message: @message
    )

    assert {:ok, _iodata} =
             LiteralSchema.encode(%{bogus: 1}, @message, unknown_fields: :ignore)
  end

  test "generated normalize wrapper returns canonical decoded values" do
    assert {:ok, %{}} = LiteralSchema.normalize(%{text: "", count: 0}, @message)

    assert {:ok, %{text: "", count: 0}} =
             LiteralSchema.normalize(%{text: "", count: 0}, @message, defaults: true)

    assert_error(LiteralSchema.normalize(%{bogus: 1}, @message),
      operation: :normalize,
      kind: :unknown_field,
      message_name: @message,
      path: [:bogus],
      protobuf_message: @message
    )

    assert {:ok, %{}} =
             LiteralSchema.normalize(%{bogus: 1}, @message, unknown_fields: :ignore)
  end

  test "normalize applies nested protobuf field rules" do
    schema = PB.TestSupport.TestSchema.schema()
    message = :"cel.expr.conformance.proto2.TestAllTypes"

    assert {:ok, %{}} = PB.normalize(%{single_int32: 0}, schema, message)

    assert {:ok, %{single_int32_wrapper: %{}}} =
             PB.normalize(%{single_int32_wrapper: %{value: 0}}, schema, message)

    assert {:ok, %{single_float_wrapper: %{value: :infinity}}} =
             PB.normalize(%{single_float_wrapper: %{value: 1.4e55}}, schema, message)

    assert_error(
      PB.normalize(%{single_int32_wrapper: %{value: 12_345_678_900}}, schema, message),
      operation: :normalize,
      kind: :value_out_of_range,
      message_name: message,
      path: [:single_int32_wrapper, :value],
      min: -2_147_483_648,
      max: 2_147_483_647,
      value: 12_345_678_900
    )
  end

  test "normalize threads :message_names through to the trailing decode" do
    schema = PB.TestSupport.TestSchema.schema()
    message = :"cel.expr.conformance.proto2.TestAllTypes"

    assert {:ok, decoded} =
             PB.normalize(%{single_int32: 1}, schema, message, message_names: :root)

    assert decoded[:__message_name__] == message

    assert_error(PB.normalize(%{}, schema, message, message_names: :all),
      operation: :normalize,
      kind: :invalid_option,
      message_name: message,
      option: :message_names,
      value: :all
    )
  end

  test "map fields stay length-prefixed under delimited edition message defaults" do
    schema =
      PB.compile(%{
        file: [
          %{
            name: "edition_maps.proto",
            package: :edition_maps,
            syntax: :editions,
            edition: :EDITION_2023,
            options: %{features: %{message_encoding: :DELIMITED}},
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{
                    name: :items,
                    number: 1,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REPEATED,
                    type_name: :"edition_maps.Msg.ItemsEntry"
                  },
                  %{
                    name: :children,
                    number: 2,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_REPEATED,
                    type_name: :"edition_maps.Msg.ChildrenEntry"
                  },
                  %{
                    name: :child,
                    number: 3,
                    type: :TYPE_MESSAGE,
                    label: :LABEL_OPTIONAL,
                    type_name: :"edition_maps.Child"
                  }
                ],
                nested_type: [
                  %{
                    name: :ItemsEntry,
                    options: %{map_entry: true},
                    field: [
                      %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                      %{name: :value, number: 2, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
                    ]
                  },
                  %{
                    name: :ChildrenEntry,
                    options: %{map_entry: true},
                    field: [
                      %{name: :key, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                      %{
                        name: :value,
                        number: 2,
                        type: :TYPE_MESSAGE,
                        label: :LABEL_OPTIONAL,
                        type_name: :"edition_maps.Child"
                      }
                    ]
                  }
                ]
              },
              %{
                name: :Child,
                field: [%{name: :value, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}]
              }
            ],
            enum_type: []
          }
        ]
      })

    msg = schema.messages[:"edition_maps.Msg"]

    assert %{
             cardinality: :map,
             encoding: :length_prefixed,
             wire_type: 2
           } = msg.fields_by_name.items

    assert %{
             cardinality: :map,
             encoding: :length_prefixed,
             wire_type: 2,
             map_value: %{encoding: :length_prefixed, wire_type: 2}
           } = msg.fields_by_name.children

    assert %{
             cardinality: :singular,
             encoding: :delimited,
             wire_type: 3
           } = msg.fields_by_name.child
  end

  test "generated bang wrappers use the embedded schema" do
    iodata = LiteralSchema.encode!(%{text: "hi", count: 7}, @message)

    assert %{text: "hi", count: 7} =
             LiteralSchema.decode!(IO.iodata_to_binary(iodata), @message)

    assert_raise PB.DecodeError, ~r/failed to decode/, fn ->
      LiteralSchema.decode!(<<0x80>>, @message)
    end

    assert LiteralSchema.normalize!(%{text: "", count: 0}, @message) == %{}
  end

  test "generated decode wrapper forwards decoder options" do
    assert {:ok, %{text: "", count: 0}} = LiteralSchema.decode(<<>>, @message, defaults: true)

    assert_error(LiteralSchema.decode(<<>>, @message, defaults: :yes),
      operation: :decode,
      kind: :invalid_option,
      message_name: @message,
      option: :defaults,
      value: :yes
    )
  end

  test "embeds a descriptor binary file as a compiled schema" do
    path = write_descriptor_file!()
    mod = unique_module("FromFile")

    [{^mod, _bin}] =
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            use PB.Schema, descriptor: unquote(path)
          end
        end
      )

    assert mod.schema() == PB.compile(Fixtures.descriptor_set())
  end

  test "returns the same schema term on every call, also when it holds regexes" do
    mod = unique_module("WithRegexes")

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

  test "descriptor file path may come from a module attribute" do
    path = write_descriptor_file!()
    mod = unique_module("FromModuleAttribute")

    [{^mod, _bin}] =
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            @descriptor_path unquote(path)
            use PB.Schema, descriptor: @descriptor_path
          end
        end
      )

    {:ok, iodata} = mod.encode(%{text: "from file", count: 9}, @message)

    assert {:ok, %{text: "from file", count: 9}} =
             mod.decode(IO.iodata_to_binary(iodata), @message)
  end

  test "requires exactly one schema source option" do
    mod = unique_module("MissingSource")

    assert_raise ArgumentError, "expected exactly one of :descriptor or :descriptor_set", fn ->
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            use PB.Schema
          end
        end
      )
    end
  end

  describe "schema module dispatch" do
    test "PB.encode/decode/normalize accept a schema module" do
      {:ok, bin} = PB.encode(%{text: "hi", count: 3}, LiteralSchema, @message)
      assert {:ok, %{text: "hi", count: 3}} = PB.decode(bin, LiteralSchema, @message)
      assert {:ok, %{}} = PB.normalize(%{text: "", count: 0}, LiteralSchema, @message)
    end

    test "PB.message_equal? accepts a schema module" do
      assert PB.message_equal?(%{text: "hi"}, %{text: "hi"}, LiteralSchema, @message)
      refute PB.message_equal?(%{text: "hi"}, %{text: "ho"}, LiteralSchema, @message)
    end

    test "PB.JSON.encode/decode accept a schema module" do
      {:ok, json} = PB.JSON.to_term(%{text: "hi", count: 3}, LiteralSchema, @message)
      assert json == %{"text" => "hi", "count" => 3}

      assert {:ok, %{text: "hi", count: 3}} =
               PB.JSON.from_term(json, LiteralSchema, @message)
    end

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

    test "a compiled schema map still works" do
      schema = PB.compile(Fixtures.descriptor_set())
      {:ok, bin} = PB.encode(%{text: "hi"}, schema, @message)
      assert {:ok, %{text: "hi"}} = PB.decode(bin, schema, @message)
    end

    test "non-schema modules raise a clear error" do
      assert_raise ArgumentError,
                   ~r/expected a PB schema map or a module that `use PB.Schema`/,
                   fn -> PB.encode(%{}, Enum, @message) end
    end

    test "random atoms that don't resolve to a module raise a clear error" do
      assert_raise ArgumentError,
                   ~r/expected a PB schema map or a module that `use PB.Schema`/,
                   fn -> PB.encode(%{}, :not_a_module, @message) end
    end

    test "non-atom non-map schema values raise a clear error" do
      assert_raise ArgumentError,
                   ~r/expected a PB schema map or a module that `use PB.Schema`/,
                   fn -> PB.encode(%{}, 42, @message) end
    end
  end

  test "rejects unknown options" do
    mod = unique_module("UnknownOption")

    assert_raise ArgumentError, "unknown PB.Schema option(s): [:schema]", fn ->
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            use PB.Schema, schema: %{}
          end
        end
      )
    end
  end

  defp write_descriptor_file! do
    dir = Path.join(System.tmp_dir!(), "pb_schema_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "schema.binpb")
    File.write!(path, Fixtures.descriptor_binary())
    path
  end

  defp unique_module(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
