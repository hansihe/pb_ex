# Embedding a schema at compile time

For a stable schema — the common case — define a **schema module** to compile and
embed it when your application compiles. This is the path most applications should
use: you get the full encode/decode/validate API without reading and compiling a
descriptor set at runtime. Runtime schema maps (`PB.compile/1`) remain available
and are the right choice when a schema is loaded or selected dynamically.

## Define the module

```elixir
defmodule MyApp.Schema do
  use PB.Schema,
    descriptor: "priv/proto/schema.binpb",
    projections: [
      {:"google.protobuf.Timestamp", adapter: MyApp.TimestampAdapter.spec()},
      {:"my.app.Event", struct: MyApp.Event}
    ]
end
```

Generate the descriptor file the usual way:

```sh
protoc --descriptor_set_out=priv/proto/schema.binpb --include_imports your.proto
```

`PB.Schema` marks descriptor files as external resources, so Mix recompiles the
schema module when the descriptor file changes. If a `.proto` file changes,
regenerate the descriptor set first — PB tracks the descriptor file, not the
source `.proto` files.

## Use it

The module exposes the encode/decode/validate API with the schema baked in, so
you only pass the message name:

```elixir
{:ok, binary} = MyApp.Schema.encode(%{name: "Alice", id: 42}, :"mypackage.Person")
{:ok, person} = MyApp.Schema.decode(binary, :"mypackage.Person")
```

The generated functions are `schema/0`, `__pb_schema__/0`, `encode/2,3`,
`encode!/2,3`, `encode_iodata/2,3`, `encode_iodata!/2,3`, `decode/2,3`,
`decode!/2,3`, `normalize/2,3`, `normalize!/2,3`, `validate/2,3`, and
`validate!/2,3`.

The top-level `PB.encode/4` and `PB.decode/4` also accept a schema module
directly in place of a compiled schema map, so library code can stay agnostic
about which form it was given.

## Projections

The optional `:projections` value is passed straight to `PB.compile/2`, so schema
modules and dynamic schemas share the same projection model.

When you own the schema, prefer declaring structural representation
(`:struct`, `:unwrap`, identity oneofs) **in proto source** via the
`elixir.pb.v1` custom options — it lives next to the message it describes. The
example above uses the `:projections` list because that is the right place for
the two things proto source can't carry: **adapters** (they need code, like the
`Timestamp` adapter) and **overrides for schemas you do not own**.

See [Decoding into structs](structs-and-representation.md) and
[Adapters and well-known types](adapters-and-well-known-types.md).

## Hand-authored schemas (tests, fixtures)

For tests or hand-authored schemas, pass a decoded descriptor-set map instead of
a file:

```elixir
defmodule MyApp.Schema do
  use PB.Schema, descriptor_set: %{
    file: [
      %{
        name: "person.proto",
        package: :mypackage,
        syntax: :proto3,
        message_type: [
          %{
            name: :Person,
            field: [
              %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}
            ]
          }
        ]
      }
    ]
  }
end
```

See [Data representation](../reference/data-representation.md#schema-format-hand-written-schemas)
for the full hand-written schema format.
