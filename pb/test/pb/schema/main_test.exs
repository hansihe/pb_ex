defmodule PB.Schema.MainTest do
  use ExUnit.Case, async: true

  alias PB.Schema.Main

  test "embeds the bundled main descriptor set as a normal schema provider" do
    schema = Main.schema()

    assert Map.has_key?(schema.messages, :"google.protobuf.FileDescriptorSet")
    assert Map.has_key?(schema.messages, :"google.protobuf.Int32Value")
    assert Map.has_key?(schema.messages, :"google.protobuf.Value")
    assert Map.has_key?(schema.messages, :"google.protobuf.ListValue")
    assert Map.has_key?(schema.messages, :"google.protobuf.Struct")
    assert Map.has_key?(schema.messages, :"google.protobuf.Timestamp")
    assert Map.has_key?(schema.messages, :"google.protobuf.Duration")
  end

  test "decodes the bundled main descriptor set through its schema wrapper" do
    binary = File.read!("priv/main.binpb")

    assert {:ok, %{file: files}} = Main.decode(binary, :"google.protobuf.FileDescriptorSet")

    file_names = MapSet.new(files, & &1.name)

    assert MapSet.member?(file_names, "google/protobuf/descriptor.proto")
    assert MapSet.member?(file_names, "google/protobuf/struct.proto")
    assert MapSet.member?(file_names, "google/protobuf/wrappers.proto")
    assert MapSet.member?(file_names, "google/protobuf/timestamp.proto")
    assert MapSet.member?(file_names, "proto/main.proto")
  end
end
