defmodule PB.Schema.OptionImportsTest do
  # `option_imports.binpb` is `proto/option_imports.proto`, an edition 2024 file,
  # built by protoc with its imports: the well-known Timestamp, imported as
  # usual, and `proto/option_imports_options.proto`, imported with `import
  # option`, which defines the `option_imports.label` message option. buf never
  # includes option imports in a set, so the tests drop it, as buf does.
  use ExUnit.Case, async: true

  @set "test/fixtures/schema/option_imports.binpb" |> File.read!() |> PB.decode_descriptor_set!()
  @options_file "proto/option_imports_options.proto"

  defp without(names), do: Map.update!(@set, :file, &Enum.reject(&1, fn f -> f.name in names end))

  defp thing_options(schema), do: schema.messages[:"option_imports.Thing"].options

  test "a set with its option imports compiles, with the options they define decoded" do
    assert thing_options(PB.compile(@set)) ==
             %{__extensions__: %{"option_imports.label": "a thing"}}
  end

  test "a set missing an option import compiles, leaving the options it defines undecoded" do
    set = without([@options_file])
    root = Enum.find(set.file, &(&1.name == "proto/option_imports.proto"))
    assert root.option_dependency == [@options_file]

    options = thing_options(PB.compile(set))

    assert %{__unknown_fields__: [%PB.UnknownField{number: 50_002}]} = options
    refute Map.has_key?(options, :__extensions__)
  end

  test "a set missing an option import and a regular import lists only the regular one" do
    error =
      assert_raise PB.SchemaError, fn ->
        PB.compile(without([@options_file, "google/protobuf/timestamp.proto"]))
      end

    assert error.kind == :missing_imports
    assert error.reason == [{"proto/option_imports.proto", ["google/protobuf/timestamp.proto"]}]
  end
end
