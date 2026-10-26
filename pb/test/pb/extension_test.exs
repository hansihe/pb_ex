defmodule PB.ExtensionTest do
  use ExUnit.Case, async: true

  alias PB.Wire

  @extensions :__extensions__

  test "compiles extension fields separately from regular fields" do
    schema = proto2_schema()
    msg = schema.messages[:"ext.Msg"]

    assert msg.fields_by_number[1].name == :id
    refute Map.has_key?(msg.fields_by_number, 100)

    assert msg.extensions_by_number[100].name == :"ext.extension_int32"
    assert msg.extensions_by_number[100].kind == :extension
    assert msg.extensions_by_number[100].extendee == :"ext.Msg"
    assert msg.extensions_by_name[:"ext.extension_int32"].local_name == :extension_int32
  end

  test "encodes and decodes proto2 scalar and message extensions" do
    schema = proto2_schema()

    data = %{
      @extensions => %{
        :"ext.extension_int32" => 123,
        :"ext.child" => %{id: 42}
      },
      id: 7
    }

    assert {:ok, encoded} = PB.encode(data, schema, :"ext.Msg")

    assert PB.decode(IO.iodata_to_binary(encoded), schema, :"ext.Msg") ==
             {:ok, data}
  end

  test "proto2 repeated scalar extensions default to expanded encoding" do
    schema = proto2_schema()
    data = %{@extensions => %{:"ext.extension_nums" => [1, 2]}}

    assert {:ok, encoded} = PB.encode(data, schema, :"ext.Msg")

    assert IO.iodata_to_binary(encoded) ==
             IO.iodata_to_binary([
               Wire.encode_tag(102, 0),
               Wire.encode_varint(1),
               Wire.encode_tag(102, 0),
               Wire.encode_varint(2)
             ])

    assert PB.decode(IO.iodata_to_binary(encoded), schema, :"ext.Msg") == {:ok, data}
  end

  test "edition repeated scalar extensions default to packed encoding" do
    schema = edition_schema()
    data = %{@extensions => %{:"ed.extension_nums" => [1, 2, 3]}}

    assert {:ok, encoded} = PB.encode(data, schema, :"ed.Msg")

    assert IO.iodata_to_binary(encoded) ==
             IO.iodata_to_binary([
               Wire.encode_tag(100, 2),
               Wire.encode_varint(3),
               <<1, 2, 3>>
             ])

    assert PB.decode(IO.iodata_to_binary(encoded), schema, :"ed.Msg") == {:ok, data}
  end

  test "edition string extensions apply utf8 validation" do
    schema = edition_schema()

    invalid =
      IO.iodata_to_binary([
        Wire.encode_tag(101, 2),
        Wire.encode_varint(1),
        <<255>>
      ])

    assert {:error,
            %PB.DecodeError{
              kind: :malformed,
              reason: :invalid_utf8,
              path: [@extensions, :"ed.extension_string"]
            }} = PB.decode(invalid, schema, :"ed.Msg")
  end

  # Custom options whose extendee message type is itself absent from the schema
  # (e.g. descriptors compiled without `--include_imports` of
  # descriptor.proto) are decoded through a synthetic stand-in for the
  # extendee. The materializer folds these synthetic messages in once before
  # its single prepare pass, so materialization does not re-prepare the whole
  # schema per option value — and the synthetic messages never leak into the
  # compiled schema.
  test "materializes custom options against a synthetic extendee" do
    draft = PB.Schema.Compiler.compile(synthetic_option_schema(10))

    fields = draft.messages[:"synth.Msg"].fields_by_name

    for i <- 1..10 do
      assert fields[:"f#{i}"][:options] == %{@extensions => %{"synth.my_opt": 42}}
    end

    # The synthetic stand-in for google.protobuf.FieldOptions is a decode aid
    # only; it must not appear in the compiled schema's messages.
    assert Map.keys(draft.messages) == [:"synth.Msg"]
  end

  defp synthetic_option_schema(field_count) do
    option = PB.UnknownField.from_raw(50_000, 0, <<42>>)

    fields =
      for i <- 1..field_count do
        %{
          name: :"f#{i}",
          number: i,
          label: :LABEL_OPTIONAL,
          type: :TYPE_INT32,
          options: %{PB.UnknownField.key() => [option]}
        }
      end

    %{
      file: [
        %{
          name: "synth.proto",
          package: :synth,
          syntax: :proto2,
          message_type: [%{name: :Msg, field: fields}],
          extension: [
            %{
              name: :my_opt,
              number: 50_000,
              label: :LABEL_OPTIONAL,
              type: :TYPE_INT32,
              extendee: ".google.protobuf.FieldOptions"
            }
          ]
        }
      ]
    }
  end

  defp proto2_schema do
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

  defp edition_schema do
    PB.compile(%{
      file: [
        %{
          name: "ed.proto",
          package: :ed,
          edition: :EDITION_2023,
          message_type: [
            %{
              name: :Msg,
              extension_range: [%{start: 100, end: 200}]
            }
          ],
          extension: [
            %{
              name: :extension_nums,
              number: 100,
              label: :LABEL_REPEATED,
              type: :TYPE_INT32,
              extendee: ".ed.Msg"
            },
            %{
              name: :extension_string,
              number: 101,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
              extendee: ".ed.Msg"
            }
          ]
        }
      ]
    })
  end
end
