defmodule PB.WireTest do
  use ExUnit.Case, async: true

  alias PB.Wire

  # A start-group tag (wire type 3) for the given field number.
  defp start_group(field_number), do: Wire.encode_tag(field_number, 3)

  describe "group decoding depth guard" do
    test "adversarially nested groups return a malformed error instead of blowing the stack" do
      # 200 unmatched start-group tags: each nested group recurses one level
      # deeper, so this exceeds @max_group_depth (100) before running out of input.
      bin = :binary.copy(start_group(1), 200)

      assert {:error, {:malformed, :max_group_depth_exceeded, _details}} =
               Wire.read_message_field(1, :delimited, bin)
    end

    test "nesting under the cap fails on truncation, not the depth guard" do
      # 50 unmatched start-group tags stays under the cap, so the failure is the
      # ordinary truncated-group error once the input runs out.
      bin = :binary.copy(start_group(1), 50)

      assert {:error, {:malformed, :truncated_group, _details}} =
               Wire.read_message_field(1, :delimited, bin)
    end
  end

  describe "group bodies" do
    test "are sub-binaries of the input, however deeply groups nest" do
      payload = Wire.encode_tag(2, 2) <> Wire.encode_varint(1_000) <> :binary.copy("x", 1_000)

      bin =
        Enum.reduce(1..90, payload, fn _, inner ->
          start_group(1) <> inner <> Wire.encode_tag(1, 4)
        end) <> Wire.encode_tag(1, 4)

      assert {:ok, body, raw, ""} = Wire.read_message_field(1, :delimited, bin)
      assert raw == bin
      assert byte_size(body) == byte_size(bin) - 1
      assert :binary.referenced_byte_size(body) == byte_size(bin)
    end
  end
end
