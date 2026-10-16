#!/usr/bin/env bash
set -euo pipefail

# Generates priv/descriptor.binpb from protoc's bundled descriptor.proto.
# This is a one-time/rare regeneration, not a build step.

if ! command -v protoc &>/dev/null; then
  echo "error: protoc not found on PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

mkdir -p "$PROJECT_ROOT/priv"
protoc --descriptor_set_out="$PROJECT_ROOT/priv/descriptor.binpb" \
       --include_imports \
       google/protobuf/descriptor.proto

echo "Generated priv/descriptor.binpb ($(wc -c < "$PROJECT_ROOT/priv/descriptor.binpb") bytes)"
