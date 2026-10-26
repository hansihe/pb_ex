# PB.CEL

CEL over protobuf messages: `PB.CEL.types/1` is the `CEL.TypeProvider` that
makes the messages and enums of a [`pb`](https://hexdocs.pm/pb) schema the
types of a [`cel_ex`](https://hexdocs.pm/cel_ex) environment, so CEL
expressions read decoded protobuf messages directly.

## Installation

Add `pb_cel` to your dependencies in `mix.exs`, next to `pb` and `cel_ex`:

```elixir
def deps do
  [
    {:pb, "~> 0.1"},
    {:cel_ex, "~> 0.1"},
    {:pb_cel, "~> 0.1"}
  ]
end
```

## Quick start

```elixir
env =
  CEL.Env.build(
    types: PB.CEL.types(MyApp.Schema),
    container: "my.app",
    vars: [user: {:message, "my.app.User"}]
  )

{:ok, user} = MyApp.Schema.decode(binary, :"my.app.User")

CEL.eval("user.age >= 18 && user.role == Role.ADMIN", %{user: user}, env)
#=> {:ok, {:bool, true}}
```

`PB.CEL.types/1` takes a module that `use PB.Schema` or a schema compiled with
`PB.compile/2`. Messages bind as `PB.decode/4` returns them, and the
well-known types read as the CEL types they stand for.

## Documentation

- [CEL over protobuf messages](guides/cel-over-protobuf.md)
- [Conformance status](guides/conformance.md)

The language itself, environments, unknown inputs and custom functions are
covered by [`cel_ex`'s documentation](https://hexdocs.pm/cel_ex).

## Development

The upstream CEL conformance fixtures are fetched with
`scripts/fetch_cel_conformance.sh`, and `build_protos.sh` rebuilds the bundled
descriptors and the test schema with `buf`.

## License

MIT
