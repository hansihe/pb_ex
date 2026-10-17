defmodule PB.Schema.ImportsTest do
  # `imports.binpb` is `proto/imports.proto` built with its imports: the
  # well-known Duration and Timestamp, and `proto/imports_options.proto`, which
  # defines the `imports.note` message option (and imports descriptor.proto).
  # The tests drop files from it, as a set built without `--include_imports`
  # lacks them.
  use ExUnit.Case, async: true

  @set "test/fixtures/schema/imports.binpb" |> File.read!() |> PB.decode_descriptor_set!()

  defp without(names), do: Map.update!(@set, :file, &Enum.reject(&1, fn f -> f.name in names end))

  defp event_options(schema), do: schema.messages[:"imports.Event"].options

  test "a set with its imports compiles, with its custom options decoded" do
    assert event_options(PB.compile(@set)) == %{__extensions__: %{"imports.note": "an event"}}
  end

  test "a set missing an import raises, naming the importing and the missing file" do
    error =
      assert_raise PB.SchemaError, fn -> PB.compile(without(["proto/imports_options.proto"])) end

    assert error.kind == :missing_imports
    assert error.operation == :compile
    assert error.reason == [{"proto/imports.proto", ["proto/imports_options.proto"]}]

    assert Exception.message(error) ==
             "PB failed to compile: descriptor set is missing imported files: " <>
               ~s("proto/imports.proto" imports "proto/imports_options.proto". ) <>
               "Build the set with its imports (`protoc --include_imports`, or `buf build`, " <>
               "which includes them by default), or pass `allow_missing_imports: true` to " <>
               "compile it without them"
  end

  test "every missing import of every file is listed" do
    set =
      without([
        "google/protobuf/descriptor.proto",
        "google/protobuf/duration.proto",
        "google/protobuf/timestamp.proto"
      ])

    error = assert_raise PB.SchemaError, fn -> PB.compile(set) end

    assert error.reason == [
             {"proto/imports_options.proto", ["google/protobuf/descriptor.proto"]},
             {"proto/imports.proto",
              ["google/protobuf/duration.proto", "google/protobuf/timestamp.proto"]}
           ]

    assert Exception.message(error) =~
             ~s("proto/imports_options.proto" imports "google/protobuf/descriptor.proto"; ) <>
               ~s("proto/imports.proto" imports "google/protobuf/duration.proto", ) <>
               ~s("google/protobuf/timestamp.proto". )
  end

  test "weak imports may be missing" do
    set = %{
      file: [
        %{name: "kept.proto", package: "kept", syntax: "proto2"},
        %{
          name: "weak.proto",
          package: "weak",
          syntax: "proto2",
          dependency: ["gone.proto", "kept.proto", "also_gone.proto"],
          weak_dependency: [0, 2]
        }
      ]
    }

    assert %{messages: %{}} = PB.compile(set)

    error =
      assert_raise PB.SchemaError, fn ->
        PB.compile(update_in(set, [:file, Access.at(1), :weak_dependency], fn _ -> [0] end))
      end

    assert error.reason == [{"weak.proto", ["also_gone.proto"]}]
  end

  test "allow_missing_imports: true compiles, leaving the options undecoded" do
    schema = PB.compile(without(["proto/imports_options.proto"]), allow_missing_imports: true)

    options = event_options(schema)

    assert %{__unknown_fields__: [%PB.UnknownField{number: 50_001}]} = options
    refute Map.has_key?(options, :__extensions__)

    assert {:ok, encoded} = PB.encode(%{took: %{seconds: 1}}, schema, :"imports.Event")
    assert PB.decode(encoded, schema, :"imports.Event") == {:ok, %{took: %{seconds: 1}}}
  end

  test "allow_missing_imports must be a boolean" do
    assert_raise PB.OptionError, fn -> PB.compile(@set, allow_missing_imports: :yes) end
  end

  test "use PB.Schema passes allow_missing_imports on to PB.compile/2" do
    mod = Module.concat(__MODULE__, "Schema#{System.unique_integer([:positive])}")
    set = Macro.escape(without(["proto/imports_options.proto"]))

    [{^mod, _bin}] =
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            use PB.Schema, descriptor_set: unquote(set), allow_missing_imports: true
          end
        end
      )

    assert %{__unknown_fields__: [_note]} = event_options(mod.schema())
  end
end
