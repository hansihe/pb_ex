#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROTOVALIDATE_CONFORMANCE_REPO="${PROTOVALIDATE_CONFORMANCE_REPO:-https://github.com/bufbuild/protovalidate.git}"
PROTOVALIDATE_CONFORMANCE_REF="${PROTOVALIDATE_CONFORMANCE_REF:-6f020e0413e2527563d7ac96c93fd727075679da}"
PROTOVALIDATE_CONFORMANCE_SRC_DIR="${PROTOVALIDATE_CONFORMANCE_SRC_DIR:-"$ROOT/tmp/protovalidate_conformance_src"}"

BUILD_DIR="$ROOT/tmp/protovalidate_conformance"
BIN_DIR="$BUILD_DIR/bin"
BIN="$BIN_DIR/protovalidate-conformance"
STAMP="$BUILD_DIR/protovalidate-conformance.ref"

if [[ -x "$BIN" && -f "$STAMP" && "$(cat "$STAMP")" == "$PROTOVALIDATE_CONFORMANCE_REF" ]]; then
  printf '%s\n' "$BIN"
  exit 0
fi

mkdir -p "$BIN_DIR"

if [[ ! -d "$PROTOVALIDATE_CONFORMANCE_SRC_DIR/.git" ]]; then
  git clone "$PROTOVALIDATE_CONFORMANCE_REPO" "$PROTOVALIDATE_CONFORMANCE_SRC_DIR"
fi

git -C "$PROTOVALIDATE_CONFORMANCE_SRC_DIR" fetch --depth 1 origin "$PROTOVALIDATE_CONFORMANCE_REF"
git -C "$PROTOVALIDATE_CONFORMANCE_SRC_DIR" checkout --detach "$PROTOVALIDATE_CONFORMANCE_REF"

export GOPATH="${GOPATH:-"$BUILD_DIR/go"}"
export GOMODCACHE="${GOMODCACHE:-"$GOPATH/pkg/mod"}"
export GOCACHE="${GOCACHE:-"$BUILD_DIR/go-build"}"

go -C "$PROTOVALIDATE_CONFORMANCE_SRC_DIR/tools" build -o "$BIN" ./protovalidate-conformance
printf '%s\n' "$PROTOVALIDATE_CONFORMANCE_REF" >"$STAMP"
printf '%s\n' "$BIN"
