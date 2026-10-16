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
  files. Always pass it unless you have a specific reason not to — PB needs every
  referenced type present to resolve fields.

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

buf images are `FileDescriptorSet`-compatible and load the same way.

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
