# Why data-driven (no code generation)

Most protobuf libraries run a `protoc` plugin that generates a struct (and often
a module) per message, committed to your source tree. PB deliberately does not.
Understanding why explains most of PB's API.

## The problem with a struct per message

On real Elixir codebases, schemas can carry thousands of messages. Emitting a
struct and module for each one means:

- generated source that dominates compile times,
- a build step and a generated tree to keep in sync, and
- a `protoc` plugin dependency in everyone's toolchain.

## PB's choice

PB treats the schema as **data at compile time** and messages as **ordinary
Elixir data at runtime**:

- **Messages flow as plain maps and primitives.** No generated struct per
  message. The ergonomic cost — no struct-shaped autocomplete — is real, and the
  intended payback is schema-derived typespecs (a materialized typespec view is
  on the roadmap).
- **Schemas are read directly from `FileDescriptorSet`.** No `protoc` plugin and
  no generated files in the tree. Because the schema is data, Elixir can do
  meaningful work with it — index it, slice it, introspect it, attach
  representations.
- **Runtime first.** `PB.encode/4` and `PB.decode/4` are the production path.
  (A generated-code path exists only under `test/support` for benchmarks and
  behaviour comparison; it does not define the public surface.)

## What you give up, and how it is paid back

You lose compile-time struct shapes by default. You get them back, selectively,
through two mechanisms layered on the same data-driven core:

- [Term representation](../how-to/structs-and-representation.md) — opt a message
  into a struct, sum type, or unwrapped value when you want a domain shape.
- [Adapters](../how-to/adapters-and-well-known-types.md) — map a message to a
  native Elixir value with a bidirectional contract.

Both are declared on the schema, so the value you validate is always the value
you encode. See [Representation vs adapters](representation-vs-adapters.md).
