defmodule PB.WellKnownTypes.AnyTest do
  use ExUnit.Case, async: true

  alias PB.WellKnownTypes.Any

  @nested :"protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage"

  defmodule Nested do
    defstruct [:a, :corecursive]
  end

  describe "type URLs" do
    test "type_url/1 uses the default prefix" do
      assert Any.type_url(:"pkg.Msg") == "type.googleapis.com/pkg.Msg"
      assert Any.type_url("pkg.Msg") == "type.googleapis.com/pkg.Msg"
    end

    test "split_type_url/1 splits after the last slash" do
      assert Any.split_type_url("type.googleapis.com/pkg.Msg") ==
               {:ok, "type.googleapis.com/", "pkg.Msg"}

      assert Any.split_type_url("example.com/a/b/pkg.Msg") == {:ok, "example.com/a/b/", "pkg.Msg"}
      assert Any.split_type_url("/pkg.Msg") == {:ok, "/", "pkg.Msg"}
    end

    test "split_type_url/1 rejects URLs without a name after a slash" do
      assert Any.split_type_url("pkg.Msg") == :error
      assert Any.split_type_url("type.googleapis.com/") == :error
      assert Any.split_type_url("") == :error
    end
  end

  describe "pack/3 and unpack/3" do
    setup do
      descriptor_set = PB.decode_descriptor_set!(File.read!("test/fixtures/schema/test.binpb"))
      %{schema: PB.compile(descriptor_set, projections: [{@nested, struct: Nested}])}
    end

    test "convert between proto-maps and bytes through the projection", %{schema: schema} do
      {:ok, bytes} = PB.encode(%Nested{a: 5}, schema, @nested)

      assert Any.pack(%{a: 5}, schema, @nested) == {:ok, bytes}
      assert Any.unpack(bytes, schema, @nested) == {:ok, %{a: 5}}
    end

    test "return PB errors", %{schema: schema} do
      assert {:error, %PB.SchemaError{kind: :unknown_message}} = Any.pack(%{}, schema, :"no.Such")

      assert {:error, %PB.SchemaError{kind: :unknown_message}} =
               Any.unpack("", schema, :"no.Such")

      assert {:error, %PB.DecodeError{}} = Any.unpack(<<0xFF>>, schema, @nested)
      assert {:error, %PB.ValueError{}} = Any.pack(%{a: "x"}, schema, @nested)
    end
  end
end
