# PB

Data-driven protobuf toolkit for Elixir. Runtime usage needs no code generation,
no build step, and no dependencies: PB reads standard `protoc` descriptor sets
as data. For stable schemas, PB can
also embed the compiled schema in a BEAM module at Elixir compile time.

## Installation

Add `pb` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pb, "~> 0.1.0"}
  ]
end
```

## Quick start

```elixir
# 1. Generate a descriptor set with protoc:
#    protoc --descriptor_set_out=schema.binpb --include_imports your.proto

# 2. Decode and compile it into a schema (just data — no code generation):
{:ok, descriptor_set} = PB.decode_descriptor_set(File.read!("schema.binpb"))
schema = PB.compile(descriptor_set)

# 3. Encode an Elixir map:
{:ok, binary} = PB.encode(%{name: "Alice", id: 42}, schema, :"mypackage.Person")

# 4. Decode it back:
{:ok, person} = PB.decode(binary, schema, :"mypackage.Person")
# => %{name: "Alice", id: 42}
```

The runtime `compile/1` path above shows the model — the schema is just data —
and is the right choice for dynamic schemas. **Most applications have a stable
schema and should embed it at compile time** with `use PB.Schema`:

```elixir
defmodule MyApp.Schema do
  use PB.Schema, descriptor: "priv/proto/schema.binpb"
end

{:ok, binary} = MyApp.Schema.encode(%{name: "Alice", id: 42}, :"mypackage.Person")
{:ok, person} = MyApp.Schema.decode(binary, :"mypackage.Person")
```

See [Getting started](guides/tutorials/getting-started.md) for a step-by-step
walkthrough.

## What PB does

- **Wire encode/decode** of any proto2/proto3/editions schema — `PB.encode/4`,
  `PB.decode/4`.
- **Compile-time schema modules** — embed a stable schema with `use PB.Schema`.
- **Application-friendly shapes** — decode into structs, sum types, or unwrapped
  values, and map messages to native Elixir values with adapters.
- **ProtoJSON** — `PB.JSON`.
- **Text format** — `PB.TextFormat`.
- **Schema introspection** for messages, enums, services, and extensions —
  `PB.Schema`.
- **Schema plugins** that compile a library's own data into the schema —
  `PB.Schema.Plugin`.

Two companion packages build on it:

- [`pb_validate`](https://hexdocs.pm/pb_validate): **protovalidate**
  validation, a schema plugin (`plugins: [PB.Validate]`).
- [`pb_cel`](https://hexdocs.pm/pb_cel): **CEL** expressions over protobuf
  messages, a type provider for [`cel_ex`](https://hexdocs.pm/cel_ex).

## Documentation

The full documentation is organised along the
[Diátaxis](https://diataxis.fr) framework.

**Tutorial**

- [Getting started](guides/tutorials/getting-started.md)

**How-to guides**

- [Generating a descriptor set](guides/how-to/descriptor-sets.md)
- [Embedding a schema at compile time](guides/how-to/schema-modules.md)
- [Decoding into structs and sum types](guides/how-to/structs-and-representation.md)
- [Adapters and well-known types](guides/how-to/adapters-and-well-known-types.md)
- [Encoding and decoding JSON](guides/how-to/json.md)
- [Extensions and unknown fields](guides/how-to/extensions-and-unknown-fields.md)
- [Introspecting a schema](guides/how-to/introspection.md)

For protovalidate and CEL, see the documentation of
[`pb_validate`](https://hexdocs.pm/pb_validate) and
[`pb_cel`](https://hexdocs.pm/pb_cel).

**Reference**

- [Data representation](guides/reference/data-representation.md)
- [Options](guides/reference/options.md)
- [Conformance status](guides/reference/conformance.md)
- [Benchmarks](guides/reference/benchmarks.md)

**Explanation**

- [Why data-driven (no code generation)](guides/explanation/why-data-driven.md)
- [Encoding and decoding semantics](guides/explanation/encoding-semantics.md)
- [Representation vs adapters](guides/explanation/representation-vs-adapters.md)

## Development

The codegen implementation is not part of the production library surface. It lives
under `test/support` and is loaded by `bench/codegen_vs_runtime.exs` only to
compare the runtime path against the old generated-code reference.

The upstream protobuf conformance suite is run with
`scripts/run_protobuf_conformance.sh`, which needs `buf` and Node.js (the
repository's `mise.toml` declares both). Current results and intentional
deviations are documented in [Conformance status](guides/reference/conformance.md).
`build_protos.sh` rebuilds the bundled descriptors and the test fixtures with
`buf`.

`mix dialyzer` should report no warnings; it catches broken typespecs that
would otherwise only show up in a consumer's Dialyzer run.

## License

MIT
