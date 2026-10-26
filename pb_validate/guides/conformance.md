# Conformance status

`PB.Validate` runs the upstream
[protovalidate](https://github.com/bufbuild/protovalidate) conformance suite
with `scripts/run_protovalidate_conformance.sh`, which needs Go to build the
harness and `buf` to rebuild the descriptor fixtures.

Expected failures are tracked in
`test/fixtures/protovalidate_conformance/expected_failures.yaml`. At the pinned
upstream `bufbuild/protovalidate` commit, the current baseline passes all cases:

```text
PASS (failed: 0, skipped: 0, passed: 2872, total: 2872)
```
