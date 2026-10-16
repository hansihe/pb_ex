defmodule CEL.ValueTest do
  use ExUnit.Case, async: true

  doctest CEL.Value

  alias CEL.ProtoType
  alias CEL.Value

  test "infers tagged values from plain terms" do
    assert Value.infer(%{"a" => [1, nil]}) ==
             {:ok, Value.map(%{Value.string("a") => Value.list([Value.int(1), Value.null()])})}

    env = CEL.Env.build(vars: %{x: :dyn})
    assert CEL.eval(~S|x.a + x["b"]|, %{x: %{"a" => 1, "b" => 2}}, env) == {:ok, Value.int(3)}
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

    test "recurses into lists and maps, and gives a message's payload" do
      assert Value.to_native(Value.list([Value.int(1), Value.string("a")])) == [1, "a"]

      assert Value.to_native(Value.map(%{Value.string("k") => Value.bool(true)})) ==
               %{"k" => true}

      assert Value.to_native({:message, :"my.Msg", %{a: 1, b: "x"}}) == %{a: 1, b: "x"}
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

    end

    test "turns a type value into its name" do
      assert Value.to_native({:type, ProtoType.null()}) == "null_type"
      assert Value.to_native(CEL.eval!("[type(1), type(optional.of(1))]")) ==
               ["int", "optional_type"]
    end
  end

  describe "type_name/1" do
    test "gives CEL's runtime type names, without parameters" do
      for {source, name} <- [
            {"type(1)", "int"},
            {"type(1u)", "uint"},
            {"type(1.5)", "double"},
            {"type(true)", "bool"},
            {"type('a')", "string"},
            {"type(b'a')", "bytes"},
            {"type(null)", "null_type"},
            {"type([1])", "list"},
            {"type({'a': 1})", "map"},
            {"type(int)", "type"},
            {"type(optional.of(1))", "optional_type"},
            {"type(timestamp(0))", "google.protobuf.Timestamp"},
            {"type(duration('1s'))", "google.protobuf.Duration"}
          ] do
        assert source |> CEL.eval!() |> Value.type_name() == name, source
      end
    end

    test "type values are equal when their names are, as in cel-go" do
      for source <- [
            "type(optional.of(1)) == optional_type",
            "type(optional.none()) == optional_type",
            "type([1]) == list",
            "type({1: 'a'}) == map",
            "[type(optional.of('a'))].exists(t, t == optional_type)"
          ] do
        assert CEL.eval!(source) == {:bool, true}, source
      end

      assert CEL.eval!("type(1) == type(1u)") == {:bool, false}
    end
  end
end
