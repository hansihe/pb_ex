# CEL

The [Common Expression Language](https://cel.dev) (CEL) for Elixir: a small,
safe expression language for rules, filters and policies. `cel_ex` parses,
type-checks and evaluates CEL expressions against variables and messages.

It has no dependencies and knows nothing of protobuf. CEL's own types are
always available, including the protobuf well-known types it builds in;
message and enum types come from a `CEL.TypeProvider` you supply.

## Installation

Add `cel_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cel_ex, "~> 0.1"}
  ]
end
```

## Quick start

```elixir
env = CEL.Env.build(vars: [age: :int, tags: {:list, :string}])

CEL.eval("age >= 18 && 'vip' in tags", %{age: 30, tags: ["vip"]}, env)
#=> {:ok, {:bool, true}}
```

For an expression evaluated many times, compile it once:

```elixir
{:ok, program} = CEL.compile("age >= 18 && 'vip' in tags", env)

CEL.Program.eval(program, %{age: 30, tags: ["vip"]})
#=> {:ok, {:bool, true}}
```

`CEL.compile/2` parses and type-checks; type errors are reported there, with
the line and column of the problem, rather than when evaluating. Results are
tagged `CEL.Value` terms, so `{:int, 1}` and `{:uint, 1}` stay distinct;
`CEL.Value.to_native/1` turns one back into a plain term.

## What it does

- **Parse, check and evaluate** CEL, with the standard macros and the
  strings, math, encoders and optional-value extensions — `CEL`,
  `CEL.Env`, `CEL.Program`.
- **Custom functions** called from expressions — `CEL.Function`.
- **Unknown inputs**: bind a variable to `{:unknown, reason}` and get back
  the inputs a result was waiting for — `CEL.Unknown`.
- **Inspection** of checked expressions before evaluating them: the variables
  and functions they reference, their type and their tree — `CEL.Checked`,
  `CEL.Expr`.

## Documentation

- [Evaluating CEL expressions](guides/evaluating-expressions.md)
- [Custom CEL functions](guides/custom-functions.md)

## Message types

An environment's message and enum types come from a `CEL.TypeProvider`,
given to `CEL.Env.build/1` as `:types`. A provider is a `{module, state}`
tuple; the module says which types exist, what their fields are, and how to
read and build their values.

For protobuf messages, the [`pb_cel`](https://hexdocs.pm/pb_cel) package
provides one: `PB.CEL.types/1` makes the messages and enums of a
[`pb`](https://hexdocs.pm/pb) schema the types of an environment.

```elixir
env =
  CEL.Env.build(
    types: PB.CEL.types(MyApp.Schema),
    container: "my.pkg",
    vars: [user: {:message, "my.pkg.User"}]
  )

CEL.eval("user.age >= 18", %{user: %{age: 30}}, env)
#=> {:ok, {:bool, true}}
```

## Conformance

CEL runs the upstream [cel-spec](https://github.com/google/cel-spec) simple
conformance suite. The runner lives in the `pb_cel` project, because the
conformance fixtures are protobuf messages; see
[pb_cel's conformance status](https://github.com/hansihe/pb_ex/blob/main/pb_cel/guides/conformance.md)
for the results and the intentionally unsupported areas.

## License

MIT
