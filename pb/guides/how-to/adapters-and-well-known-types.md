# Adapters and well-known types

An **adapter** maps a protobuf message to a native Elixir value and back — for
example `google.protobuf.Timestamp` to a timestamp tuple, or a custom message to
a domain value. Adapters are *semantic* conversions, distinct from the
*structural* representation options covered in
[Decoding into structs](structs-and-representation.md). See
[Representation vs adapters](../explanation/representation-vs-adapters.md) for the
distinction.

## The adapter contract

An adapter is a `PB.Adapter` struct with two `{module, function}` MFAs, each
returning `{:ok, value} | {:error, reason}`:

```elixir
adapter =
  %PB.Adapter{
    to_proto: {MyApp.TimestampCodec, :to_proto},     # app value -> field map
    from_proto: {MyApp.TimestampCodec, :from_proto},  # field map -> app value
    type: quote(do: DateTime.t())                     # optional typespec, for docs
  }
```

Register it for a fully-qualified message name via the `:projections` option:

```elixir
PB.compile(descriptor_set,
  projections: [{:"google.protobuf.Timestamp", adapter: adapter}]
)
```

Adapted message fields decode to the adapter's Elixir value and encode from that
same value. The callbacks convert one message level at a time; PB still owns
wire encoding and decoding, and PB still recurses into child messages.

That recursion rule matters for nested adapted messages:

- `from_proto` receives a field map whose message-typed children have already
  been converted to their native representation.
- `to_proto` must return a field map whose message-typed children are still in
  their native representation. Do not pre-convert child messages to protobuf
  maps inside the adapter.

### Invariants

Adapters are deliberately constrained so you cannot validate against a different
shape than you encode against:

- **Adapters live only on the schema provider** — declared once via
  `PB.compile/2` or `use PB.Schema`. No per-call or field-level overrides.
- **Adapters are bidirectional, always** — every adapter declares both
  `from_proto` and `to_proto`. CEL field reads, encoding, and validation all
  reuse the same `to_proto` transform.

## Built-in well-known type adapters

`PB.WellKnownTypes.projections/1` returns ready-to-use `:projections` entries for
groups of well-known types. They are opt-in — nothing is forced on a schema that
does not register them.

```elixir
PB.compile(descriptor_set,
  projections: PB.WellKnownTypes.projections([:time, :wrappers, :json])
)
```

The groups are:

- `:time` — `google.protobuf.Timestamp` → `{:timestamp, unix_nanoseconds}` and
  `google.protobuf.Duration` → `{:duration, nanoseconds}`. Integer nanoseconds
  keep protobuf precision intact (see `PB.WellKnownTypes`).
- `:wrappers` — `google.protobuf.Int32Value` and friends unwrap to their scalar.
- `:json` — `google.protobuf.Value`/`Struct`/`ListValue` map to JSON-compatible
  Elixir terms.

If you want lossy but friendlier forms — e.g. `DateTime` instead of a nanosecond
tuple — write a custom adapter, as in the contract example above.

## Adapters and validation

Because validation reads through the same adapters as encode, protovalidate rules
see the value you actually hand to `PB.encode/4`. CEL unwraps adapted messages
lazily and shallowly: the adapter's `to_proto` runs only when an expression
selects into that message. See [Validation](validation.md).
