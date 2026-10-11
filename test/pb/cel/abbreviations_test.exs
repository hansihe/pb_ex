defmodule PB.CEL.AbbreviationsTest do
  # Mirrors cel-go's common/containers/container_test.go and the TestAbbrevs*
  # tests in cel/cel_test.go.
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Checked
  alias PB.CEL.Env
  alias PB.CEL.Expr.Ident

  @proto3 "cel.expr.conformance.proto3"

  defp env(opts), do: Env.build(Keyword.put_new(opts, :schema, PB.TestSupport.TestSchema))

  defp resolved_name(source, env) do
    %Ident{name: name} = source |> CEL.check!(env) |> Checked.expr()
    name
  end

  describe "resolution (TestContainers_Abbrevs)" do
    test "an abbreviation is the only candidate, without and with a container" do
      vars = ["my.alias.R": :int, "a.b.c.R": :int, "my.alias.R.S.T": :int, "a.b.S": :int]

      assert resolved_name("R", env(abbreviations: ["my.alias.R"], vars: vars)) ==
               "my.alias.R"

      env = env(container: "a.b.c", abbreviations: ["my.alias.R"], vars: vars)

      assert resolved_name("R", env) == "my.alias.R"
      assert resolved_name("R.S.T", env) == "my.alias.R.S.T"
      assert resolved_name("S", env) == "a.b.S"
    end

    test "the container is not searched when the expansion does not resolve" do
      env = env(container: "a.b.c", abbreviations: ["my.alias.R"], vars: ["a.b.c.R": :int])

      assert {:error, %{message: message}} = CEL.check("R", env)
      assert message =~ "undeclared identifier"
    end

    test "an abbreviation hides a variable of the same name" do
      env = env(abbreviations: ["my.alias.R"], vars: [R: :string, "my.alias.R": :int])

      assert CEL.eval!("R", %{"R" => "plain", "my.alias.R" => 1}, env) == {:int, 1}
    end

    test "an abbreviation applies after a leading dot, as in cel-go and cel-cpp" do
      env = env(abbreviations: ["my.alias.R"], vars: [R: :string, "my.alias.R": :int])

      assert resolved_name(".R", env) == "my.alias.R"
    end

    test "variables a macro binds hide an abbreviation, unless written with a dot" do
      env = env(abbreviations: ["my.alias.x"], vars: ["my.alias.x": :int])

      assert CEL.eval!("[1].exists(x, x == 1)", %{"my.alias.x" => 5}, env) == {:bool, true}
      assert CEL.eval!("[1].exists(x, .x == 5)", %{"my.alias.x" => 5}, env) == {:bool, true}
    end
  end

  test "an abbreviated variable is read under its full name (TestAbbrevsCompiled)" do
    env =
      env(
        abbreviations: ["qualified.identifier.name"],
        vars: ["qualified.identifier.name.first": :string]
      )

    values = %{"qualified.identifier.name.first" => "Jim"}

    assert CEL.eval!(~S("hello " + name.first), values, env) == {:string, "hello Jim"}

    assert %{vars: [%{name: "qualified.identifier.name.first", path: []}]} =
             ~S("hello " + name.first) |> CEL.check!(env) |> Checked.references()
  end

  test "an abbreviation wins over a name the container resolves (TestAbbrevsDisambiguation)" do
    env =
      env(
        abbreviations: ["external.TestAllTypes"],
        container: @proto3,
        vars: [test: :bool, "external.TestAllTypes": :string]
      )

    source = "test ? dyn(TestAllTypes) : #{@proto3}.TestAllTypes{single_int64: 1}"

    assert CEL.eval!(source, %{test: true, "external.TestAllTypes": "string expr"}, env) ==
             {:string, "string expr"}

    assert {:message, _name, %{single_int64: 1}} =
             CEL.eval!(source, %{test: false, "external.TestAllTypes": "wrong expr"}, env)
  end

  describe "types and enums" do
    test "resolve to their full names whatever the container" do
      for container <- ["", "cel.expr.conformance.proto2"] do
        env = env(abbreviations: ["#{@proto3}.GlobalEnum"], container: container)

        checked = CEL.check!("GlobalEnum.GAZ", env)
        assert %Ident{scope: :enum, name: "#{@proto3}.GlobalEnum.GAZ"} = Checked.expr(checked)
        assert Checked.type(checked) == {:enum, "#{@proto3}.GlobalEnum"}
        assert CEL.eval!("GlobalEnum.GAZ", %{}, env) == {:enum, "#{@proto3}.GlobalEnum", 2}

        assert resolved_name("GlobalEnum", env) == "#{@proto3}.GlobalEnum"
        assert CEL.eval!("GlobalEnum(2) == GlobalEnum.GAZ", %{}, env) == {:bool, true}

        assert %PB.CEL.Expr.Call{function: "#{@proto3}.GlobalEnum"} =
                 "GlobalEnum(2)" |> CEL.check!(env) |> Checked.expr()
      end
    end

    test "an abbreviated package qualifies messages and enums" do
      env = env(abbreviations: [@proto3])

      assert resolved_name("proto3.GlobalEnum.GAZ", env) == "#{@proto3}.GlobalEnum.GAZ"

      assert CEL.eval!("proto3.TestAllTypes{single_int64: 3}.single_int64", %{}, env) ==
               {:int, 3}

      assert CEL.eval!("proto3.TestAllTypes.NestedEnum.BAR", %{}, env) ==
               {:enum, "#{@proto3}.TestAllTypes.NestedEnum", 1}
    end

    test "an abbreviated message literal" do
      env = env(abbreviations: ["#{@proto3}.TestAllTypes"])

      assert %PB.CEL.Expr.MessageLiteral{message: "#{@proto3}.TestAllTypes"} =
               "TestAllTypes{}" |> CEL.check!(env) |> Checked.expr()
    end
  end

  test "Env.build/1 rejects bad abbreviations (TestContainers_Aliasing_Errors)" do
    for {opts, pattern} <- [
          {[abbreviations: ["my.alias.R", "yer.other.R"]], ~r/R already abbreviates my.alias.R/},
          {[container: "a.b.c.M.N", abbreviations: ["my.alias.a", "yer.other.b"]],
           ~r/a collides with container a.b.c.M.N/},
          {[container: "a", abbreviations: ["my.alias.a"]], ~r/a collides with container a/},
          {[abbreviations: [".bad"]], ~r/expected a qualified name/},
          {[abbreviations: ["bad.alias."]], ~r/expected a qualified name/},
          {[abbreviations: ["   bad_alias1"]], ~r/expected a qualified name/},
          {[abbreviations: ["   bad.alias!  "]], ~r/expected a qualified name/},
          {[abbreviations: ["bad_alias1"]], ~r/expected a qualified name/},
          {[abbreviations: ["a..b"]], ~r/expected a qualified name/},
          {[abbreviations: [:"a.b"]], ~r/expected a qualified name/},
          {[abbreviations: "a.b"], ~r/:abbreviations/}
        ] do
      assert_raise PB.OptionError, pattern, fn -> Env.build(opts) end
    end
  end
end
