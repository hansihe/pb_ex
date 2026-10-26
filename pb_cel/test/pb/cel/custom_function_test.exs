defmodule PB.CEL.CustomFunctionTest do
  # Custom functions over a PB schema's enums; the rest of CEL's custom function
  # tests are cel_ex's.
  use ExUnit.Case, async: true

  alias CEL.Function
  alias CEL.Function.Overload
  alias CEL.Value

  defmodule Handlers do
    def decide([{:string, _rule}]) do
      {:ok, Value.enum(:"cel.expr.conformance.proto3.GlobalEnum", 2)}
    end

    def enum_number([{:enum, _name, number}]), do: {:ok, Value.int(number)}
  end

  test "resolves message and enum names in signatures through the provider" do
    types = PB.CEL.types(PB.TestSupport.TestSchema)

    enum = :"cel.expr.conformance.proto3.GlobalEnum"

    for name <- [enum, Atom.to_string(enum)] do
      function = %Function{
        name: "f",
        overloads: [%Overload{id: "f_enum", args: [{:enum, name}], result: :int}]
      }

      assert [%Overload{args: [{:enum, ^enum}]}] =
               env(types: types, functions: [function]).functions
               |> Enum.find(&(&1.name == "f"))
               |> Map.fetch!(:overloads)
    end

    function = %Function{
      name: "f",
      overloads: [%Overload{id: "f_msg", args: [{:message, "pkg.Nope"}], result: :int}]
    }

    assert_raise CEL.OptionError,
                 ~r/:functions: unknown message or enum type pkg.Nope in "f" overload "f_msg"/,
                 fn ->
                   env(types: types, functions: [function])
                 end
  end

  describe "enum types in overload signatures" do
    @global_enum "cel.expr.conformance.proto3.GlobalEnum"

    defp enum_env do
      decide = %Function{
        name: "decide",
        overloads: [
          %Overload{
            id: "decide_string",
            args: [:string],
            result: {:enum, @global_enum},
            eval: {Handlers, :decide}
          }
        ]
      }

      number = %Function{
        name: "number",
        overloads: [
          %Overload{
            id: "number_global_enum",
            args: [{:enum, @global_enum}],
            result: :int,
            eval: {Handlers, :enum_number}
          }
        ]
      }

      env(
        types: PB.CEL.types(PB.TestSupport.TestSchema),
        container: "cel.expr.conformance.proto3",
        functions: [decide, number]
      )
    end

    test "an enum result compares with its own enum's values, not another's" do
      env = enum_env()

      global_enum = String.to_atom(@global_enum)
      assert CEL.check!("decide('r')", env) |> CEL.Checked.type() == {:enum, global_enum}
      assert CEL.eval!("decide('r')", %{}, env) == {:enum, global_enum, 2}
      assert CEL.eval!("decide('r') == GlobalEnum.GAZ", %{}, env) == {:bool, true}

      assert {:error, %CEL.Error{phase: :check, message: message}} =
               CEL.check("decide('r') == TestAllTypes.NestedEnum.BAZ", env)

      assert message =~ "no matching overload for _==_"
    end

    test "an enum argument takes values of that enum only" do
      env = enum_env()

      assert CEL.eval!("number(GlobalEnum.GAR)", %{}, env) == {:int, 1}
      assert CEL.eval!("number(decide('r'))", %{}, env) == {:int, 2}

      assert {:error, %CEL.Error{phase: :check}} =
               CEL.check("number(TestAllTypes.NestedEnum.BAZ)", env)

      assert {:error, %CEL.Error{phase: :check}} = CEL.check("number(1)", env)
    end
  end

  defp env(opts), do: CEL.Env.build(opts)
end
