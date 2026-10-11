defmodule PB.TextFormat.FuzzTest do
  use ExUnit.Case, async: true

  # Mutates valid inputs and checks that decoding only ever returns a result
  # or a PB error, never raises. Seeded, so failures reproduce.

  alias PB.TestSupport.TestSchema

  @proto3 :"protobuf_test_messages.proto3.TestAllTypesProto3"
  @proto2 :"protobuf_test_messages.proto2.TestAllTypesProto2"

  @corpus [
    ~S(optional_int32: -5 optional_uint64: 0xFF optional_sint32: 017),
    ~S(optional_float: 1.5f optional_double: -inf optional_bool: t),
    ~S(optional_string: "héllo" 'x' optional_bytes: '\x00\377'),
    ~S(optional_nested_message { a: 1 corecursive < optional_int32: 2 > }),
    ~S(optional_nested_enum: BAZ repeated_nested_enum: [FOO, 1, -1]),
    ~S(repeated_int32: [1, 2, 3] repeated_string: ["a", "b"]; repeated_bool: 1,),
    ~S(repeated_nested_message [{a: 1}, <a: 2>] repeated_nested_message {a: 3}),
    ~S(map_string_string { key: "k" value: "v" } map_int32_int32: [{key: 1}]),
    ~S(map_string_nested_message { key: "a" value { a: 1 } }),
    ~S(oneof_uint32: 7 # trailing comment),
    ~S([pkg.ext]: 1 [type.googleapis.com/pkg.Msg] { a: 1 }),
    ~S(Data { group_int32: 1 } multiwordgroupfield < group_uint32: 2 >),
    ~S([protobuf_test_messages.proto2.extension_int32]: 5 [protobuf_test_messages.proto2.groupfield] { group_int32: 1 }),
    ~S(reserved_field: [1, 'x', {a: 1}] reserved_field { b: -inf } optional_int32: 1),
    ~S(optional_any { [type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3] { optional_int32: 1 } })
  ]

  @fragments [
    "{",
    "}",
    "<",
    ">",
    "[",
    "]",
    ":",
    ",",
    ";",
    "-",
    ".",
    "/",
    "'",
    "\"",
    "\\",
    "#",
    "\n",
    " ",
    "0x",
    "1e",
    "f",
    "inf",
    "nan",
    "a",
    "_",
    "\0",
    "\xFF",
    "é"
  ]

  @iterations 3_000

  test "mutated inputs decode or return a PB error" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..@iterations do
      text = mutate(Enum.random(@corpus))

      for message <- [@proto3, @proto2], opts <- [[], [ignore_unknown: true]] do
        result =
          try do
            PB.TextFormat.decode(text, TestSchema, message, opts)
          rescue
            exception ->
              flunk("""
              decode raised for #{inspect(text)} (#{inspect(message)}, #{inspect(opts)}):
              #{Exception.format(:error, exception, __STACKTRACE__)}
              """)
          end

        case result do
          {:ok, _value} -> :ok
          {:error, error} -> assert is_exception(error) and pb_error?(error), inspect(result)
        end
      end
    end
  end

  defp pb_error?(error),
    do: error.__struct__ in [PB.DecodeError, PB.ValueError, PB.SchemaError, PB.AdapterError]

  defp mutate(text) do
    Enum.reduce(1..Enum.random(1..3), text, fn _, text ->
      position = if text == "", do: 0, else: :rand.uniform(byte_size(text) + 1) - 1
      <<before::binary-size(^position), rest::binary>> = text

      case :rand.uniform(4) do
        1 -> before <> Enum.random(@fragments) <> rest
        2 -> before <> drop_byte(rest)
        3 -> before <> Enum.random(@fragments) <> drop_byte(rest)
        4 -> before
      end
    end)
  end

  defp drop_byte(<<_, rest::binary>>), do: rest
  defp drop_byte(<<>>), do: <<>>
end
