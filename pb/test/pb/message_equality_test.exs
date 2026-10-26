defmodule PB.MessageEqualityTest do
  use ExUnit.Case, async: true

  @schema PB.TestSupport.TestSchema
  @proto2 :"cel.expr.conformance.proto2.TestAllTypes"
  @proto3 :"cel.expr.conformance.proto3.TestAllTypes"

  test "compares explicit and implicit scalar presence through schema" do
    assert PB.message_equal?(%{}, %{}, @schema, @proto2)
    refute PB.message_equal?(%{}, %{single_int32: 0}, @schema, @proto2)
    assert PB.message_equal?(%{}, %{single_int32: 0}, @schema, @proto3)
  end

  test "treats nil fields as unset" do
    assert PB.message_equal?(%{single_int32: nil}, %{}, @schema, @proto2)
    refute PB.message_equal?(%{single_int32: nil}, %{single_int32: 0}, @schema, @proto2)

    assert PB.message_equal?(
             %{single_nested_message: nil},
             %{single_nested_message: nil},
             @schema,
             @proto2
           )

    assert PB.message_equal?(%{repeated_int32: nil, map_int32_int32: nil}, %{}, @schema, @proto2)
  end

  test "compares repeated and map fields by protobuf value semantics" do
    assert PB.message_equal?(%{}, %{repeated_int32: []}, @schema, @proto2)
    assert PB.message_equal?(%{}, %{map_int32_int32: %{}}, @schema, @proto2)

    assert PB.message_equal?(
             %{map_int32_int32: %{1 => 2, 3 => 4}},
             %{map_int32_int32: %{3 => 4, 1 => 2}},
             @schema,
             @proto2
           )

    refute PB.message_equal?(
             %{repeated_int32: [1, 2]},
             %{
               repeated_int32: [2, 1]
             },
             @schema,
             @proto2
           )
  end

  test "ignores PB message-name metadata" do
    assert PB.message_equal?(
             %{__message_name__: @proto2, single_int32: 7},
             %{single_int32: 7},
             @schema,
             @proto2
           )
  end

  test "uses IEEE equality for decoded float fields" do
    refute PB.message_equal?(
             %{single_double: :nan},
             %{
               single_double: :nan
             },
             @schema,
             @proto2
           )

    assert PB.message_equal?(
             %{single_double: 0.0},
             %{
               single_double: -0.0
             },
             @schema,
             @proto2
           )
  end

  test "recurses into nested message fields only when present" do
    assert PB.message_equal?(%{}, %{}, @schema, @proto2)

    assert PB.message_equal?(
             %{single_nested_message: %{bb: 1}},
             %{single_nested_message: %{bb: 1}},
             @schema,
             @proto2
           )

    refute PB.message_equal?(
             %{single_nested_message: %{bb: 1}},
             %{single_nested_message: %{bb: 2}},
             @schema,
             @proto2
           )
  end

  test "treats Any as an ordinary protobuf message" do
    refute PB.message_equal?(
             %{type_url: "type.googleapis.com/example.Msg", value: <<1, 2>>},
             %{type_url: "type.googleapis.com/example.Msg", value: <<2, 1>>},
             @schema,
             :"google.protobuf.Any"
           )
  end

  test "raises on unknown message" do
    assert_raise PB.SchemaError, fn ->
      PB.message_equal?(%{}, %{}, @schema, :"does.not.Exist")
    end
  end

  test "raises when an input is not a valid term for the message type" do
    for {left, right} <- [{42, %{}}, {%{}, "nope"}] do
      error =
        assert_raise PB.ValueError, fn -> PB.message_equal?(left, right, @schema, @proto2) end

      assert error.operation == :message_equal
    end
  end

  test "raises when a nested message value is malformed rather than reporting unequal" do
    error =
      assert_raise PB.ValueError, fn ->
        PB.message_equal?(
          %{single_nested_message: 42},
          %{single_nested_message: %{bb: 1}},
          @schema,
          @proto2
        )
      end

    assert error.operation == :message_equal
  end
end
