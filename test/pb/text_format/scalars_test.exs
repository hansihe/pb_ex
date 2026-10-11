defmodule PB.TextFormat.ScalarsTest do
  use ExUnit.Case, async: true

  alias PB.TestSupport.TestSchema
  alias PB.TextFormat.Scalars
  alias PB.Wire

  @proto3 :"protobuf_test_messages.proto3.TestAllTypesProto3"

  defp text(field, value), do: field |> Scalars.format(value) |> IO.iodata_to_binary()
  defp double(value), do: text(%{type: :TYPE_DOUBLE}, value)
  defp float(value), do: text(%{type: :TYPE_FLOAT}, value)

  describe "doubles" do
    test "print the shortest text, positional for exponents -4..15" do
      for {value, expected} <- [
            {0.0, "0"},
            {-0.0, "-0"},
            {1.0, "1"},
            {3, "3"},
            {-2.5, "-2.5"},
            {0.1, "0.1"},
            {123_456.789, "123456.789"},
            {1.0e15, "1000000000000000"},
            {1.0e16, "1e+16"},
            {1.2345e20, "1.2345e+20"},
            {0.0001, "0.0001"},
            {1.0e-5, "1e-5"},
            {1.5e-7, "1.5e-7"},
            {5.0e-324, "5e-324"},
            {1.7976931348623157e308, "1.7976931348623157e+308"},
            {:infinity, "inf"},
            {:negative_infinity, "-inf"},
            {:nan, "nan"}
          ] do
        assert double(value) == expected, inspect(value)
      end
    end
  end

  describe "floats" do
    test "print the shortest text for the 32-bit value" do
      for {value, expected} <- [
            {3.1928369998931885, "3.192837"},
            {0.1, "0.1"},
            {0.10000000149011612, "0.1"},
            {3.4028234663852886e38, "3.4028235e+38"},
            {1.401298464324817e-45, "1e-45"},
            {16_777_217.0, "16777216"},
            {-0.0, "-0"},
            {1.0e39, "inf"},
            {:nan, "nan"}
          ] do
        assert float(value) == expected, inspect(value)
      end
    end
  end

  describe "round trips through the parser" do
    # Seeded random bit patterns: every finite double and float must read
    # back as exactly the same value.
    test "for random doubles and floats" do
      :rand.seed(:exsss, {7, 8, 9})

      doubles =
        for _ <- 1..3_000,
            <<value::float-64>> <- [<<:rand.uniform(0xFFFFFFFFFFFFFFFF + 1) - 1::64>>],
            do: value

      floats =
        for _ <- 1..3_000,
            bits = <<:rand.uniform(0xFFFFFFFF + 1) - 1::32>>,
            value = Wire.decode_float32(Wire.encode_float32(decode32(bits))),
            is_float(value),
            do: value

      for value <- doubles do
        assert_reads_back(:optional_double, double(value), value)
      end

      for value <- floats do
        assert_reads_back(:optional_float, float(value), value)
      end
    end
  end

  describe "strings and bytes" do
    test "strings keep UTF-8 and escape quotes, backslashes and control characters" do
      assert text(%{type: :TYPE_STRING}, "héllo \"q\" \\ \n\t\x01\x7f") ==
               ~S("héllo \"q\" \\ \n\t\x01\x7f")
    end

    test "strings that are not valid UTF-8 escape like bytes" do
      assert text(%{type: :TYPE_STRING}, <<0xC0, ?a>>) == ~S("\xc0a")
    end

    test "bytes escape everything outside printable ASCII with two hex digits" do
      assert text(%{type: :TYPE_BYTES}, <<0, 255, ?a, ?", 0xC3, 0xA9, 1, ?f>>) ==
               ~S("\x00\xffa\"\xc3\xa9\x01f")
    end
  end

  describe "other scalars" do
    test "enums print the value name, or the number without one" do
      field = %{type: :TYPE_ENUM, enum: %{by_number: %{1 => :BAR}}}
      assert text(field, :BAR) == "BAR"
      assert text(field, 1) == "BAR"
      assert text(field, 42) == "42"
    end

    test "booleans and integers" do
      assert text(%{type: :TYPE_BOOL}, true) == "true"
      assert text(%{type: :TYPE_BOOL}, false) == "false"
      assert text(%{type: :TYPE_SINT64}, -9_223_372_036_854_775_808) == "-9223372036854775808"
    end
  end

  defp decode32(<<value::float-32>>), do: value
  defp decode32(<<sign::1, _::31>>), do: if(sign == 1, do: -1.0e39, else: 1.0e39)

  defp assert_reads_back(field, text, value) do
    {:ok, decoded} = PB.TextFormat.decode("#{field}: #{text}", TestSchema, @proto3)
    read = Map.get(decoded, field, 0.0)

    assert <<read::float-64>> == <<value::float-64>>,
           "#{text} read back as #{inspect(read)}, not #{inspect(value)}"
  end
end
