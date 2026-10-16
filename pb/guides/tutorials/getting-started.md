# Getting started

This tutorial takes you from a `.proto` file to encoding and decoding a message
in Elixir. It assumes you have `protoc` installed and a working Elixir project.

By the end you will have:

1. compiled a schema from a protobuf descriptor set,
2. encoded an Elixir map to protobuf bytes, and
3. decoded those bytes back into a map.

## 1. Add PB to your project

```elixir
def deps do
  [
    {:pb, "~> 0.1.0"}
  ]
end
```

Run `mix deps.get`.

## 2. Write a `.proto` file

Create `person.proto`:

```proto
syntax = "proto3";

package mypackage;

message Person {
  string name = 1;
  int32 id = 2;
}
```

## 3. Generate a descriptor set

PB does not use a `protoc` plugin and does not generate Elixir source. Instead it
reads the standard `FileDescriptorSet` that `protoc` already knows how to emit:

```sh
protoc --descriptor_set_out=schema.binpb --include_imports person.proto
```

`--include_imports` ensures the descriptor set is self-contained, including any
imported `.proto` files.

## 4. Compile the schema

`PB.decode_descriptor_set/1` turns the binary descriptor set into a plain Elixir
data structure, and `PB.compile/1` indexes it into a schema you can encode and
decode against:

```elixir
{:ok, descriptor_set} = PB.decode_descriptor_set(File.read!("schema.binpb"))
schema = PB.compile(descriptor_set)
```

This is not code generation — `compile/1` builds lookup tables for O(1) field
resolution. The result is just data.

## 5. Encode a message

Messages are ordinary Elixir maps with atom keys. Fully-qualified message names
are atoms like `:"mypackage.Person"`:

```elixir
{:ok, binary} = PB.encode(%{name: "Alice", id: 42}, schema, :"mypackage.Person")
```

## 6. Decode it back

```elixir
{:ok, person} = PB.decode(binary, schema, :"mypackage.Person")
# => %{name: "Alice", id: 42}
```

That is the whole round trip. Fields that were not set are simply absent from the
decoded map (see [Data representation](data-representation.md) for the details on
presence, defaults, enums, oneofs, and maps).

## 7. Recommended: embed the schema at compile time

Steps 4–6 use the runtime `PB.compile/1` path. That path is the clearest way to
see PB's model — *the schema is just data* — and it is the right choice when a
schema is loaded or chosen dynamically.

For a **stable schema, which is the common case, embed it at compile time** with
`use PB.Schema`. You get the same API without reading and compiling a descriptor
set at runtime:

```elixir
defmodule MyApp.Schema do
  use PB.Schema, descriptor: "priv/proto/schema.binpb"
end

{:ok, binary} = MyApp.Schema.encode(%{name: "Alice", id: 42}, :"mypackage.Person")
{:ok, person} = MyApp.Schema.decode(binary, :"mypackage.Person")
# => %{name: "Alice", id: 42}
```

This is the path most applications should reach for. See
[Schema modules](schema-modules.md) for the full surface.

## Where to go next

- To make decoded data look like your domain (structs instead of maps, native
  `DateTime` for timestamps), see
  [Decoding into structs](structs-and-representation.md) and
  [Adapters and well-known types](adapters-and-well-known-types.md).
- For the full set of representation rules, read the
  [Data representation reference](data-representation.md).
