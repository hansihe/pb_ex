#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROTOBUF_CONFORMANCE_PACKAGE="${PROTOBUF_CONFORMANCE_PACKAGE:-protobuf-conformance}"
PROTOBUF_CONFORMANCE_VERSION="${PROTOBUF_CONFORMANCE_VERSION:-34.1.0}"
OUT_DIR="${PROTOBUF_CONFORMANCE_DIR:-"$ROOT/test/fixtures/protobuf_conformance"}"

export npm_config_cache="${npm_config_cache:-${NPM_CONFIG_CACHE:-"${TMPDIR:-/tmp}/pb-npm-cache"}}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pb-protobuf-conformance.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

PROTO_DIR="$OUT_DIR/proto"
TMP_PROTO_DIR="$TMP_DIR/proto"

npm exec --yes --package "${PROTOBUF_CONFORMANCE_PACKAGE}@${PROTOBUF_CONFORMANCE_VERSION}" -- \
  conformance_proto_eject "$TMP_PROTO_DIR"

# The test schema intentionally targets edition 2023; current Buf rejects the
# upstream UNSTABLE edition fixture before PB can build the descriptor set.
rm -f "$TMP_PROTO_DIR/google/protobuf/test_messages_edition_unstable.proto"

rm -rf "$PROTO_DIR"
mkdir -p "$OUT_DIR"
mv "$TMP_PROTO_DIR" "$PROTO_DIR"

manifest="$OUT_DIR/manifest.term"

{
  printf '%%{\n'
  printf '  package: "%s",\n' "$PROTOBUF_CONFORMANCE_PACKAGE"
  printf '  version: "%s",\n' "$PROTOBUF_CONFORMANCE_VERSION"
  printf '  fixtures: [\n'
} >"$manifest"

find "$PROTO_DIR" -name '*.proto' -type f | sort | while IFS= read -r source; do
  rel_path="${source#"$OUT_DIR/"}"
  sha256="$(shasum -a 256 "$source" | awk '{ print $1 }')"

  printf '    %%{path: "%s", sha256: "%s"},\n' "$rel_path" "$sha256" >>"$manifest"
done

{
  printf '  ]\n'
  printf '}\n'
} >>"$manifest"

touch "$OUT_DIR/failures.txt" "$OUT_DIR/text_format_failures.txt"

echo "Wrote protobuf conformance protos to $PROTO_DIR"
