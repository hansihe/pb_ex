defmodule PB.RuntimeErrorEncoderTest do
  use ExUnit.Case

  import PB.TestSupport.Assertions

  alias PB.TestSupport.Fixtures

  setup_all do
    %{schema: PB.compile(Fixtures.person_descriptor_set())}
  end

  # ── T8 - Error paths / malformed input ──────────────────────────────

  describe "T8 - error paths" do
    setup do
      desc = %{
        file: [
          %{
            name: "err.proto",
            package: :err,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                  %{
                    name: :role,
                    number: 2,
                    type: :TYPE_ENUM,
                    label: :LABEL_OPTIONAL,
                    type_name: :"err.Role"
                  },
                  %{name: :count, number: 3, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                  %{name: :vals, number: 4, type: :TYPE_INT32, label: :LABEL_REPEATED}
                ]
              }
            ],
            enum_type: [
              %{
                name: :Role,
                value: [%{name: :NONE, number: 0}, %{name: :ADMIN, number: 1}]
              }
            ]
          }
        ]
      }

      %{es: PB.compile(desc)}
    end

    test "truncated varint returns error", %{es: es} do
      assert_error(PB.decode(<<0x80>>, es, :"err.Msg"),
        operation: :decode,
        kind: :malformed,
        message_name: :"err.Msg",
        path: [],
        reason: :truncated_varint
      )
    end

    test "overlong varint returns error", %{es: es} do
      assert_error(PB.decode(:binary.copy(<<0x80>>, 10) <> <<0x00>>, es, :"err.Msg"),
        operation: :decode,
        kind: :malformed,
        message_name: :"err.Msg",
        path: [],
        reason: :varint_overflow
      )
    end

    test "truncated length-delimited returns error", %{es: es} do
      # tag(field 1, wire type 2) = 0x0A, length=10 but only 3 bytes follow
      assert_error(PB.decode(<<0x0A, 10, "abc">>, es, :"err.Msg"),
        operation: :decode,
        kind: :malformed,
        message_name: :"err.Msg",
        path: [:name],
        reason: :truncated_length_delimited
      )
    end

    test "known fields with the wrong wire type are kept as unknown fields", %{es: es} do
      # As in C++ and Go: name is a string sent as a varint, and count is a
      # singular int32 sent length-delimited (including in packed form).
      for bin <- [<<0x08, 0x7B>>, <<0x1A, 1, 0x7B>>, <<0x1A, 2, 10, 20>>] do
        {:ok, tag, value} = PB.Wire.decode_tag(bin)

        assert PB.decode(bin, es, :"err.Msg") ==
                 {:ok,
                  %{
                    __unknown_fields__: [
                      PB.UnknownField.from_raw(Bitwise.>>>(tag, 3), Bitwise.&&&(tag, 7), value)
                    ]
                  }}
      end

      # The unknown field does not hide later values of the same field.
      assert PB.decode(<<0x08, 0x7B, 0x0A, 1, ?a>>, es, :"err.Msg") ==
               {:ok,
                %{
                  name: "a",
                  __unknown_fields__: [PB.UnknownField.from_raw(1, 0, <<0x7B>>)]
                }}
    end

    test "packed field with truncated payload returns error", %{es: es} do
      # field 4 packed payload contains a single unterminated varint.
      assert_error(PB.decode(<<0x22, 1, 0x80>>, es, :"err.Msg"),
        operation: :decode,
        kind: :malformed,
        message_name: :"err.Msg",
        path: [:vals, {:index, 0}],
        reason: :truncated_varint
      )
    end

    test "nested fields with the wrong wire type are kept as unknown fields", %{
      schema: schema
    } do
      # Person.phones[0].number is a string, but the nested field is encoded as varint.
      nested = <<0x08, 0x7B>>

      assert {:ok, %{phones: [phone]}} =
               PB.decode(<<0x22, byte_size(nested), nested::binary>>, schema, :"test.Person")

      assert phone.__unknown_fields__ == [PB.UnknownField.from_raw(1, 0, <<0x7B>>)]
    end

    test "repeated int32 still accepts packed and unpacked wire encodings", %{es: es} do
      # field 4, wire type 2, payload varints 10 and 20
      assert {:ok, %{vals: [10, 20]}} = PB.decode(<<0x22, 2, 10, 20>>, es, :"err.Msg")

      # field 4, wire type 0, two unpacked values
      assert {:ok, %{vals: [10, 20]}} = PB.decode(<<0x20, 10, 0x20, 20>>, es, :"err.Msg")
    end

    test "unknown fields are still skipped by wire type", %{es: es} do
      # unknown field 99, wire type 0, followed by valid name = "x".
      assert {:ok, %{name: "x"}} =
               PB.decode(<<0x98, 0x06, 0x7B, 0x0A, 1, "x">>, es, :"err.Msg")
    end

    test "field number zero returns error", %{es: es} do
      # tag(field 0, wire type 5) is invalid even if the payload is otherwise skip-able.
      assert_error(PB.decode(<<0x05, 1, 2, 3, 4>>, es, :"err.Msg"),
        operation: :decode,
        kind: :malformed,
        message_name: :"err.Msg",
        path: [],
        reason: :invalid_field_number
      )
    end

    test "invalid wire type returns error", %{es: es} do
      # tag(field 1, wire type 6)
      assert_error(PB.decode(<<0x0E>>, es, :"err.Msg"),
        operation: :decode,
        kind: :malformed,
        message_name: :"err.Msg",
        path: [],
        reason: :invalid_wire_type
      )
    end

    test "truncated 64-bit field returns error" do
      desc = %{
        file: [
          %{
            name: "err2.proto",
            package: :err2,
            syntax: :proto3,
            message_type: [
              %{
                name: :Msg,
                field: [
                  %{name: :val, number: 1, type: :TYPE_DOUBLE, label: :LABEL_OPTIONAL}
                ]
              }
            ],
            enum_type: []
          }
        ]
      }

      s = PB.compile(desc)

      # tag(field 1, wire type 1) = 0x09, but only 4 bytes instead of 8
      assert_error(PB.decode(<<0x09, 1, 2, 3, 4>>, s, :"err2.Msg"),
        operation: :decode,
        kind: :malformed,
        message_name: :"err2.Msg",
        path: [:val],
        reason: :truncated_fixed64
      )
    end

    test "unknown enum value falls back to raw integer", %{es: es} do
      # tag(field 2, wire type 0) = (2 << 3) | 0 = 16, varint 99
      {:ok, decoded} = PB.decode(<<16, 99>>, es, :"err.Msg")
      assert decoded.role == 99
    end

    test "negative enum value falls back to raw integer", %{es: es} do
      # Encode -1 as a varint: to_unsigned64(-1) = 0xFFFFFFFFFFFFFFFF
      # tag(field 2, wire type 0) = 16
      # -1 as protobuf varint = 10 bytes of 0xFF + 0x01
      neg_one_varint =
        <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01>>

      {:ok, decoded} = PB.decode(<<16>> <> neg_one_varint, es, :"err.Msg")
      assert decoded.role == -1
    end

    test "decode_descriptor_set/1 with corrupt binary" do
      assert_error(PB.decode_descriptor_set(<<0xFF, 0xFF, 0xFF>>),
        operation: :decode,
        kind: :malformed,
        message_name: :"google.protobuf.FileDescriptorSet",
        path: [],
        reason: :truncated_varint
      )
    end

    test "decode options are validated", %{es: es} do
      assert_error(PB.decode(<<>>, es, :"err.Msg", bogus: true),
        operation: :decode,
        kind: :unknown_options,
        message_name: :"err.Msg",
        options: [:bogus]
      )

      assert_error(PB.decode(<<>>, es, :"err.Msg", defaults: :yes),
        operation: :decode,
        kind: :invalid_option,
        message_name: :"err.Msg",
        option: :defaults,
        value: :yes
      )

      assert_error(PB.decode(<<>>, es, :"err.Msg", message_names: :all),
        operation: :decode,
        kind: :invalid_option,
        message_name: :"err.Msg",
        option: :message_names,
        value: :all
      )

      assert_error(PB.decode(<<>>, es, :"err.Msg", :not_a_keyword),
        operation: :decode,
        kind: :invalid_options,
        message_name: :"err.Msg",
        reason: :atom
      )

      assert_error(PB.decode(<<>>, es, :"err.Msg", [:not_a_keyword]),
        operation: :decode,
        kind: :invalid_options,
        message_name: :"err.Msg",
        reason: :list
      )
    end

    test "decode! returns maps and raises on errors", %{es: es} do
      assert %{name: "x"} = PB.decode!(<<0x0A, 1, "x">>, es, :"err.Msg")

      assert_raise PB.DecodeError, ~r/malformed protobuf input/, fn ->
        PB.decode!(<<0x80>>, es, :"err.Msg")
      end
    end
  end

  # ── T9 - Encoder edge cases ─────────────────────────────────────────

  describe "T9 - encoder edge cases" do
    test "nil values are unset", %{schema: schema} do
      {:ok, bin} = PB.encode(%{name: nil, id: 42}, schema, :"test.Person")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"test.Person")
      assert decoded == %{id: 42}
      refute Map.has_key?(decoded, :name)

      # Explicit presence too: a nil field is not written, where it used to be
      # written as its default.
      proto2 = PB.TestSupport.TestSchema
      message = :"cel.expr.conformance.proto2.TestAllTypes"

      assert {:ok, ""} =
               PB.encode(
                 %{
                   single_int32: nil,
                   single_nested_message: nil,
                   repeated_int32: nil,
                   map_int32_int32: nil,
                   nested_type: nil,
                   __extensions__: nil
                 },
                 proto2,
                 message
               )

      assert_error(PB.encode(%{bogus: nil}, schema, :"test.Person"),
        kind: :unknown_field,
        path: [:bogus]
      )
    end

    test "unknown field names return errors by default", %{schema: schema} do
      assert_error(PB.encode(%{name: "Alice", bogus: "ignored"}, schema, :"test.Person"),
        operation: :encode,
        kind: :unknown_field,
        message_name: :"test.Person",
        path: [:bogus],
        protobuf_message: :"test.Person"
      )
    end

    test "unknown field names can be ignored explicitly", %{schema: schema} do
      {:ok, bin} =
        PB.encode(%{name: "Alice", bogus: "ignored"}, schema, :"test.Person",
          unknown_fields: :ignore
        )

      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"test.Person")
      assert decoded == %{name: "Alice"}
    end

    test "empty packed repeated list produces no output", %{schema: schema} do
      {:ok, bin} = PB.encode(%{scores: []}, schema, :"test.Person")
      assert IO.iodata_to_binary(bin) == <<>>
    end

    test "top-level data must be a map", %{schema: schema} do
      assert_error(PB.encode([], schema, :"test.Person"),
        operation: :encode,
        kind: :invalid_value,
        message_name: :"test.Person",
        path: [],
        expected: :map,
        got: :list
      )
    end

    test "repeated fields must be lists", %{schema: schema} do
      assert_error(PB.encode(%{scores: 1}, schema, :"test.Person"),
        operation: :encode,
        kind: :invalid_value,
        message_name: :"test.Person",
        path: [:scores],
        expected: :list,
        got: :integer
      )
    end

    test "string fields reject invalid UTF-8 for proto3", %{schema: schema} do
      assert_error(PB.encode(%{name: <<255>>}, schema, :"test.Person"),
        operation: :encode,
        kind: :invalid_value,
        message_name: :"test.Person",
        path: [:name],
        expected: :utf8_string,
        got: :binary
      )

      assert_error(PB.decode(<<0x0A, 0x01, 0xFF>>, schema, :"test.Person"),
        operation: :decode,
        kind: :malformed,
        message_name: :"test.Person",
        path: [:name],
        reason: :invalid_utf8
      )
    end

    test "integer fields are range checked", %{schema: schema} do
      assert_error(PB.encode(%{id: 2_147_483_648}, schema, :"test.Person"),
        operation: :encode,
        kind: :value_out_of_range,
        message_name: :"test.Person",
        path: [:id],
        min: -2_147_483_648,
        max: 2_147_483_647,
        value: 2_147_483_648
      )
    end

    test "unknown enum atoms return errors", %{schema: schema} do
      assert_error(PB.encode(%{role: :BOGUS}, schema, :"test.Person"),
        operation: :encode,
        kind: :unknown_enum_value,
        message_name: :"test.Person",
        path: [:role],
        value: :BOGUS,
        enum: :"test.Role"
      )
    end

    test "oneof members must use the oneof wrapper key", %{schema: schema} do
      assert_error(PB.encode(%{pet: %{name: "Rex"}}, schema, :"test.Person"),
        operation: :encode,
        kind: :invalid_oneof,
        message_name: :"test.Person",
        path: [:pet],
        reason: :oneof_member_must_use_wrapper
      )
    end

    test "oneof wrapper rejects unknown members", %{schema: schema} do
      assert_error(PB.encode(%{companion: {:name, "Rex"}}, schema, :"test.Person"),
        operation: :encode,
        kind: :invalid_oneof,
        message_name: :"test.Person",
        path: [:companion],
        reason: {:unknown_member, :name}
      )
    end

    test "encode! raises on validation errors", %{schema: schema} do
      assert_raise PB.ValueError, ~r/unknown field bogus/, fn ->
        PB.encode!(%{bogus: true}, schema, :"test.Person")
      end
    end

    test "encode options are validated", %{schema: schema} do
      assert_error(PB.encode(%{}, schema, :"test.Person", bogus: true),
        operation: :encode,
        kind: :unknown_options,
        message_name: :"test.Person",
        options: [:bogus]
      )

      assert_error(PB.encode(%{}, schema, :"test.Person", unknown_fields: :drop),
        operation: :encode,
        kind: :invalid_option,
        message_name: :"test.Person",
        option: :unknown_fields,
        value: :drop
      )

      assert_error(PB.encode(%{}, schema, :"test.Person", [:not_a_keyword]),
        operation: :encode,
        kind: :invalid_options,
        message_name: :"test.Person",
        reason: :list
      )
    end
  end
end
