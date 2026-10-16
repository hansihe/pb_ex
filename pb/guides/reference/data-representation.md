# Data representation

PB's default public representation is the canonical protobuf-shaped Elixir map.
This page is the reference for how every protobuf construct maps to Elixir values
on encode and decode.

For application-friendly shapes (structs, sum types, unwrapped wrappers) see
[Decoding into structs](../how-to/structs-and-representation.md). For semantic
conversions such as timestamps to `DateTime` see
[Adapters and well-known types](../how-to/adapters-and-well-known-types.md).

## Supported types

| Proto type    | Wire format       | Elixir type        |
|---------------|-------------------|--------------------|
| `double`      | 64-bit LE         | `float`            |
| `float`       | 32-bit LE         | `float`            |
| `int32/64`    | varint            | `integer`          |
| `uint32/64`   | varint            | `integer`          |
| `sint32/64`   | zigzag varint     | `integer`          |
| `fixed32/64`  | 32/64-bit LE      | `integer`          |
| `sfixed32/64` | 32/64-bit LE      | `integer`          |
| `bool`        | varint            | `boolean`          |
| `string`      | length-delimited  | `String.t()`       |
| `bytes`       | length-delimited  | `binary`           |
| `enum`        | varint            | `atom \| integer`  |
| `message`     | length-delimited  | `map`              |
| `group`       | delimited         | `map`              |

Groups (`TYPE_GROUP`) use the delimited wire format and decode to the same map
representation as nested messages.

## Scalar fields

Missing fields are omitted from decoded maps by default. Pass `defaults: true` to
`PB.decode/4` to populate missing fields with proto3 default values:

```elixir
{:ok, person} = PB.decode(data, schema, :"mypackage.Person", defaults: true)
# => %{name: "", id: 0, role: :UNKNOWN, scores: [], tags: %{}}
```

Singular message fields and oneofs are never populated by `:defaults`.

## Repeated fields

Decoded as lists. Packed encoding is handled transparently.

```elixir
%{scores: [100, 95, 88]}
```

## Enums

Atoms on encode and decode. Unknown values fall back to raw integers.

```elixir
# Encode -- both work:
%{role: :ADMIN}
%{role: 1}

# Decode:
%{role: :ADMIN}   # known value
%{role: 42}       # unknown value
```

## Oneofs

Tagged tuples under the oneof name:

```elixir
%{companion: {:pet, %{name: "Rex"}}}
```

If no oneof field is set, the key is absent from the map.

## Maps

Plain Elixir maps. The `map<K,V>` desugaring into repeated `MapEntry` messages is
handled internally.

```elixir
%{tags: %{"team" => 1, "level" => 5}}
```

## Reserved metadata keys

PB stores non-protobuf metadata under reserved dunder atom keys so it cannot
collide with real `.proto` field names. These atoms are the stable contract for
both encode input and decode output:

- `:__unknown_fields__` — preserved unknown wire fields, as a list of
  `PB.UnknownField` structs.
- `:__extensions__` — known extension field values, keyed by fully-qualified
  extension name.
- `:__message_name__` — optional message-name metadata produced by `PB.decode/4`
  when `message_names: :root` is set. When supplied on input to encode or
  validation APIs, it must match the message being processed.

Decode omits message-name metadata by default. Pass `message_names: :root` to
annotate only the root decoded message map. If the root message decodes through a
struct representation, unwrap representation, or adapter, there is no map layer to
annotate and no message-name metadata is added.

See [Extensions and unknown fields](../how-to/extensions-and-unknown-fields.md)
for working with these.

## Encode-time validation

`PB.encode/4` validates input before writing protobuf bytes. Unknown fields
return errors by default:

```elixir
PB.encode(%{name: "Alice", typo: 1}, schema, :"mypackage.Person")
# => {:error, %PB.Error{kind: :unknown_field, path: [:typo]}}
```

Pass `unknown_fields: :ignore` to drop unknown keys. Presence is controlled by
map keys: a missing key is absent, and a key set to `nil` is the same as a
missing one, for every kind of field (for oneofs, no selected variant). This
holds across encoding, ProtoJSON and text format, `PB.Validate` and
`PB.message_equal?/4`. The exception is a message field whose type has an
adapter: `nil` goes to the adapter, which may read it as a value (a
`google.protobuf.Value` field holding JSON `null`). Implicit-presence fields
set to their default are elided. String fields must be binaries, integer fields
are range checked, and PB does not validate UTF-8 in the core wire codec.

## Schema format (hand-written schemas)

`PB.decode_descriptor_set/1` produces a schema-source map from a `protoc` image,
but you can also write it by hand. It mirrors `google.protobuf.FileDescriptorSet`
using atom keys and atom values for all proto names:

```elixir
descriptor_set = %{
  file: [
    %{
      name: "test.proto",
      package: :test,
      syntax: :proto3,
      message_type: [
        %{
          name: :Person,
          field: [
            %{name: :name, number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL},
            %{name: :id,   number: 2, type: :TYPE_INT32,  label: :LABEL_OPTIONAL},
            %{name: :role, number: 3, type: :TYPE_ENUM,   label: :LABEL_OPTIONAL,
              type_name: :"test.Role"}
          ]
        }
      ],
      enum_type: [
        %{
          name: :Role,
          value: [
            %{name: :UNKNOWN, number: 0},
            %{name: :ADMIN,   number: 1}
          ]
        }
      ]
    }
  ]
}

schema = PB.compile(descriptor_set)
```
