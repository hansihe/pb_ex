defmodule PB.CEL.ValueTest do
  # The protobuf half of CEL's value tests: cel.expr.Value conversion and
  # schema-backed names. The rest are cel_ex's.
  use ExUnit.Case, async: true

  alias CEL.ProtoType
  alias CEL.Value
  alias PB.CEL.ProtoCodec
  alias PB.WellKnownTypes.Codec, as: WKTCodec
  alias PB.WellKnownTypes.Time, as: WKTTime

  test "decodes cel.expr.ExprValue and cel.expr.Value scalars" do
    assert ProtoCodec.from_expr_value(%{kind: {:value, %{kind: {:int64_value, 42}}}}) ==
             {:ok, Value.int(42)}

    assert ProtoCodec.from_expr_value(%{kind: {:double_value, :infinity}}) ==
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

    assert ProtoCodec.from_expr_value(expr_value) ==
             {:ok, Value.list([Value.string("one"), Value.null()])}
  end

  test "decodes timestamp and duration object values" do
    {:ok, timestamp_message} =
      WKTTime.to_proto_timestamp(Value.timestamp(1_234_567_890_123_456_789))

    assert {:ok, timestamp_bytes} = WKTCodec.encode_timestamp(timestamp_message)

    assert ProtoCodec.from_expr_value(
             %{
               kind:
                 {:object_value,
                  %{
                    type_url: "type.googleapis.com/google.protobuf.Timestamp",
                    value: IO.iodata_to_binary(timestamp_bytes)
                  }}
             }
           ) == {:ok, Value.timestamp(1_234_567_890_123_456_789)}

    {:ok, duration_message} = WKTTime.to_proto_duration(Value.duration(123_321_456_789))

    assert {:ok, duration_bytes} = WKTCodec.encode_duration(duration_message)

    assert ProtoCodec.from_expr_value(
             %{
               kind:
                 {:object_value,
                  %{
                    type_url: "type.googleapis.com/google.protobuf.Duration",
                    value: IO.iodata_to_binary(duration_bytes)
                  }}
             }
           ) == {:ok, Value.duration(123_321_456_789)}
  end

  test "decodes schema-backed object values" do
    schema = PB.TestSupport.TestSchema.schema()

    assert ProtoCodec.from_expr_value(
             %{
               kind:
                 {:object_value,
                  %{
                    type_url: "type.googleapis.com/cel.expr.conformance.proto2.TestAllTypes",
                    value: <<8, 17>>
                  }}
             },
             schema
           ) ==
             {:ok, {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_int32: 17}}}

    assert ProtoCodec.from_expr_value(
             %{
               kind:
                 {:object_value,
                  %{
                    type_url: "type.googleapis.com/google.protobuf.Int32Value",
                    value: <<8, 128, 137, 122>>
                  }}
             },
             schema
           ) == {:ok, Value.int(2_000_000)}
  end

  test "resolves object values by the last segment of any type URL" do
    schema = PB.TestSupport.TestSchema.schema()
    object = fn type_url, value ->
      ProtoCodec.from_expr_value(%{kind: {:object_value, %{type_url: type_url, value: value}}}, schema)
    end

    assert object.("example.com/a/cel.expr.conformance.proto2.TestAllTypes", <<8, 17>>) ==
             {:ok, {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_int32: 17}}}

    assert object.("type.googleprod.com/google.protobuf.Duration", <<8, 3>>) ==
             {:ok, Value.duration(3_000_000_000)}
  end

  test "decodes CEL type values" do
    assert ProtoCodec.from_expr_value(%{kind: {:type_value, "null_type"}}) ==
             {:ok, {:type, ProtoType.null()}}

    assert ProtoCodec.from_expr_value(%{kind: {:type_value, "list"}}) ==
             {:ok, {:type, ProtoType.list(ProtoType.dyn())}}

    assert ProtoCodec.from_expr_value(%{kind: {:type_value, "google.protobuf.Timestamp"}}) ==
             {:ok, {:type, ProtoType.timestamp()}}
  end

  test "round-trips supported values through cel.expr.ExprValue shape" do
    value =
      Value.map(%{
        Value.string("k") => Value.list([Value.uint(1), Value.double(:negative_infinity)])
      })

    assert {:ok, expr_value} = ProtoCodec.to_expr_value(value)
    assert ProtoCodec.from_expr_value(expr_value) == {:ok, value}
  end

  test "packs and unpacks timestamps and durations as Any payloads" do
    for value <- [Value.timestamp(1_234_567_890_123_456_789), Value.duration(-1_500_000_000)] do
      assert {:ok, expr_value} = ProtoCodec.to_expr_value(value)
      assert {:object_value, _object} = expr_value.kind |> elem(1) |> Map.fetch!(:kind)
      assert ProtoCodec.from_expr_value(expr_value) == {:ok, value}
    end
  end

  describe "type_name/1" do
    test "gives a message's or enum's full name" do
      env =
        CEL.Env.build(
          types: PB.CEL.types(PB.TestSupport.TestSchema),
          container: "cel.expr.conformance.proto3"
        )

      for {source, name} <- [
            {"type(TestAllTypes{})", "cel.expr.conformance.proto3.TestAllTypes"},
            {"type(GlobalEnum.GAZ)", "cel.expr.conformance.proto3.GlobalEnum"}
          ] do
        assert source |> CEL.eval!(%{}, env) |> Value.type_name() == name
      end
    end
  end
end
