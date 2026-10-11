# Conformance status

PB runs the upstream conformance suites for protobuf, CEL, and protovalidate.
This page records the current results and the intentionally unsupported areas.
The runner scripts and how to fetch testdata are documented in the repository
(`scripts/`, including `scripts/fetch_cel_conformance.sh`).

## Protocol Buffers

PB tracks expected failures in
`test/fixtures/protobuf_conformance/failures.txt`. The current edition `2023`
baseline passes with no unexpected failures.

Intentional deviations:

- `EditionUnstable` cases are expected failures: the current Buf/protobuf
  toolchain rejects the upstream `edition = "UNSTABLE"` fixture, and the fetch
  script drops it after ejection, so PB cannot import that message schema.
- Protobuf and JSON conformance cases both run. The two
  `JsonInput.FieldNameExtension.Validator` cases (proto2 and editions) are
  tracked as expected failures.
- JSPB conformance cases are intentionally skipped by the testee; PB does not
  implement that format.
- Text-format parsing (`PB.TextFormat`) is in progress. Its cases are tracked
  separately in `test/fixtures/protobuf_conformance/text_format_failures.txt`;
  the runner fails when a listed case starts passing, so the list only shrinks.
  Every parsing case passes; the text-output cases stay listed until a
  text-format printer exists. Separately, the upstream `.textproto` source of
  each CEL conformance fixture must decode with `PB.TextFormat` to the same
  value as its committed `buf convert` output.

## CEL

PB's CEL implementation runs the upstream simple conformance suite through
parser, checker, and evaluator harnesses. Intentionally unsupported areas are
tracked as named buckets in `test/pb/cel/conformance_test.exs`:

- The proto2 extension `proto.getExt`/`proto.hasExt` macro form (the
  `proto2_ext` fixture) is out of scope. The select form — `` msg.`pkg.ext` ``
  and `` has(msg.`pkg.ext`) `` — is supported.
- Optimizer-shaped block tests are out of scope for now (they use test-only
  macros such as `cel.block`, `cel.index`, `cel.iterVar`).
- `disable_check` eval cases require an unchecked/dynamic evaluation mode; PB
  evaluates checked CEL IR.
- Legacy enum behavior and weak enum field typing are not targeted; PB uses
  stronger schema-backed enum typing.
- CEL `==`/`!=` on `google.protobuf.Any` values should unpack both sides and
  compare the wrapped messages structurally; PB does not implement that
  unpack-on-equality step yet (4 `any_unpack` eval cases). Packing and field
  access on `Any` are otherwise supported.

Check-only conformance cases are used for checker coverage and are not evaluator
failures.

## Protovalidate

PB tracks expected failures in
`test/fixtures/protovalidate_conformance/expected_failures.yaml`. At the pinned
upstream `bufbuild/protovalidate` commit, the current baseline passes all cases:

```text
PASS (failed: 0, skipped: 0, passed: 2872, total: 2872)
```
