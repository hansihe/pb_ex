defmodule PB.CEL.EvaluatorTest do
  # The schema-backed half of CEL's evaluator tests; the rest are cel_ex's.
  use ExUnit.Case, async: true

  alias CEL.Error
  alias CEL.ProtoType
  alias CEL.Value
  alias PB.Validate.CELExtensions

  test "evaluates schema-backed optional selects with checked field refs" do
    opts =
      env(
        vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
        types: PB.CEL.types(PB.TestSupport.TestSchema)
      )

    assert CEL.eval!("x.?single_int32.hasValue()", %{"x" => %{single_int32: 18}}, opts) ==
             Value.bool(true)

    assert CEL.eval!("x.?single_int32.hasValue()", %{"x" => %{}}, opts) == Value.bool(false)

    assert CEL.eval!(
             "optional.of(x).single_int32.orValue(0)",
             %{"x" => %{single_int32: 18}},
             opts
           ) ==
             Value.int(18)
  end

  test "evaluates schema-backed protobuf object values" do
    schema = PB.TestSupport.TestSchema.schema()

    value =
      PB.CEL.ProtoCodec.from_expr_value!(
        %{
          kind:
            {:object_value,
             %{
               type_url: "type.googleapis.com/cel.expr.conformance.proto2.TestAllTypes",
               value: <<8, 17>>
             }}
        },
        schema
      )

    assert CEL.eval!(
             "x.single_int32",
             %{"x" => value},
             env(
               vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
               types: PB.CEL.types(schema)
             )
           ) == Value.int(17)

    assert CEL.eval!(
             "x.single_int32",
             %{"x" => %{single_int32: 18}},
             env(
               vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
               types: PB.CEL.types(schema)
             )
           ) == Value.int(18)

    assert {:error, %Error{phase: :check, message: ~s/no such field "unknown_ext"/}} =
             CEL.eval(
               "has(x.unknown_ext)",
               %{"x" => %{single_int32: 18}},
               env(
                 vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
                 types: PB.CEL.types(schema)
               )
             )

    assert CEL.eval!(
             ~S|google.protobuf.Any{type_url: "type.googleapis.com/cel.expr.conformance.proto2.TestAllTypes", value: b"\x08\x96\x01"}|,
             %{},
             env(types: PB.CEL.types(schema))
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_int32: 150}}
  end

  test "packs CEL values and explicit message literals into Any fields" do
    opts =
      env(
        container: "cel.expr.conformance.proto2",
        types: PB.CEL.types(PB.TestSupport.TestSchema)
      )

    assert CEL.eval!("TestAllTypes{single_any: 1}", %{}, opts) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{
                single_any: %{
                  type_url: "type.googleapis.com/google.protobuf.Int64Value",
                  value: <<8, 1>>
                }
              }}

    # A wrapper literal is its CEL value, so it packs as that value does, as in
    # cel-go.
    assert CEL.eval!("TestAllTypes{single_any: google.protobuf.Int32Value{value: 1}}", %{}, opts) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{
                single_any: %{
                  type_url: "type.googleapis.com/google.protobuf.Int64Value",
                  value: <<8, 1>>
                }
              }}

    assert CEL.eval!("TestAllTypes{single_any: true}.single_any", %{}, opts) ==
             Value.bool(true)

    assert CEL.eval!("TestAllTypes{single_any: []}.single_any", %{}, opts) ==
             Value.list([])

    assert CEL.eval!("TestAllTypes{single_any: {}}.single_any", %{}, opts) ==
             Value.map(%{})
  end

  test "packs CEL values into protobuf Value fields with JSON mapping" do
    opts = [
      container: "cel.expr.conformance.proto2",
      types: PB.CEL.types(PB.TestSupport.TestSchema)
    ]

    cel_env = env(opts)

    assert CEL.eval!("TestAllTypes{single_value: 9007199254740993}", %{}, cel_env) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "9007199254740993"}}}}

    assert CEL.eval!("TestAllTypes{single_value: 9007199254740993u}", %{}, cel_env) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "9007199254740993"}}}}

    assert CEL.eval!(~S|TestAllTypes{single_value: b"\x00\x01\x02\xff"}|, %{}, cel_env) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "AAEC/w=="}}}}

    assert CEL.eval!(~S|TestAllTypes{single_value: double("NaN")}|, %{}, cel_env) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "NaN"}}}}

    assert CEL.eval!(~S|TestAllTypes{single_value: double("Infinity")}|, %{}, cel_env) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "Infinity"}}}}

    assert CEL.eval!(~S|TestAllTypes{single_value: double("-Infinity")}|, %{}, cel_env) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "-Infinity"}}}}

    assert CEL.eval!(
             ~S|TestAllTypes{single_value: timestamp("2006-01-02T15:04:05.999999999Z")}|,
             %{},
             cel_env
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "2006-01-02T15:04:05.999999999Z"}}}}

    assert CEL.eval!(~S|TestAllTypes{single_value: duration("1.000340012s")}|, %{}, cel_env) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "1.000340012s"}}}}

    assert CEL.eval!(
             ~S|TestAllTypes{single_value: google.protobuf.Timestamp{seconds: 1136214245, nanos: 999999999}}|,
             %{},
             cel_env
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "2006-01-02T15:04:05.999999999Z"}}}}

    assert CEL.eval!(
             ~S|TestAllTypes{single_value: google.protobuf.Duration{seconds: 1, nanos: 340012}}|,
             %{},
             cel_env
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "1.000340012s"}}}}

    assert CEL.eval!(
             "TestAllTypes{single_value: x}",
             %{"x" => %{paths: ["foo_bar", "baz"]}},
             env(Keyword.put(opts, :vars, %{"x" => {:message, "google.protobuf.FieldMask"}}))
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:string_value, "fooBar,baz"}}}}

    assert CEL.eval!(
             "TestAllTypes{single_value: google.protobuf.BoolValue{value: true}}",
             %{},
             cel_env
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:bool_value, true}}}}

    # A declared well-known type is the CEL type it stands for.
    assert CEL.eval!(
             "TestAllTypes{single_value: x}",
             %{"x" => true},
             env(Keyword.put(opts, :vars, %{"x" => {:message, "google.protobuf.BoolValue"}}))
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:bool_value, true}}}}

    assert CEL.eval!(
             "TestAllTypes{single_value: google.protobuf.Empty{}}.single_value",
             %{},
             cel_env
           ) ==
             Value.map(%{})
  end

  test "normalizes schema-backed protobuf message literals" do
    proto2_opts =
      env(
        container: "cel.expr.conformance.proto2",
        types: PB.CEL.types(PB.TestSupport.TestSchema)
      )

    assert CEL.eval!("TestAllTypes{single_int32_wrapper: 0}", %{}, proto2_opts) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_int32_wrapper: %{}}}

    assert CEL.eval!("TestAllTypes{single_float_wrapper: 1.4e55}", %{}, proto2_opts) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_float_wrapper: %{value: :infinity}}}

    assert CEL.eval!(
             "TestAllTypes{single_bool_wrapper: google.protobuf.BoolValue{value: true}}",
             %{},
             proto2_opts
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_bool_wrapper: %{value: true}}}

    assert CEL.eval!(
             "TestAllTypes{single_value: google.protobuf.BoolValue{value: true}}",
             %{},
             proto2_opts
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{single_value: %{kind: {:bool_value, true}}}}

    assert CEL.eval!(
             "TestAllTypes{single_bool: google.protobuf.BoolValue{value: true}}",
             %{},
             proto2_opts
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_bool: true}}

    assert {:error,
            %Error{
              phase: :eval,
              message: "PB failed to normalize" <> _,
              details: %{
                reason: %PB.ValueError{
                  operation: :normalize,
                  kind: :value_out_of_range,
                  path: [:single_int32_wrapper, :value]
                }
              }
            }} = CEL.eval("TestAllTypes{single_int32_wrapper: 12345678900}", %{}, proto2_opts)

    proto3_opts =
      env(
        container: "cel.expr.conformance.proto3",
        types: PB.CEL.types(PB.TestSupport.TestSchema)
      )

    assert CEL.eval!("has(TestAllTypes{single_int32: 0}.single_int32)", %{}, proto3_opts) ==
             Value.bool(false)
  end

  test "evaluates schema-backed enum names and constructors" do
    opts =
      env(
        container: "cel.expr.conformance.proto3",
        types: PB.CEL.types(PB.TestSupport.TestSchema)
      )

    assert CEL.eval!("GlobalEnum.GAZ", %{}, opts) ==
             Value.enum(:"cel.expr.conformance.proto3.GlobalEnum", 2)

    assert CEL.eval!("GlobalEnum", %{}, opts) ==
             {:type, ProtoType.message(:"cel.expr.conformance.proto3.GlobalEnum")}

    assert CEL.eval!("type(GlobalEnum.GOO)", %{}, opts) ==
             {:type, ProtoType.message(:"cel.expr.conformance.proto3.GlobalEnum")}

    assert CEL.eval!("int(GlobalEnum.GAZ)", %{}, opts) == Value.int(2)

    assert CEL.eval!("TestAllTypes.NestedEnum(2)", %{}, opts) ==
             Value.enum(:"cel.expr.conformance.proto3.TestAllTypes.NestedEnum", 2)

    assert CEL.eval!(~S|TestAllTypes.NestedEnum("BAZ")|, %{}, opts) ==
             Value.enum(:"cel.expr.conformance.proto3.TestAllTypes.NestedEnum", 2)

    assert CEL.eval!(
             "TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.BAZ}.standalone_enum",
             %{},
             opts
           ) == Value.enum(:"cel.expr.conformance.proto3.TestAllTypes.NestedEnum", 2)

    assert CEL.eval!("GlobalEnum.GAZ in [2]", %{}, opts) == Value.bool(true)
    assert CEL.eval!("GlobalEnum.GAZ in [1]", %{}, opts) == Value.bool(false)
  end

  test "evaluates protovalidate unique extension" do
    opts = env(functions: CELExtensions.functions())

    assert CEL.eval!(~S|["foo", "Foo"].unique()|, %{}, opts) == Value.bool(true)
    assert CEL.eval!(~S|unique([1, 2, 1])|, %{}, opts) == Value.bool(false)
  end

  test "has() follows CEL presence for stored defaults, as PB.decode(defaults: true) writes" do
    stored = %{single_int64: 0, repeated_int64: [], map_string_string: %{}, single_string: "a"}

    for {field, set?} <- [
          single_int64: false,
          repeated_int64: false,
          map_string_string: false,
          single_string: true
        ] do
      assert CEL.eval("has(msg.#{field})", %{msg: stored}, presence_env()) == {:ok, {:bool, set?}}
    end

    assert CEL.eval("msg.?repeated_int64", %{msg: stored}, presence_env()) == {:ok, {:optional, :none}}
  end

  defp env(opts), do: CEL.Env.build(opts)

  defp presence_env do
    CEL.Env.build(
      types: PB.CEL.types(PB.TestSupport.TestSchema),
      vars: [msg: {:message, "cel.expr.conformance.proto3.TestAllTypes"}]
    )
  end
end
