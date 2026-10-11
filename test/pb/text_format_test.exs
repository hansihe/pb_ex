defmodule PB.TextFormatTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias PB.{DecodeError, OptionError, SchemaError, TextFormat, ValueError}
  alias PB.TestSupport.TestSchema

  @proto3 :"protobuf_test_messages.proto3.TestAllTypesProto3"
  @proto2 :"protobuf_test_messages.proto2.TestAllTypesProto2"
  @required :"protobuf_test_messages.proto2.TestAllRequiredTypesProto2"
  @edition2023 :"protobuf_test_messages.editions.TestAllTypesEdition2023"

  defmodule Child do
    defstruct [:id, :req]
  end

  defmodule Nested do
    defstruct [:a, :corecursive]
  end

  @ext_descriptor_set %{
    file: [
      %{
        name: "ext.proto",
        package: :ext,
        syntax: :proto2,
        message_type: [
          %{
            name: :Msg,
            field: [%{name: :id, number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32}],
            extension_range: [%{start: 100, end: 200}]
          },
          %{
            name: :Child,
            field: [
              %{name: :id, number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32},
              %{name: :req, number: 2, label: :LABEL_REQUIRED, type: :TYPE_INT32}
            ],
            extension: [
              %{
                name: :scoped,
                number: 104,
                label: :LABEL_OPTIONAL,
                type: :TYPE_STRING,
                extendee: ".ext.Msg"
              }
            ]
          }
        ],
        enum_type: [
          %{name: :Color, value: [%{name: :RED, number: 0}, %{name: :GREEN, number: 1}]}
        ],
        extension: [
          %{
            name: :number,
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
            name: :nums,
            number: 102,
            label: :LABEL_REPEATED,
            type: :TYPE_INT32,
            extendee: ".ext.Msg"
          },
          %{
            name: :color,
            number: 103,
            label: :LABEL_OPTIONAL,
            type: :TYPE_ENUM,
            type_name: ".ext.Color",
            extendee: ".ext.Msg"
          }
        ]
      }
    ]
  }

  defp ext_schema(opts \\ []), do: PB.compile(@ext_descriptor_set, opts)

  @nested :"protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage"
  @nested_url "type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage"

  defp packed(message, data, schema \\ TestSchema) do
    {:ok, bytes} = PB.encode(data, schema, message)
    bytes
  end

  defp decode(text, message \\ @proto3, opts \\ []),
    do: TextFormat.decode(text, TestSchema, message, opts)

  defp decode!(text, message \\ @proto3), do: TextFormat.decode!(text, TestSchema, message)

  defp value(text, field, message \\ @proto3), do: Map.fetch!(decode!(text, message), field)

  describe "integers" do
    test "accepts decimal, hex and octal literals" do
      assert value("optional_int32: 2147483647", :optional_int32) == 2_147_483_647
      assert value("optional_int32: 0x7FFFFFFF", :optional_int32) == 2_147_483_647
      assert value("optional_int32: -0x80000000", :optional_int32) == -2_147_483_648
      assert value("optional_int32: -020000000000", :optional_int32) == -2_147_483_648
      assert value("optional_uint64: 0xFFFFFFFFFFFFFFFF", :optional_uint64) == 0xFFFFFFFFFFFFFFFF

      assert value("optional_sint64: -9223372036854775808", :optional_sint64) ==
               -0x8000000000000000

      assert value("optional_fixed32: 0777", :optional_fixed32) == 0o777
    end

    test "rejects out-of-range values" do
      assert {:error,
              %ValueError{
                kind: :value_out_of_range,
                path: [:optional_int32],
                value: 2_147_483_648
              }} =
               decode("optional_int32: 2147483648")

      assert {:error, %ValueError{kind: :value_out_of_range, value: -2_147_483_649}} =
               decode("optional_sfixed32: -2147483649")

      assert {:error, %ValueError{kind: :value_out_of_range}} =
               decode("optional_uint64: 18446744073709551616")
    end

    test "rejects a minus sign on unsigned fields and non-integer literals" do
      assert {:error, %ValueError{kind: :invalid_value, expected: :unsigned_integer, got: "-1"}} =
               decode("optional_uint32: -1")

      assert {:error, %ValueError{kind: :invalid_value, expected: :integer, got: "1.5"}} =
               decode("optional_int32: 1.5")

      assert {:error, %ValueError{kind: :invalid_value, expected: :integer, got: "1"}} =
               decode("optional_int32: '1'")
    end
  end

  describe "floats" do
    test "accepts integers, floats, suffixes and leading-dot literals" do
      assert value("optional_double: 1", :optional_double) == 1.0
      assert value("optional_double: .5e1", :optional_double) == 5.0
      assert value("optional_double: -2.5f", :optional_double) == -2.5

      assert value("optional_double: 18446744073709551616", :optional_double) ==
               1.8446744073709552e19
    end

    test "accepts inf, infinity and nan in any case, with an optional minus" do
      assert value("optional_double: inf", :optional_double) == :infinity
      assert value("optional_double: -Infinity", :optional_double) == :negative_infinity
      assert value("optional_float: nAn", :optional_float) == :nan
    end

    test "maps overflow to infinity and underflow to zero, keeping the sign" do
      assert value("optional_double: 1e9999", :optional_double) == :infinity

      assert value("optional_double: -1e18446744073709551616", :optional_double) ==
               :negative_infinity

      assert value("optional_float: 1e50", :optional_float) == :infinity
      assert value("optional_double: -1e-18446744073709551616", :optional_double) === -0.0
      assert value("optional_float: -1e-50", :optional_float) === -0.0
    end

    test "rounds float fields to 32 bits like a wire round trip" do
      assert value("optional_float: 3.192837", :optional_float) == 3.1928369998931885
      assert value("optional_float: 3.4028235e+38", :optional_float) == 3.4028234663852886e38
      assert value("optional_float: 3.4028235e+39", :optional_float) == :infinity
    end

    test "rejects hex and octal literals" do
      assert {:error, %ValueError{kind: :invalid_value, expected: :decimal_number, got: "0x1"}} =
               decode("optional_float: 0x1")

      assert {:error, %ValueError{kind: :invalid_value, got: "-012"}} =
               decode("optional_double: -012")
    end

    test "keeps negative zero, which is not a default value" do
      assert value("optional_double: -0", :optional_double) === -0.0
      assert decode!("optional_double: 0") == %{}
    end
  end

  describe "booleans" do
    test "accepts the C++ spellings and 0/1 in any base" do
      for {text, expected} <- [
            {"true", true},
            {"True", true},
            {"t", true},
            {"1", true},
            {"0x1", true},
            {"false", false},
            {"False", false},
            {"f", false},
            {"0", false}
          ] do
        assert decode!("optional_bool: #{text}") ==
                 if(expected, do: %{optional_bool: true}, else: %{}),
               text
      end
    end

    test "rejects other values" do
      for text <- ["TRUE", "2", "-1", "yes", "'true'"] do
        assert {:error, %ValueError{kind: :invalid_value, expected: :boolean}} =
                 decode("optional_bool: #{text}"),
               text
      end
    end
  end

  describe "strings and bytes" do
    test "concatenate adjacent literals" do
      assert value(~s(optional_string: 'a' "b"\n'c'), :optional_string) == "abc"
    end

    test "string fields reject invalid UTF-8; bytes fields keep raw bytes" do
      assert {:error,
              %ValueError{kind: :invalid_value, path: [:optional_string], expected: :utf8_string}} =
               decode(~S(optional_string: '\300'))

      assert value(~S(optional_bytes: '\300'), :optional_bytes) == <<0xC0>>
    end

    test "proto2 string fields do not check UTF-8" do
      assert value(~S(optional_string: '\300'), :optional_string, @proto2) == <<0xC0>>
    end

    test "reject non-string literals" do
      assert {:error, %ValueError{kind: :invalid_value, expected: :string, got: "abc"}} =
               decode("optional_string: abc")
    end
  end

  describe "enums" do
    test "accept value names and numbers" do
      assert value("optional_nested_enum: BAR", :optional_nested_enum) == :BAR
      assert value("optional_nested_enum: 2", :optional_nested_enum) == :BAZ
      assert value("optional_nested_enum: -1", :optional_nested_enum) == :NEG
    end

    test "open enums keep unknown numbers" do
      assert value("optional_nested_enum: 42", :optional_nested_enum) == 42
    end

    test "closed enums reject unknown numbers" do
      assert {:error, %ValueError{kind: :unknown_enum_value, value: 42}} =
               decode("optional_nested_enum: 42", @proto2)
    end

    test "reject unknown names and other literals" do
      assert {:error, %ValueError{kind: :unknown_enum_value, value: "QUX"}} =
               decode("optional_nested_enum: QUX")

      assert {:error, %ValueError{kind: :invalid_value, expected: :enum}} =
               decode("optional_nested_enum: 'BAR'")

      assert {:error, %ValueError{kind: :value_out_of_range}} =
               decode("optional_nested_enum: 2147483648")
    end
  end

  describe "messages" do
    test "accept braces or angle brackets, with or without a colon" do
      expected = %{optional_nested_message: %{a: 1}}
      assert decode!("optional_nested_message { a: 1 }") == expected
      assert decode!("optional_nested_message: < a: 1 >") == expected
    end

    test "decode nested messages recursively" do
      assert decode!("optional_nested_message { corecursive { optional_int32: 5 } }") ==
               %{optional_nested_message: %{corecursive: %{optional_int32: 5}}}
    end

    test "an empty message value is present" do
      assert decode!("optional_nested_message {}") == %{optional_nested_message: %{}}
    end

    test "a message field needs a message value" do
      assert {:error, %DecodeError{kind: :malformed_text, details: %{line: 1, column: 26}}} =
               decode("optional_nested_message: 1")
    end

    test "a scalar field needs a colon" do
      assert {:error, %DecodeError{kind: :malformed_text, path: [:optional_int32]} = error} =
               decode("optional_int32 { }")

      assert Exception.message(error) =~ ~s(expected ":" after field name "optional_int32")
    end
  end

  describe "repeated fields" do
    test "accept lists, one value per occurrence, or both" do
      assert value("repeated_int32: [1, 2] repeated_int32: 3", :repeated_int32) == [1, 2, 3]
      assert value("repeated_int32: []", :repeated_int32) == []

      assert value(
               "repeated_nested_message [{a: 1}, {a: 2}] repeated_nested_message {a: 3}",
               :repeated_nested_message
             ) ==
               [%{a: 1}, %{a: 2}, %{a: 3}]
    end

    test "locate invalid elements by index across occurrences" do
      assert {:error, %ValueError{path: [:repeated_int32, {:index, 2}]}} =
               decode("repeated_int32: [1, 2] repeated_int32: 'x'")
    end

    test "list elements must match the field type" do
      assert {:error, %DecodeError{kind: :malformed_text}} =
               decode("repeated_nested_message: [1]")

      assert {:error, %ValueError{kind: :invalid_value}} = decode("repeated_int32: [{}]")
    end

    test "a list is not allowed for a non-repeated field" do
      assert {:error, %DecodeError{kind: :malformed_text} = error} = decode("optional_int32: [1]")
      assert Exception.message(error) =~ "a list is only allowed for repeated fields"
    end
  end

  describe "map fields" do
    test "are written as repeated entries" do
      assert value(
               ~s(map_string_string { key: "a" value: "1" } map_string_string: [{key: "b", value: "2"}]),
               :map_string_string
             ) ==
               %{"a" => "1", "b" => "2"}
    end

    test "a missing key or value takes its default" do
      assert value("map_int32_int32 { value: 5 } map_int32_int32 { key: 1 }", :map_int32_int32) ==
               %{0 => 5, 1 => 0}

      assert value(~s(map_string_nested_message { key: "a" }), :map_string_nested_message) ==
               %{"a" => %{}}

      assert value(~s(map_string_nested_enum { key: "a" }), :map_string_nested_enum) == %{
               "a" => :FOO
             }
    end

    test "a repeated key keeps the last entry" do
      text = ~s"""
      map_string_nested_message { key: "dup" value: { a: 123 } }
      map_string_nested_message { key: "dup" value: { corecursive: {} } }
      """

      assert value(text, :map_string_nested_message) == %{"dup" => %{corecursive: %{}}}
    end
  end

  describe "presence" do
    test "omits implicit-presence fields set to their default" do
      assert decode!("optional_int32: 0 optional_string: '' optional_nested_enum: FOO") == %{}
    end

    test "rejects a non-repeated field given twice, even after a default value" do
      assert {:error,
              %DecodeError{
                kind: :duplicate_field,
                format: :text,
                path: [:optional_int32],
                details: %{line: 2, column: 1}
              } = error} = decode("optional_int32: 0\noptional_int32: 1")

      assert Exception.message(error) =~
               "duplicate field at line 2, column 1 (field optional_int32): " <>
                 "non-repeated field is specified more than once"
    end

    test "rejects two members of the same oneof" do
      assert {:error, %ValueError{kind: :invalid_oneof, path: [:oneof_string]}} =
               decode("oneof_uint32: 1 oneof_string: 'x'")
    end

    test "wraps the set oneof member" do
      assert decode!("oneof_string: 'x'") == %{oneof_field: {:oneof_string, "x"}}
    end

    test "checks required fields" do
      assert {:error, %ValueError{kind: :missing_required}} = decode("", @required)
    end
  end

  describe "unknown fields" do
    test "are rejected by default" do
      assert {:error,
              %ValueError{kind: :unknown_field, path: ["nope"], protobuf_message: @proto3}} =
               decode("nope: 1")

      assert {:error, %ValueError{kind: :unknown_field, path: ["[pkg.nope]"]}} =
               decode("[pkg.nope]: 1")
    end

    test "are skipped with unknown_fields: :ignore" do
      text = "a: 1 b: [1, 'x', {c: 2}] d { e: -inf } [pkg.ext] < f: 'g' > optional_int32: 7"
      assert decode(text, @proto3, unknown_fields: :ignore) == {:ok, %{optional_int32: 7}}
    end

    test "a skipped field without a colon must hold a message" do
      assert {:error, %DecodeError{kind: :malformed_text}} =
               decode("a [1]", @proto3, unknown_fields: :ignore)
    end
  end

  describe "extensions" do
    test "are stored under :__extensions__ by full name" do
      text = ~S"""
      id: 1
      [ext.number]: 5
      [ext.nums]: [1, 2] [ext.nums]: 3
      [ext.color]: GREEN
      [ext.child] { id: 7 req: 8 }
      [ext.Child.scoped]: "s"
      """

      assert TextFormat.decode(text, ext_schema(), :"ext.Msg") ==
               {:ok,
                %{
                  id: 1,
                  __extensions__: %{
                    "ext.number": 5,
                    "ext.nums": [1, 2, 3],
                    "ext.color": :GREEN,
                    "ext.child": %{id: 7, req: 8},
                    "ext.Child.scoped": "s"
                  }
                }}
    end

    test "decode to the same value as a wire round trip" do
      schema = ext_schema()

      decoded =
        TextFormat.decode!("[ext.nums]: [1, 2] [ext.child] { req: 1 }", schema, :"ext.Msg")

      {:ok, wire} = PB.encode(decoded, schema, :"ext.Msg")
      assert PB.decode(IO.iodata_to_binary(wire), schema, :"ext.Msg") == {:ok, decoded}
    end

    test "follow ordinary field rules" do
      schema = ext_schema()

      assert {:error,
              %DecodeError{kind: :duplicate_field, path: [:__extensions__, :"ext.number"]}} =
               TextFormat.decode("[ext.number]: 1 [ext.number]: 2", schema, :"ext.Msg")

      assert {:error, %DecodeError{kind: :malformed_text}} =
               TextFormat.decode("[ext.number] { }", schema, :"ext.Msg")

      assert {:error,
              %ValueError{kind: :value_out_of_range, path: [:__extensions__, :"ext.number"]}} =
               TextFormat.decode("[ext.number]: 2147483648", schema, :"ext.Msg")

      assert {:error,
              %ValueError{kind: :missing_required, path: [:__extensions__, :"ext.child", :req]}} =
               TextFormat.decode("[ext.child] { id: 1 }", schema, :"ext.Msg")
    end

    test "must use the full extension name" do
      assert {:error, %ValueError{kind: :unknown_field, path: ["[number]"]}} =
               TextFormat.decode("[number]: 1", ext_schema(), :"ext.Msg")

      assert {:error, %ValueError{kind: :unknown_field}} =
               TextFormat.decode("number: 1", ext_schema(), :"ext.Msg")
    end

    test "are decoded through the schema's projections" do
      schema = ext_schema(projections: [{:"ext.Child", struct: Child}])

      assert TextFormat.decode("[ext.child] { id: 1 req: 2 }", schema, :"ext.Msg") ==
               {:ok, %{__extensions__: %{"ext.child": %Child{id: 1, req: 2}}}}

      assert TextFormat.decode("req: 2", schema, :"ext.Child") == {:ok, %Child{req: 2}}
    end
  end

  describe "group fields" do
    test "answer to the field name or the exact type name" do
      for text <- [
            "data { group_int32: 1 }",
            "Data: { group_int32: 1 }",
            "Data < group_int32: 1 >"
          ] do
        assert decode!(text, @proto2) == %{data: %{group_int32: 1}}, text
      end

      assert decode!("MultiWordGroupField {}", @proto2) == %{multiwordgroupfield: %{}}
    end

    test "do not answer to other spellings of the type name" do
      for text <- ["DATA {}", "dATA {}", "Multiwordgroupfield {}"] do
        assert {:error, %ValueError{kind: :unknown_field}} = decode(text, @proto2), text
      end
    end

    test "count the field once whichever name is used" do
      assert {:error, %DecodeError{kind: :duplicate_field}} = decode("data {} Data {}", @proto2)
    end

    test "only a group-like delimited field answers to its type name" do
      assert decode!("GroupLikeType { group_int32: 1 }", @edition2023) ==
               %{groupliketype: %{group_int32: 1}}

      assert decode!("delimited_field { group_int32: 1 }", @edition2023) ==
               %{delimited_field: %{group_int32: 1}}
    end

    test "group extensions use the extension name, never the type name" do
      assert %{__extensions__: %{"protobuf_test_messages.proto2.groupfield": %{group_int32: 1}}} =
               decode!("[protobuf_test_messages.proto2.groupfield] { group_int32: 1 }", @proto2)

      assert {:error, %ValueError{kind: :unknown_field}} =
               decode("[protobuf_test_messages.proto2.GroupField] { group_int32: 1 }", @proto2)
    end
  end

  describe "reserved names" do
    test "are skipped whatever their value" do
      for value <- ["true", "-123", "'x' 'y'", "{ a: 1 }", "< a: 1 >", "[1, 'x', {}]", "-inf"] do
        assert decode!("reserved_field: #{value} optional_int32: 1") == %{optional_int32: 1},
               value
      end

      assert decode!("reserved_field { nested { deeper: 1 } }") == %{}
    end

    test "must still be well-formed" do
      assert {:error, %DecodeError{kind: :malformed_text}} = decode("reserved_field [1]")
      assert {:error, %DecodeError{kind: :malformed_text}} = decode("reserved_field: -FOO")
    end
  end

  describe "field numbers" do
    test "name fields and extensions with allow_field_numbers" do
      assert decode("1: 5 14: 'x' 18 { a: 1 }", @proto3, allow_field_numbers: true) ==
               {:ok, %{optional_int32: 5, optional_string: "x", optional_nested_message: %{a: 1}}}

      assert decode("120: 7", @proto2, allow_field_numbers: true) ==
               {:ok, %{__extensions__: %{"protobuf_test_messages.proto2.extension_int32": 7}}}
    end

    test "follow the named field's rules" do
      assert {:error, %DecodeError{kind: :duplicate_field}} =
               decode("1: 5 optional_int32: 6", @proto3, allow_field_numbers: true)

      assert {:error, %ValueError{kind: :value_out_of_range, path: [:optional_int32]}} =
               decode("1: 2147483648", @proto3, allow_field_numbers: true)
    end

    test "a reserved number is skipped" do
      assert decode("505: [1, 'x'] 999999 { a: 1 } 1: 5", @proto3, allow_field_numbers: true) ==
               {:ok, %{optional_int32: 5}}
    end

    test "unknown numbers are unknown fields" do
      assert {:error, %ValueError{kind: :unknown_field, path: ["12345"]}} =
               decode("12345: 1", @proto3, allow_field_numbers: true)

      assert {:error, %ValueError{kind: :unknown_field, path: ["150"]}} =
               decode("150: 1", @proto2, allow_field_numbers: true)

      opts = [allow_field_numbers: true, unknown_fields: :ignore]
      assert decode("12345: 1 150 {}", @proto2, opts) == {:ok, %{}}
    end

    test "are unknown names without allow_field_numbers" do
      assert {:error, %ValueError{kind: :unknown_field, path: ["1"]}} = decode("1: 5")
      assert decode("1: 5 2 { a: 1 }", @proto3, unknown_fields: :ignore) == {:ok, %{}}
    end

    test "must be decimal int32 values" do
      for text <- ["0x1: 5", "2147483648: 5"] do
        assert {:error, %ValueError{kind: :unknown_field}} =
                 decode(text, @proto3, allow_field_numbers: true),
               text
      end
    end
  end

  describe "google.protobuf.Any" do
    test "the expanded form packs the message into type_url and value" do
      expected = %{optional_any: %{type_url: @nested_url, value: packed(@nested, %{a: 5})}}

      for text <- [
            "optional_any { [#{@nested_url}] { a: 5 } }",
            "optional_any: < [#{@nested_url}]: < a: 5 > >",
            "optional_any { [ type.googleapis.com / protobuf_test_messages . proto3.TestAllTypesProto3.NestedMessage ] { a: 5 } }"
          ] do
        assert decode!(text) == expected, text
      end
    end

    test "keeps a type.googleprod.com prefix as written" do
      url = "type.googleprod.com/#{@nested}"
      assert value("optional_any { [#{url}] { a: 5 } }", :optional_any).type_url == url
    end

    test "an empty packed message leaves value unset" do
      assert value("optional_any { [#{@nested_url}] {} }", :optional_any) == %{
               type_url: @nested_url
             }
    end

    test "nests, and works in lists" do
      inner_url = "type.googleapis.com/#{@proto3}"

      text = """
      repeated_any [
        { [#{@nested_url}] { a: 1 } },
        { [type.googleapis.com/google.protobuf.Any] { [#{inner_url}] { optional_int32: 2 } } }
      ]
      """

      inner = %{type_url: inner_url, value: packed(@proto3, %{optional_int32: 2})}

      assert value(text, :repeated_any) == [
               %{type_url: @nested_url, value: packed(@nested, %{a: 1})},
               %{
                 type_url: "type.googleapis.com/google.protobuf.Any",
                 value: packed(:"google.protobuf.Any", inner)
               }
             ]
    end

    test "the explicit type_url and value fields still work" do
      assert decode!(~s(optional_any { type_url: "x/y" value: "\\001" })) ==
               %{optional_any: %{type_url: "x/y", value: <<1>>}}
    end

    test "packs projected message types through their projection" do
      descriptor_set = PB.decode_descriptor_set!(File.read!("test/fixtures/schema/test.binpb"))
      schema = PB.compile(descriptor_set, projections: [{@nested, struct: Nested}])

      assert TextFormat.decode("[#{@nested_url}] { a: 5 }", schema, :"google.protobuf.Any") ==
               {:ok, %{type_url: @nested_url, value: packed(@nested, %Nested{a: 5}, schema)}}
    end

    test "rejects prefixes C++ does not resolve and unknown types" do
      for url <- ["example.com/#{@nested}", "type.googleapis.com/no.Such", "a/b/#{@nested}"] do
        assert {:error,
                %DecodeError{kind: :malformed_text, details: %{line: 1, column: 16}} = error} =
                 decode("optional_any { [#{url}] {} }"),
               url

        assert Exception.message(error) =~
                 ~s(could not find type "#{url}" for google.protobuf.Any)
      end
    end

    test "rejects a bracketed name without a slash" do
      assert {:error, %DecodeError{kind: :malformed_text} = error} =
               decode("optional_any { [#{@nested}] {} }")

      assert Exception.message(error) =~ "expected a type URL"
    end

    test "the packed value must be a message" do
      for value <- [": 1", ": [{}]"] do
        assert {:error, %DecodeError{kind: :malformed_text}} =
                 decode("optional_any { [#{@nested_url}]#{value} }"),
               value
      end
    end

    test "cannot be set twice" do
      for text <- [
            "optional_any { [#{@nested_url}] {} [#{@nested_url}] {} }",
            ~s(optional_any { type_url: "x/y" [#{@nested_url}] {} }),
            ~s(optional_any { [#{@nested_url}] {} value: "" })
          ] do
        assert {:error, %DecodeError{kind: :duplicate_field}} = decode(text), text
      end
    end

    test "locates errors in the packed message under value" do
      assert {:error, %ValueError{kind: :invalid_value, path: [:optional_any, :value, :a]}} =
               decode("optional_any { [#{@nested_url}] { a: 'x' } }")
    end

    test "checks required fields of the packed message" do
      assert {:error, %ValueError{kind: :missing_required}} =
               decode("optional_any { [type.googleapis.com/#{@required}] {} }")
    end

    test "type URLs outside an Any are rejected" do
      assert {:error, %DecodeError{kind: :malformed_text} = error} = decode("[#{@nested_url}] {}")
      assert Exception.message(error) =~ "is only allowed in a google.protobuf.Any"
    end
  end

  describe "encoding" do
    defp encode!(value, message \\ @proto3, opts \\ []),
      do: TextFormat.encode!(value, TestSchema, message, opts)

    @rich %{
      optional_int32: -5,
      optional_uint64: 255,
      optional_float: 3.192837,
      optional_double: 0.1,
      optional_string: "héllo \"q\"\n",
      optional_bytes: <<0, 255, ?a>>,
      optional_nested_message: %{a: 1, corecursive: %{}},
      optional_nested_enum: :BAZ,
      repeated_int32: [1, 2],
      repeated_string: ["a"],
      map_string_string: %{"b" => "2", "a" => "1"},
      oneof_field: {:oneof_uint32, 7}
    }

    test "prints the C++ layout, in field-number order with sorted map entries" do
      assert encode!(@rich) == ~S"""
             optional_int32: -5
             optional_uint64: 255
             optional_float: 3.192837
             optional_double: 0.1
             optional_string: "héllo \"q\"\n"
             optional_bytes: "\x00\xffa"
             optional_nested_message {
               a: 1
               corecursive {}
             }
             optional_nested_enum: BAZ
             repeated_int32: 1
             repeated_int32: 2
             repeated_string: "a"
             map_string_string {
               key: "a"
               value: "1"
             }
             map_string_string {
               key: "b"
               value: "2"
             }
             oneof_uint32: 7
             """
    end

    test "single_line and short_repeated" do
      value = %{
        repeated_int32: [1, 2],
        repeated_nested_enum: [:FOO, :BAR],
        repeated_string: ["a", "b"]
      }

      assert encode!(value, @proto3, single_line: true, short_repeated: true) ==
               ~S(repeated_int32: [1, 2] repeated_string: "a" repeated_string: "b" repeated_nested_enum: [FOO, BAR])
    end

    test "prints what the wire would carry" do
      assert encode!(%{optional_int32: 0, optional_string: "", optional_nested_enum: 1}) ==
               "optional_nested_enum: BAR\n"

      assert encode!(%{optional_nested_enum: 42}) == "optional_nested_enum: 42\n"
      assert encode!(%{optional_float: 0.1}) == "optional_float: 0.1\n"
      assert encode!(%{optional_int32: 0}, @proto2) == "optional_int32: 0\n"
      assert encode!(%{}) == ""
    end

    test "prints group-like fields by type name and extensions by full name" do
      value = %{
        data: %{group_int32: 1},
        optional_int32: 2,
        __extensions__: %{"protobuf_test_messages.proto2.extension_int32": 5}
      }

      assert encode!(value, @proto2) == """
             optional_int32: 2
             [protobuf_test_messages.proto2.extension_int32]: 5
             Data {
               group_int32: 1
             }
             """
    end

    test "expands Any values whose type resolves" do
      packed = %{type_url: @nested_url, value: packed(@nested, %{a: 5})}

      assert encode!(%{optional_any: packed}) == """
             optional_any {
               [#{@nested_url}] {
                 a: 5
               }
             }
             """

      prod = %{packed | type_url: "type.googleprod.com/#{@nested}"}
      assert encode!(%{optional_any: prod}) =~ "[type.googleprod.com/#{@nested}] {"
    end

    test "prints other Any values raw" do
      for any <- [
            %{type_url: "example.com/#{@nested}", value: packed(@nested, %{a: 5})},
            %{type_url: "type.googleapis.com/no.Such", value: <<1>>},
            %{type_url: @nested_url, value: <<0xFF>>}
          ] do
        assert encode!(%{optional_any: any}) =~ ~s(  type_url: "#{any.type_url}"\n), inspect(any)
      end
    end

    test "prints unknown fields by number unless told not to" do
      unknowns = [
        PB.UnknownField.from_raw(12_345, 0, <<150, 1>>),
        PB.UnknownField.from_raw(12_346, 2, <<3, 8, 150, 1>>),
        PB.UnknownField.from_raw(12_347, 2, <<2, 0xFF, 0xFE>>),
        PB.UnknownField.from_raw(12_348, 5, <<1, 0, 0, 0>>)
      ]

      value = %{optional_int32: 1, __unknown_fields__: unknowns}

      assert encode!(value) == ~S"""
             optional_int32: 1
             12345: 150
             12346 {
               1: 150
             }
             12347: "\xff\xfe"
             12348: 0x00000001
             """

      assert encode!(value, @proto3, print_unknown_fields: false) == "optional_int32: 1\n"
    end

    test "encodes projected types through their projection" do
      descriptor_set = PB.decode_descriptor_set!(File.read!("test/fixtures/schema/test.binpb"))
      schema = PB.compile(descriptor_set, projections: [{@nested, struct: Nested}])

      assert TextFormat.encode(%Nested{a: 5}, schema, @nested) == {:ok, "a: 5\n"}
    end

    test "decodes back to the same value" do
      for {value, message} <- [
            {@rich, @proto3},
            {%{
               data: %{group_int32: 1},
               __extensions__: %{"protobuf_test_messages.proto2.extension_int32": 5}
             }, @proto2},
            {%{optional_any: %{type_url: @nested_url, value: packed(@nested, %{a: 5})}}, @proto3}
          ] do
        {:ok, canonical} = PB.normalize(value, TestSchema, message)

        for opts <- [[], [single_line: true, short_repeated: true]] do
          assert decode!(encode!(value, message, opts), message) == canonical
        end
      end
    end

    test "returns the errors PB.encode would, as text_encode" do
      assert {:error, %ValueError{kind: :value_out_of_range, operation: :text_encode}} =
               TextFormat.encode(%{optional_int32: 1 <<< 40}, TestSchema, @proto3)

      assert {:error, %ValueError{kind: :unknown_field, operation: :text_encode}} =
               TextFormat.encode(%{nope: 1}, TestSchema, @proto3)

      assert {:error, %ValueError{kind: :missing_required, operation: :text_encode}} =
               TextFormat.encode(%{}, TestSchema, @required)

      assert {:error, %SchemaError{kind: :unknown_message, operation: :text_encode}} =
               TextFormat.encode(%{}, TestSchema, :"no.Such")

      assert {:error, %OptionError{kind: :unknown_options}} =
               TextFormat.encode(%{}, TestSchema, @proto3, allow_field_numbers: true)

      assert {:error, %ValueError{kind: :unknown_field, operation: :text_encode}} =
               TextFormat.encode(%{bogus: 1}, TestSchema, @proto3)

      assert {:ok, ""} =
               TextFormat.encode(%{bogus: 1}, TestSchema, @proto3, unknown_fields: :ignore)

      assert_raise ValueError, fn -> encode!(%{optional_int32: "x"}) end
    end

    test "encode_iodata returns iodata" do
      assert {:ok, iodata} = TextFormat.encode_iodata(%{optional_int32: 1}, TestSchema, @proto3)
      assert IO.iodata_to_binary(iodata) == "optional_int32: 1\n"
    end
  end

  describe "errors" do
    test "malformed text reports the line and column" do
      assert {:error,
              %DecodeError{
                kind: :malformed_text,
                format: :text,
                operation: :text_decode,
                message_name: @proto3,
                details: %{line: 2, column: 18}
              } = error} = decode("optional_int32: 1\noptional_string: 'x")

      assert Exception.message(error) ==
               "PB failed to text_decode #{inspect(@proto3)}: malformed text format input " <>
                 "at line 2, column 18: unterminated string literal"
    end

    test "value errors carry the operation and message name" do
      assert {:error, %ValueError{operation: :text_decode, message_name: @proto3}} =
               decode("optional_int32: 'x'")
    end

    test "unknown message names return a schema error" do
      assert {:error, %SchemaError{kind: :unknown_message, operation: :text_decode}} =
               decode("", :"no.Such")
    end

    test "options are validated" do
      assert {:error, %OptionError{kind: :unknown_options}} =
               decode("", @proto3, emit_defaults: true)

      assert {:error, %OptionError{kind: :invalid_option}} =
               decode("", @proto3, unknown_fields: true)

      assert {:error, %OptionError{kind: :invalid_options}} = decode("", @proto3, :nope)
    end

    test "decode! raises" do
      assert_raise DecodeError, fn -> decode!("optional_int32: ") end
    end
  end

  test "decodes to the same value as a wire round trip" do
    text = ~S"""
    optional_int32: -5 optional_uint64: 0xFF optional_float: 0.1 optional_double: 2.5
    optional_string: "héllo" optional_bytes: '\x00\xff'
    optional_nested_message { a: 1 corecursive { optional_bool: true } }
    optional_nested_enum: BAZ
    repeated_int32: [1, 2, 3] repeated_string: ["a", "b"]
    repeated_nested_message { a: 1 } repeated_nested_message { a: 2 }
    map_string_string { key: "k" value: "v" }
    map_int32_double { key: 1 value: -inf }
    oneof_uint32: 7
    """

    decoded = decode!(text)
    {:ok, wire} = PB.encode(decoded, TestSchema, @proto3)
    assert PB.decode(IO.iodata_to_binary(wire), TestSchema, @proto3) == {:ok, decoded}
  end
end
