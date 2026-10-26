# Conformance status

[`cel_ex`](https://hexdocs.pm/cel_ex), the CEL implementation, runs the
upstream [cel-spec](https://github.com/google/cel-spec) simple conformance
suite through parser, checker, and evaluator harnesses. The runner lives in
pb_cel because the fixtures are protobuf messages, and evaluates them with
`PB.CEL.types/1`. The fixtures are fetched with
`scripts/fetch_cel_conformance.sh`. Intentionally unsupported areas are
tracked as named buckets in `test/pb/cel/conformance_test.exs`:

- The proto2 extension `proto.getExt`/`proto.hasExt` macro form (the
  `proto2_ext` fixture) is out of scope. The select form — `` msg.`pkg.ext` ``
  and `` has(msg.`pkg.ext`) `` — is supported.
- Optimizer-shaped block tests are out of scope for now (they use test-only
  macros such as `cel.block`, `cel.index`, `cel.iterVar`).
- `disable_check` eval cases require an unchecked/dynamic evaluation mode;
  cel_ex evaluates checked CEL IR.
- Legacy enum behavior and weak enum field typing are not targeted; PB.CEL
  uses stronger schema-backed enum typing.
- CEL `==`/`!=` on `google.protobuf.Any` values should unpack both sides and
  compare the wrapped messages structurally. PB.CEL passes the upstream
  `any_unpack` cases because an `Any` literal is unpacked when evaluated and
  packed again canonically, but it does not unpack `Any` fields when comparing
  messages, so ones decoded from differently serialized bytes compare unequal.

Check-only conformance cases are used for checker coverage and are not evaluator
failures.

The upstream `.textproto` source of each fixture must also decode with
`PB.TextFormat` to the same value as its committed `buf convert` output and
print back to it.
