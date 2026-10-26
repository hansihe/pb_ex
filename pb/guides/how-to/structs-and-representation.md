# Decoding into structs and sum types

By default messages decode into [canonical maps](../reference/data-representation.md).
**Term representation** lets a schema declare the Elixir shape a message decodes
into and encodes from — without changing wire semantics. The three structural
representations are:

- **Struct messages** — decode into a `%MyApp.User{}` instead of a map.
- **Identity oneofs** — represent a oneof by the value's struct identity instead
  of a `{:tag, value}` tuple.
- **Single-field unwrap** — collapse a one-field wrapper message into that field.

Representation is *structural and invertible*. For semantic conversions (a
timestamp message to a `DateTime`, `google.protobuf.Value` to JSON terms) use
[adapters](adapters-and-well-known-types.md) instead. See
[Representation vs adapters](../explanation/representation-vs-adapters.md) for
when to reach for which.

## Where to declare it

Structural representation can be declared in two places, and both compile to the
*same* plan — runtime code does not care which produced it. If both configure the
same message differently, compilation fails rather than applying precedence rules.

**Prefer proto source options when you own the schema.** They travel inside the
descriptor set, so the representation lives next to the message it describes, via
`elixir/pb/v1/options.proto`:

```proto
import "elixir/pb/v1/options.proto";

message User {
  option (elixir.pb.v1.message).struct = "MyApp.User";

  string id = 1;
}

message Event {
  oneof kind {
    option (elixir.pb.v1.oneof).representation = IDENTITY;

    Created created = 1;
    Deleted deleted = 2;
  }
}
```

**Use the compile-time `:projections` option for schemas you do not own** — and
for adapters, which need code and so cannot be expressed in proto source (see
[Adapters and well-known types](adapters-and-well-known-types.md)). It takes the
same structural options as an override, keyed by message name, on `PB.compile/2`
or `use PB.Schema`:

```elixir
PB.compile(descriptor_set,
  projections: [
    {:"my.pkg.User", struct: MyApp.User, preserved_unknown_fields: :drop, extensions: :reject},
    {:"my.pkg.Event", oneofs: [kind: [representation: :identity]]}
  ]
)
```

Within an entry, `adapter:` is mutually exclusive with the structural keys
`struct:`, `unwrap:`, `preserved_unknown_fields:`, `extensions:`, and `oneofs:`.

## Struct messages

```elixir
# struct: MyApp.User  =>  decode/encode use %MyApp.User{} instead of a map
%MyApp.User{id: "123"}
```

Struct field names must match protobuf field names. If decode could produce a
field the struct has no place for, compilation fails.

### Auxiliary data policies

Structs need explicit policies for data that is not an ordinary declared field:

Unknown wire fields (`preserved_unknown_fields:`), default `:drop`:

- `:drop` — discard unknown wire fields during decode.
- `:reject` — fail decode if unknown wire fields are present.
- `{:field, name}` — store preserved unknown fields in that struct field.

Known extensions (`extensions:`), default `:reject`:

- `:reject` — fail *compilation* if the message can receive known extensions.
- `{:field, name}` — store decoded extensions in that struct field.

The default (`preserved_unknown_fields: :drop, extensions: :reject`) keeps common
usage low-friction while refusing to silently lose schema-modeled extension data.
Use underscore-prefixed names for auxiliary fields by convention
(`_unknown_fields`, `_extensions`).

## Identity oneofs

The canonical tagged shape `%{kind: {:created, %{...}}}` becomes identity-based:

```elixir
%MyApp.Event{kind: %MyApp.Created{...}}
```

Encode inspects the struct module to choose the protobuf member. Constraints are
strict and checked at compile time:

- every member must be a message field,
- every member message must target a distinct struct, and
- scalar members are not currently supported.

## Single-field unwrap

A message with exactly one representable field can unwrap directly to that field:

```elixir
# canonical:  %{value: "abc"}
# unwrapped:  "abc"
```

This composes with struct and oneof representation (e.g. a oneof member whose
public value is its only field). It is rejected at compile time when unwrapping
would be ambiguous or would erase required presence information.

## What stays the same

Representation never changes wire semantics. Decode still scans, merges, applies
required-field and default rules, and *then* projects into the configured term
shape. CEL, protovalidate, and message equality all project through the same
single-message proto view used by encode, so what you validate matches what you
encode.
