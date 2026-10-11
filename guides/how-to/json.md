# Encoding and decoding JSON

`PB.JSON` implements ProtoJSON — the canonical protobuf JSON mapping — on top of
the same compiled schema you use for the wire codec.

## String in, string out

The headline API works with JSON binary strings:

```elixir
{:ok, json}    = PB.JSON.encode(%{name: "Alice", id: 42}, schema, :"mypackage.Person")
{:ok, decoded} = PB.JSON.decode(json, schema, :"mypackage.Person")
```

Parsing and serialisation use OTP's built-in `:json` module (OTP 27+) with two
ProtoJSON-required customisations: JSON `null` maps to Elixir `nil` (not `:null`),
and duplicate JSON object keys are rejected as `kind: :malformed_json` rather than
silently keeping the last one.

Bang variants `encode!/4` and `decode!/4` are available.

## Term in, term out

When composing with another JSON library, or asserting on the JSON shape
directly, use the term-level surface. `to_term/4` returns a JSON-compatible Elixir
term (maps, lists, strings, numbers, booleans, `nil`); `from_term/4` accepts one:

```elixir
{:ok, term} = PB.JSON.to_term(%{name: "Alice"}, schema, :"mypackage.Person")
# => %{"name" => "Alice"}
```

## Projections apply

Like the wire codec, JSON honors the schema's configured projections. Under a
struct/unwrap representation or an adapter, the value may be a struct, a tuple, or
a bare scalar rather than a plain map. See
[Decoding into structs](structs-and-representation.md) and
[Adapters and well-known types](adapters-and-well-known-types.md).

## Well-known types

PB applies the ProtoJSON mappings for well-known types automatically: wrapper
messages serialise as their bare scalar; `Duration` as a decimal-seconds string
ending in `"s"`; `Timestamp` as an RFC 3339 UTC string ending in `"Z"`;
`FieldMask` as a comma-separated lowerCamelCase path string; `Value`/`Struct`/
`ListValue` as bare JSON values, objects, and arrays; and `Any` as an object with
a `@type` URL.

## Options

Encode (`encode/4`, `to_term/4`) accepts:

- `:emit_defaults` — emit present-less fields at their default value
  (default `false`).
- `:use_proto_names` — emit snake_case field names instead of lowerCamelCase
  (default `false`; parsers always accept both).
- `:enums_as_ints` — emit enum numeric values instead of names (default `false`).

Both directions accept:

- `:unknown_fields` — `:error` (the default) returns a `kind: :unknown_field`
  error for a key the message does not define; `:ignore` skips it. On decode,
  `:ignore` also skips enum strings the enum does not declare.

Options are validated per direction: a typo, a wrong-direction option, or a
value the option does not take returns a `PB.OptionError` rather than being
silently ignored.
