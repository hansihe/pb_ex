defmodule PB.CEL.Syntax.ParserTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Error
  alias PB.CEL.Proto

  test "parses binary operators with CEL precedence" do
    parsed = CEL.parse!("1 + 2 * 3")

    [one, multiplication] = call_args(parsed.expr, "_+_")
    assert const_kind(one) == {:int64_value, 1}

    [two, three] = call_args(multiplication, "_*_")
    assert const_kind(two) == {:int64_value, 2}
    assert const_kind(three) == {:int64_value, 3}
  end

  test "parses ternary conditionals as right associative calls" do
    parsed = CEL.parse!("a ? b : c ? d : e")

    [condition, true_expr, false_expr] = call_args(parsed.expr, "_?_:_")
    assert ident_name(condition) == "a"
    assert ident_name(true_expr) == "b"

    [nested_condition, nested_true, nested_false] = call_args(false_expr, "_?_:_")
    assert ident_name(nested_condition) == "c"
    assert ident_name(nested_true) == "d"
    assert ident_name(nested_false) == "e"
  end

  test "preserves literal CEL kinds" do
    parsed = CEL.parse!(~s([1, 2u, 3.5, true, null, "x\\n", b"\\xFF"]))

    assert list_elements(parsed.expr) |> Enum.map(&const_kind/1) == [
             {:int64_value, 1},
             {:uint64_value, 2},
             {:double_value, 3.5},
             {:bool_value, true},
             {:null_value, :NULL_VALUE},
             {:string_value, "x\n"},
             {:bytes_value, <<255>>}
           ]

    assert const_kind(CEL.parse!("-9223372036854775808").expr) ==
             {:int64_value, -9_223_372_036_854_775_808}

    assert const_kind(CEL.parse!(".99").expr) == {:double_value, 0.99}
  end

  test "parses selects, indexes, and receiver calls" do
    parsed = CEL.parse!(~s|request.auth.claims["sub"].startsWith("x")|)

    %{expr_kind: {:call_expr, call}} = parsed.expr
    assert call.function == "startsWith"
    assert [arg] = call.args
    assert const_kind(arg) == {:string_value, "x"}

    [selected_claims, index] = call_args(call.target, "_[_]")
    assert const_kind(index) == {:string_value, "sub"}

    %{expr_kind: {:select_expr, claims}} = selected_claims
    assert claims.field == "claims"

    %{expr_kind: {:select_expr, auth}} = claims.operand
    assert auth.field == "auth"
    assert ident_name(auth.operand) == "request"

    parsed = CEL.parse!(~s|{'foo.txt': 32}.`foo.txt`|)
    %{expr_kind: {:select_expr, select}} = parsed.expr
    assert select.field == "foo.txt"
  end

  test "parses optional selects and indexes as CEL operator calls" do
    parsed = CEL.parse!(~s|request.?`foo.txt`|)

    [target, field] = call_args(parsed.expr, "_?._")
    assert ident_name(target) == "request"
    assert const_kind(field) == {:string_value, "foo.txt"}

    parsed = CEL.parse!("items[?0]")

    [target, index] = call_args(parsed.expr, "_[?_]")
    assert ident_name(target) == "items"
    assert const_kind(index) == {:int64_value, 0}
  end

  test "parses optional list and struct literal entries" do
    parsed = CEL.parse!("[1, ?optional.of(2), ?optional.none()]")
    %{expr_kind: {:list_expr, list}} = parsed.expr

    assert list.optional_indices == [1, 2]
    assert length(list.elements) == 3

    parsed = CEL.parse!(~s|{?'x': optional.of(1), 'y': 2}|)
    %{expr_kind: {:struct_expr, %{entries: [optional_entry, required_entry]}}} = parsed.expr

    assert optional_entry.optional_entry == true
    assert const_kind(elem(optional_entry.key_kind, 1)) == {:string_value, "x"}
    assert required_entry.optional_entry == false

    parsed = CEL.parse!("Msg{?field: optional.of(1), normal: 2}")
    %{expr_kind: {:struct_expr, %{entries: [optional_field, required_field]}}} = parsed.expr

    assert optional_field.optional_entry == true
    assert optional_field.key_kind == {:field_key, "field"}
    assert required_field.optional_entry == false
  end

  test "expands has macros into presence selects" do
    parsed = CEL.parse!("has(msg.field)")

    %{expr_kind: {:select_expr, select}} = parsed.expr
    assert select.field == "field"
    assert select.test_only == true

    %{expr_kind: {:call_expr, macro_call}} = parsed.source_info.macro_calls[parsed.expr.id]
    assert macro_call.function == "has"
  end

  test "expands receiver macros into comprehensions" do
    parsed = CEL.parse!("[1].all(x, x > 0)")

    %{expr_kind: {:comprehension_expr, comprehension}} = parsed.expr
    assert comprehension.iter_var == "x"
    assert comprehension.accu_var == "__result__"

    %{expr_kind: {:call_expr, macro_call}} = parsed.source_info.macro_calls[parsed.expr.id]
    assert macro_call.function == "all"
  end

  test "can leave macro calls unexpanded" do
    parsed = CEL.parse!("[1].all(x, x > 0)", macros: false)

    %{expr_kind: {:call_expr, call}} = parsed.expr
    assert call.function == "all"
    assert parsed.source_info.macro_calls == %{}
  end

  test "parses map and message literals" do
    parsed = CEL.parse!(~s(.pkg.Msg{field: [1, 2u], nested: {"k": b"v"},}))

    %{expr_kind: {:struct_expr, struct}} = parsed.expr
    assert struct.message_name == ".pkg.Msg"

    assert [
             %{key_kind: {:field_key, "field"}, value: field_value},
             %{key_kind: {:field_key, "nested"}, value: nested_value}
           ] = struct.entries

    assert list_elements(field_value) |> Enum.map(&const_kind/1) == [
             {:int64_value, 1},
             {:uint64_value, 2}
           ]

    %{expr_kind: {:struct_expr, %{entries: [entry]}}} = nested_value
    assert %{key_kind: {:map_key, key}, value: value} = entry
    assert const_kind(key) == {:string_value, "k"}
    assert const_kind(value) == {:bytes_value, "v"}
  end

  test "generated CEL proto codecs can round-trip parsed expressions" do
    parsed = CEL.parse!(~s|request.auth.claims["sub"].startsWith("x")|, location: "policy.cel")

    assert {:ok, iodata} = Proto.encode_parsed_expr(parsed)
    assert {:ok, decoded} = Proto.decode_parsed_expr(IO.iodata_to_binary(iodata))

    assert decoded.expr == parsed.expr
    assert decoded.source_info.location == "policy.cel"
    assert decoded.source_info.positions == parsed.source_info.positions

    macro_parsed = CEL.parse!("[1].all(x, x > 0)")
    assert {:ok, iodata} = Proto.encode_parsed_expr(macro_parsed)
    assert {:ok, decoded} = Proto.decode_parsed_expr(IO.iodata_to_binary(iodata))
    assert decoded == macro_parsed

    optional_parsed = CEL.parse!(~s|{?'x': optional.of(1), 'y': [?'z']}|)
    assert {:ok, iodata} = Proto.encode_parsed_expr(optional_parsed)
    assert {:ok, decoded} = Proto.decode_parsed_expr(IO.iodata_to_binary(iodata))
    assert decoded == optional_parsed
  end

  test "returns parse errors" do
    assert {:error, %Error{phase: :parse, message: "expected expression", offset: 0}} =
             CEL.parse("in")
  end

  test "rejects sources above the parser byte-size cap before tokenization" do
    source = String.duplicate("@", 100_001)

    assert {:error,
            %Error{
              phase: :parse,
              message: "CEL source exceeds maximum size of 100000 bytes",
              offset: 0,
              location: "too-large.cel"
            }} = CEL.parse(source, location: "too-large.cel")
  end

  test "rejects expressions above the parser recursion-depth cap" do
    assert CEL.parse!(String.duplicate("!", 32) <> "true")

    assert {:error,
            %Error{
              phase: :parse,
              message: "CEL expression exceeds maximum parse recursion depth of 250",
              offset: 250
            }} = CEL.parse(String.duplicate("!", 300) <> "true")
  end

  defp call_args(%{expr_kind: {:call_expr, %{function: function, args: args}}}, function),
    do: args

  defp const_kind(%{expr_kind: {:const_expr, %{constant_kind: constant_kind}}}), do: constant_kind

  defp ident_name(%{expr_kind: {:ident_expr, %{name: name}}}), do: name

  defp list_elements(%{expr_kind: {:list_expr, %{elements: elements}}}), do: elements
end
