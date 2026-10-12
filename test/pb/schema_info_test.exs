defmodule PB.SchemaInfoTest do
  use ExUnit.Case, async: true

  alias PB.Schema
  alias PB.Schema.Info
  alias PB.TestSupport.Fixtures

  setup_all do
    %{schema: PB.compile(Fixtures.person_descriptor_set())}
  end

  # ── list_* ─────────────────────────────────────────────────────────

  describe "list_messages/1" do
    test "returns sorted FQNs", %{schema: schema} do
      names = Schema.list_messages(schema)

      # Synthetic map-entry message :"test.Person.TagsEntry" is included.
      assert :"test.Person" in names
      assert :"test.PhoneNumber" in names
      assert :"test.Pet" in names
      assert :"test.Fish" in names
      assert :"test.Person.TagsEntry" in names
      assert names == Enum.sort(names)
    end

    test "accepts a schema module", _ctx do
      assert Schema.list_messages(PB.Schema.Main)
             |> Enum.any?(fn name ->
               name == :"google.protobuf.FileDescriptorSet"
             end)
    end
  end

  describe "list_enums/1" do
    test "returns sorted FQNs", %{schema: schema} do
      assert Schema.list_enums(schema) == [:"test.Role"]
    end
  end

  describe "list_services/1" do
    test "empty when no services", %{schema: schema} do
      assert Schema.list_services(schema) == []
    end

    test "returns sorted FQNs from a grpc schema" do
      %{schema: schema} = Fixtures.grpc_schema_fixture()
      assert Schema.list_services(schema) == [:"grpct.Greeter"]
    end
  end

  describe "list_extensions/1" do
    test "empty for a schema with no extensions", %{schema: schema} do
      assert Schema.list_extensions(schema) == []
    end
  end

  # ── fetch_/!/2 ────────────────────────────────────────────────────

  describe "fetch_message/2 + message!/2" do
    test "returns scalar field info", %{schema: schema} do
      {:ok, msg} = Schema.fetch_message(schema, :"test.PhoneNumber")

      assert %Info.Message{name: :"test.PhoneNumber", map_entry?: false, syntax: :proto3} = msg
      assert [%Info.Field{name: :number, number: 1, type: {:scalar, :string}}] = msg.fields
    end

    test "fields are ordered by field number", %{schema: schema} do
      {:ok, msg} = Schema.fetch_message(schema, :"test.Person")

      numbers = Enum.map(msg.fields, & &1.number)
      assert numbers == Enum.sort(numbers)
    end

    test "message-typed fields use {:message, fqn}", %{schema: schema} do
      {:ok, msg} = Schema.fetch_message(schema, :"test.Person")

      phones = Enum.find(msg.fields, &(&1.name == :phones))
      assert phones.type == {:message, :"test.PhoneNumber"}
      assert phones.cardinality == :repeated
    end

    test "enum-typed fields use {:enum, fqn}", %{schema: schema} do
      {:ok, msg} = Schema.fetch_message(schema, :"test.Person")

      role = Enum.find(msg.fields, &(&1.name == :role))
      assert role.type == {:enum, :"test.Role"}
    end

    test "map fields use {:map, key_type, value_type} and not the synthetic entry", %{
      schema: schema
    } do
      {:ok, msg} = Schema.fetch_message(schema, :"test.Person")

      tags = Enum.find(msg.fields, &(&1.name == :tags))
      assert tags.type == {:map, {:scalar, :string}, {:scalar, :int32}}
      assert tags.cardinality == :map
    end

    test "oneof fields carry the oneof declaration name", %{schema: schema} do
      {:ok, msg} = Schema.fetch_message(schema, :"test.Person")

      pet = Enum.find(msg.fields, &(&1.name == :pet))
      fish = Enum.find(msg.fields, &(&1.name == :fish))

      assert pet.oneof == :companion
      assert fish.oneof == :companion
      assert pet.presence == :oneof
    end

    test "oneofs list reflects declaration order", %{schema: schema} do
      {:ok, msg} = Schema.fetch_message(schema, :"test.Person")

      assert msg.oneofs == [%Info.Oneof{name: :companion, fields: [:pet, :fish]}]
    end

    test "fetch returns :error for unknown message", %{schema: schema} do
      assert Schema.fetch_message(schema, :"nope.Nada") == :error
    end

    test "message! raises PB.Error with :unknown_message", %{schema: schema} do
      assert_raise PB.SchemaError,
                   ~r/unknown message :"nope\.Nada"/,
                   fn -> Schema.message!(schema, :"nope.Nada") end
    end
  end

  describe "fetch_enum/2 + enum!/2" do
    test "returns values ordered by number", %{schema: schema} do
      {:ok, enum} = Schema.fetch_enum(schema, :"test.Role")

      assert enum.name == :"test.Role"

      assert enum.values == [
               %Info.EnumValue{name: :UNKNOWN, number: 0},
               %Info.EnumValue{name: :ADMIN, number: 1},
               %Info.EnumValue{name: :USER, number: 2}
             ]
    end

    test "fetch returns :error for unknown enum", %{schema: schema} do
      assert Schema.fetch_enum(schema, :"test.Nope") == :error
    end

    test "enum! raises PB.Error with :unknown_enum", %{schema: schema} do
      error =
        assert_raise PB.SchemaError, fn -> Schema.enum!(schema, :"test.Nope") end

      assert error.kind == :unknown_enum
      assert error.type_name == :"test.Nope"
      assert error.operation == :introspect
    end

    test "preserves enum aliases (multiple names sharing one number)" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "aliased.proto",
              package: :alias_test,
              syntax: :proto3,
              enum_type: [
                %{
                  name: :Color,
                  options: %{allow_alias: true},
                  value: [
                    %{name: :UNKNOWN, number: 0},
                    %{name: :RED, number: 1},
                    %{name: :CRIMSON, number: 1}
                  ]
                }
              ]
            }
          ]
        })

      {:ok, enum} = Schema.fetch_enum(schema, :"alias_test.Color")

      numbers = Enum.map(enum.values, & &1.number)
      names = Enum.map(enum.values, & &1.name) |> Enum.sort()

      assert numbers == [0, 1, 1]
      assert names == [:CRIMSON, :RED, :UNKNOWN]
    end
  end

  describe "package" do
    test "is the declaring file's package, also for nested types" do
      schema =
        PB.compile(%{
          file: [
            %{
              name: "a/b/outer.proto",
              package: :"a.b",
              syntax: :proto3,
              message_type: [
                %{
                  name: :Outer,
                  nested_type: [%{name: :Inner}],
                  enum_type: [%{name: :Kind, value: [%{name: :KIND_UNSPECIFIED, number: 0}]}]
                }
              ],
              service: [
                %{
                  name: :Lookup,
                  method: [%{name: :Get, input_type: ".a.b.Outer", output_type: ".a.b.Outer"}]
                }
              ]
            },
            %{name: "bare.proto", syntax: :proto3, message_type: [%{name: :Bare}]}
          ]
        })

      assert Schema.message!(schema, :"a.b.Outer").package == :"a.b"
      assert Schema.message!(schema, :"a.b.Outer.Inner").package == :"a.b"
      assert Schema.enum!(schema, :"a.b.Outer.Kind").package == :"a.b"
      assert Schema.service!(schema, :"a.b.Lookup").package == :"a.b"
      assert Schema.message!(schema, :Bare).package == nil
    end
  end

  describe "fetch_service/2 + service!/2" do
    test "returns method info" do
      %{schema: schema} = Fixtures.grpc_schema_fixture()

      {:ok, svc} = Schema.fetch_service(schema, :"grpct.Greeter")

      assert svc.name == :"grpct.Greeter"

      assert [
               %Info.Method{
                 name: :SayHello,
                 input_type: :"grpct.HelloRequest",
                 output_type: :"grpct.HelloReply",
                 client_streaming: false,
                 server_streaming: false
               }
             ] = svc.methods
    end

    test "service! raises with :unknown_service" do
      %{schema: schema} = Fixtures.grpc_schema_fixture()

      assert_raise PB.SchemaError,
                   ~r/unknown service :"grpct\.Nope"/,
                   fn -> Schema.service!(schema, :"grpct.Nope") end
    end
  end

  describe "fetch_extension/2 + extension!/2" do
    test "extension! raises with :unknown_extension", %{schema: schema} do
      assert_raise PB.SchemaError,
                   ~r/unknown extension :"nope\.Ext"/,
                   fn -> Schema.extension!(schema, :"nope.Ext") end
    end

    test "returns Field info for an extension" do
      schema = extension_schema()

      {:ok, ext} = Schema.fetch_extension(schema, :"ext.extension_int32")

      assert %Info.Field{
               name: :"ext.extension_int32",
               number: 100,
               type: {:scalar, :int32},
               extendee: :"ext.Msg"
             } = ext
    end

    test "list_extensions/1 includes every extension, sorted" do
      schema = extension_schema()

      assert Schema.list_extensions(schema) ==
               [:"ext.child", :"ext.extension_int32", :"ext.extension_nums"]
    end

    test "extension targeting a message also appears on the message's :extensions" do
      schema = extension_schema()

      {:ok, msg} = Schema.fetch_message(schema, :"ext.Msg")

      names = Enum.map(msg.extensions, & &1.name)
      assert names == [:"ext.extension_int32", :"ext.child", :"ext.extension_nums"]
    end

    test "message exposes extension_ranges" do
      schema = extension_schema()

      {:ok, msg} = Schema.fetch_message(schema, :"ext.Msg")

      assert msg.extension_ranges == [%Info.ExtensionRange{start: 100, end: 200}]
    end
  end

  defp extension_schema do
    PB.compile(%{
      file: [
        %{
          name: "ext.proto",
          package: :ext,
          syntax: :proto2,
          message_type: [
            %{
              name: :Msg,
              field: [
                %{name: :id, number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32}
              ],
              extension_range: [%{start: 100, end: 200}]
            },
            %{
              name: :Child,
              field: [
                %{name: :id, number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32}
              ]
            }
          ],
          extension: [
            %{
              name: :extension_int32,
              number: 100,
              label: :LABEL_OPTIONAL,
              type: :TYPE_INT32,
              extendee: ".ext.Msg"
            },
            %{
              name: :child,
              number: 101,
              label: :LABEL_OPTIONAL,
              type: :TYPE_MESSAGE,
              type_name: ".ext.Child",
              extendee: ".ext.Msg"
            },
            %{
              name: :extension_nums,
              number: 102,
              label: :LABEL_REPEATED,
              type: :TYPE_INT32,
              extendee: ".ext.Msg"
            }
          ]
        }
      ]
    })
  end
end
