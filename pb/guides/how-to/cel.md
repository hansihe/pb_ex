# CEL over protobuf messages

PB evaluates [CEL](https://cel.dev) expressions with
[`cel_ex`](https://hexdocs.pm/cel_ex), which knows nothing of protobuf itself.
`PB.CEL.types/1` connects the two: it is the `CEL.TypeProvider` that makes the
messages and enums of a PB schema the types of a `CEL.Env`.

```elixir
env =
  CEL.Env.build(
    types: PB.CEL.types(MyApp.Schema),
    container: "my.app",
    vars: [user: {:message, "my.app.User"}]
  )

{:ok, program} = CEL.compile("user.age >= 18 && user.role == Role.ADMIN", env)

{:ok, user} = MyApp.Schema.decode(binary, :"my.app.User")
CEL.Program.eval(program, %{user: user})
#=> {:ok, {:bool, true}}
```

`PB.CEL.types/1` takes a module that `use PB.Schema` or a schema compiled with
`PB.compile/2`.

## Names and values

- Message and enum types are named by PB's atoms. A declaration may name one
  by atom or string, `{:message, "my.app.User"}`, but the types and values CEL
  returns carry the atom: `{:message, :"my.app.User", fields}`,
  `{:enum, :"my.app.Role", 2}`.
- A message variable binds to the message as `PB.decode/4` returns it, and an
  enum variable to a value's name as an atom or its number.
- The well-known types are the CEL types they stand for: a
  `google.protobuf.Timestamp` field reads as a timestamp, an `Int64Value` one
  as an int or `null`.

## Validation

protovalidate's `cel` rules are evaluated with CEL over the same types; see
[Validating with protovalidate](validation.md).

## More

The language, environments, unknown inputs, inspecting expressions and custom
functions are covered by `cel_ex`'s guides:

- [Evaluating CEL expressions](https://hexdocs.pm/cel_ex/evaluating-expressions.html)
- [Custom CEL functions](https://hexdocs.pm/cel_ex/custom-functions.html)
