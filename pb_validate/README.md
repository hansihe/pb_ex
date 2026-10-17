# PB.Validate

[protovalidate](https://github.com/bufbuild/protovalidate) validation for
[`pb`](https://hexdocs.pm/pb): `PB.Validate` checks protobuf messages against
the `buf.validate` rules in their schema, including the CEL ones, which it
evaluates with [`cel_ex`](https://hexdocs.pm/cel_ex).

## Installation

Add `pb_validate` to your dependencies in `mix.exs`, next to `pb`:

```elixir
def deps do
  [
    {:pb, "~> 0.1"},
    {:pb_validate, "~> 0.1"}
  ]
end
```

## Quick start

Declare rules with `buf.validate` options in your `.proto` files:

```proto
import "buf/validate/validate.proto";

message Person {
  string name  = 1 [(buf.validate.field).string.min_len = 1];
  string email = 2 [(buf.validate.field).string.email = true];
}
```

`PB.Validate` is a schema plugin: list it in `:plugins` when you compile the
schema, and schema modules get `validate/2,3` and `validate!/2,3`:

```elixir
defmodule MyApp.Schema do
  use PB.Schema, descriptor: "priv/proto/schema.binpb", plugins: [PB.Validate]
end

MyApp.Schema.validate(%{name: "", email: "alice@example.com"}, :"mypackage.Person")
#=> {:error, %PB.Validate.Error{violations: [%PB.Validate.Violation{...}]}}
```

or, with a schema compiled at runtime:

```elixir
schema = PB.compile(descriptor_set, plugins: [PB.Validate])
PB.Validate.validate(person, schema, :"mypackage.Person")
```

Compiling type-checks every rule, and raises `PB.Validate.CompileError` for
rules that don't fit the schema.

## Documentation

- [Validating with protovalidate](guides/validation.md)
- [Conformance status](guides/conformance.md)

## Development

The upstream protovalidate conformance suite runs with
`scripts/run_protovalidate_conformance.sh`, which builds the Go harness with
`scripts/build_protovalidate_conformance.sh`. `build_protos.sh` rebuilds the
bundled descriptors and the test fixtures with `buf`. The repository's
`mise.toml` declares Go and `buf`.

## License

MIT
