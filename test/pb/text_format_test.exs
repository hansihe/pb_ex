defmodule PB.TextFormatTest do
  use ExUnit.Case, async: true

  alias PB.{DecodeError, OptionError, SchemaError, TextFormat, ValueError}
  alias PB.TestSupport.TestSchema

  @proto3 :"protobuf_test_messages.proto3.TestAllTypesProto3"
  @proto2 :"protobuf_test_messages.proto2.TestAllTypesProto2"
  @required :"protobuf_test_messages.proto2.TestAllRequiredTypesProto2"

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

    test "are skipped with ignore_unknown" do
      text = "a: 1 b: [1, 'x', {c: 2}] d { e: -inf } [pkg.ext] < f: 'g' > optional_int32: 7"
      assert decode(text, @proto3, ignore_unknown: true) == {:ok, %{optional_int32: 7}}
    end

    test "a skipped field without a colon must hold a message" do
      assert {:error, %DecodeError{kind: :malformed_text}} =
               decode("a [1]", @proto3, ignore_unknown: true)
    end
  end

  describe "not yet supported" do
    test "type URLs outside google.protobuf.Any are rejected" do
      assert {:error, %DecodeError{kind: :malformed_text} = error} =
               decode("[type.googleapis.com/pkg.Msg] {}")

      assert Exception.message(error) =~ "is only allowed in a google.protobuf.Any"
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
               decode("", @proto3, ignore_unknown: 1)

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
