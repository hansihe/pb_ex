# Custom CEL functions

PB ships a [CEL](https://cel.dev) implementation used both by protovalidate's
`cel` rules and as a standalone expression engine. This guide covers the common
task of **registering your own function** so it can be called from CEL source.

CEL itself is a standard; this guide only covers the PB integration surface. For
the language, see the [CEL specification](https://github.com/google/cel-spec).
For evaluating expressions, see [Evaluating CEL expressions](cel.md).

## Declare and register

A function is a `CEL.Function` with one or more `CEL.Function.Overload`s.
Each overload carries its argument and result types plus an optional `:eval`
target. The target must be a `{Module, function}` tuple; closures and
anonymous functions are rejected, so environments stay introspectable.

```elixir
alias CEL.Function
alias CEL.Function.Overload

defmodule MyHandlers do
  # Receives the list of evaluated CEL.Value arguments.
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

env = CEL.Env.build(functions: [function])
{:ok, value} = CEL.eval(~s|greet("world")|, %{}, env)
# => {:ok, {:string, "Hello, world"}}
```

## Call styles and generic signatures

`:modes` says how expressions call the function: `:global` (`greet(x)`, the
default), `:receiver` (`x.greet()`, with `x` as the first argument) or
`{:namespace, "ns"}` (`ns.greet(x)`). Argument and result types are
`CEL.Type` shorthand; `{:param, "T"}` is a type parameter that must be the
same type everywhere it appears:

```elixir
%Function{
  name: "first",
  modes: [:receiver],
  overloads: [
    %Overload{
      id: "first_list",
      args: [{:list, {:param, "T"}}],
      result: {:param, "T"},
      eval: {MyHandlers, :first}
    }
  ]
}
# [1, 2].first() + 1 type-checks as int
```

## Results

Results come back as tagged `CEL.Value` terms (so `int`/`uint` and
`string`/`bytes` stay distinct). Call `CEL.Value.to_native/1` when you just
want a plain Elixir value:

```elixir
CEL.Value.to_native(value)
# => "Hello, world"
```

## The eval contract

- The target receives **one argument**: the list of evaluated `CEL.Value`
  arguments. For receiver-mode calls (`x.greet(y)`) the target value is prepended
  to that list.
- It must return `{:ok, value} | {:unknown, reason} | {:error, reason}`, with
  `value` a `CEL.Value` of the declared result type. Nothing checks the
  value against that type, so build it with the constructors: an `{:enum,
  "pkg.Enum"}` result is `CEL.Value.enum("pkg.Enum", number)`, which is
  also how enum arguments arrive.
  `{:unknown, reason}` makes the call's result unknown; `reason` is any term and
  is reported in the `CEL.Unknown` entry `{{:call, name, expr_id}, reason}`.
- The function is not called when an argument is an error or unknown; the call
  returns that error or unknown instead. Set `strict: false` on the overload to
  be called anyway: such arguments then arrive as `{:error, %CEL.Error{}}` and
  `{:unknown, %CEL.Unknown{}}`, and returning one of them passes it through
  unchanged. A non-strict
  function that turns an unknown into a value decides the result without that
  input, so the result no longer reflects that the input was unknown.
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
- `:call` passes `%{function: name, overload_id: id, expr_id: id}`, naming the
  function, the overload the checker chose and the call site, so one handler
  can serve several registered functions. `name` includes the namespace for
  namespaced calls (`ns.fn`). `expr_id` is the call's expression id, the same
  one `CEL.Checked.references/1` reports for the call and `CEL.Unknown`
  uses in `{:call, name, expr_id}`, so results computed per call site before
  evaluation can be looked up by it.
  Context arguments follow in the order the list gives them:

  ```elixir
  defmodule Rules do
    def call([{:string, user}], %{function: "is_" <> label}),
      do: {:ok, {:bool, Labels.has?(user, label)}}
  end

  for label <- ["spam", "bot"] do
    %Function{
      name: "is_" <> label,
      overloads: [
        %Overload{
          id: "is_" <> label <> "_string",
          args: [:string],
          result: :bool,
          eval: {Rules, :call},
          eval_context: [:call]
        }
      ]
    }
  end
  ```
- Registration validates only the MFA *shape* (both elements must be atoms). It
  does not check that the module/function exists, so a missing `Mod.fun/arity` at
  dispatch time raises `:undef` to the caller.
- An overload with no `:eval` MFA is a check-only declaration; evaluating such a
  call raises an evaluator error.

## Using the function in validation

The same `CEL.Env` mechanism backs protovalidate `cel` rules. Register your
functions on the environment PB uses to evaluate validation expressions, then
reference them by name in your `(buf.validate.field).cel` expressions. See
[Validating with protovalidate](validation.md).
