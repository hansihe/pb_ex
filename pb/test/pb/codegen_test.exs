defmodule PB.CodegenTest.Fixtures do
  def descriptor_set do
    %{
      file: [
        %{
          name: "codegen.proto",
          package: :codegen,
          syntax: :proto3,
          message_type: [
            %{
              name: :Greeting,
              field: [
                %{name: :text, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
                %{
                  name: :detail,
                  number: 2,
                  type: :TYPE_MESSAGE,
                  label: :LABEL_OPTIONAL,
                  type_name: :"codegen.Detail"
                }
              ]
            },
            %{
              name: :Detail,
              field: [
                %{name: :note, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
              ]
            },
            %{
              name: :Unused,
              field: [
                %{name: :value, number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}
              ]
            }
          ]
        }
      ]
    }
  end
end

defmodule PB.CodegenTest.Schema do
  use PB.Schema, descriptor_set: PB.CodegenTest.Fixtures.descriptor_set()
end

defmodule PB.CodegenTest.Generated do
  use PB.Codegen,
    schema: PB.CodegenTest.Schema,
    roots: [:"codegen.Greeting"]
end

defmodule PB.CodegenTest.GeneratedBound do
  use PB.Codegen,
    schema: PB.CodegenTest.Schema,
    roots: [{:"codegen.Greeting", as: :hello}]
end

defmodule PB.CodegenTest do
  use ExUnit.Case

  alias PB.Codegen
  alias PB.CodegenTest.Generated
  alias PB.CodegenTest.GeneratedBound
  alias PB.CodegenTest.Schema

  @greeting :"codegen.Greeting"
  @detail :"codegen.Detail"

  test "use PB.Codegen emits codecs for selected provider roots" do
    message = %{text: "hello", detail: %{note: "there"}}
    bin = encode!(Schema.schema(), @greeting, message)

    assert {:ok, ^message} = Generated.decode_greeting(bin)
    assert Generated.decode_greeting!(bin) == message
    assert {:ok, generated} = Generated.encode_greeting(message)
    assert IO.iodata_to_binary(generated) == bin

    refute function_exported?(Generated, :encode_detail, 1)
    refute function_exported?(Generated, :decode_detail, 1)
    refute function_exported?(Generated, :encode_unused, 1)
    refute function_exported?(Generated, :decode_unused, 1)
  end

  test "generated modules expose the prepared schema slice metadata" do
    slice = Generated.__pb_schema_slice__()

    assert Generated.__pb_roots__() == [@greeting]
    assert Generated.__pb_root_names__() == %{}

    assert slice.roots == [@greeting]
    assert Map.has_key?(slice.messages, @greeting)
    assert Map.has_key?(slice.messages, @detail)
    refute Map.has_key?(slice.messages, :"codegen.Unused")
    assert slice.services == %{}
  end

  test "use PB.Codegen honors root aliases" do
    message = %{text: "hello", detail: %{note: "there"}}
    bin = encode!(Schema.schema(), @greeting, message)

    assert {:ok, ^message} = GeneratedBound.decode_hello(bin)

    assert GeneratedBound.__pb_root_names__() == %{@greeting => :hello}
    assert GeneratedBound.__pb_schema_slice__().messages[@detail].kind == :message
    refute function_exported?(GeneratedBound, :encode_detail, 1)
    refute function_exported?(GeneratedBound, :decode_detail, 1)

    assert {:ok, encoded} = GeneratedBound.encode_hello(message)

    assert {:ok, ^message} = GeneratedBound.decode_hello(IO.iodata_to_binary(encoded))
  end

  test "Codegen.generate emits type declarations and codec declarations" do
    schema = Schema.schema() |> PB.Schema.Transform.slice(roots: [@greeting])

    rendered =
      schema
      |> Codegen.generate()
      |> Enum.map_join("\n", &Macro.to_string/1)

    assert rendered =~ "@type detail ::"
    assert rendered =~ "@type greeting ::"
    assert rendered =~ "def encode_greeting(data, opts \\\\ [])"
    assert rendered =~ "def decode_greeting(binary)"
  end

  test "Codegen.module wraps generated declarations in a module" do
    mod = unique_module("Wrapped")
    schema = Schema.schema() |> PB.Schema.Transform.slice(roots: [@detail])
    ast = Codegen.module(mod, schema)

    [{^mod, _bin}] = Code.compile_quoted(ast)

    bin = encode!(Schema.schema(), @detail, %{note: "wrapped"})
    assert {:ok, %{note: "wrapped"}} = mod.decode_detail(bin)
    assert {:ok, encoded} = mod.encode_detail(%{note: "wrapped"})
    assert IO.iodata_to_binary(encoded) == bin
    assert mod.__pb_roots__() == [@detail]
  end

  test "Codegen.generate can emit encoder declarations only" do
    schema = Schema.schema() |> PB.Schema.Transform.slice(roots: [@greeting])

    rendered =
      schema
      |> Codegen.generate(emit: :encoder)
      |> Enum.map_join("\n", &Macro.to_string/1)

    assert rendered =~ "def encode_greeting(data, opts \\\\ [])"
    refute rendered =~ "def decode_greeting(binary)"
  end

  test "codegen rejects unknown emitters" do
    schema = Schema.schema() |> PB.Schema.Transform.slice(roots: [@greeting])

    assert_raise ArgumentError, "unknown PB codegen emitter :wat", fn ->
      Codegen.generate(schema, emit: :wat)
    end

    assert_raise ArgumentError, "unknown PB.Codegen.generate option(s): [:wat]", fn ->
      Codegen.generate(schema, wat: true)
    end
  end

  test "use PB.Codegen requires roots" do
    mod = unique_module("MissingRoots")

    assert_raise ArgumentError, "missing required PB.Codegen option :roots", fn ->
      Code.compile_quoted(
        quote do
          defmodule unquote(mod) do
            use PB.Codegen, schema: PB.CodegenTest.Schema
          end
        end
      )
    end
  end

  defp encode!(schema, fqn, message) do
    {:ok, iodata} = PB.encode(message, schema, fqn)
    IO.iodata_to_binary(iodata)
  end

  defp unique_module(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
