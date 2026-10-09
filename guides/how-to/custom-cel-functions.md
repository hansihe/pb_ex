# Writing a custom CEL function

PB ships a [CEL](https://cel.dev) implementation used both by protovalidate's
`cel` rules and as a standalone expression engine. This guide covers the common
task of **registering your own function** so it can be called from CEL source.

CEL itself is a standard; this guide only covers the PB integration surface. For
the language, see the [CEL specification](https://github.com/google/cel-spec).
For evaluating expressions, see `PB.CEL`.

> **Unstable surface.** The function-declaration structs shown below are a
> low-level registration API that is still being reshaped, and are intentionally
> not part of the published module reference yet. The shapes here are accurate
> for the current version but may change before they are committed as stable
> public API.

## Declare and register

A function is declared as a Function struct (aliased below) with one or more
overloads. Each overload carries a checker signature (argument and result types)
plus an optional
`:eval` MFA. The MFA must be a `{Module, function}` 2-tuple — closures and
anonymous functions are rejected at registration so functions stay
introspectable.

```elixir
alias PB.CEL.Function
alias PB.CEL.Function.Overload

defmodule MyHandlers do
  # Receives the list of evaluated PB.CEL.Value arguments.
  def greet([{:string, name}]), do: {:ok, {:string, "Hello, " <> name}}
end

function = %Function{
  name: "greet",
  overloads: [
    %Overload{
      id: "greet_string",
      args: [:string],
      result: :string,
      eval: {MyHandlers, :greet}
    }
  ]
}

env = PB.CEL.Env.build(functions: [function])
{:ok, value} = PB.CEL.eval(~s|greet("world")|, %{}, env)
# => {:ok, {:string, "Hello, world"}}
```

Results come back as tagged `PB.CEL.Value` terms (so `int`/`uint` and
`string`/`bytes` stay distinct). Call `PB.CEL.Value.to_native/1` when you just
want a plain Elixir value:

```elixir
PB.CEL.Value.to_native(value)
# => "Hello, world"
```

## The eval contract

- The target receives **one argument**: the list of evaluated `PB.CEL.Value`
  arguments. For receiver-mode calls (`x.greet(y)`) the target value is prepended
  to that list.
- It must return `{:ok, value} | {:unknown, reason} | {:error, reason}`.
  `{:unknown, reason}` makes the call's result unknown; `reason` is any term and
  is reported in the `PB.CEL.Unknown` entry `{{:call, name, expr_id}, reason}`.
- The function is not called when an argument is an error or unknown; the call
  returns that error or unknown instead.
- An overload's `:eval_context` lists extra arguments appended after the
  argument list. `:vars` passes the variable bindings given to eval, as a map
  keyed by string name, so a function can read results fetched before
  evaluation:

  ```elixir
  defmodule Labels do
    def label([{:string, name}], vars) do
      case Map.fetch(vars, "labels") do
        {:ok, {:unknown, _reason} = unknown} -> unknown
        {:ok, labels} -> {:ok, {:bool, name in labels}}
        :error -> {:unknown, :labels_not_fetched}
      end
    end
  end

  %Overload{
    id: "label_string",
    args: [:string],
    result: :bool,
    eval: {Labels, :label},
    eval_context: [:vars]
  }
  ```
- Registration validates only the MFA *shape* (both elements must be atoms). It
  does not check that the module/function exists, so a missing `Mod.fun/arity` at
  dispatch time raises `:undef` to the caller.
- An overload with no `:eval` MFA is a check-only declaration; evaluating such a
  call raises an evaluator error.

## Using the function in validation

The same `PB.CEL.Env` mechanism backs protovalidate `cel` rules. Register your
functions on the environment PB uses to evaluate validation expressions, then
reference them by name in your `(buf.validate.field).cel` expressions. See
[Validating with protovalidate](validation.md).
