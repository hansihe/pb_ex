defmodule PB.CEL.EvaluatorTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Checked
  alias PB.CEL.Error
  alias PB.CEL.ProtoType
  alias PB.CEL.Value
  alias PB.Validate.CEL.MessageRuntime, as: Message
  alias PB.Validate.CELExtensions

  defmodule StubMessageRuntime do
    @behaviour PB.CEL.Message.Runtime

    defdelegate from_decoded(schema, message, value), to: Message
    defdelegate from_literal(schema, message, fields, wkt_unwrap?), to: Message
    defdelegate from_literal_message(schema, message, fields), to: Message
    defdelegate select_ref(schema, message, field_ref, test_only?), to: Message
    defdelegate optional_select(schema, value, field), to: Message
    defdelegate optional_select_ref(schema, value, field_ref), to: Message
    defdelegate field_value(schema, field, value), to: Message
    defdelegate raw_fields_for_encode(schema, message, value), to: Message
    defdelegate equal?(schema, left, right), to: Message

    def select(_schema, {:message, _name, _fields}, "field", false),
      do: {:ok, Value.string("runtime")}

    def select(schema, message, field, test_only?),
      do: Message.select(schema, message, field, test_only?)
  end

  test "evaluates checked source with runtime bindings" do
    assert CEL.eval!("x + 1", %{x: 2}, env(vars: %{x: :int})) == Value.int(3)
  end

  test "preserves uint values at runtime" do
    assert CEL.eval!("1u + 2u") == Value.uint(3)
  end

  test "defers dyn overload failures to runtime" do
    assert {:error, %Error{phase: :eval, message: "no runtime overload for _+_(int, uint)"}} =
             CEL.eval("dyn(1) + 2u")
  end

  test "evaluates dyn arithmetic through dynamic runtime overloads" do
    assert CEL.eval!("dyn(1) + 2") == Value.int(3)
    assert CEL.eval!(~S|dyn("a") + "b"|) == Value.string("ab")
    assert CEL.eval!("dyn(6) / 3") == Value.int(2)
  end

  test "evaluates maps, selects, indexes, and conditionals" do
    expr = ~s|{"a": [1, 2]}.a[true ? 1 : 0]|

    assert CEL.eval!(expr) == Value.int(2)
  end

  test "uses configured runtime message provider for selects" do
    checked = CEL.check!("msg.field", env(vars: %{"msg" => {:message, "example.Msg"}}))

    assert {:ok, value} =
             CEL.Evaluator.eval(checked, %{"msg" => {:message, "example.Msg", %{}}},
               message_runtime: StubMessageRuntime
             )

    assert value == Value.string("runtime")
  end

  test "evaluates macro-expanded comprehensions" do
    assert CEL.eval!("[1, 2, 3].all(x, x > 0)") == Value.bool(true)
    assert CEL.eval!("[1, 2, 3].exists(x, x == 2)") == Value.bool(true)
    assert CEL.eval!("[1, 2, 3].exists_one(x, x > 1)") == Value.bool(false)
    assert CEL.eval!("[1, 2, 3].filter(x, x > 1)") == Value.list([Value.int(2), Value.int(3)])

    assert CEL.eval!("[1, 2, 3].map(x, x + 1)") ==
             Value.list([Value.int(2), Value.int(3), Value.int(4)])
  end

  test "evaluates comprehension locals separately from root variables" do
    assert CEL.eval!("[1].map(x, x)[0]", %{x: Value.string("root")}, env(vars: %{x: :string})) ==
             Value.int(1)

    assert CEL.eval!(
             "[1].map(x, .x)[0]",
             %{x: Value.string("root")},
             env(vars: %{x: :string})
           ) ==
             Value.string("root")
  end

  test "evaluates cel.bind lexical locals" do
    assert CEL.eval!(~S|cel.bind(x, "a", x + x)|) == Value.string("aa")
    assert CEL.eval!("cel.bind(x, 1, cel.bind(x, 2, x) + x)") == Value.int(3)

    assert {:error, %Error{phase: :eval, message: "division by zero"}} =
             CEL.eval("cel.bind(x, 1 / 0, true)")
  end

  test "evaluates local-qualified selects without stealing root qualified names" do
    assert CEL.eval!(
             ~S|[{"y": 1}].map(x, x.y)[0]|,
             %{"x.y" => Value.string("root")},
             env(vars: %{"x.y" => :string})
           ) == Value.int(1)

    assert CEL.eval!(
             ~S|[{"y": 1}].map(x, .x.y)[0]|,
             %{"x.y" => Value.string("root")},
             env(vars: %{"x.y" => :string})
           ) == Value.string("root")
  end

  test "absorbs runtime errors in CEL logical operators when the result is determined" do
    assert CEL.eval!("dyn([1, 2, 3][3]) || true") == Value.bool(true)
    assert CEL.eval!("dyn([1, 2, 3][3]) && false") == Value.bool(false)

    assert CEL.eval!("(2 / 0 > 3 ? false : true) || true") == Value.bool(true)
    assert CEL.eval!("(2 / 0 > 3 ? false : true) && false") == Value.bool(false)

    assert CEL.eval!("[1, 2, 3].all(e, 6 / (2 - e) == 6)") == Value.bool(false)

    assert {:error, %Error{phase: :eval, message: "division by zero"}} =
             CEL.eval("true && (1 / 0 == 1)")
  end

  test "evaluates bool ordering and dynamic numeric list indexes" do
    assert CEL.eval!("false < true") == Value.bool(true)
    assert CEL.eval!("true >= false") == Value.bool(true)
    assert CEL.eval!("[7, 8, 9][dyn(0u)]") == Value.int(7)
    assert CEL.eval!("[7, 8, 9][dyn(0.0)]") == Value.int(7)
  end

  test "evaluates type denotations as runtime type values" do
    assert CEL.eval!("type(int) == type") == Value.bool(true)
    assert CEL.eval!("bool == bool") == Value.bool(true)
    assert CEL.eval!("list == list") == Value.bool(true)
    assert CEL.eval!("google.protobuf.Timestamp == google.protobuf.Timestamp") == Value.bool(true)
  end

  test "evaluates qualified identifiers with longest-prefix resolution" do
    assert CEL.eval!(
             "a.b.c",
             %{"a.b.c" => Value.string("yeah")},
             env(vars: %{"a.b.c" => :string})
           ) ==
             Value.string("yeah")

    assert CEL.eval!(
             "a.b.c",
             %{
               "a.b" => Value.map(%{Value.string("c") => Value.string("oops")}),
               "a.b.c" => Value.string("yeah")
             },
             env(vars: %{"a.b" => {:map, :string, :string}, "a.b.c" => :string})
           ) == Value.string("yeah")

    assert CEL.eval!(
             "a.b.c",
             %{"a.b" => Value.map(%{Value.string("c") => Value.string("yeah")})},
             env(vars: %{"a.b" => {:map, :string, :string}})
           ) == Value.string("yeah")
  end

  test "evaluates container-relative identifiers and message literals" do
    assert CEL.eval!(
             "y",
             %{"x.y" => Value.bool(true), "y" => Value.string("false")},
             env(
               vars: %{"x.y" => :bool, "y" => :string},
               container: "x"
             )
           ) == Value.bool(true)

    assert CEL.eval!(
             ".y",
             %{"x.y" => Value.bool(true), "y" => Value.string("root")},
             env(
               vars: %{"x.y" => :bool, "y" => :string},
               container: "x"
             )
           ) == Value.string("root")

    assert CEL.eval!("Int32Value{value: 34}", %{}, env(container: "google.protobuf")) ==
             Value.int(34)
  end

  test "evaluates optional chaining through selects, indexes, and entries" do
    assert CEL.eval!("optional.none().optMap(y, y + 1).hasValue()") == Value.bool(false)

    assert CEL.eval!(
             "optional.of(1).optMap(x, .x).orValue('missing')",
             %{x: Value.string("root")},
             env(vars: %{x: :string})
           ) == Value.string("root")

    assert CEL.eval!(
             ~S|optional.of({"y": 1}).optMap(x, x.y).orValue(0)|,
             %{"x.y" => Value.string("root")},
             env(vars: %{"x.y" => :string})
           ) == Value.int(1)

    assert CEL.eval!("optional.of({'c': {'index': 'goodbye'}}).c.index.orValue('default')") ==
             Value.string("goodbye")

    assert CEL.eval!("optional.of({'c': {}}).c.missing.orValue('default')") ==
             Value.string("default")

    assert CEL.eval!("{?'nested': {}.?missing, 'present': true}") ==
             Value.map(%{Value.string("present") => Value.bool(true)})

    assert CEL.eval!("[?{}.?missing, ?optional.of(42), ?optional.none()]") ==
             Value.list([Value.int(42)])

    assert CEL.eval!(~S|has({"foo": optional.none()}.foo)|) == Value.bool(true)
  end

  test "evaluates schema-backed optional selects with checked field refs" do
    opts =
      env(
        vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
        schema: PB.TestSupport.TestSchema
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

  test "reports field errors for present optional scalar values" do
    assert {:error, %Error{phase: :eval, message: message}} =
             CEL.eval("{'null_key': dyn(null)}.?null_key.invalid.hasValue()")

    assert message =~ "no such key"
  end

  test "evaluates scalar conversions and size" do
    assert CEL.eval!("int(1u)") == Value.int(1)
    assert CEL.eval!("uint('42')") == Value.uint(42)
    assert CEL.eval!("double(1)") == Value.double(1.0)
    assert CEL.eval!("string(b'abc')") == Value.string("abc")
    assert CEL.eval!("bytes('abc')") == Value.bytes("abc")
    assert CEL.eval!("bytes(b'abc')") == Value.bytes("abc")
    assert CEL.eval!("bool('FALSE')") == Value.bool(false)
    assert CEL.eval!("size([1, 2, 3])") == Value.int(3)
    assert CEL.eval!("'fiance\\u0301'.size()") == Value.int(7)
  end

  test "evaluates well-known type message literals as CEL values" do
    assert CEL.eval!(~S|google.protobuf.Int32Value{value: 7}|, %{}, env([])) == Value.int(7)

    assert CEL.eval!(~S|google.protobuf.FloatValue{value: 1.1}|, %{}, env([])) ==
             Value.double(1.100000023841858)

    assert CEL.eval!(~S|google.protobuf.FloatValue{value: -1e40}|, %{}, env([])) ==
             Value.double(:negative_infinity)

    assert CEL.eval!(~S|google.protobuf.Value{string_value: "x"}|, %{}, env([])) ==
             Value.string("x")

    assert CEL.eval!(~S|google.protobuf.ListValue{values: ["x"]}|, %{}, env([])) ==
             Value.list([Value.string("x")])

    assert CEL.eval!(
             ~S|google.protobuf.Any{type_url: "type.googleapis.com/example.Msg", value: b"abc"}|,
             %{},
             env([])
           ) ==
             Value.object("type.googleapis.com/example.Msg", "abc")
  end

  test "evaluates schema-backed protobuf object values" do
    schema = PB.TestSupport.TestSchema.schema()

    value =
      Value.from_expr_value!(
        %{
          kind:
            {:object_value,
             %{
               type_url: "type.googleapis.com/cel.expr.conformance.proto2.TestAllTypes",
               value: <<8, 17>>
             }}
        },
        schema: schema,
        message_schema: PB.Validate.CEL.MessageSchema,
        message_runtime: Message
      )

    assert CEL.eval!(
             "x.single_int32",
             %{"x" => value},
             env(
               vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
               schema: schema
             )
           ) == Value.int(17)

    assert CEL.eval!(
             "x.single_int32",
             %{"x" => %{single_int32: 18}},
             env(
               vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
               schema: schema
             )
           ) == Value.int(18)

    assert {:error, %Error{phase: :check, message: ~s/no such field "unknown_ext"/}} =
             CEL.eval(
               "has(x.unknown_ext)",
               %{"x" => %{single_int32: 18}},
               env(
                 vars: %{"x" => {:message, "cel.expr.conformance.proto2.TestAllTypes"}},
                 schema: schema
               )
             )

    assert CEL.eval!(
             ~S|google.protobuf.Any{type_url: "type.googleapis.com/cel.expr.conformance.proto2.TestAllTypes", value: b"\x08\x96\x01"}|,
             %{},
             env(schema: schema)
           ) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes", %{single_int32: 150}}
  end

  test "packs CEL values and explicit message literals into Any fields" do
    opts =
      env(
        container: "cel.expr.conformance.proto2",
        schema: PB.TestSupport.TestSchema
      )

    assert CEL.eval!("TestAllTypes{single_any: 1}", %{}, opts) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{
                single_any: %{
                  type_url: "type.googleapis.com/google.protobuf.Int64Value",
                  value: <<8, 1>>
                }
              }}

    assert CEL.eval!("TestAllTypes{single_any: google.protobuf.Int32Value{value: 1}}", %{}, opts) ==
             {:message, :"cel.expr.conformance.proto2.TestAllTypes",
              %{
                single_any: %{
                  type_url: "type.googleapis.com/google.protobuf.Int32Value",
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
      schema: PB.TestSupport.TestSchema
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
             %{"x" => {:message, "google.protobuf.FieldMask", %{paths: ["foo_bar", "baz"]}}},
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

    assert CEL.eval!(
             "TestAllTypes{single_value: x}",
             %{"x" => {:message, "google.protobuf.BoolValue", %{value: true}}},
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
        schema: PB.TestSupport.TestSchema
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
        schema: PB.TestSupport.TestSchema
      )

    assert CEL.eval!("has(TestAllTypes{single_int32: 0}.single_int32)", %{}, proto3_opts) ==
             Value.bool(false)
  end

  test "evaluates schema-backed enum names and constructors" do
    opts =
      env(
        container: "cel.expr.conformance.proto3",
        schema: PB.TestSupport.TestSchema
      )

    assert CEL.eval!("GlobalEnum.GAZ", %{}, opts) ==
             Value.enum("cel.expr.conformance.proto3.GlobalEnum", 2)

    assert CEL.eval!("GlobalEnum", %{}, opts) ==
             {:type, ProtoType.message("cel.expr.conformance.proto3.GlobalEnum")}

    assert CEL.eval!("type(GlobalEnum.GOO)", %{}, opts) ==
             {:type, ProtoType.message("cel.expr.conformance.proto3.GlobalEnum")}

    assert CEL.eval!("int(GlobalEnum.GAZ)", %{}, opts) == Value.int(2)

    assert CEL.eval!("TestAllTypes.NestedEnum(2)", %{}, opts) ==
             Value.enum("cel.expr.conformance.proto3.TestAllTypes.NestedEnum", 2)

    assert CEL.eval!(~S|TestAllTypes.NestedEnum("BAZ")|, %{}, opts) ==
             Value.enum("cel.expr.conformance.proto3.TestAllTypes.NestedEnum", 2)

    assert CEL.eval!(
             "TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.BAZ}.standalone_enum",
             %{},
             opts
           ) == Value.enum("cel.expr.conformance.proto3.TestAllTypes.NestedEnum", 2)

    assert CEL.eval!("GlobalEnum.GAZ in [2]", %{}, opts) == Value.bool(true)
    assert CEL.eval!("GlobalEnum.GAZ in [1]", %{}, opts) == Value.bool(false)
  end

  test "evaluates protovalidate unique extension" do
    opts = env(functions: CELExtensions.functions())

    assert CEL.eval!(~S|["foo", "Foo"].unique()|, %{}, opts) == Value.bool(true)
    assert CEL.eval!(~S|unique([1, 2, 1])|, %{}, opts) == Value.bool(false)
  end

  test "evaluates timestamp and duration functions" do
    assert CEL.eval!(~S|string(timestamp("2009-02-13T23:31:30Z"))|) ==
             Value.string("2009-02-13T23:31:30Z")

    assert CEL.eval!(~S|timestamp("2009-02-13T23:00:00Z") + duration("240s")|) ==
             Value.timestamp(1_234_566_240_000_000_000)

    assert CEL.eval!(~S|duration("3730s").getMinutes()|) == Value.int(62)
    assert CEL.eval!(~S|timestamp("2009-02-13T23:31:30Z").getHours("02:00")|) == Value.int(1)
  end

  test "reports runtime conversion failures" do
    assert {:error, %Error{phase: :eval, message: "uint value is out of int range"}} =
             CEL.eval("int(18446744073709551615u)")

    assert {:error, %Error{phase: :eval, message: "bytes value is not valid UTF-8"}} =
             CEL.eval("string(b'\\xff')")

    assert {:error, %Error{phase: :eval, message: "cannot convert string to bool"}} =
             CEL.eval("bool('FaLsE')")

    assert {:error, %Error{phase: :eval, message: "division by zero"}} =
             CEL.eval("1 / 0")

    assert {:error, %Error{phase: :eval, message: "modulus by zero"}} =
             CEL.eval("1 % 0")

    assert {:error, %Error{phase: :eval, message: "integer overflow"}} =
             CEL.eval("9223372036854775807 + 1")

    assert {:error, %Error{phase: :eval, message: "unsigned integer overflow"}} =
             CEL.eval("0u - 1u")
  end

  test "evaluates CEL special double values" do
    assert CEL.eval!("15.75 / 0.0") == Value.double(:infinity)
    assert CEL.eval!("-15.75 / 0.0") == Value.double(:negative_infinity)
    assert CEL.eval!("0.0 / 0.0") == Value.double(:nan)
    assert CEL.eval!("2.0 * 8.988466e307") == Value.double(:infinity)
    assert CEL.eval!("2.0 * -8.988466e307") == Value.double(:negative_infinity)
    assert CEL.eval!("0.0 / 0.0 == 0.0 / 0.0") == Value.bool(false)
    assert CEL.eval!("0.0 / 0.0 != 0.0 / 0.0") == Value.bool(true)
    assert CEL.eval!("double('NaN')") == Value.double(:nan)
    assert CEL.eval!("string(double('Infinity'))") == Value.string("Infinity")
  end

  test "evaluates math extension predicates and extrema" do
    assert CEL.eval!("math.isNaN(0.0 / 0.0)") == Value.bool(true)
    assert CEL.eval!("math.isInf(1.0 / 0.0)") == Value.bool(true)
    assert CEL.eval!("math.isFinite(1.0 / 1.5)") == Value.bool(true)
    assert CEL.eval!("math.bitShiftRight(-8, 0)") == Value.int(-8)
    assert CEL.eval!("math.bitShiftRight(-8, 1)") == Value.int(9_223_372_036_854_775_804)
    assert CEL.eval!("math.bitShiftLeft(-8, 0)") == Value.int(-8)

    assert CEL.eval!("math.greatest(5.4, 10, 3u, -5.0, 9223372036854775807)") ==
             Value.int(9_223_372_036_854_775_807)

    assert CEL.eval!("math.least([5.4, 10, 3u, -5.0, 3.5])") ==
             Value.double(-5.0)

    assert {:error, %Error{phase: :eval, message: "no such overload"}} =
             CEL.eval("math.isNaN(dyn(true))")
  end

  test "evaluates base64 encoder extension functions" do
    assert CEL.eval!(~S|base64.encode(b'hello')|) == Value.string("aGVsbG8=")
    assert CEL.eval!(~S|base64.decode('aGVsbG8=')|) == Value.bytes("hello")
    assert CEL.eval!(~S|base64.decode('aGVsbG8')|) == Value.bytes("hello")

    assert CEL.eval!(~S|base64.decode(base64.encode(b'Hello World!'))|) ==
             Value.bytes("Hello World!")

    assert {:error, %Error{phase: :eval, message: "invalid base64"}} =
             CEL.eval(~S|base64.decode('***')|)
  end

  test "evaluates string extension functions" do
    assert CEL.eval!(~S|'tacocat'.charAt(3)|) == Value.string("o")
    assert CEL.eval!(~S|'©αT'.charAt(1)|) == Value.string("α")
    assert CEL.eval!(~S|'ta©o©αT'.indexOf('©αT', 3)|) == Value.int(4)
    assert CEL.eval!(~S|'bananananana'.lastIndexOf('nana', 7)|) == Value.int(6)
    assert CEL.eval!(~S|'ta©o©αT'.substring(2, 6)|) == Value.string("©o©α")

    assert CEL.eval!(~S|'{0} days {0} hours'.replace('{0}', '2', 1)|) ==
             Value.string("2 days {0} hours")

    assert CEL.eval!(~S|'hello world events!'.split(' ', 2)|) ==
             Value.list([Value.string("hello"), Value.string("world events!")])

    assert CEL.eval!(~S|'hello world events!'.split(' ', 0) == []|) == Value.bool(true)
    assert CEL.eval!(~S|['x', 'y'].join('-')|) == Value.string("x-y")
    assert CEL.eval!(~S|dyn('tacocat').charAt(3)|) == Value.string("o")
    assert CEL.eval!(~S|[dyn('x'), dyn('y')].join('-')|) == Value.string("x-y")
    assert CEL.eval!(~S|'TacoCÆt Xii'.lowerAscii()|) == Value.string("tacocÆt xii")
    assert CEL.eval!(~S|'tacoCαt'.upperAscii()|) == Value.string("TACOCαT")
    assert CEL.eval!(~S|' \f\n\r\t\vtext  '.trim()|) == Value.string("text")
    assert CEL.eval!(~S|'hubba'.matches('ubb')|) == Value.bool(true)
    assert CEL.eval!(~S<matches('grey', 'gr(a|e)y')>) == Value.bool(true)
    assert CEL.eval!(~S|strings.quote("bell\a")|) == Value.string(~S|"bell\a"|)
    assert CEL.eval!(~S|b"abcdef".startsWith(b"abc")|) == Value.bool(true)
    assert CEL.eval!(~S|b"abcdef".endsWith(b"def")|) == Value.bool(true)
    assert CEL.eval!(~S|b"abcdef".contains(b"cd")|) == Value.bool(true)
    assert CEL.eval!(~S|b"abcdef".contains(b"")|) == Value.bool(true)

    assert {:error, %Error{phase: :eval, message: "index out of range: 30"}} =
             CEL.eval(~S|'tacocat'.charAt(30)|)

    assert {:error, %Error{phase: :eval, message: "no such overload"}} =
             CEL.eval(~S|[dyn('x'), dyn(1)].join()|)
  end

  test "uses supplied precompiled regexes for matches calls" do
    checked =
      CEL.check!(~S|value.matches(pattern)|, env(vars: %{value: :string, pattern: :string}))

    matches_id = checked.expr.id
    assert {:call, %{name: "matches"}} = Checked.op(checked, matches_id)

    vars = %{"value" => "aaa", "pattern" => "^z+$"}

    assert {:ok, {:bool, false}} = CEL.Evaluator.eval(checked, vars)

    assert {:ok, {:bool, true}} =
             CEL.Evaluator.eval(checked, vars, regexes: %{matches_id => ~r/^a+$/})
  end

  test "matches with RE2-like Unicode rules and a bounded match" do
    # `.` matches a code point; `\w` stays ASCII, as in RE2.
    assert CEL.eval!(~S|'é'.matches('^.$')|) == Value.bool(true)
    assert CEL.eval!(~S|'é'.matches('^\\w$')|) == Value.bool(false)

    # Catastrophic backtracking ends in an error rather than running on.
    input = String.duplicate("a", 40) <> "b"

    assert {:error, %Error{phase: :eval, message: "regex match exceeded" <> _}} =
             CEL.eval(~s|'#{input}'.matches('^(a+)+$')|)
  end

  test "compiled programs compile literal patterns once" do
    program = CEL.compile!(~S|value.matches('^a+$')|, env(vars: %{value: :string}))
    assert [%Regex{source: "^a+$"}] = Map.values(program.regexes)
    assert CEL.Program.eval!(program, %{"value" => "aaa"}) == Value.bool(true)

    # An invalid literal pattern is reported when evaluated.
    program = CEL.compile!(~S|value.matches('(')|, env(vars: %{value: :string}))
    assert program.regexes == %{}

    assert {:error, %Error{message: "invalid regex" <> _}} =
             CEL.Program.eval(program, %{"value" => "a"})
  end

  test "error messages are strings, with the runtime reason in details" do
    assert {:error,
            %Error{
              message: "no message runtime",
              details: %{reason: :no_message_runtime}
            }} = CEL.eval("google.protobuf.Int32Value{value: 1}", %{})
  end

  test "evaluates string format extension" do
    assert CEL.eval!(~S|'%d %s %x'.format([42, 'ok', b'AZ'])|) ==
             Value.string("42 ok 415a")

    assert CEL.eval!(~S|'%.0f %.0f %.3f'.format([1.5, 2.5, 123.4999])|) ==
             Value.string("2 2 123.500")

    assert CEL.eval!(~S|'%s'.format([[double('NaN'), null, {'b': 2, 'a': 1}]])|) ==
             Value.string("[NaN, null, {a: 1, b: 2}]")

    assert CEL.eval!(~S|'%.2f %.0f %.20f'.format([1.005, 0.5, 0.1])|) ==
             Value.string("1.00 0 0.10000000000000000555")

    assert CEL.eval!(~S|'%f'.format([1e303])|) ==
             Value.string(
               "1000000000000000000161765076786456438212668646231659438295495017101117499" <>
                 "2257387478652602430342139152537797735681803374160274458205677791996433915" <>
                 "4160602606861115074612228497617725665004420052727680732706769046211266142" <>
                 "7500197051226489898260678763391449376088547292320814127957486330655468919" <>
                 "122263277568.000000"
             )

    assert CEL.eval!(~S|'%e %e %.2e %e'.format([5e-324, 1.7976931348623157e308, 9.996, -0.0])|) ==
             Value.string("4.940656e-324 1.797693e+308 1.00e+01 -0.000000e+00")

    assert {:error, %Error{phase: :eval, message: message}} = CEL.eval(~S|'%d'.format([null])|)
    assert message =~ "decimal clause"
  end

  test "can evaluate a pre-compiled program" do
    program = CEL.compile!("x.startsWith('he')", env(vars: %{x: :string}))

    assert CEL.Program.eval!(program, %{x: "hello"}) == Value.bool(true)
  end

  defp env(opts) do
    opts
    |> Keyword.put_new(:message_runtime, Message)
    |> Keyword.put_new(:message_schema, PB.Validate.CEL.MessageSchema)
    |> CEL.Env.build()
  end
end
