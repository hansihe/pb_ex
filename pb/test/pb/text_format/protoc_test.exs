defmodule PB.TextFormat.ProtocTest do
  use ExUnit.Case, async: true

  # Checks that the C++ parser reads PB's text output as the same value:
  # `protoc --encode` parses the printed text, and the bytes it writes must
  # decode to the value PB printed.

  @moduletag :protoc

  alias PB.TestSupport.TestSchema

  @proto_root Path.expand("../../fixtures/protobuf_conformance/proto", __DIR__)

  @proto3 {:"protobuf_test_messages.proto3.TestAllTypesProto3",
           "google/protobuf/test_messages_proto3.proto"}
  @proto2 {:"protobuf_test_messages.proto2.TestAllTypesProto2",
           "google/protobuf/test_messages_proto2.proto"}
  @edition2023 {:"protobuf_test_messages.editions.TestAllTypesEdition2023",
                "google/protobuf/test_messages_edition2023.proto"}

  @nested :"protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage"

  @tag :tmp_dir
  test "protoc reads PB's output as the same value", %{tmp_dir: tmp_dir} do
    {:ok, packed} = PB.encode(%{a: 5}, TestSchema, @nested)

    cases = [
      {@proto3,
       %{
         optional_int32: -5,
         optional_uint64: 0xFFFFFFFFFFFFFFFF,
         optional_sint64: -0x8000000000000000,
         optional_float: 3.192837,
         optional_double: 1.0e-300,
         optional_bool: true,
         optional_string: "héllo \"q\" \\ \n\t\x01 世界",
         optional_bytes: <<0, 255, ?", ?\\, 0xC3, 0xA9>>,
         optional_nested_message: %{a: 1, corecursive: %{optional_int32: 2}},
         optional_nested_enum: :NEG,
         repeated_double: [:infinity, :negative_infinity, -0.0, 5.0e-324],
         repeated_float: [1.401298464324817e-45, 3.4028234663852886e38],
         repeated_nested_enum: [:FOO, :BAR, 42],
         map_string_string: %{"" => "", "b" => "2"},
         map_bool_bool: %{true => false, false => true},
         map_int32_double: %{-1 => 0.1},
         map_string_nested_message: %{"x" => %{a: 3}},
         optional_any: %{type_url: "type.googleapis.com/#{@nested}", value: packed},
         oneof_field: {:oneof_string, "o"}
       }},
      {@proto2,
       %{
         optional_int32: 0,
         optional_string: <<0xC0, 0xFF>>,
         data: %{group_int32: 1},
         multiwordgroupfield: %{group_uint32: 2},
         __extensions__: %{
           "protobuf_test_messages.proto2.extension_int32": 5,
           "protobuf_test_messages.proto2.groupfield": %{group_int32: 3}
         }
       }},
      {@edition2023,
       %{
         groupliketype: %{group_int32: 1},
         delimited_field: %{group_int32: 2}
       }}
    ]

    for {{message, proto}, value} <- cases,
        opts <- [[], [single_line: true, short_repeated: true]] do
      text = PB.TextFormat.encode!(value, TestSchema, message, opts)
      path = Path.join(tmp_dir, "input.txtpb")
      File.write!(path, text)

      {bytes, 0} =
        System.cmd("sh", [
          "-c",
          ~S(protoc --encode="$1" --proto_path="$2" "$3" < "$4"),
          "sh",
          Atom.to_string(message),
          @proto_root,
          proto,
          path
        ])

      assert PB.decode(bytes, TestSchema, message) == PB.normalize(value, TestSchema, message),
             "protoc read #{inspect(text)} differently"
    end
  end
end
