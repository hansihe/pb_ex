# Conformance status

PB runs the upstream protobuf conformance suite. This page records the current
results and the intentionally unsupported areas. The runner scripts and how to
fetch testdata are documented in the repository (`scripts/`); the runner needs
`buf` and Node.js.

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
- Text-format conformance cases (`PB.TextFormat`) all pass. They have their
  own expected-failure list,
  `test/fixtures/protobuf_conformance/text_format_failures.txt`, which is
  currently empty; the runner fails when a listed case starts passing.
  When `protoc` is installed, the test suite also checks that
  `protoc --encode` reads PB's text output as the same value. `pb_cel` checks
  `PB.TextFormat` against the upstream `.textproto` sources of the CEL
  conformance fixtures.

## CEL

CEL over protobuf messages, and with it the upstream CEL conformance suite,
lives in [`pb_cel`](https://hexdocs.pm/pb_cel/conformance.html).

## Protovalidate

The protovalidate conformance suite runs in
[`pb_validate`](https://hexdocs.pm/pb_validate/conformance.html).
