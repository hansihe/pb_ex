defmodule PB.UnknownFieldTest do
  use ExUnit.Case, async: true

  test "from_raw rejects invalid wire types before encoding a tag" do
    assert_raise ArgumentError, ~r/wire type 0\.\.5/, fn ->
      PB.UnknownField.from_raw(1, 8, <<42>>)
    end

    assert_raise ArgumentError, ~r/wire type 0\.\.5/, fn ->
      PB.UnknownField.from_raw(1, -1, <<42>>)
    end
  end

  test "new rejects unknown fields outside the protobuf tag domain" do
    assert_raise ArgumentError, ~r/field number 1\.\./, fn ->
      PB.UnknownField.new(0, 0, <<8, 1>>)
    end

    assert_raise ArgumentError, ~r/wire type 0\.\.5/, fn ->
      PB.UnknownField.new(1, 6, <<8, 1>>)
    end
  end
end
