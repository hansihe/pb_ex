# Generating a descriptor set

PB reads standard protobuf `FileDescriptorSet` images — the same artifact any
protobuf toolchain can produce. There is no PB-specific `protoc` plugin and no
generated Elixir source.

## With protoc

```sh
protoc --descriptor_set_out=schema.binpb --include_imports your.proto
```

- `--descriptor_set_out` writes the binary `FileDescriptorSet`.
- `--include_imports` makes the set self-contained by including imported `.proto`
  files. Always pass it: PB needs every imported file, both to resolve the types
  it defines and to decode the custom options it defines, so `PB.compile/2`
  rejects a set that lacks one (see [Missing imports](#missing-imports)).

Load and compile it:

```elixir
{:ok, descriptor_set} = PB.decode_descriptor_set(File.read!("schema.binpb"))
schema = PB.compile(descriptor_set)
```

A bang variant `PB.decode_descriptor_set!/1` is also available.

## With buf

If you use [buf](https://buf.build), produce a descriptor set (an "image") with:

```sh
buf build -o schema.binpb
```

buf images are `FileDescriptorSet`-compatible and load the same way. They
include the imported files unless you pass `--exclude-imports`, except those
imported with `import option` (see [Missing imports](#missing-imports)).

## Missing imports

`PB.compile/2` raises a `PB.SchemaError` (`kind: :missing_imports`) when a file
in the set imports a file the set doesn't contain, listing every missing import:

```text
PB failed to compile: descriptor set is missing imported files: "orders.proto"
imports "buf/validate/validate.proto". Build the set with its imports ...
```

Without the imported file, the custom options it defines — such as the
`buf.validate` rules that [pb_validate](https://hexdocs.pm/pb_validate) reads —
could only stay undecoded, so rebuilding the set with its imports is almost
always the fix. Weak imports may be missing.

So may the files an edition 2024 file imports with `import option`: `buf build`
never includes them, even without `--exclude-imports`. The options they define
then stay unknown fields (`:__unknown_fields__`) of the descriptor options. A set
built with `protoc --include_imports` includes them, and `PB.compile/2` decodes
their options.

If the set deliberately leaves out imports that nothing needs, such as an
option-only import like `google/api/annotations.proto` whose HTTP annotations
you don't use, compile it with `allow_missing_imports: true`:

```elixir
schema = PB.compile(descriptor_set, allow_missing_imports: true)
```

`use PB.Schema` takes the same option. The options a missing file defines then
stay unknown fields (`:__unknown_fields__`) of the descriptor options, and a
field whose type a missing file defines still fails to compile.

## Custom representation options in proto source

If you want to declare Elixir representation (`struct:`, `unwrap:`, identity
oneofs) directly in your `.proto` files rather than at compile time, import
`elixir/pb/v1/options.proto` and set the `elixir.pb.v1` custom options. Those options
travel inside the descriptor set and are picked up by `PB.compile/2`. See
[Decoding into structs](structs-and-representation.md) for the option surface.

## Embedding at compile time

Loading the descriptor set at runtime is fine for dynamic schemas. For a stable
schema, embed it into a module at compile time with `use PB.Schema` — see
[Schema modules](schema-modules.md).
