defmodule PB.CEL.Runtime.NumberTest do
  use ExUnit.Case, async: true

  alias PB.CEL.Runtime.Number
  alias PB.CEL.Value

  test "handles CEL special double arithmetic" do
    assert Number.arithmetic(:/, Value.double(1.0), Value.double(0.0)) ==
             {:ok, Value.double(:infinity)}

    assert Number.arithmetic(:/, Value.double(-1.0), Value.double(0.0)) ==
             {:ok, Value.double(:negative_infinity)}

    assert Number.arithmetic(:/, Value.double(0.0), Value.double(0.0)) ==
             {:ok, Value.double(:nan)}

    assert Number.arithmetic(:*, Value.double(2.0), Value.double(8.988466e307)) ==
             {:ok, Value.double(:infinity)}
  end

  test "handles CEL numeric equality and comparison" do
    assert Number.equal?(Value.int(1), Value.uint(1)) == {:ok, true}
    assert Number.equal?(Value.double(:nan), Value.double(:nan)) == {:ok, false}
    assert Number.compare(Value.double(:nan), Value.double(1.0)) == {:ok, :nan}
    assert Number.compare(Value.double(:negative_infinity), Value.int(0)) == {:ok, :lt}
  end

  test "reports CEL integer overflow errors" do
    assert Number.add(Value.int(9_223_372_036_854_775_807), Value.int(1)) ==
             {:error, "integer overflow"}

    assert Number.add(Value.uint(0), Value.uint(18_446_744_073_709_551_615)) ==
             {:ok, Value.uint(18_446_744_073_709_551_615)}

    assert Number.arithmetic(:-, Value.uint(0), Value.uint(1)) ==
             {:error, "unsigned integer overflow"}
  end
end
