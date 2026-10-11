defmodule PB.ValidateTest do
  use ExUnit.Case, async: true

  alias PB.Validate.Context
  alias PB.Validate.Error
  alias PB.Validate.Violation

  @phase2_binpb_path "test/fixtures/schema/validate_phase2.binpb"
  @predefined_binpb_path "test/fixtures/schema/validate_predefined.binpb"
  @custom_predefined_binpb_path "test/fixtures/schema/validate_custom_predefined.binpb"
  @structural_binpb_path "test/fixtures/schema/validate_structural.binpb"

  setup_all do
    phase2_schema =
      @phase2_binpb_path
      |> File.read!()
      |> PB.decode_descriptor_set!()
      |> PB.compile()

    structural_schema =
      @structural_binpb_path
      |> File.read!()
      |> PB.decode_descriptor_set!()
      |> PB.compile()

    structural_nested_schema =
      @structural_binpb_path
      |> File.read!()
      |> PB.decode_descriptor_set!()
      |> with_nested_message_oneof_parent()
      |> PB.compile()

    predefined_schema =
      @predefined_binpb_path
      |> File.read!()
      |> PB.decode_descriptor_set!()
      |> PB.compile()

    custom_predefined_schema =
      @custom_predefined_binpb_path
      |> File.read!()
      |> PB.decode_descriptor_set!()
      |> PB.compile()

    {:ok,
     phase2_schema: phase2_schema,
     predefined_schema: predefined_schema,
     custom_predefined_schema: custom_predefined_schema,
     structural_schema: structural_schema,
     structural_nested_schema: structural_nested_schema}
  end

  test "evaluates message-level user CEL", %{phase2_schema: schema} do
    assert :ok = PB.Validate.validate(%{value: "ok"}, schema, :"validate_phase2.MessageCEL")

    assert {:error, %Error{violations: [violation]} = error} =
             PB.Validate.validate(%{value: ""}, schema, :"validate_phase2.MessageCEL")

    assert violation.rule_id == "x"
    assert violation.message == "value must not be empty"
    assert violation.source == "this.value.size() > 0"

    assert violation.rule.elements == [
             %{
               field_number: 3,
               field_name: "cel",
               field_type: :TYPE_MESSAGE,
               subscript: {:index, 0}
             }
           ]

    assert PB.Validate.to_proto_violations(error) == %{
             violations: [
               %{
                 rule_id: "x",
                 message: "value must not be empty"
               }
             ]
           }
  end

  test "evaluates field-level user CEL", %{phase2_schema: schema} do
    assert :ok = PB.Validate.validate(%{value: "ok"}, schema, :"validate_phase2.FieldCEL")

    assert {:error, %Error{violations: [violation]} = error} =
             PB.Validate.validate(%{value: ""}, schema, :"validate_phase2.FieldCEL")

    assert violation.rule_id == "y"
    assert violation.message == "field value must not be empty"
    assert violation.source == "this.size() > 0"

    assert violation.field.elements == [
             %{field_number: 1, field_name: "value", field_type: :TYPE_STRING}
           ]

    assert violation.rule.elements == [
             %{
               field_number: 23,
               field_name: "cel",
               field_type: :TYPE_MESSAGE,
               subscript: {:index, 0}
             }
           ]

    assert PB.Validate.to_proto_violations(error) == %{
             violations: [
               %{
                 rule_id: "y",
                 message: "field value must not be empty",
                 field: %{
                   elements: [%{field_number: 1, field_name: "value", field_type: :TYPE_STRING}]
                 },
                 rule: %{
                   elements: [
                     %{
                       field_number: 23,
                       field_name: "cel",
                       field_type: :TYPE_MESSAGE,
                       subscript: {:index, 0}
                     }
                   ]
                 }
               }
             ]
           }
  end

  test "field-level CEL reports wrong-typed message values as PB.ValueError",
       %{phase2_schema: schema} do
    error =
      assert_raise PB.ValueError, fn ->
        PB.Validate.validate(%{value: "oops"}, schema, :"validate_phase2.NowCEL")
      end

    assert error.operation == :validate
    assert error.kind == :invalid_value
    assert error.message_name == :"validate_phase2.NowCEL"
    assert error.path == [:value]
    assert error.expected == {:message, :"google.protobuf.Timestamp"}
    assert error.got == "oops"
  end

  test "evaluates message-level cel_expression shorthand", %{phase2_schema: schema} do
    message = :"validate_phase2.MessageCELExpression"

    assert :ok = PB.Validate.validate(%{value: "ok"}, schema, message)

    assert {:error, %Error{violations: [violation]}} =
             PB.Validate.validate(%{value: ""}, schema, message)

    assert violation.rule_id == "this.value.size() > 0"
    assert violation.message == ~s|"this.value.size() > 0" returned false|
    assert violation.source == "this.value.size() > 0"

    assert violation.rule.elements == [
             %{
               field_number: 5,
               field_name: "cel_expression",
               field_type: :TYPE_STRING,
               subscript: {:index, 0}
             }
           ]
  end

  test "evaluates field-level cel_expression shorthand", %{phase2_schema: schema} do
    message = :"validate_phase2.FieldCELExpression"

    assert :ok = PB.Validate.validate(%{value: "ok"}, schema, message)

    assert {:error, %Error{violations: [violation]} = error} =
             PB.Validate.validate(%{value: ""}, schema, message)

    assert violation.rule_id == "this.size() > 0"
    assert violation.message == ~s|"this.size() > 0" returned false|
    assert violation.source == "this.size() > 0"

    assert violation.field.elements == [
             %{field_number: 1, field_name: "value", field_type: :TYPE_STRING}
           ]

    assert violation.rule.elements == [
             %{
               field_number: 29,
               field_name: "cel_expression",
               field_type: :TYPE_STRING,
               subscript: {:index, 0}
             }
           ]

    assert PB.Validate.to_proto_violations(error) == %{
             violations: [
               %{
                 rule_id: "this.size() > 0",
                 message: ~s|"this.size() > 0" returned false|,
                 field: %{
                   elements: [%{field_number: 1, field_name: "value", field_type: :TYPE_STRING}]
                 },
                 rule: %{
                   elements: [
                     %{
                       field_number: 29,
                       field_name: "cel_expression",
                       field_type: :TYPE_STRING,
                       subscript: {:index, 0}
                     }
                   ]
                 }
               }
             ]
           }
  end

  test "evaluates CEL with validation context", %{phase2_schema: schema} do
    message = :"validate_phase2.NowCEL"
    context = Context.new(now: {:timestamp, 1_000_000_000})

    assert :ok =
             PB.Validate.validate(%{value: %{seconds: 2}}, schema, message, context: context)

    assert {:error, %Error{violations: [violation]}} =
             PB.Validate.validate(%{value: %{seconds: 1}}, schema, message, now: 1_000_000_000)

    assert violation.rule_id == "future"
    assert violation.message == "value must be in the future"
    assert violation.source == "this > now"
  end

  test "validate options are validated", %{phase2_schema: schema} do
    message = :"validate_phase2.MessageCEL"

    assert {:error,
            %PB.OptionError{
              operation: :validate,
              message_name: ^message,
              kind: :unknown_options,
              options: [:bogus]
            }} = PB.Validate.validate(%{value: "ok"}, schema, message, bogus: true)

    assert {:error, %PB.OptionError{kind: :unknown_options, options: [:nowx]}} =
             PB.Validate.validate(%{value: "ok"}, schema, message, nowx: 1_000_000_000)

    assert {:error, %PB.OptionError{kind: :invalid_options, reason: :atom}} =
             PB.Validate.validate(%{value: "ok"}, schema, message, :not_options)

    assert {:error, %PB.OptionError{kind: :invalid_options, reason: :list}} =
             PB.Validate.validate(%{value: "ok"}, schema, message, [:not_a_keyword])

    assert {:error, %PB.OptionError{kind: :invalid_option, option: :now, value: :bad}} =
             PB.Validate.validate(%{value: "ok"}, schema, message, now: :bad)

    assert {:error, %PB.OptionError{kind: :invalid_option, option: :context, value: :bad}} =
             PB.Validate.validate(%{value: "ok"}, schema, message, context: :bad)

    assert_raise PB.OptionError, ~r/unknown option/, fn ->
      PB.Validate.validate!(%{value: "ok"}, schema, message, bogus: true)
    end
  end

  test "evaluates predefined field CEL", %{predefined_schema: schema} do
    message = :"validate_predefined.StringRules"

    assert :ok =
             PB.Validate.validate(
               %{
                 email: "name@example.com",
                 min_len: "abc",
                 const: "foo",
                 header_name: "X-Foo"
               },
               schema,
               message
             )

    assert {:error, %Error{violations: [violation]} = error} =
             PB.Validate.validate(
               %{
                 email: "not-an-email",
                 min_len: "abc",
                 const: "foo",
                 header_name: "X-Foo"
               },
               schema,
               message
             )

    assert violation.rule_id == "string.email"
    assert violation.message == "must be a valid email address"
    assert violation.source == "!rules.email || this == '' || this.isEmail()"

    assert violation.rule.elements == [
             %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
             %{field_number: 12, field_name: "email", field_type: :TYPE_BOOL}
           ]

    assert PB.Validate.to_proto_violations(error) == %{
             violations: [
               %{
                 rule_id: "string.email",
                 message: "must be a valid email address",
                 field: %{
                   elements: [%{field_number: 1, field_name: "email", field_type: :TYPE_STRING}]
                 },
                 rule: %{
                   elements: [
                     %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
                     %{field_number: 12, field_name: "email", field_type: :TYPE_BOOL}
                   ]
                 }
               }
             ]
           }

    assert {:error, %Error{violations: [min_len]}} =
             PB.Validate.validate(
               %{
                 email: "name@example.com",
                 min_len: "ab",
                 const: "foo",
                 header_name: "X-Foo"
               },
               schema,
               message
             )

    assert min_len.rule_id == "string.min_len"
    assert min_len.message == "must be at least 3 characters"

    assert {:error, %Error{violations: [const]}} =
             PB.Validate.validate(
               %{
                 email: "name@example.com",
                 min_len: "abc",
                 const: "bar",
                 header_name: "X-Foo"
               },
               schema,
               message
             )

    assert const.rule_id == "string.const"
    assert const.message == "must equal `foo`"

    assert {:error, %Error{violations: [header_name]}} =
             PB.Validate.validate(
               %{
                 email: "name@example.com",
                 min_len: "abc",
                 const: "foo",
                 header_name: "bad header"
               },
               schema,
               message
             )

    assert header_name.rule_id == "string.well_known_regex.header_name"
    assert header_name.message == "must be a valid HTTP header name"
  end

  test "evaluates repeated item and map key/value rules", %{predefined_schema: schema} do
    message = :"validate_predefined.NestedRules"

    assert :ok =
             PB.Validate.validate(
               %{
                 names: ["abc"],
                 labels: %{"ab" => "abc"},
                 ignored_items: [%{count: -1}]
               },
               schema,
               message
             )

    assert {:error, %Error{violations: [name, key, value]}} =
             PB.Validate.validate(
               %{
                 names: ["ab"],
                 labels: %{"x" => "ABC"},
                 ignored_items: [%{count: -1}]
               },
               schema,
               message
             )

    assert name.rule_id == "string.min_len"

    assert name.field.elements == [
             %{
               field_number: 1,
               field_name: "names",
               field_type: :TYPE_STRING,
               subscript: {:index, 0}
             }
           ]

    assert name.rule.elements == [
             %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
             %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
             %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
             %{field_number: 2, field_name: "min_len", field_type: :TYPE_UINT64}
           ]

    assert key.rule_id == "string.min_len"
    assert key.for_key == true

    assert key.field.elements == [
             %{
               field_number: 2,
               field_name: "labels",
               field_type: :TYPE_MESSAGE,
               key_type: :TYPE_STRING,
               value_type: :TYPE_STRING,
               subscript: {:string_key, "x"}
             }
           ]

    assert key.rule.elements == [
             %{field_number: 19, field_name: "map", field_type: :TYPE_MESSAGE},
             %{field_number: 4, field_name: "keys", field_type: :TYPE_MESSAGE},
             %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
             %{field_number: 2, field_name: "min_len", field_type: :TYPE_UINT64}
           ]

    assert value.rule_id == "string.pattern"
    assert value.for_key == nil

    assert value.field.elements == [
             %{
               field_number: 2,
               field_name: "labels",
               field_type: :TYPE_MESSAGE,
               key_type: :TYPE_STRING,
               value_type: :TYPE_STRING,
               subscript: {:string_key, "x"}
             }
           ]

    assert value.rule.elements == [
             %{field_number: 19, field_name: "map", field_type: :TYPE_MESSAGE},
             %{field_number: 5, field_name: "values", field_type: :TYPE_MESSAGE},
             %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
             %{field_number: 6, field_name: "pattern", field_type: :TYPE_STRING}
           ]
  end

  test "evaluates native Any rules", %{predefined_schema: schema} do
    message = :"validate_predefined.AnyRules"
    duration = %{type_url: "type.googleapis.com/google.protobuf.Duration"}
    timestamp = %{type_url: "type.googleapis.com/google.protobuf.Timestamp"}

    assert :ok =
             PB.Validate.validate(
               %{
                 allowed: duration,
                 blocked: duration
               },
               schema,
               message
             )

    assert {:error, %Error{violations: [allowed]}} =
             PB.Validate.validate(
               %{
                 allowed: timestamp,
                 blocked: duration
               },
               schema,
               message
             )

    assert allowed.rule_id == "any.in"
    assert allowed.message == "type URL must be in the allow list"

    assert allowed.field.elements == [
             %{field_number: 1, field_name: "allowed", field_type: :TYPE_MESSAGE}
           ]

    assert allowed.rule.elements == [
             %{field_number: 20, field_name: "any", field_type: :TYPE_MESSAGE},
             %{field_number: 2, field_name: "in", field_type: :TYPE_STRING}
           ]

    assert {:error, %Error{violations: [blocked]}} =
             PB.Validate.validate(
               %{
                 allowed: duration,
                 blocked: timestamp
               },
               schema,
               message
             )

    assert blocked.rule_id == "any.not_in"
    assert blocked.message == "type URL must not be in the block list"

    assert blocked.field.elements == [
             %{field_number: 2, field_name: "blocked", field_type: :TYPE_MESSAGE}
           ]

    assert blocked.rule.elements == [
             %{field_number: 20, field_name: "any", field_type: :TYPE_MESSAGE},
             %{field_number: 3, field_name: "not_in", field_type: :TYPE_STRING}
           ]
  end

  test "evaluates native Any rules on repeated items", %{predefined_schema: schema} do
    message = :"validate_predefined.NestedRules"

    assert {:error, %Error{violations: [violation]}} =
             PB.Validate.validate(
               %{
                 names: ["abc"],
                 labels: %{"ab" => "abc"},
                 ignored_items: [%{count: -1}],
                 any_values: [%{type_url: "type.googleapis.com/google.protobuf.Timestamp"}]
               },
               schema,
               message
             )

    assert violation.rule_id == "any.in"
    assert violation.message == "type URL must be in the allow list"

    assert violation.field.elements == [
             %{
               field_number: 4,
               field_name: "any_values",
               field_type: :TYPE_MESSAGE,
               subscript: {:index, 0}
             }
           ]

    assert violation.rule.elements == [
             %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
             %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
             %{field_number: 20, field_name: "any", field_type: :TYPE_MESSAGE},
             %{field_number: 2, field_name: "in", field_type: :TYPE_STRING}
           ]
  end

  test "evaluates native enum defined_only rules", %{predefined_schema: schema} do
    message = :"validate_predefined.EnumRules"

    assert :ok =
             PB.Validate.validate(
               %{
                 status: :STATUS_OK,
                 statuses: [:STATUS_UNSPECIFIED, 1]
               },
               schema,
               message
             )

    assert {:error, %Error{violations: [status]}} =
             PB.Validate.validate(
               %{
                 status: 123,
                 statuses: [:STATUS_OK]
               },
               schema,
               message
             )

    assert status.rule_id == "enum.defined_only"
    assert status.message == "value must be one of the defined enum values"

    assert status.field.elements == [
             %{field_number: 1, field_name: "status", field_type: :TYPE_ENUM}
           ]

    assert status.rule.elements == [
             %{field_number: 16, field_name: "enum", field_type: :TYPE_MESSAGE},
             %{field_number: 2, field_name: "defined_only", field_type: :TYPE_BOOL}
           ]

    assert {:error, %Error{violations: [item]}} =
             PB.Validate.validate(
               %{
                 status: :STATUS_OK,
                 statuses: [123]
               },
               schema,
               message
             )

    assert item.rule_id == "enum.defined_only"

    assert item.field.elements == [
             %{
               field_number: 2,
               field_name: "statuses",
               field_type: :TYPE_ENUM,
               subscript: {:index, 0}
             }
           ]

    assert item.rule.elements == [
             %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
             %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
             %{field_number: 16, field_name: "enum", field_type: :TYPE_MESSAGE},
             %{field_number: 2, field_name: "defined_only", field_type: :TYPE_BOOL}
           ]
  end

  test "evaluates extension-backed predefined rules", %{custom_predefined_schema: schema} do
    message = :"validate_custom_predefined.CustomPredefinedRules"

    assert :ok =
             PB.Validate.validate(
               %{
                 value: "good",
                 items: ["fine"],
                 count: 2
               },
               schema,
               message
             )

    assert {:error, %Error{violations: [value]}} =
             PB.Validate.validate(
               %{
                 value: "bad",
                 items: ["fine"],
                 count: 2
               },
               schema,
               message
             )

    assert value.rule_id == "string.not_bad"
    assert value.message == "must not be bad"

    assert value.field.elements == [
             %{field_number: 1, field_name: "value", field_type: :TYPE_STRING}
           ]

    assert value.rule.elements == [
             %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
             %{
               field_number: 1000,
               field_name: "[validate_custom_predefined.string_not_bad]",
               field_type: :TYPE_BOOL
             }
           ]

    assert {:error, %Error{violations: [item]}} =
             PB.Validate.validate(
               %{
                 value: "good",
                 items: ["bad"],
                 count: 2
               },
               schema,
               message
             )

    assert item.rule_id == "string.not_bad"

    assert item.field.elements == [
             %{
               field_number: 2,
               field_name: "items",
               field_type: :TYPE_STRING,
               subscript: {:index, 0}
             }
           ]

    assert item.rule.elements == [
             %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
             %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
             %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
             %{
               field_number: 1000,
               field_name: "[validate_custom_predefined.string_not_bad]",
               field_type: :TYPE_BOOL
             }
           ]

    assert {:error, %Error{violations: [count]}} =
             PB.Validate.validate(
               %{
                 value: "good",
                 items: ["fine"],
                 count: 3
               },
               schema,
               message
             )

    assert count.rule_id == "int64.abs_in"
    assert count.message == "must be in absolute value of list"

    assert count.rule.elements == [
             %{field_number: 4, field_name: "int64", field_type: :TYPE_MESSAGE},
             %{
               field_number: 1000,
               field_name: "[validate_custom_predefined.int64_abs_in]",
               field_type: :TYPE_MESSAGE
             }
           ]
  end

  test "enforces required and ignore structural field rules", %{structural_schema: schema} do
    assert {:error, %Error{violations: [violation]}} =
             PB.Validate.validate(
               %{
                 choice: {:name, "set"}
               },
               schema,
               :"validate_structural.StructuralRules"
             )

    assert violation.rule_id == "required"

    assert violation.field.elements == [
             %{field_number: 1, field_name: "required_value", field_type: :TYPE_STRING}
           ]

    assert :ok =
             PB.Validate.validate(
               %{
                 choice: {:name, "set"},
                 required_value: "set",
                 ignored_required: nil,
                 ignored_zero_cel: ""
               },
               schema,
               :"validate_structural.StructuralRules"
             )
  end

  test "enforces protobuf oneof required", %{structural_schema: schema} do
    assert {:error, %Error{violations: [violation]}} =
             PB.Validate.validate(
               %{
                 required_value: "set"
               },
               schema,
               :"validate_structural.StructuralRules"
             )

    assert violation.rule_id == "required"
    assert violation.field.elements == [%{field_name: "choice"}]
  end

  test "enforces message-level oneof rules", %{structural_schema: schema} do
    message = :"validate_structural.MessageOneofRules"

    assert :ok = PB.Validate.validate(%{left: "set"}, schema, message)

    assert {:error, %Error{violations: [missing]}} =
             PB.Validate.validate(%{}, schema, message)

    assert missing.rule_id == "message.oneof"
    assert missing.message == "one of left, right must be set"
    assert missing.field == nil

    assert {:error, %Error{violations: [multiple]}} =
             PB.Validate.validate(%{left: "set", right: "set"}, schema, message)

    assert multiple.rule_id == "message.oneof"
    assert multiple.message == "only one of left, right can be set"
    assert multiple.field == nil
  end

  test "nil fields are unset", %{structural_schema: schema, predefined_schema: predefined} do
    message = :"validate_structural.StructuralRules"

    assert {:error, %Error{violations: [%{rule_id: "required"}]}} =
             PB.Validate.validate(
               %{choice: {:name, "set"}, required_value: nil},
               schema,
               message
             )

    oneofs = :"validate_structural.MessageOneofRules"
    assert :ok = PB.Validate.validate(%{left: nil, right: "set"}, schema, oneofs)

    assert {:error, %Error{violations: [%{rule_id: "message.oneof"}]}} =
             PB.Validate.validate(%{left: nil}, schema, oneofs)

    strings = :"validate_predefined.StringRules"
    fields = %{email: "name@example.com", const: "foo", header_name: "X-Foo"}

    assert PB.Validate.validate(Map.put(fields, :min_len, nil), predefined, strings) ==
             PB.Validate.validate(fields, predefined, strings)
  end

  test "nested message-level oneof rules include the parent field path",
       %{structural_nested_schema: schema} do
    message = :"validate_structural.Outer"
    expected_field = %{field_number: 1, field_name: "child", field_type: :TYPE_MESSAGE}

    assert {:error, %Error{violations: [missing]}} =
             PB.Validate.validate(%{child: %{}}, schema, message)

    assert missing.rule_id == "message.oneof"
    assert missing.message == "one of left, right must be set"
    assert missing.field.elements == [expected_field]

    assert {:error, %Error{violations: [multiple]}} =
             PB.Validate.validate(%{child: %{left: "set", right: "set"}}, schema, message)

    assert multiple.rule_id == "message.oneof"
    assert multiple.message == "only one of left, right can be set"
    assert multiple.field.elements == [expected_field]

    assert PB.Validate.to_proto_violations([missing]) == %{
             violations: [
               %{
                 rule_id: "message.oneof",
                 message: "one of left, right must be set",
                 field: %{elements: [expected_field]}
               }
             ]
           }
  end

  test "validate!/3 raises the structured validation error", %{phase2_schema: schema} do
    assert :ok = PB.Validate.validate!(%{value: "ok"}, schema, :"validate_phase2.FieldCEL")

    assert_raise Error,
                 ~r/validation failed for :"validate_phase2.FieldCEL": y field value must not be empty/,
                 fn ->
                   PB.Validate.validate!(%{value: ""}, schema, :"validate_phase2.FieldCEL")
                 end
  end

  test "validate raises PB.Error for unknown messages", %{phase2_schema: schema} do
    error =
      assert_raise PB.SchemaError, fn ->
        PB.Validate.validate(%{}, schema, :"validate_phase2.Bogus")
      end

    assert error.operation == :validate
    assert error.kind == :unknown_message
    assert error.message_name == :"validate_phase2.Bogus"
    assert error.name == :"validate_phase2.Bogus"

    assert Exception.message(error) =~
             ~s|PB failed to validate :"validate_phase2.Bogus": unknown message :"validate_phase2.Bogus"|
  end

  test "validate raises PB.Error when projection fails", %{phase2_schema: schema} do
    error =
      assert_raise PB.ValueError, fn ->
        PB.Validate.validate(:not_a_map, schema, :"validate_phase2.FieldCEL")
      end

    assert error.operation == :validate
    assert error.kind == :invalid_value
    assert error.message_name == :"validate_phase2.FieldCEL"
    assert error.path == []
    assert error.expected == :map
    assert error.got == :not_a_map

    assert Exception.message(error) =~
             ~s|PB failed to validate :"validate_phase2.FieldCEL": invalid value at <message>: expected :map, got :not_a_map|
  end

  test "validate raises PB.Error for mismatched message-name metadata",
       %{phase2_schema: schema} do
    key = :__message_name__

    error =
      assert_raise PB.ValueError, fn ->
        PB.Validate.validate(
          %{
            key => :"validate_phase2.Bogus"
          },
          schema,
          :"validate_phase2.FieldCEL"
        )
      end

    assert error.operation == :validate
    assert error.kind == :message_name_mismatch
    assert error.message_name == :"validate_phase2.FieldCEL"
    assert error.path == [key]
    assert error.expected == :"validate_phase2.FieldCEL"
    assert error.got == :"validate_phase2.Bogus"
  end

  test "canonical proto violations omit whole-map key and value type details" do
    assert PB.Validate.to_proto_violations([
             %Violation{
               rule_id: "map.max_pairs",
               field: %{
                 elements: [
                   %{
                     field_number: 1,
                     field_name: "val",
                     field_type: :TYPE_MESSAGE,
                     key_type: :TYPE_STRING,
                     value_type: :TYPE_BOOL
                   }
                 ]
               }
             },
             %Violation{
               rule_id: "map.keys.string.pattern",
               field: %{
                 elements: [
                   %{
                     field_number: 1,
                     field_name: "val",
                     field_type: :TYPE_MESSAGE,
                     key_type: :TYPE_STRING,
                     value_type: :TYPE_BOOL,
                     subscript: {:string_key, "bad"}
                   }
                 ]
               }
             }
           ]) == %{
             violations: [
               %{
                 rule_id: "map.max_pairs",
                 field: %{
                   elements: [
                     %{field_number: 1, field_name: "val", field_type: :TYPE_MESSAGE}
                   ]
                 }
               },
               %{
                 rule_id: "map.keys.string.pattern",
                 field: %{
                   elements: [
                     %{
                       field_number: 1,
                       field_name: "val",
                       field_type: :TYPE_MESSAGE,
                       key_type: :TYPE_STRING,
                       value_type: :TYPE_BOOL,
                       subscript: {:string_key, "bad"}
                     }
                   ]
                 }
               }
             ]
           }
  end

  defp with_nested_message_oneof_parent(%{file: files} = descriptor_set) do
    parent_file = %{
      name: "validate_structural_nested.proto",
      package: "validate_structural",
      syntax: "proto3",
      message_type: [
        %{
          name: "Outer",
          field: [
            %{
              name: "child",
              number: 1,
              label: :LABEL_OPTIONAL,
              type: :TYPE_MESSAGE,
              type_name: ".validate_structural.MessageOneofRules"
            }
          ]
        }
      ]
    }

    %{descriptor_set | file: files ++ [parent_file]}
  end
end
