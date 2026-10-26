# Encoding and decoding semantics

This page explains the conceptual model PB upholds when it encodes and decodes —
the *why* behind behaviours you will observe, such as when defaults appear and why
validation runs where it does. It is independent of any particular runtime detail.
For the byte-level type mapping, see the
[Data representation reference](../reference/data-representation.md).

## Layers PB keeps distinct

- **Wire occurrences** — raw field records in the byte stream. A field may occur
  zero, one, or many times.
- **Logical message values** — the value after occurrences are interpreted and
  merged.
- **Presence** — whether a field was actually present, kept separate from the
  field's default value.
- **Presentation values** — what callers receive, optionally with materialized
  defaults.
- **PB metadata** — reserved dunder keys (`:__unknown_fields__`, `:__extensions__`,
  `:__message_name__`), never confused with real fields.

The central invariant: **defaults must not erase presence.** A materialized
default is presentation, not a present value, so it never participates in merge,
required-field checks, oneof selection, or presence-sensitive validation as if it
had been on the wire.

## Decode, conceptually

1. **Scan** — read tags in wire order, tolerating any order, preserving unknown
   fields as raw bytes, and resolving known fields and extensions.
2. **Interpret & merge** — apply protobuf merge semantics: singular scalars are
   last-write-wins, singular messages merge, repeated fields append (packed and
   unpacked both), oneofs keep one active member, map entries collapse with
   last-key-wins.
3. **Finalize** — collapse map entries, wrap oneofs, check required fields, keep
   presence distinct from defaults, and apply caller-facing defaults only if
   `defaults: true` was requested.
4. **Validate** — runs on the *post-merge* logical message, never on individual
   occurrences.

Validation after merge matters. These two wire occurrences:

```text
child { name: "a" }
child { id: 123 }
```

merge to `%{child: %{name: "a", id: 123}}`. If `Child.id` is required, validating
the first occurrence alone would wrongly reject the message; PB validates the
merged value.

## Encode, conceptually

Encode has no merge stage — the caller supplies an already-logical value.

1. **Adapt** — convert application values to protobuf logical values where
   adapters are configured (errors keep the logical field path).
2. **Validate** — check map shape, required fields, scalar ranges, enum rules,
   oneof selection, and run protovalidate against the logical value.
3. **Elide & handle presence** — implicit-presence defaults are omitted;
   explicit-presence fields encode even when equal to the default; empty
   repeated/map fields emit nothing; oneofs encode only the selected member.
   Presence is determined from the caller's input, not by comparing to a default.
4. **Construct wire bytes** — correct tags and wire types, packed/expanded
   repeated encoding per schema, map entries as repeated messages, extensions as
   normal fields, unknown fields as preserved raw bytes.

Field order is not semantically meaningful; stable ordering is only useful for
tests and reproducibility.

## Further reading

The full semantic specification, including the internal scan/finalize model and
schema compile/prepare phases, lives in the repository design notes
(`docs/semantics.md`).
