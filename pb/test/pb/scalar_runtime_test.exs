defmodule PB.ScalarRuntimeTest do
  use ExUnit.Case

  # ── All scalar types ───────────────────────────────────────────────

  describe "all scalar types" do
    @scalar_schema %{
      file: [
        %{
          name: "scalars.proto",
          package: :s,
          syntax: :proto3,
          message_type: [
            %{
              name: :Scalars,
              field: [
                %{name: :f_double, number: 1, type: :TYPE_DOUBLE, label: :LABEL_OPTIONAL},
                %{name: :f_float, number: 2, type: :TYPE_FLOAT, label: :LABEL_OPTIONAL},
                %{name: :f_int64, number: 3, type: :TYPE_INT64, label: :LABEL_OPTIONAL},
                %{name: :f_uint64, number: 4, type: :TYPE_UINT64, label: :LABEL_OPTIONAL},
                %{name: :f_int32, number: 5, type: :TYPE_INT32, label: :LABEL_OPTIONAL},
                %{name: :f_fixed64, number: 6, type: :TYPE_FIXED64, label: :LABEL_OPTIONAL},
                %{name: :f_fixed32, number: 7, type: :TYPE_FIXED32, label: :LABEL_OPTIONAL},
                %{name: :f_bool, number: 8, type: :TYPE_BOOL, label: :LABEL_OPTIONAL},
                %{name: :f_string, number: 9, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{name: :f_bytes, number: 12, type: :TYPE_BYTES, label: :LABEL_OPTIONAL},
                %{name: :f_uint32, number: 13, type: :TYPE_UINT32, label: :LABEL_OPTIONAL},
                %{name: :f_sfixed32, number: 15, type: :TYPE_SFIXED32, label: :LABEL_OPTIONAL},
                %{name: :f_sfixed64, number: 16, type: :TYPE_SFIXED64, label: :LABEL_OPTIONAL},
                %{name: :f_sint32, number: 17, type: :TYPE_SINT32, label: :LABEL_OPTIONAL},
                %{name: :f_sint64, number: 18, type: :TYPE_SINT64, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }

    setup do
      %{ss: PB.compile(@scalar_schema)}
    end

    test "double", %{ss: ss} do
      assert_roundtrip(ss, %{f_double: 3.14})
    end

    test "float", %{ss: ss} do
      {:ok, bin} = PB.encode(%{f_float: 1.5}, ss, :"s.Scalars")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), ss, :"s.Scalars")
      assert_in_delta d.f_float, 1.5, 0.001
    end

    test "int64", %{ss: ss} do
      assert_roundtrip(ss, %{f_int64: 9_999_999_999})
    end

    test "negative int64", %{ss: ss} do
      assert_roundtrip(ss, %{f_int64: -9_999_999_999})
    end

    test "uint64", %{ss: ss} do
      assert_roundtrip(ss, %{f_uint64: 18_446_744_073_709_551_615})
    end

    test "fixed64", %{ss: ss} do
      assert_roundtrip(ss, %{f_fixed64: 123_456_789})
    end

    test "fixed32", %{ss: ss} do
      assert_roundtrip(ss, %{f_fixed32: 42})
    end

    test "bool true", %{ss: ss} do
      assert_roundtrip(ss, %{f_bool: true})
    end

    test "bool false", %{ss: ss} do
      {:ok, bin} = PB.encode(%{f_bool: false}, ss, :"s.Scalars")
      assert IO.iodata_to_binary(bin) == <<>>

      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), ss, :"s.Scalars")
      refute Map.has_key?(decoded, :f_bool)
    end

    test "bytes", %{ss: ss} do
      assert_roundtrip(ss, %{f_bytes: <<0, 1, 2, 255>>})
    end

    test "uint32", %{ss: ss} do
      assert_roundtrip(ss, %{f_uint32: 4_294_967_295})
    end

    test "sfixed32 negative", %{ss: ss} do
      assert_roundtrip(ss, %{f_sfixed32: -42})
    end

    test "sfixed64 negative", %{ss: ss} do
      assert_roundtrip(ss, %{f_sfixed64: -999_999})
    end

    test "sint32 negative", %{ss: ss} do
      assert_roundtrip(ss, %{f_sint32: -100})
    end

    test "sint64 negative", %{ss: ss} do
      assert_roundtrip(ss, %{f_sint64: -100_000_000_000})
    end

    defp assert_roundtrip(schema, data) do
      {:ok, bin} = PB.encode(data, schema, :"s.Scalars")
      {:ok, decoded} = PB.decode(IO.iodata_to_binary(bin), schema, :"s.Scalars")
      assert decoded == data
    end
  end

  # ── IEEE 754 float special values ─────────────────────────────────

  describe "float32 IEEE 754 special values" do
    @float_schema %{
      file: [
        %{
          name: "floats.proto",
          package: :fp,
          syntax: :proto3,
          message_type: [
            %{
              name: :Floats,
              field: [
                %{name: :f32, number: 1, type: :TYPE_FLOAT, label: :LABEL_OPTIONAL},
                %{name: :f64, number: 2, type: :TYPE_DOUBLE, label: :LABEL_OPTIONAL}
              ]
            }
          ],
          enum_type: []
        }
      ]
    }

    setup do
      %{fs: PB.compile(@float_schema)}
    end

    # -- float32 encode/decode round-trips --

    test "float32 positive infinity", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f32: :infinity}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert d.f32 == :infinity
    end

    test "float32 negative infinity", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f32: :negative_infinity}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert d.f32 == :negative_infinity
    end

    test "float32 NaN", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f32: :nan}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert d.f32 == :nan
    end

    test "float32 negative zero", %{fs: fs} do
      # IEEE 754: negative zero = sign bit 1, exponent 0, fraction 0
      # Encode -0.0, decode should give -0.0 (or 0.0 — both valid)
      {:ok, bin} = PB.encode(%{f32: -0.0}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      # -0.0 == 0.0 in Elixir, so just check it's a valid float
      assert is_float(d.f32)
      assert d.f32 == 0.0
    end

    test "float32 smallest positive subnormal", %{fs: fs} do
      # Float32 min subnormal: 2^-149 ≈ 1.4e-45
      # Bit pattern: 0x00000001
      raw = <<1, 0, 0, 0>>
      # Manually build a protobuf message: tag(field 1, wire type 5) + 4 bytes
      tag = <<13>>
      msg = IO.iodata_to_binary([tag, raw])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert is_float(d.f32)
      assert d.f32 > 0.0
      assert d.f32 < 1.0e-44
    end

    test "float32 canonical NaN bit pattern on decode", %{fs: fs} do
      # Quiet NaN: 0x7FC00000 -> <<0, 0, 192, 127>> little-endian
      tag = <<13>>
      msg = IO.iodata_to_binary([tag, <<0, 0, 192, 127>>])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert d.f32 == :nan
    end

    test "float32 non-canonical NaN bit pattern on decode", %{fs: fs} do
      # Signaling NaN: 0x7F800001 -> <<1, 0, 128, 127>> little-endian
      tag = <<13>>
      msg = IO.iodata_to_binary([tag, <<1, 0, 128, 127>>])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert d.f32 == :nan
    end

    test "float32 negative NaN bit pattern on decode", %{fs: fs} do
      # Negative NaN: 0xFFC00000 -> <<0, 0, 192, 255>> little-endian
      tag = <<13>>
      msg = IO.iodata_to_binary([tag, <<0, 0, 192, 255>>])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert d.f32 == :nan
    end

    # -- float64 (double) encode/decode round-trips --

    test "float64 positive infinity", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f64: :infinity}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert d.f64 == :infinity
    end

    test "float64 negative infinity", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f64: :negative_infinity}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert d.f64 == :negative_infinity
    end

    test "float64 NaN", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f64: :nan}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert d.f64 == :nan
    end

    test "float64 negative zero", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f64: -0.0}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert is_float(d.f64)
      assert d.f64 == 0.0
    end

    test "float64 smallest positive subnormal", %{fs: fs} do
      # Float64 min subnormal: 2^-1074 ≈ 5e-324
      # Bit pattern: 0x0000000000000001
      raw = <<1, 0, 0, 0, 0, 0, 0, 0>>
      # tag(field 2, wire type 1) = (2 << 3) | 1 = 17
      tag = <<17>>
      msg = IO.iodata_to_binary([tag, raw])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert is_float(d.f64)
      assert d.f64 > 0.0
      assert d.f64 < 1.0e-300
    end

    test "float64 canonical NaN bit pattern on decode", %{fs: fs} do
      # Quiet NaN: 0x7FF8000000000000 -> little-endian
      raw = <<0, 0, 0, 0, 0, 0, 248, 127>>
      tag = <<17>>
      msg = IO.iodata_to_binary([tag, raw])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert d.f64 == :nan
    end

    test "float64 signaling NaN bit pattern on decode", %{fs: fs} do
      # Signaling NaN: 0x7FF0000000000001 -> little-endian
      raw = <<1, 0, 0, 0, 0, 0, 240, 127>>
      tag = <<17>>
      msg = IO.iodata_to_binary([tag, raw])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert d.f64 == :nan
    end

    test "float64 negative NaN bit pattern on decode", %{fs: fs} do
      # Negative quiet NaN: 0xFFF8000000000000 -> little-endian
      raw = <<0, 0, 0, 0, 0, 0, 248, 255>>
      tag = <<17>>
      msg = IO.iodata_to_binary([tag, raw])
      {:ok, d} = PB.decode(msg, fs, :"fp.Floats")
      assert d.f64 == :nan
    end

    # -- boundary values --

    test "float32 max finite value", %{fs: fs} do
      # ~3.4028235e+38
      {:ok, bin} = PB.encode(%{f32: 3.4028235e+38}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert_in_delta d.f32, 3.4028235e+38, 1.0e+31
    end

    test "float64 max finite value", %{fs: fs} do
      {:ok, bin} = PB.encode(%{f64: 1.7976931348623157e+308}, fs, :"fp.Floats")
      {:ok, d} = PB.decode(IO.iodata_to_binary(bin), fs, :"fp.Floats")
      assert d.f64 == 1.7976931348623157e+308
    end
  end
end
