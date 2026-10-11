defmodule PB.CEL.ValueTest do
  use ExUnit.Case, async: true

  alias PB.CEL.ProtoType
  alias PB.CEL.Value
  alias PB.Validate.CEL.MessageRuntime
  alias PB.Validate.CEL.MessageSchema
  alias PB.WellKnownTypes.Codec, as: WKTCodec
  alias PB.WellKnownTypes.Time, as: WKTTime

  test "infers tagged values from plain terms" do
    assert Value.infer(%{"a" => [1, nil]}) ==
             {:ok, Value.map(%{Value.string("a") => Value.list([Value.int(1), Value.null()])})}

    env = PB.CEL.Env.build(vars: %{x: :dyn})
    assert PB.CEL.eval(~S|x.a + x["b"]|, %{x: %{"a" => 1, "b" => 2}}, env) == {:ok, Value.int(3)}
  end

  test "decodes cel.expr.ExprValue and cel.expr.Value scalars" do
    assert Value.from_expr_value(%{kind: {:value, %{kind: {:int64_value, 42}}}}) ==
             {:ok, Value.int(42)}

    assert Value.from_expr_value(%{kind: {:double_value, :infinity}}) ==
             {:ok, Value.double(:infinity)}
  end

  test "decodes aggregate cel.expr.Value messages" do
    expr_value = %{
      kind:
        {:value,
         %{
           kind:
             {:list_value,
              %{
                values: [
                  %{kind: {:string_value, "one"}},
                  %{kind: {:null_value, :NULL_VALUE}}
                ]
              }}
         }}
    }

    assert Value.from_expr_value(expr_value) ==
             {:ok, Value.list([Value.string("one"), Value.null()])}
  end

  test "decodes timestamp and duration object values" do
    {:ok, timestamp_message} =
      WKTTime.to_proto_timestamp(Value.timestamp(1_234_567_890_123_456_789))

    assert {:ok, timestamp_bytes} = WKTCodec.encode_timestamp(timestamp_message)

    assert Value.from_expr_value(%{
             kind:
               {:object_value,
                %{
                  type_url: "type.googleapis.com/google.protobuf.Timestamp",
                  value: IO.iodata_to_binary(timestamp_bytes)
                }}
           }) == {:ok, Value.timestamp(1_234_567_890_123_456_789)}

    {:ok, duration_message} = WKTTime.to_proto_duration(Value.duration(123_321_456_789))

    assert {:ok, duration_bytes} = WKTCodec.encode_duration(duration_message)

    assert Value.from_expr_value(%{
             kind:
               {:object_value,
                %{
                  type_url: "type.googleapis.com/google.protobuf.Duration",
                  value: IO.iodata_to_binary(duration_bytes)
                }}
           }) == {:ok, Value.duration(123_321_456_789)}
  end

  test "decodes schema-backed object values" do
    schema = PB.TestSupport.TestSchema.schema()

    assert Value.from_expr_value(
             %{
               kind:
                 {:object_value,
                  %{
                    type_url: "type.googleapis.com/cel.expr.conformance.proto2.TestAllTypes",
                    value: <<8, 17>>
                  }}
             },
             schema: schema,
             message_schema: MessageSchema,
             message_runtime: MessageRuntime
           ) ==
             {:ok, {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_int32: 17}}}

    assert Value.from_expr_value(
             %{
               kind:
                 {:object_value,
                  %{
                    type_url: "type.googleapis.com/google.protobuf.Int32Value",
                    value: <<8, 128, 137, 122>>
                  }}
             },
             schema: schema,
             message_schema: MessageSchema,
             message_runtime: MessageRuntime
           ) == {:ok, Value.int(2_000_000)}
  end

  test "resolves object values by the last segment of any type URL" do
    schema = PB.TestSupport.TestSchema.schema()
    opts = [schema: schema, message_schema: MessageSchema, message_runtime: MessageRuntime]

    object = fn type_url, value ->
      Value.from_expr_value(%{kind: {:object_value, %{type_url: type_url, value: value}}}, opts)
    end

    assert object.("example.com/a/cel.expr.conformance.proto2.TestAllTypes", <<8, 17>>) ==
             {:ok, {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_int32: 17}}}

    assert object.("type.googleprod.com/google.protobuf.Duration", <<8, 3>>) ==
             {:ok, Value.duration(3_000_000_000)}
  end

  test "decodes CEL type values" do
    assert Value.from_expr_value(%{kind: {:type_value, "null_type"}}) ==
             {:ok, {:type, ProtoType.null()}}

    assert Value.from_expr_value(%{kind: {:type_value, "list"}}) ==
             {:ok, {:type, ProtoType.list(ProtoType.dyn())}}

    assert Value.from_expr_value(%{kind: {:type_value, "google.protobuf.Timestamp"}}) ==
             {:ok, {:type, ProtoType.timestamp()}}
  end

  test "round-trips supported values through cel.expr.ExprValue shape" do
    value =
      Value.map(%{
        Value.string("k") => Value.list([Value.uint(1), Value.double(:negative_infinity)])
      })

    assert {:ok, expr_value} = Value.to_expr_value(value)
    assert Value.from_expr_value(expr_value) == {:ok, value}
  end

  describe "to_native/1" do
    test "strips scalar tags" do
      assert Value.to_native(Value.null()) == nil
      assert Value.to_native(Value.bool(true)) == true
      assert Value.to_native(Value.int(5)) == 5
      assert Value.to_native(Value.uint(7)) == 7
      assert Value.to_native(Value.double(1.5)) == 1.5
      assert Value.to_native(Value.string("x")) == "x"
      assert Value.to_native(Value.bytes(<<1, 2>>)) == <<1, 2>>
      assert Value.to_native(Value.enum("my.Enum", 3)) == 3
    end

    test "keeps non-finite doubles as atoms" do
      assert Value.to_native(Value.double(:nan)) == :nan
      assert Value.to_native(Value.double(:infinity)) == :infinity
      assert Value.to_native(Value.double(:negative_infinity)) == :negative_infinity
    end

    test "recurses into lists, maps, and messages" do
      assert Value.to_native(Value.list([Value.int(1), Value.string("a")])) == [1, "a"]

      assert Value.to_native(Value.map(%{Value.string("k") => Value.bool(true)})) ==
               %{"k" => true}

      assert Value.to_native({:message, "my.Msg", %{a: Value.int(1), b: Value.string("x")}}) ==
               %{a: 1, b: "x"}
    end

    test "unwraps optionals" do
      assert Value.to_native(Value.optional_none()) == nil
      assert Value.to_native(Value.optional_some(Value.int(9))) == 9
    end

    test "passes through values with no native form" do
      assert Value.to_native(Value.timestamp(123)) == {:timestamp, 123}
      assert Value.to_native(Value.duration(456)) == {:duration, 456}
      assert Value.to_native(Value.object("type.googleapis.com/x", <<>>)) ==
               {:object, "type.googleapis.com/x", <<>>}

      assert Value.to_native({:type, ProtoType.null()}) == {:type, ProtoType.null()}
    end
  end
end
