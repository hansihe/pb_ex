# Validating with protovalidate

`PB.Validate` runs [protovalidate](https://github.com/bufbuild/protovalidate)
rules at runtime. Rules are read from the same schema you encode against and
applied through the same projections and adapters, so the value being validated is
exactly the value you hand to `PB.encode/4`.

## Annotate rules in proto source

protovalidate rules are declared with `buf.validate` options in your `.proto`
files:

```proto
import "buf/validate/validate.proto";

message Person {
  string name  = 1 [(buf.validate.field).string.min_len = 1];
  int32  age   = 2 [(buf.validate.field).int32.gte = 0];
  string email = 3 [(buf.validate.field).string.email = true];
}
```

Generate the descriptor set with `--include_imports` so the validation
descriptors travel with it, then compile as usual.

## Validate a message

```elixir
case PB.Validate.validate(person, schema, :"mypackage.Person") do
  :ok ->
    :ok

  {:error, %PB.Validate.Error{violations: violations}} ->
    # each is a %PB.Validate.Violation{}
    {:error, violations}
end
```

`validate/3` returns `:ok` or `{:error, %PB.Validate.Error{}}`. A bang variant
`validate!/3` raises on violations. Schema modules expose `validate/2,3` directly.

The input is the same public term shape accepted by `PB.encode/4`: canonical maps,
represented structs, identity oneofs, unwrapped messages, and adapted values are
each projected one message layer at a time before field, message, and CEL rules
read protobuf fields.

## Errors vs violations

A *violation* (a rule that the message failed) is data: it comes back in
`{:error, %PB.Validate.Error{}}`. A *caller-contract or evaluation* problem is
raised instead — an unknown validation message, a message-name metadata mismatch,
non-map input, or a projection failure raises a `PB.Error`
(`PB.SchemaError`/`PB.ValueError`) with `operation: :validate`, and a CEL
constraint that fails at runtime raises `PB.CEL.Error`. Match on
`%PB.Validate.Violation{}` for rule results; let contract errors surface.

## Conformance

PB passes the full upstream protovalidate conformance suite at its pinned commit.
See [Conformance status](../reference/conformance.md).

## CEL expression rules

protovalidate's `cel` rules are evaluated by PB's built-in CEL engine against
proto-shaped values. Registering your own functions callable from those
expressions is supported, but that API is still being reshaped and is not part
of the published interface yet; it is planned for a later release.
