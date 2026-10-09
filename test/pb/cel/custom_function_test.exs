defmodule PB.CEL.CustomFunctionTest do
  use ExUnit.Case, async: true

  alias PB.CEL
  alias PB.CEL.Library.Function
  alias PB.CEL.Library.Function.Overload
  alias PB.CEL.Value

  defmodule Handlers do
    def greet([{:string, name}]), do: {:ok, Value.string("Hello, " <> name)}
    def greet(_args), do: {:error, "greet/1 expects a string"}

    def shout([{:string, target}, {:string, suffix}]) do
      {:ok, Value.string(String.upcase(target) <> suffix)}
    end

    def boom(_args), do: {:error, "boom!"}

    def label([{:string, name}], vars) do
      case Map.fetch(vars, "labels") do
        {:ok, {:unknown, _reason} = unknown} -> unknown
        {:ok, labels} -> {:ok, Value.bool(name in labels)}
        :error -> {:unknown, :labels_not_fetched}
      end
    end
  end

  defp greet_function do
    %Function{
      name: "greet",
      overloads: [
        %Overload{
          id: "greet_string",
          args: [:string],
          result: :string,
          eval: {Handlers, :greet}
        }
      ]
    }
  end

  defp shout_function do
    %Function{
      name: "shout",
      modes: [:receiver],
      overloads: [
        %Overload{
          id: "shout_string_string",
          args: [:string, :string],
          result: :string,
          eval: {Handlers, :shout}
        }
      ]
    }
  end

  defp boom_function do
    %Function{
      name: "boom",
      overloads: [
        %Overload{
          id: "boom_void",
          args: [],
          result: :string,
          eval: {Handlers, :boom}
        }
      ]
    }
  end

  test "registers and dispatches a global custom function via MFA" do
    assert {:ok, value} =
             CEL.eval(~s|greet("world")|, %{}, env(functions: [greet_function()]))

    assert value == Value.string("Hello, world")
  end

  test "registers and dispatches a receiver-mode custom function via MFA" do
    assert {:ok, value} =
             CEL.eval(~s|"x".shout("!")|, %{}, env(functions: [shout_function()]))

    assert value == Value.string("X!")
  end

  test "translates MFA errors into evaluator errors" do
    assert {:error, %CEL.Error{phase: :eval, message: "boom!"}} =
             CEL.eval("boom()", %{}, env(functions: [boom_function()]))
  end

  test "rejects closures at registration with a clear error" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: fn _args -> {:ok, Value.string("nope")} end
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "rejects function captures at registration with a clear error" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: &Handlers.greet/1
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "rejects non-atom MFA modules at registration" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: {"NotAModule", :greet}
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "rejects non-atom MFA functions at registration" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: {Handlers, "greet"}
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "rejects 3-tuple MFA values at registration" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: {Handlers, :greet, []}
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "rejects integer eval values at registration" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: 42
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "rejects list eval values at registration" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: [Handlers, :greet]
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "rejects non-tuple eval values at registration" do
    bad_function = %Function{
      name: "bad",
      overloads: [
        %Overload{
          id: "bad_void",
          args: [],
          result: :string,
          eval: :not_a_tuple
        }
      ]
    }

    assert_raise ArgumentError, ~r/must be an \{Module, function_atom\} MFA tuple/, fn ->
      CEL.check!("bad()", env(functions: [bad_function]))
    end
  end

  test "check-only custom functions still type-check but error at eval" do
    check_only =
      %Function{
        name: "stub",
        overloads: [
          %Overload{id: "stub_void", args: [], result: :string}
        ]
      }

    assert {:ok, _checked} = CEL.check("stub()", env(functions: [check_only]))

    assert {:error, %CEL.Error{phase: :eval, message: "unsupported function stub"}} =
             CEL.eval("stub()", %{}, env(functions: [check_only]))
  end

  test "passes the variable bindings to functions that request :vars" do
    label = %Function{
      name: "label",
      overloads: [
        %Overload{
          id: "label_string",
          args: [:string],
          result: :bool,
          eval: {Handlers, :label},
          eval_context: [:vars]
        }
      ]
    }

    env = env(vars: [score: :int], functions: [label])
    source = ~s{label("vip") || score > 10}

    assert CEL.eval(source, %{score: 1, labels: ["vip"]}, env) == {:ok, Value.bool(true)}
    assert CEL.eval(source, %{score: 1, labels: []}, env) == {:ok, Value.bool(false)}

    assert {:unknown, unknown} = CEL.eval(source, %{score: 1}, env)
    assert [{{:call, "label", _expr_id}, :labels_not_fetched}] = CEL.Unknown.entries(unknown)

    assert {:unknown, unknown} = CEL.eval(source, %{score: 1, labels: {:unknown, :timeout}}, env)
    assert [{{:call, "label", _expr_id}, :timeout}] = CEL.Unknown.entries(unknown)
  end

  defp env(opts), do: CEL.Env.build(opts)
end
