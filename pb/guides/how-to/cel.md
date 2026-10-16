# Evaluating CEL expressions

PB includes a [CEL](https://cel.dev) implementation: a small, safe expression
language for rules, filters and policies. It backs protovalidate's `cel`
rules and is usable on its own through `PB.CEL`.

## Declare an environment

An environment says what an expression may use: variables and their types,
custom functions, and the protobuf schema its messages come from.

```elixir
env =
  PB.CEL.Env.build(
    schema: MyApp.Schema,
    container: "my.app",
    vars: [user: {:message, "my.app.User"}, now: :timestamp, tags: {:list, :string}]
  )
```

Types are `PB.CEL.Type` shorthand: `:int`, `:string`, `:timestamp`,
`{:list, :string}`, `{:map, :string, :int}`, `{:message, "pkg.Message"}`,
`{:enum, "pkg.Enum"}` and so on. `:container` is the package names resolve in,
so `User{name: "a"}` means `my.app.User{name: "a"}`.

`:abbreviations` lets expressions use the last segment of names from other
packages: with `abbreviations: ["other.pkg.Decision"]`, `Decision.REMOVED`
means `other.pkg.Decision.REMOVED`, even when the container also has a
`Decision`. Checked expressions carry the full names.

## Compile once, evaluate many times

```elixir
{:ok, program} = PB.CEL.compile("user.age >= 18 && 'beta' in tags", env)

PB.CEL.Program.eval(program, %{user: %{age: 30}, now: DateTime.utc_now(), tags: ["beta"]})
#=> {:ok, {:bool, true}}
```

`PB.CEL.compile/2` parses and type-checks; type errors are reported here, with
the line and column of the offending expression, rather than when evaluating.
`PB.CEL.eval/3` does both steps and evaluates, for a one-off.

Variables are bound by atom or string name to plain Elixir terms, converted
using the declared type: a message variable takes the map `PB.decode/4`
returns, a `:timestamp` takes a `DateTime`. Results are tagged
`PB.CEL.Value` terms; `PB.CEL.Value.to_native/1` turns one back into a plain
term.

## Missing inputs

Bind a variable to `{:unknown, reason}` when its value is not available, for
example because a lookup timed out. If the result depends on it, evaluation
returns `{:unknown, %PB.CEL.Unknown{}}` listing the inputs it was waiting for;
if not (`false && x`), it returns the result.

```elixir
PB.CEL.Program.eval(program, %{user: {:unknown, :timeout}, now: DateTime.utc_now(), tags: []})
#=> {:ok, {:bool, false}}
```

Custom functions can return `{:unknown, reason}` too; see
[Custom CEL functions](custom-cel-functions.md).

## Inspect an expression

`PB.CEL.check/2` returns a `PB.CEL.Checked`, which can be inspected before
evaluating anything:

  * `PB.CEL.Checked.references/1` lists the variable paths an expression reads
    (`user.age`) and the custom functions it calls, with arguments that are
    constants or variable paths. Use it to fetch only the data a rule needs.
  * `PB.CEL.Checked.expr/1` returns the expression as a tree of `PB.CEL.Expr`
    nodes, for allowlists and linting. Macros such as `exists` appear as
    written.
  * `PB.CEL.Checked.type/1` is the expression's result type.
  * `PB.CEL.Checked.position/2` is where a node is in the source, to point at
    it in a message.

`PB.CEL.select/4` reads one of those variable paths from the bindings the way
evaluation would, but returns `:absent` when a field along it is not set:

```elixir
PB.CEL.select(env, %{user: %{}}, "user", ["nickname"])
#=> :absent
```

## Catch bad literals early

By default, `duration('30d')` type-checks and fails only when evaluated, as CEL
specifies. To reject such literals when compiling, list them in the
environment:

```elixir
PB.CEL.Env.build(validate_literals: [:duration, :timestamp, :regex])
```
