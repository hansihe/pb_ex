#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROTOVALIDATE_CONFORMANCE_DIR="${PROTOVALIDATE_CONFORMANCE_DIR:-"$ROOT/test/fixtures/protovalidate_conformance"}"
PROTOVALIDATE_CONFORMANCE_EXPECTED_FAILURES="${PROTOVALIDATE_CONFORMANCE_EXPECTED_FAILURES:-"$PROTOVALIDATE_CONFORMANCE_DIR/expected_failures.yaml"}"

HARNESS="${PROTOVALIDATE_CONFORMANCE_BIN:-}"

if [[ -z "$HARNESS" ]]; then
  HARNESS="$("$ROOT/scripts/build_protovalidate_conformance.sh")"
fi

"$ROOT/build_protos.sh" >&2

MIX_ENV=test mix compile >&2

BUILD_DIR="$ROOT/tmp/protovalidate_conformance"
TESTEE="$BUILD_DIR/pb_protovalidate_testee"
mkdir -p "$BUILD_DIR"

cat >"$TESTEE" <<EOF
#!/usr/bin/env sh
cd "$ROOT"
exec env MIX_ENV=test mix run --no-compile --no-deps-check \\
  -e 'PB.TestSupport.ProtovalidateConformance.Testee.main()'
EOF

chmod +x "$TESTEE"

runner_args=()

if [[ -f "$PROTOVALIDATE_CONFORMANCE_EXPECTED_FAILURES" ]]; then
  runner_args+=(--expected_failures "$PROTOVALIDATE_CONFORMANCE_EXPECTED_FAILURES")
fi

runner_args+=("$@")
runner_args+=("$TESTEE")

"$HARNESS" "${runner_args[@]}"
