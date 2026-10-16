defmodule CEL.CheckerTest do
  use ExUnit.Case, async: true

  alias CEL.Error
  alias CEL.Checked
  alias PB.CEL.ProtoCodec
  alias CEL.ProtoType
  alias CEL.Checker.TypePattern
  alias CEL.Checker.Types, as: CType
  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.Runtime.Core, as: RuntimeCore

  defmodule WrappedMessageSchema do
    @behaviour CEL.Message.Schema

    alias PB.CEL.MessageSchema

    def normalize({:wrapped, schema}), do: MessageSchema.normalize(schema)
    def normalize(schema), do: MessageSchema.normalize(schema)

    defdelegate known_message?(schema, name), to: MessageSchema
    defdelegate known_enum?(schema, name), to: MessageSchema
    defdelegate resolve_message(schema, name), to: MessageSchema
    defdelegate resolve_enum(schema, name), to: MessageSchema
    defdelegate enum_value(schema, name), to: MessageSchema
    defdelegate enum_number(schema, enum, name), to: MessageSchema
    defdelegate field(schema, message, field), to: MessageSchema
    defdelegate extension(schema, message, name), to: MessageSchema
    defdelegate field_type(schema, field), to: MessageSchema
    defdelegate literal_field(schema, message, field), to: MessageSchema
    defdelegate required_fields(schema, message), to: MessageSchema
  end

  test "checks variables and records references" do
    checked = CEL.check!("x + 1", env(vars: %{x: :int}))

    assert root_type(checked) == CType.int()
    assert ref(checked, checked.expr.id).overload_id == ["add_int64"]

    [x, one] = call_args(checked.expr)
    assert checked.types[x.id] == CType.int()
    assert ref(checked, x.id) == %{name: "x", overload_id: []}
    assert Checked.op(checked, x) == {:ident, %{kind: :var, name: "x", type: CType.int()}}

    assert Checked.op(checked, checked.expr) ==
             {:call,
              %{
                name: "_+_",
                shape: :intrinsic,
                overload_id: "add_int64",
                eval: {:mfa, {RuntimeCore, :add}},
                target_id: nil,
                arg_ids: [x.id, one.id]
              }}
  end

  test "preserves int and uint as distinct static types" do
    assert {:error, %Error{phase: :check, message: "no matching overload for _+_(int, uint)"}} =
             CEL.check("1 + 2u")

    checked = CEL.check!("1u + 2u")
    assert root_type(checked) == CType.uint()
    assert ref(checked, checked.expr.id).overload_id == ["add_uint64"]
  end

  test "check errors carry the source offset and location of the expression" do
    assert {:error, %Error{expr_id: id, offset: 7, line: 2, column: 3} = error} =
             CEL.check("1 + \n  x.foo")

    assert error.location == "<input>"
    assert is_integer(id)
    assert Exception.message(error) == ~s(undeclared identifier "x" at line 2, column 3)

    parsed = CEL.parse!("[1].map(y, y + 'a')", location: "rules/foo.txtpb")

    assert {:error, %Error{offset: 13, location: "rules/foo.txtpb"}} = CEL.check(parsed)
  end

  test "validate_literals rejects literal arguments the evaluator would reject" do
    env = env(vars: %{x: :string}, validate_literals: [:duration, :timestamp, :regex])

    for {source, message, offset} <- [
          {"duration('30d')", "invalid duration", 9},
          {"timestamp('0000-01-01T00:00:00Z')", "timestamp range", 10},
          {"x.matches('[')", "invalid regex at 1: missing terminating ] for character class", 10},
          {"matches(x, '(')", "invalid regex at 1: missing closing parenthesis", 11}
        ] do
      assert {:error, %Error{phase: :check, message: ^message, offset: ^offset}} =
               CEL.check(source, env)

      assert {:ok, _checked} = CEL.check(source, env(vars: %{x: :string}))
    end

    for source <- ["duration(x) > duration('1s')", "x.matches('^a+$')", "timestamp(x)"] do
      assert {:ok, _checked} = CEL.check(source, env)
    end

    assert {:ok, _checked} = CEL.check("duration('30d')", env(validate_literals: [:regex]))

    assert_raise CEL.OptionError, ~r/validate_literals/, fn -> env(validate_literals: [:int]) end
  end

  test "orders mixed numeric types without dyn, as the CEL spec allows" do
    for {source, overload_id, result} <- [
          {"1 < 2.5", "less_int64_double", true},
          {"-1 <= 0u", "less_equals_int64_uint64", true},
          {"18446744073709551615u > 1.0", "greater_uint64_double", true},
          {"2.0 >= 3", "greater_equals_double_int64", false}
        ] do
      checked = CEL.check!(source)
      assert root_type(checked) == CType.bool()
      assert ref(checked, checked.expr.id).overload_id == [overload_id]
      assert CEL.eval(source) == {:ok, {:bool, result}}
    end

    assert {:error, %Error{phase: :check}} = CEL.check("1 < 2.5 + 1u")
  end

  test "dyn defers mixed-type operator resolution" do
    checked = CEL.check!("dyn(1) + 2u")

    assert root_type(checked) == CType.dyn()
    assert ref(checked, checked.expr.id).overload_id == ["_+__dyn"]

    checked = CEL.check!("dyn(1) == 1")

    assert root_type(checked) == CType.bool()
    assert ref(checked, checked.expr.id).overload_id == ["_equals__dyn"]

    checked = CEL.check!("x[0]", env(vars: %{x: :dyn}))

    assert root_type(checked) == CType.dyn()
    assert ref(checked, checked.expr.id).overload_id == ["_[_]_dyn"]

    checked = CEL.check!("1 in x", env(vars: %{x: :dyn}))

    assert root_type(checked) == CType.bool()
    assert ref(checked, checked.expr.id).overload_id == ["@in_dyn"]
  end

  test "dyn calls require declared dynamic overload metadata" do
    assert {:error, %Error{phase: :check, message: "no matching overload for unknown_dyn(dyn)"}} =
             CEL.check("unknown_dyn(dyn(1))")
  end

  test "dyn widens heterogeneous list and map literals" do
    checked = CEL.check!("dyn([1, 2u, 3.0])")
    assert root_type(checked) == CType.list(CType.dyn())

    checked = CEL.check!(~s|dyn({"a": 1, "b": 2u})|)
    assert root_type(checked) == CType.map(CType.string(), CType.dyn())

    checked = CEL.check!("[1, 2u]")
    assert root_type(checked) == CType.list(CType.dyn())
  end

  test "checks custom environment functions" do
    function = %Function{
      name: "tuple",
      overloads: [
        %Overload{
          id: "tuple_T_U",
          args: [TypePattern.param(:T), TypePattern.param(:U)],
          result: TypePattern.abstract("tuple", [TypePattern.param(:T), TypePattern.param(:U)])
        }
      ]
    }

    checked = CEL.check!("tuple(1, dyn(2u))", env(functions: [function]))

    assert root_type(checked) == {:abstract, "tuple", [CType.int(), CType.dyn()]}
    assert ref(checked, checked.expr.id).overload_id == ["tuple_T_U"]
  end

  test "checks list, map, index, select, and conditional expressions" do
    checked = CEL.check!(~s|{"a": [1, 2]}.a[0] == (true ? 1 : 2)|)

    assert root_type(checked) == CType.bool()
    assert ref(checked, checked.expr.id).overload_id == ["_equals_"]
  end

  test "resolves qualified identifiers before field selection" do
    checked = CEL.check!("a.b.c", env(vars: %{"a.b.c" => :string}))

    assert root_type(checked) == CType.string()
    assert ref(checked, checked.expr.id) == %{name: "a.b.c", overload_id: []}

    checked =
      CEL.check!(
        "a.b.c",
        env(
          vars: %{
            "a.b" => {:map, :string, :string},
            "a.b.c" => :string
          }
        )
      )

    assert root_type(checked) == CType.string()
    assert ref(checked, checked.expr.id) == %{name: "a.b.c", overload_id: []}
  end

  test "falls back to field selection from the longest resolved prefix" do
    checked = CEL.check!("a.b.c", env(vars: %{"a.b" => {:map, :string, :string}}))

    assert root_type(checked) == CType.string()
    assert ref(checked, checked.expr.id).overload_id == ["select_map"]
  end

  test "keeps unchecked message selects on the dynamic path" do
    checked = CEL.check!("msg.field", env(vars: %{"msg" => CType.message("example.Unknown")}))

    assert root_type(checked) == CType.dyn()
    assert ref(checked, checked.expr.id).overload_id == ["select_dyn"]

    assert {:select, op} = Checked.op(checked, checked.expr)
    assert op.kind == :dyn_field
    refute Map.has_key?(op, :message)
    refute Map.has_key?(op, :field_ref)
  end

  test "uses schema-backed protobuf field types" do
    msg_type = CType.message("cel.expr.conformance.proto3.TestAllTypes")

    checked =
      CEL.check!(
        "msg.single_int64",
        env(
          vars: %{"msg" => msg_type},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert root_type(checked) == CType.int()
    assert ref(checked, checked.expr.id).overload_id == ["select_message"]

    %{expr_kind: {:select_expr, %{operand: operand}}} = checked.expr

    assert Checked.op(checked, checked.expr) ==
             {:select,
              %{
                kind: :message_field,
                field: "single_int64",
                receiver_id: operand.id,
                test_only: false,
                overload_id: "select_message",
                message: :"cel.expr.conformance.proto3.TestAllTypes",
                field_ref: %{
                  message: :"cel.expr.conformance.proto3.TestAllTypes",
                  field: :single_int64
                }
              }}

    checked =
      CEL.check!(
        "msg.map_int32_int64[1]",
        env(
          vars: %{"msg" => msg_type},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert root_type(checked) == CType.int()

    checked =
      CEL.check!(
        "msg.oneof_type.payload.single_int64",
        env(
          vars: %{"msg" => msg_type},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert root_type(checked) == CType.int()

    checked =
      CEL.check!(
        "[msg.single_int64_wrapper, msg.single_int64]",
        env(
          vars: %{"msg" => msg_type},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert root_type(checked) == CType.list(CType.wrapper(:int))
    assert Checked.proto_type(checked, checked.expr) == ProtoType.list(ProtoType.wrapper(:INT64))

    checked =
      CEL.check!(
        "[msg.single_timestamp, null][0]",
        env(
          vars: %{"msg" => msg_type},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert Checked.proto_type(checked, checked.expr) == ProtoType.timestamp()

    assert {:error, %Error{phase: :check, message: "no such field \"missing\""}} =
             CEL.check(
               "msg.missing",
               env(
                 vars: %{"msg" => msg_type},
                 schema: PB.TestSupport.TestSchema
               )
             )

    checked =
      CEL.check!(
        "has(msg.single_int64)",
        env(
          vars: %{"msg" => msg_type},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert root_type(checked) == CType.bool()

    %{expr_kind: {:select_expr, %{operand: operand}}} = checked.expr

    assert Checked.op(checked, checked.expr) ==
             {:select,
              %{
                kind: :presence_test,
                field: "single_int64",
                receiver_id: operand.id,
                test_only: true,
                overload_id: "select_message",
                message: :"cel.expr.conformance.proto3.TestAllTypes",
                field_ref: %{
                  message: :"cel.expr.conformance.proto3.TestAllTypes",
                  field: :single_int64
                }
              }}

    assert {:error, %Error{phase: :check, message: "no such field \"missing\""}} =
             CEL.check(
               "has(msg.missing)",
               env(
                 vars: %{"msg" => msg_type},
                 schema: PB.TestSupport.TestSchema
               )
             )
  end

  test "uses configured checker message schema provider" do
    msg_type = CType.message("cel.expr.conformance.proto3.TestAllTypes")

    checked =
      CEL.check!(
        "msg.single_int64",
        env(
          vars: %{"msg" => msg_type},
          schema: {:wrapped, PB.TestSupport.TestSchema},
          message_schema: WrappedMessageSchema
        )
      )

    assert root_type(checked) == CType.int()
    assert ref(checked, checked.expr.id).overload_id == ["select_message"]
  end

  test "uses schema-backed protobuf field refs for optional selects" do
    msg_type = CType.message("cel.expr.conformance.proto3.TestAllTypes")

    checked =
      CEL.check!(
        "msg.?single_int64",
        env(
          vars: %{"msg" => msg_type},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert root_type(checked) == CType.optional(CType.int())
    assert ref(checked, checked.expr.id) == %{name: "_?._", overload_id: ["optional_select"]}

    %{expr_kind: {:call_expr, %{args: [operand, _field]}}} = checked.expr

    assert Checked.op(checked, checked.expr) ==
             {:select,
              %{
                kind: :optional_field,
                name: "_?._",
                field: "single_int64",
                receiver_id: operand.id,
                test_only: false,
                overload_id: "optional_select",
                message: :"cel.expr.conformance.proto3.TestAllTypes",
                field_ref: %{
                  message: :"cel.expr.conformance.proto3.TestAllTypes",
                  field: :single_int64
                }
              }}

    checked =
      CEL.check!(
        "maybe_msg.single_int64",
        env(
          vars: %{"maybe_msg" => CType.optional(msg_type)},
          schema: PB.TestSupport.TestSchema
        )
      )

    assert root_type(checked) == CType.optional(CType.int())

    assert {:select, op} = Checked.op(checked, checked.expr)
    assert op.kind == :optional_field

    assert op.field_ref == %{
             message: :"cel.expr.conformance.proto3.TestAllTypes",
             field: :single_int64
           }

    checked = CEL.check!("fields.?key", env(vars: %{"fields" => CType.map(:string, :int)}))

    assert root_type(checked) == CType.optional(CType.int())

    assert {:select, op} = Checked.op(checked, checked.expr)
    assert op.kind == :optional_map_field
    refute Map.has_key?(op, :field_ref)

    checked = CEL.check!("fields.?key", env(vars: %{"fields" => CType.dyn()}))

    assert root_type(checked) == CType.optional(CType.dyn())

    assert {:select, op} = Checked.op(checked, checked.expr)
    assert op.kind == :optional_dyn_field
    refute Map.has_key?(op, :field_ref)
  end

  test "resolves schema-backed enum names" do
    opts =
      env(
        container: "cel.expr.conformance.proto3",
        schema: PB.TestSupport.TestSchema
      )

    checked = CEL.check!("GlobalEnum.GAZ", opts)

    assert root_type(checked) == CType.message("cel.expr.conformance.proto3.GlobalEnum")

    assert ref(checked, checked.expr.id) == %{
             name: "cel.expr.conformance.proto3.GlobalEnum.GAZ",
             overload_id: [],
             value: %{
               kind: {:enum_value, %{type: "cel.expr.conformance.proto3.GlobalEnum", value: 2}}
             }
           }

    assert Checked.op(checked, checked.expr) ==
             {:ident,
              %{
                kind: :enum_value,
                name: "cel.expr.conformance.proto3.GlobalEnum.GAZ",
                value: {:enum, "cel.expr.conformance.proto3.GlobalEnum", 2}
              }}

    checked = CEL.check!("GlobalEnum", opts)

    assert root_type(checked) ==
             CType.type(CType.message("cel.expr.conformance.proto3.GlobalEnum"))

    assert Checked.op(checked, checked.expr) ==
             {:ident,
              %{
                kind: :type,
                name: "cel.expr.conformance.proto3.GlobalEnum",
                denotation: CEL.ProtoType.message("cel.expr.conformance.proto3.GlobalEnum")
              }}

    assert root_type(CEL.check!("type(GlobalEnum.GOO)", opts)) ==
             CType.type(CType.message("cel.expr.conformance.proto3.GlobalEnum"))

    assert root_type(CEL.check!("int(GlobalEnum.GAZ)", opts)) == CType.int()

    assert root_type(CEL.check!("TestAllTypes.NestedEnum(2)", opts)) ==
             CType.message("cel.expr.conformance.proto3.TestAllTypes.NestedEnum")
  end

  test "resolves identifiers and message literals through the container" do
    checked = CEL.check!("y", env(vars: %{"x.y" => :bool, "y" => :string}, container: "x"))

    assert root_type(checked) == CType.bool()
    assert ref(checked, checked.expr.id) == %{name: "x.y", overload_id: []}

    checked = CEL.check!("Int32Value{value: 34}", env(container: "google.protobuf"))

    assert root_type(checked) == CType.int()

    assert ref(checked, checked.expr.id) == %{
             name: "google.protobuf.Int32Value",
             overload_id: []
           }

    assert Checked.op(checked, checked.expr) ==
             {:message_literal,
              %{
                message: "google.protobuf.Int32Value",
                fields: [%{field: "value", value_id: 1, optional?: false}]
              }}
  end

  test "records special checked ops" do
    checked = CEL.check!("true ? 1 : 2")
    [condition, then_expr, else_expr] = call_args(checked.expr)

    assert Checked.op(checked, checked.expr) ==
             {:special,
              %{
                kind: :conditional,
                name: "_?_:_",
                overload_id: "conditional",
                eval: :intrinsic,
                target_id: nil,
                arg_ids: [condition.id, then_expr.id, else_expr.id]
              }}

    checked = CEL.check!("dyn(1)")
    [arg] = call_args(checked.expr)

    assert Checked.op(checked, checked.expr) ==
             {:call,
              %{
                name: "dyn",
                shape: :global,
                overload_id: "dyn",
                eval: {:mfa, {RuntimeCore, :dyn}},
                target_id: nil,
                arg_ids: [arg.id]
              }}
  end

  test "checks cel.bind as a lexical special form" do
    checked = CEL.check!(~S|cel.bind(x, "a", x + "b")|)
    %{expr_kind: {:call_expr, %{args: [var, init, body]}}} = checked.expr

    assert root_type(checked) == CType.string()

    assert Checked.op(checked, checked.expr) ==
             {:special,
              %{
                kind: :bind,
                name: "bind",
                overload_id: "cel_bind",
                target_id: nil,
                arg_ids: [init.id, body.id],
                var: "x",
                var_id: var.id
              }}
  end

  test "checks macro-expanded comprehensions" do
    checked = CEL.check!("[1].all(x, x > 0)")

    assert root_type(checked) == CType.bool()
    assert match?({:comprehension_expr, _comprehension}, checked.expr.expr_kind)

    assert {:comprehension,
            %{
              iter_var: "x",
              accu_var: "__result__",
              iter_range_id: iter_range_id,
              accu_init_id: accu_init_id,
              loop_condition_id: loop_condition_id,
              loop_step_id: loop_step_id,
              result_id: result_id
            }} = Checked.op(checked, checked.expr)

    assert is_integer(iter_range_id)
    assert is_integer(accu_init_id)
    assert is_integer(loop_condition_id)
    assert is_integer(loop_step_id)
    assert is_integer(result_id)
  end

  test "infers macro-expanded list comprehension result types" do
    checked = CEL.check!("[1].map(x, x)")

    assert root_type(checked) == CType.list(CType.int())

    checked = CEL.check!("[1].map(x, x)[0]")

    assert root_type(checked) == CType.int()

    checked = CEL.check!("[1].filter(x, x > 0)[0]")

    assert root_type(checked) == CType.int()
  end

  test "checks macro-expanded bodies over empty maps" do
    assert root_type(CEL.check!("{}.transformMap(k, v, k + v)")) ==
             CType.map(CType.dyn(), CType.dyn())

    assert root_type(CEL.check!(~S|{}.transformMap(k, v, k == 'foo' && v == 'bar', k + v)|)) ==
             CType.map(CType.string(), CType.string())
  end

  test "rejects comprehension ranges that are not lists or maps" do
    assert {:error, %Error{phase: :check, message: message, expr_id: id}} =
             CEL.check("1.all(x, true)")

    assert message =~ "comprehension range must be list, map, or dyn"
    assert is_integer(id)
  end

  test "widens literals whose element types cannot unify to dyn" do
    assert root_type(CEL.check!("[].exists(x, [x, [x]] == [])")) == CType.bool()
    assert {:ok, {:bool, false}} = CEL.eval("[].exists(x, [x, [x]] == [])", %{})
  end

  test "finalizes unresolved empty literal type variables to dyn" do
    assert root_type(CEL.check!("[]")) == CType.list(CType.dyn())
    assert root_type(CEL.check!("{}")) == CType.map(CType.dyn(), CType.dyn())
  end

  test "generic signatures refine empty literal type variables" do
    checked = CEL.check!("[] + [1]")

    assert root_type(checked) == CType.list(CType.int())
    assert ref(checked, checked.expr.id).overload_id == ["add_list"]

    checked = CEL.check!(~s|{} + {"a": 1}|)

    assert root_type(checked) == CType.map(CType.string(), CType.int())
    assert ref(checked, checked.expr.id).overload_id == ["add_map"]

    checked = CEL.check!("1 in []")
    [_needle, haystack] = call_args(checked.expr)

    assert root_type(checked) == CType.bool()
    assert checked.types[haystack.id] == CType.list(CType.int())
    assert ref(checked, checked.expr.id).overload_id == ["in_list"]

    checked = CEL.check!("true ? [] : [1]")
    [_condition, empty, _values] = call_args(checked.expr)

    assert root_type(checked) == CType.list(CType.int())
    assert checked.types[empty.id] == CType.list(CType.int())
  end

  test "optional signatures refine optional none through fallback values" do
    assert root_type(CEL.check!("optional.none().orValue(1)")) == CType.int()

    assert root_type(CEL.check!("optional.none().or(optional.of(1))")) ==
             CType.optional(CType.int())

    assert root_type(CEL.check!("optional.of(1).or(dyn(optional.of(2)))")) ==
             CType.optional(CType.dyn())

    assert {:error,
            %Error{phase: :check, message: "no matching overload for or(optional_type(int), int)"}} =
             CEL.check("optional.of(1).or(1)")

    assert {:error,
            %Error{phase: :check, message: "no matching overload for optional.unwrap(int)"}} =
             CEL.check("optional.unwrap(1)")
  end

  test "generic signatures preserve explicit dyn type parameters" do
    assert root_type(CEL.check!("optional.of(dyn(1))")) == CType.optional(CType.dyn())

    assert root_type(CEL.check!("[optional.of(1), optional.of(dyn(1))]")) ==
             CType.list(CType.optional(CType.dyn()))

    assert root_type(CEL.check!("true ? optional.of(dyn(1)) : optional.of(1)")) ==
             CType.optional(CType.dyn())
  end

  test "comprehension locals shadow env declarations without hiding root-qualified names" do
    checked = CEL.check!("[1].exists(x, x > 0)", env(vars: %{x: :string}))

    assert root_type(checked) == CType.bool()

    checked = CEL.check!("[1].exists(x, .x == 'root')", env(vars: %{x: :string}))

    assert root_type(checked) == CType.bool()
  end

  test "local first segments force qualified names through field selection" do
    checked =
      CEL.check!(
        ~S|[{"y": 1}].exists(x, x.y > 0)|,
        env(vars: %{"x.y" => :string})
      )

    assert root_type(checked) == CType.bool()

    checked =
      CEL.check!(
        ~S|[{"y": 1}].exists(x, .x.y == 'root')|,
        env(vars: %{"x.y" => :string})
      )

    assert root_type(checked) == CType.bool()
  end

  test "checks scalar conversions and size" do
    assert root_type(CEL.check!("type(1)")) == CType.type(CType.int())
    assert root_type(CEL.check!("int(1u)")) == CType.int()
    assert root_type(CEL.check!("uint(1)")) == CType.uint()
    assert root_type(CEL.check!("double('1.5')")) == CType.double()
    assert root_type(CEL.check!("string(b'abc')")) == CType.string()
    assert root_type(CEL.check!("bytes('abc')")) == CType.bytes()
    assert root_type(CEL.check!("bytes(b'abc')")) == CType.bytes()
    assert root_type(CEL.check!("bool('true')")) == CType.bool()
    assert root_type(CEL.check!("size([1, 2, 3])")) == CType.int()
    assert root_type(CEL.check!("'abc'.size()")) == CType.int()
  end

  test "checks timestamp and duration catalog signatures" do
    assert root_type(CEL.check!(~S|timestamp("2009-02-13T23:31:30Z")|)) == CType.timestamp()
    assert root_type(CEL.check!(~S|duration("60s").getSeconds()|)) == CType.int()

    checked = CEL.check!(~S|timestamp("2009-02-13T23:31:30Z") + duration("1s")|)

    assert root_type(checked) == CType.timestamp()
    assert ref(checked, checked.expr.id).overload_id == ["add_timestamp_duration"]
  end

  test "checked expressions export to generated CEL proto codecs" do
    checked = CEL.check!("x + 1", env(vars: %{x: :int}))
    proto = Checked.to_proto(checked)

    assert {:ok, iodata} = ProtoCodec.encode_checked_expr(proto)
    assert {:ok, decoded} = ProtoCodec.decode_checked_expr(IO.iodata_to_binary(iodata))

    assert decoded == proto
  end

  defp env(opts) do
    opts
    |> Keyword.put_new(:message_schema, PB.CEL.MessageSchema)
    |> CEL.Env.build()
  end
  defp root_type(checked), do: checked.root_type
  defp ref(checked, expr_or_id), do: Checked.ref(checked, expr_or_id)

  defp call_args(%{expr_kind: {:call_expr, %{args: args}}}), do: args
end
