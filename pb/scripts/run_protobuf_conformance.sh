#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROTOBUF_CONFORMANCE_PACKAGE="${PROTOBUF_CONFORMANCE_PACKAGE:-protobuf-conformance}"
PROTOBUF_CONFORMANCE_VERSION="${PROTOBUF_CONFORMANCE_VERSION:-34.1.0}"
PROTOBUF_CONFORMANCE_DIR="${PROTOBUF_CONFORMANCE_DIR:-"$ROOT/test/fixtures/protobuf_conformance"}"
PROTOBUF_CONFORMANCE_MAXIMUM_EDITION="${PROTOBUF_CONFORMANCE_MAXIMUM_EDITION:-2023}"
PROTOBUF_CONFORMANCE_ENFORCE_RECOMMENDED="${PROTOBUF_CONFORMANCE_ENFORCE_RECOMMENDED:-1}"
PROTOBUF_CONFORMANCE_FAILURE_LIST="${PROTOBUF_CONFORMANCE_FAILURE_LIST:-"$PROTOBUF_CONFORMANCE_DIR/failures.txt"}"
PROTOBUF_CONFORMANCE_TEXT_FORMAT_FAILURE_LIST="${PROTOBUF_CONFORMANCE_TEXT_FORMAT_FAILURE_LIST:-"$PROTOBUF_CONFORMANCE_DIR/text_format_failures.txt"}"

export npm_config_cache="${npm_config_cache:-${NPM_CONFIG_CACHE:-"${TMPDIR:-/tmp}/pb-npm-cache"}}"

if [[ ! -f "$PROTOBUF_CONFORMANCE_DIR/proto/conformance/conformance.proto" ]]; then
  "$ROOT/scripts/fetch_protobuf_conformance.sh"
fi

"$ROOT/build_protos.sh"

MIX_ENV=test mix compile

BUILD_DIR="$ROOT/tmp/protobuf_conformance"
TESTEE="$BUILD_DIR/pb_protobuf_testee"
mkdir -p "$BUILD_DIR"

cat >"$TESTEE" <<EOF
#!/usr/bin/env sh
cd "$ROOT"
exec env MIX_ENV=test mix run --no-compile --no-deps-check \\
  -e 'PB.TestSupport.ProtobufConformance.Testee.main()'
EOF

chmod +x "$TESTEE"

runner_args=()

if [[ -n "$PROTOBUF_CONFORMANCE_MAXIMUM_EDITION" ]]; then
  runner_args+=(--maximum_edition "$PROTOBUF_CONFORMANCE_MAXIMUM_EDITION")
fi

if [[ -f "$PROTOBUF_CONFORMANCE_FAILURE_LIST" ]]; then
  runner_args+=(--failure_list "$PROTOBUF_CONFORMANCE_FAILURE_LIST")
fi

if [[ -f "$PROTOBUF_CONFORMANCE_TEXT_FORMAT_FAILURE_LIST" ]]; then
  runner_args+=(--text_format_failure_list "$PROTOBUF_CONFORMANCE_TEXT_FORMAT_FAILURE_LIST")
fi

case "$PROTOBUF_CONFORMANCE_ENFORCE_RECOMMENDED" in
  "" | 0 | false | FALSE | no | NO)
    ;;
  *)
    runner_args+=(--enforce_recommended)
    ;;
esac

runner_args+=("$@")
runner_args+=("$TESTEE")

if [[ -n "${CONFORMANCE_TEST_RUNNER:-}" ]]; then
  "$CONFORMANCE_TEST_RUNNER" "${runner_args[@]}"
else
  npm exec --yes --package "${PROTOBUF_CONFORMANCE_PACKAGE}@${PROTOBUF_CONFORMANCE_VERSION}" -- \
    conformance_test_runner "${runner_args[@]}"
fi
