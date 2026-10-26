#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEL_SPEC_REPO="${CEL_SPEC_REPO:-https://github.com/google/cel-spec}"
CEL_SPEC_REF="${CEL_SPEC_REF:-v0.25.1}"
OUT_DIR="${CEL_CONFORMANCE_DIR:-"$ROOT/test/fixtures/cel_conformance"}"

CEL_SPEC_BSR_COMMIT="${CEL_SPEC_BSR_COMMIT:-}"
if [[ -z "$CEL_SPEC_BSR_COMMIT" ]]; then
  CEL_SPEC_BSR_COMMIT="$(
    awk '
      $0 ~ /name: buf.build\/google\/cel-spec/ { found = 1; next }
      found && $0 ~ /commit:/ { print $2; exit }
    ' "$ROOT/buf.lock"
  )"
fi

SCHEMA_INPUT="${CEL_SPEC_SCHEMA_INPUT:-buf.build/google/cel-spec:${CEL_SPEC_BSR_COMMIT}}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pb-cel-conformance.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

SRC_DIR="$TMP_DIR/cel-spec"
mkdir -p "$SRC_DIR"

curl -L --fail --silent --show-error \
  "$CEL_SPEC_REPO/archive/${CEL_SPEC_REF}.tar.gz" |
  tar -xz --strip-components=1 -C "$SRC_DIR"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/simple"

manifest="$OUT_DIR/manifest.term"

{
  printf '%%{\n'
  printf '  repo: "%s",\n' "$CEL_SPEC_REPO"
  printf '  ref: "%s",\n' "$CEL_SPEC_REF"
  printf '  schema_input: "%s",\n' "$SCHEMA_INPUT"
  printf '  fixtures: [\n'
} >"$manifest"

simple_type="cel.expr.conformance.test.SimpleTestFile"
simple_dir="$SRC_DIR/tests/simple/testdata"

find "$simple_dir" -name '*.textproto' -type f | sort | while IFS= read -r source; do
  name="$(basename "$source" .textproto)"
  rel_source="tests/simple/testdata/${name}.textproto"
  rel_output="simple/${name}.binpb"
  output="$OUT_DIR/$rel_output"

  buf convert "$SCHEMA_INPUT" \
    --type="$simple_type" \
    --from="$source#format=txtpb" \
    --to="$output#format=binpb"

  sha256="$(shasum -a 256 "$output" | awk '{ print $1 }')"

  # Keep the text source too: PB.TextFormat must decode it to the same value.
  rel_text="simple/${name}.textproto"
  cp "$source" "$OUT_DIR/$rel_text"
  text_sha256="$(shasum -a 256 "$OUT_DIR/$rel_text" | awk '{ print $1 }')"

  printf '    %%{suite: :simple, type: "%s", source: "%s", output: "%s", sha256: "%s", text: "%s", text_sha256: "%s"},\n' \
    "$simple_type" "$rel_source" "$rel_output" "$sha256" "$rel_text" "$text_sha256" >>"$manifest"
done

{
  printf '  ]\n'
  printf '}\n'
} >>"$manifest"

echo "Wrote CEL conformance fixtures to $OUT_DIR"
