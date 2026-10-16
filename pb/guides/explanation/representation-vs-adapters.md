# Representation vs adapters

PB offers two ways to make decoded data look like your domain rather than a raw
protobuf map. They are easy to confuse, so this page draws the line.

## The distinction

**Representation is structural.** It re-shapes the *same* protobuf data into a
different Elixir container, mechanically and invertibly:

- map vs struct,
- tagged oneof vs identity oneof,
- wrapper message vs unwrapped field,
- auxiliary-data storage or rejection.

**Adapters are semantic.** They change the *value domain* and need code:

- a timestamp message to `{:timestamp, nanoseconds}`,
- a duration message to `{:duration, nanoseconds}`,
- `google.protobuf.Value` to JSON-compatible terms,
- any application-specific conversion.

## How to choose

> If a conversion can be described as a static, mechanical plan, prefer
> **representation**. If it needs arbitrary logic, use an **adapter**.

The two should not overlap casually. Representation options never run your code;
they are validated entirely at compile time and fail there if a shape is
ambiguous. Adapters run your `to_proto`/`from_proto` MFAs at the message boundary.

## Why they share one principle

Both are declared **only on the schema provider** — never per call, never per
field. That is what makes it structurally impossible to validate against a
different shape than you encode against: CEL field reads, encoding, JSON, and
protovalidate all project through the same single-message proto view. See
[Adapters and well-known types](../how-to/adapters-and-well-known-types.md) and
[Decoding into structs](../how-to/structs-and-representation.md).

## Further reading

The full design rationale, including the constraints PB enforces at compile time,
lives in the repository design notes (`docs/term-representation.md`).
