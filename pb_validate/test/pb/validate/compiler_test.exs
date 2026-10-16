defmodule PB.Validate.CompilerTest do
  use ExUnit.Case, async: true

  alias CEL.Checked
  alias PB.Validate.CompileError
  alias PB.Validate.Schema.CELOp
  alias PB.Validate.Schema.CELSource
  alias PB.Validate.Schema.MapRules
  alias PB.Validate.Schema.NativeOp
  alias PB.Validate.Schema.Predefined
  alias PB.Validate.Schema.RepeatedRules
  alias PB.Validate.Schema.RuleSet

  @valid_binpb_path "test/fixtures/schema/validate_phase2.binpb"
  @invalid_binpb_path "test/fixtures/schema/validate_phase2_invalid.binpb"
  @predefined_binpb_path "test/fixtures/schema/validate_predefined.binpb"
  @any_invalid_binpb_path "test/fixtures/schema/validate_any_invalid.binpb"
  @rule_family_float_invalid_binpb_path "test/fixtures/schema/validate_rule_family_float_invalid.binpb"
  @rule_family_duration_invalid_binpb_path "test/fixtures/schema/validate_rule_family_duration_invalid.binpb"
  @custom_predefined_binpb_path "test/fixtures/schema/validate_custom_predefined.binpb"
  @structural_binpb_path "test/fixtures/schema/validate_structural.binpb"
  @structural_oneof_duplicate_invalid_binpb_path "test/fixtures/schema/validate_structural_oneof_duplicate_invalid.binpb"
  @structural_oneof_zero_invalid_binpb_path "test/fixtures/schema/validate_structural_oneof_zero_invalid.binpb"

  setup_all do
    {:ok,
     valid_binpb: File.read!(@valid_binpb_path),
     invalid_binpb: File.read!(@invalid_binpb_path),
     predefined_binpb: File.read!(@predefined_binpb_path),
     any_invalid_binpb: File.read!(@any_invalid_binpb_path),
     rule_family_float_invalid_binpb: File.read!(@rule_family_float_invalid_binpb_path),
     rule_family_duration_invalid_binpb: File.read!(@rule_family_duration_invalid_binpb_path),
     custom_predefined_binpb: File.read!(@custom_predefined_binpb_path),
     structural_binpb: File.read!(@structural_binpb_path),
     structural_oneof_duplicate_invalid_binpb:
       File.read!(@structural_oneof_duplicate_invalid_binpb_path),
     structural_oneof_zero_invalid_binpb: File.read!(@structural_oneof_zero_invalid_binpb_path)}
  end

  test "PB.Validate.compile/2 annotates message-level user CEL", %{valid_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_phase2.MessageCEL"]

    assert %{PB.Validate => %{cel: [op]}} = message
    assert op.id == "x"
    assert op.kind == :message_cel
    assert op.message == "value must not be empty"
    assert op.source == "this.value.size() > 0"
    assert op.vars == %{}

    assert op.rule_path == %{
             elements: [
               %{
                 field_number: 3,
                 field_name: "cel",
                 field_type: :TYPE_MESSAGE,
                 subscript: {:index, 0}
               }
             ]
           }

    assert op.proto_rule_path == nil
    assert %Checked{} = op.checked
  end

  test "PB.Validate.compile/2 annotates field-level user CEL", %{valid_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_phase2.FieldCEL"]
    field = message.fields_by_name.value

    assert %{PB.Validate => %{cel: [op]}} = field
    assert op.id == "y"
    assert op.kind == :field_cel
    assert op.message == "field value must not be empty"
    assert op.source == "this.size() > 0"
    assert op.vars == %{}

    assert op.rule_path == %{
             elements: [
               %{
                 field_number: 23,
                 field_name: "cel",
                 field_type: :TYPE_MESSAGE,
                 subscript: {:index, 0}
               }
             ]
           }

    assert op.proto_rule_path == op.rule_path
    assert %Checked{} = op.checked
  end

  test "PB.Validate.compile/2 annotates message-level cel_expression shorthand", %{
    valid_binpb: binpb
  } do
    descriptor_set = PB.decode_descriptor_set!(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_phase2.MessageCELExpression"]

    assert %{PB.Validate => %{cel: [op]}} = message
    assert op.id == "this.value.size() > 0"
    assert op.kind == :message_cel
    assert op.message == ~s|"this.value.size() > 0" returned false|
    assert op.source == "this.value.size() > 0"

    assert op.rule_path == %{
             elements: [
               %{
                 field_number: 5,
                 field_name: "cel_expression",
                 field_type: :TYPE_STRING,
                 subscript: {:index, 0}
               }
             ]
           }

    assert op.proto_rule_path == nil
    assert %Checked{} = op.checked
  end

  test "PB.Validate.compile/2 annotates field-level cel_expression shorthand", %{
    valid_binpb: binpb
  } do
    descriptor_set = PB.decode_descriptor_set!(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_phase2.FieldCELExpression"]
    field = message.fields_by_name.value

    assert %{PB.Validate => %{cel: [op]}} = field
    assert op.id == "this.size() > 0"
    assert op.kind == :field_cel
    assert op.message == ~s|"this.size() > 0" returned false|
    assert op.source == "this.size() > 0"

    assert op.rule_path == %{
             elements: [
               %{
                 field_number: 29,
                 field_name: "cel_expression",
                 field_type: :TYPE_STRING,
                 subscript: {:index, 0}
               }
             ]
           }

    assert op.proto_rule_path == op.rule_path
    assert %Checked{} = op.checked
  end

  test "PB.Validate.compile/2 annotates predefined field CEL", %{predefined_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_predefined.StringRules"]

    email = message.fields_by_name.email
    assert %{PB.Validate => %{cel: [%CELOp{} = email_rule, %CELOp{} = empty_rule]}} = email

    assert email_rule.kind == :predefined
    assert email_rule.id == "string.email"
    assert email_rule.vars == %{
             "rules" => {:message, :"buf.validate.StringRules", %{well_known: {:email, true}}},
             "rule" => {:bool, true}
           }

    assert email_rule.rule_path == %{
             elements: [
               %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
               %{field_number: 12, field_name: "email", field_type: :TYPE_BOOL}
             ]
           }

    assert email_rule.proto_rule_path == email_rule.rule_path
    assert empty_rule.kind == :predefined
    assert empty_rule.id == "string.email_empty"
    assert empty_rule.rule_path == email_rule.rule_path

    min_len = message.fields_by_name.min_len
    assert %{PB.Validate => %{cel: [%CELOp{} = min_len_rule]}} = min_len
    assert min_len_rule.kind == :predefined
    assert min_len_rule.id == "string.min_len"
    assert min_len_rule.vars == %{
             "rules" => {:message, :"buf.validate.StringRules", %{min_len: 3}},
             "rule" => {:uint, 3}
           }

    assert min_len_rule.rule_path == %{
             elements: [
               %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
               %{field_number: 2, field_name: "min_len", field_type: :TYPE_UINT64}
             ]
           }

    const = message.fields_by_name.const
    assert %{PB.Validate => %{cel: [%CELOp{} = const_rule]}} = const
    assert const_rule.id == "string.const"
    assert const_rule.vars == %{
             "rules" => {:message, :"buf.validate.StringRules", %{const: "foo"}},
             "rule" => {:string, "foo"}
           }

    header_name = message.fields_by_name.header_name
    assert %{PB.Validate => %{cel: [%CELOp{} = header_name_rule | _rules]}} = header_name
    assert header_name_rule.id == "string.well_known_regex.header_name"

    assert header_name_rule.vars == %{
             "rules" =>
               {:message, :"buf.validate.StringRules",
                %{well_known: {:well_known_regex, :KNOWN_REGEX_HTTP_HEADER_NAME}}},
             "rule" => {:enum, :"buf.validate.KnownRegex", 1}
           }
  end

  test "PB.Validate.compile/2 annotates nested repeated and map rules", %{predefined_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_predefined.NestedRules"]

    names = message.fields_by_name.names
    assert %{PB.Validate => %{repeated: %RepeatedRules{items: %RuleSet{cel: [name_rule]}}}} = names
    assert name_rule.id == "string.min_len"

    assert name_rule.rule_path == %{
             elements: [
               %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
               %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
               %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
               %{field_number: 2, field_name: "min_len", field_type: :TYPE_UINT64}
             ]
           }

    labels = message.fields_by_name.labels

    assert %{
             PB.Validate => %{
               map: %MapRules{
                 keys: %RuleSet{cel: [key_rule]},
                 values: %RuleSet{cel: [value_rule]}
               }
             }
           } = labels

    assert key_rule.id == "string.min_len"

    assert key_rule.rule_path == %{
             elements: [
               %{field_number: 19, field_name: "map", field_type: :TYPE_MESSAGE},
               %{field_number: 4, field_name: "keys", field_type: :TYPE_MESSAGE},
               %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
               %{field_number: 2, field_name: "min_len", field_type: :TYPE_UINT64}
             ]
           }

    assert value_rule.id == "string.pattern"
    assert [{matches_id, %Regex{} = regex}] = Map.to_list(value_rule.regexes)
    assert {:call, %{name: "matches"}} = Checked.op(value_rule.checked, matches_id)
    assert Regex.match?(regex, "abc")
    refute Regex.match?(regex, "ABC")

    assert value_rule.rule_path == %{
             elements: [
               %{field_number: 19, field_name: "map", field_type: :TYPE_MESSAGE},
               %{field_number: 5, field_name: "values", field_type: :TYPE_MESSAGE},
               %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
               %{field_number: 6, field_name: "pattern", field_type: :TYPE_STRING}
             ]
           }

    ignored_items = message.fields_by_name.ignored_items

    assert %{
             PB.Validate => %{
               repeated: %RepeatedRules{items: %RuleSet{cel: [], ignore: :IGNORE_ALWAYS}}
             }
           } = ignored_items

    any_values = message.fields_by_name.any_values

    assert %{
             PB.Validate => %{
               repeated: %RepeatedRules{items: %RuleSet{native: [%NativeOp{} = any_rule]}}
             }
           } = any_values

    assert any_rule.kind == :any_in
    assert any_rule.id == "any.in"
    assert any_rule.message == "type URL must be in the allow list"
    assert any_rule.values == ["type.googleapis.com/google.protobuf.Duration"]

    assert any_rule.rule_path == %{
             elements: [
               %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
               %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
               %{field_number: 20, field_name: "any", field_type: :TYPE_MESSAGE},
               %{field_number: 2, field_name: "in", field_type: :TYPE_STRING}
             ]
           }
  end

  test "PB.Validate.compile/2 annotates native Any rules", %{predefined_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_predefined.AnyRules"]

    allowed = message.fields_by_name.allowed
    assert %{PB.Validate => %{native: [%NativeOp{} = allowed_rule]}} = allowed
    assert allowed_rule.kind == :any_in
    assert allowed_rule.id == "any.in"
    assert allowed_rule.message == "type URL must be in the allow list"
    assert allowed_rule.values == ["type.googleapis.com/google.protobuf.Duration"]

    assert allowed_rule.rule_path == %{
             elements: [
               %{field_number: 20, field_name: "any", field_type: :TYPE_MESSAGE},
               %{field_number: 2, field_name: "in", field_type: :TYPE_STRING}
             ]
           }

    assert allowed_rule.proto_rule_path == allowed_rule.rule_path

    blocked = message.fields_by_name.blocked
    assert %{PB.Validate => %{native: [%NativeOp{} = blocked_rule]}} = blocked
    assert blocked_rule.kind == :any_not_in
    assert blocked_rule.id == "any.not_in"
    assert blocked_rule.message == "type URL must not be in the block list"
    assert blocked_rule.values == ["type.googleapis.com/google.protobuf.Timestamp"]

    assert blocked_rule.rule_path == %{
             elements: [
               %{field_number: 20, field_name: "any", field_type: :TYPE_MESSAGE},
               %{field_number: 3, field_name: "not_in", field_type: :TYPE_STRING}
             ]
           }
  end

  test "PB.Validate.compile/2 annotates native enum defined_only rules", %{predefined_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_predefined.EnumRules"]

    status = message.fields_by_name.status
    assert %{PB.Validate => %{native: [%NativeOp{} = status_rule]}} = status
    assert status_rule.kind == :enum_defined_only
    assert status_rule.id == "enum.defined_only"
    assert status_rule.message == "value must be one of the defined enum values"
    assert status_rule.values == [0, 1, :STATUS_OK, :STATUS_UNSPECIFIED]

    assert status_rule.rule_path == %{
             elements: [
               %{field_number: 16, field_name: "enum", field_type: :TYPE_MESSAGE},
               %{field_number: 2, field_name: "defined_only", field_type: :TYPE_BOOL}
             ]
           }

    statuses = message.fields_by_name.statuses

    assert %{
             PB.Validate => %{
               repeated: %RepeatedRules{items: %RuleSet{native: [%NativeOp{} = item_rule]}}
             }
           } = statuses

    assert item_rule.kind == :enum_defined_only

    assert item_rule.rule_path == %{
             elements: [
               %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
               %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
               %{field_number: 16, field_name: "enum", field_type: :TYPE_MESSAGE},
               %{field_number: 2, field_name: "defined_only", field_type: :TYPE_BOOL}
             ]
           }
  end

  test "PB.Validate.compile/2 annotates extension-backed predefined CEL", %{
    custom_predefined_binpb: binpb
  } do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_custom_predefined.CustomPredefinedRules"]
    extension = schema.extensions_by_name[:"validate_custom_predefined.string_not_bad"]
    extension_key = :__extensions__

    assert %{PB.Validate => %{predefined: %{cel: [source]}}} = extension
    assert source.id == "string.not_bad"

    value = message.fields_by_name.value
    assert %{PB.Validate => %{cel: [%CELOp{} = value_rule]}} = value
    assert value_rule.kind == :predefined
    assert value_rule.id == "string.not_bad"

    assert value_rule.vars == %{
             "rules" =>
               {:message, :"buf.validate.StringRules",
                %{extension_key => %{:"validate_custom_predefined.string_not_bad" => true}}},
             "rule" => {:bool, true}
           }

    assert value_rule.rule_path == %{
             elements: [
               %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
               %{
                 field_number: 1000,
                 field_name: "[validate_custom_predefined.string_not_bad]",
                 field_type: :TYPE_BOOL
               }
             ]
           }

    items = message.fields_by_name.items

    assert %{
             PB.Validate => %{
               repeated: %RepeatedRules{items: %RuleSet{cel: [%CELOp{} = item_rule]}}
             }
           } = items

    assert item_rule.id == "string.not_bad"

    assert item_rule.rule_path == %{
             elements: [
               %{field_number: 18, field_name: "repeated", field_type: :TYPE_MESSAGE},
               %{field_number: 4, field_name: "items", field_type: :TYPE_MESSAGE},
               %{field_number: 14, field_name: "string", field_type: :TYPE_MESSAGE},
               %{
                 field_number: 1000,
                 field_name: "[validate_custom_predefined.string_not_bad]",
                 field_type: :TYPE_BOOL
               }
             ]
           }

    count = message.fields_by_name.count
    assert %{PB.Validate => %{cel: [%CELOp{} = count_rule]}} = count
    assert count_rule.id == "int64.abs_in"

    rules = %{extension_key => %{:"validate_custom_predefined.int64_abs_in" => [%{value: -2}]}}

    assert count_rule.vars == %{
             "rules" => {:message, :"buf.validate.Int64Rules", rules},
             "rule" => {:list, [int: -2]}
           }

    assert count_rule.rule_path == %{
             elements: [
               %{field_number: 4, field_name: "int64", field_type: :TYPE_MESSAGE},
               %{
                 field_number: 1000,
                 field_name: "[validate_custom_predefined.int64_abs_in]",
                 field_type: :TYPE_MESSAGE
               }
             ]
           }
  end

  test "Schema.Compiler.compile/1 materializes same-schema rule extensions", %{
    custom_predefined_binpb: binpb
  } do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.Schema.Compiler.compile(descriptor_set)
    message = schema.messages[:"validate_custom_predefined.CustomPredefinedRules"]
    extension_key = :__extensions__
    unknown_key = PB.UnknownField.key()

    value_rules =
      message.fields_by_name.value.options[extension_key][:"buf.validate.field"]

    assert %{type: {:string, %{^extension_key => value_extensions} = string_rules}} =
             value_rules

    assert value_extensions == %{:"validate_custom_predefined.string_not_bad" => true}
    refute Map.has_key?(string_rules, unknown_key)

    count_rules =
      message.fields_by_name.count.options[extension_key][:"buf.validate.field"]

    assert %{type: {:int64, %{^extension_key => count_extensions} = int64_rules}} =
             count_rules

    assert count_extensions == %{:"validate_custom_predefined.int64_abs_in" => [%{value: -2}]}
    refute Map.has_key?(int64_rules, unknown_key)
  end

  test "Schema.Transform.slice/2 keeps option-referenced extension definitions and recompiles the rules",
       %{custom_predefined_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema =
      descriptor_set
      |> PB.compile(plugins: [PB.Validate])
      |> PB.Schema.Transform.slice(roots: [:"validate_custom_predefined.CustomPredefinedRules"])

    assert schema.plugins == [{PB.Validate, []}]

    assert Map.has_key?(
             schema.extensions_by_name,
             :"validate_custom_predefined.string_not_bad"
           )

    assert Map.has_key?(
             schema.extensions_by_name,
             :"validate_custom_predefined.int64_abs_in"
           )

    message = schema.messages[:"validate_custom_predefined.CustomPredefinedRules"]

    assert %{PB.Validate => %{cel: [%CELOp{id: "string.not_bad"}]}} =
             message.fields_by_name.value

    assert %{PB.Validate => %{cel: [%CELOp{id: "int64.abs_in"}]}} =
             message.fields_by_name.count
  end

  test "the standard-rule schema reads predefined rule CEL from the bundled descriptors", %{
    predefined_binpb: binpb
  } do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    rule_schema = PB.Validate.Schema.standard_rule_schema(schema)
    email = rule_schema.messages[:"buf.validate.StringRules"].fields_by_name.email

    assert %{PB.Validate => %{predefined: %Predefined{cel: rules}}} = email
    assert [%CELSource{id: "string.email"}, %CELSource{id: "string.email_empty"}] = rules
    assert schema[PB.Validate].standard_rule_schema == rule_schema
  end

  test "PB.Validate.compile/2 wraps CEL check errors in Validate.CompileError", %{
    invalid_binpb: binpb
  } do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    assert_raise CompileError,
                 ~r/validate_phase2_invalid\.InvalidMessageCEL constraint "bad" CEL check error: no such field "foo"/,
                 fn -> PB.compile(descriptor_set, plugins: [PB.Validate]) end
  end

  test "PB.Validate.compile/2 rejects Any rules on non-Any fields", %{any_invalid_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    assert_raise CompileError,
                 ~r/validate_any_invalid\.WrongAnyRules\.value constraint "any\.in" CEL type error: mismatched rule type and field type/,
                 fn -> PB.compile(descriptor_set, plugins: [PB.Validate]) end
  end

  test "PB.Validate.compile/2 rejects float and double family mismatches", %{
    rule_family_float_invalid_binpb: binpb
  } do
    descriptor_set = PB.decode_descriptor_set!(binpb)

    assert_raise CompileError,
                 ~r/validate_rule_family_float_invalid\.WrongFloatRules\.value constraint "double\.gt" CEL type error: mismatched rule type and field type/,
                 fn -> PB.compile(descriptor_set, plugins: [PB.Validate]) end
  end

  test "PB.Validate.compile/2 rejects duration rules on non-Duration messages", %{
    rule_family_duration_invalid_binpb: binpb
  } do
    descriptor_set = PB.decode_descriptor_set!(binpb)

    assert_raise CompileError,
                 ~r/validate_rule_family_duration_invalid\.WrongDurationRules\.value constraint "duration\.example" CEL type error: mismatched rule type and field type/,
                 fn -> PB.compile(descriptor_set, plugins: [PB.Validate]) end
  end

  test "PB.Validate.compile/2 annotates structural field rules", %{structural_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_structural.StructuralRules"]

    assert message.fields_by_name.required_value[PB.Validate] == %{required: true}
    assert message.fields_by_name.ignored_always[PB.Validate] == %{ignore: :IGNORE_ALWAYS}
    assert message.fields_by_name.ignored_zero[PB.Validate] == %{ignore: :IGNORE_IF_ZERO_VALUE}
  end

  test "PB.Validate.compile/2 annotates structural oneof rules", %{structural_binpb: binpb} do
    {:ok, descriptor_set} = PB.decode_descriptor_set(binpb)

    schema = PB.compile(descriptor_set, plugins: [PB.Validate])
    message = schema.messages[:"validate_structural.StructuralRules"]

    assert message.oneofs[0][PB.Validate] == %{required: true}
  end

  test "PB.Validate.compile/2 rejects empty message oneof rules", %{
    structural_oneof_zero_invalid_binpb: binpb
  } do
    descriptor_set = PB.decode_descriptor_set!(binpb)

    assert_raise CompileError, ~r/message oneof rule 0 must reference at least one field/, fn ->
      PB.compile(descriptor_set, plugins: [PB.Validate])
    end
  end

  test "PB.Validate.compile/2 rejects duplicate message oneof fields", %{
    structural_oneof_duplicate_invalid_binpb: binpb
  } do
    descriptor_set = PB.decode_descriptor_set!(binpb)

    assert_raise CompileError, ~r/message oneof rule 0 references duplicate field "value"/, fn ->
      PB.compile(descriptor_set, plugins: [PB.Validate])
    end
  end
end
