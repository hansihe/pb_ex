# Evaluating CEL expressions

`cel_ex` is a [CEL](https://cel.dev) implementation: a small, safe expression
language for rules, filters and policies, used through `CEL`.

## Declare an environment

An environment says what an expression may use: variables and their types,
custom functions, and the message and enum types it knows:

```elixir
env =
  CEL.Env.build(
    vars: [user: {:map, :string, :dyn}, now: :timestamp, tags: {:list, :string}]
  )
```

Types are `CEL.Type` shorthand: `:int`, `:string`, `:timestamp`,
`{:list, :string}`, `{:map, :string, :int}`, `{:message, "pkg.Message"}`,
`{:enum, "pkg.Enum"}` and so on.

## Compile once, evaluate many times

```elixir
{:ok, program} = CEL.compile("user.age >= 18 && 'beta' in tags", env)

CEL.Program.eval(program, %{user: %{"age" => 30}, now: DateTime.utc_now(), tags: ["beta"]})
#=> {:ok, {:bool, true}}
```

`CEL.compile/2` parses and type-checks; type errors are reported here, with
the line and column of the offending expression, rather than when evaluating.
`CEL.eval/3` does both steps and evaluates, for a one-off.

Variables are bound by atom or string name to plain Elixir terms, converted
using the declared type: a `:timestamp` takes a `DateTime`, and a message
variable takes what its provider converts, for `PB.CEL.types/1` the map
`PB.decode/4` returns. Results are tagged `CEL.Value` terms;
`CEL.Value.to_native/1` turns one back into a plain term.

## Message types

Without `:types`, expressions can use CEL's own types only, which include
timestamps, durations and the other protobuf well-known types. Message and
enum types come from a `CEL.TypeProvider`, given as `:types`. For protobuf
messages, the [`pb_cel`](https://hexdocs.pm/pb_cel) package's
`PB.CEL.types/1` gives an environment the messages and enums of a PB schema:

```elixir
pb_env =
  CEL.Env.build(
    types: PB.CEL.types(MyApp.Schema),
    container: "my.app",
    vars: [user: {:message, "my.app.User"}, now: :timestamp, tags: {:list, :string}]
  )
```

A message or enum name may be an atom or a string; building the environment
resolves it, and raises for one the provider does not have. Types and values
CEL returns name messages and enums as the provider does; `PB.CEL.types/1`
names them by atom: `{:message, :"my.app.User"}`, `{:enum, :"my.app.Role", 2}`.
`:container` is the package names resolve in, so `User{name: "a"}` means
`my.app.User{name: "a"}`.

`:abbreviations` lets expressions use the last segment of names from other
packages: with `abbreviations: ["other.pkg.Decision"]`, `Decision.REMOVED`
means `other.pkg.Decision.REMOVED`, even when the container also has a
`Decision`. Checked expressions carry the full names.

## Missing inputs

Bind a variable to `{:unknown, reason}` when its value is not available, for
example because a lookup timed out. If the result depends on it, evaluation
returns `{:unknown, %CEL.Unknown{}}` listing the inputs it was waiting for;
if not (`false && x`), it returns the result.

```elixir
CEL.Program.eval(program, %{user: {:unknown, :timeout}, now: DateTime.utc_now(), tags: []})
#=> {:ok, {:bool, false}}
```

Custom functions can return `{:unknown, reason}` too; see
[Custom CEL functions](custom-functions.md).

## Inspect an expression

`CEL.check/2` returns a `CEL.Checked`, which can be inspected before
evaluating anything:

  * `CEL.Checked.references/1` lists the variable paths an expression reads
    (`user.age`) and the custom functions it calls, with arguments that are
    constants or variable paths. Use it to fetch only the data a rule needs.
  * `CEL.Checked.expr/1` returns the expression as a tree of `CEL.Expr`
    nodes, for allowlists and linting. Macros such as `exists` appear as
    written.
  * `CEL.Checked.type/1` is the expression's result type.
  * `CEL.Checked.position/2` is where a node is in the source, to point at
    it in a message.

`CEL.select/4` reads one of those variable paths from the bindings the way
evaluation would, but returns `:absent` when a field along it is not set:

```elixir
CEL.select(env, %{user: %{}}, "user", ["nickname"])
#=> :absent
```

## Catch bad literals early

By default, `duration('30d')` type-checks and fails only when evaluated, as CEL
specifies. To reject such literals when compiling, list them in the
environment:

```elixir
CEL.Env.build(validate_literals: [:duration, :timestamp, :regex])
```
