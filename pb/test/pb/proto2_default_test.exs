defmodule PB.Proto2DefaultTest do
  use ExUnit.Case, async: true

  @schema PB.TestSupport.TestSchema
  @message :"cel.expr.conformance.proto2.TestAllTypes"

  test "preserves declared proto2 scalar defaults in field metadata" do
    field = @schema.schema().messages[@message].fields_by_name.single_int32

    assert field.default == -32
    assert PB.Runtime.Scalar.default_value(field) == {:ok, -32}
  end

  test "materializes declared proto2 defaults when decoding with defaults" do
    assert {:ok, decoded} = PB.decode(<<>>, @schema, @message, defaults: true)
    assert decoded.single_int32 == -32
  end
end
