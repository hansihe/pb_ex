#!/usr/bin/env bash
#
# Regenerate the benchmark's proto artifacts, run the PB-vs-protobuf suite, and
# splice the raw results into the docs reference page
# (guides/reference/benchmarks.md), between the BENCHMARK RESULTS markers.
#
# Usage:
#
#     bench/run.sh                 # full run (slow, publishable numbers)
#     BENCH_TIME=1 bench/run.sh    # quick pass while iterating
#
# Requires `protoc` and the `protoc-gen-elixir` escript (mix escript.install
# protobuf) on PATH or in ~/.mix/escripts.

set -euo pipefail

cd "$(dirname "$0")"                     # -> bench/
BENCH_DIR="$PWD"
PAGE="$BENCH_DIR/../guides/reference/benchmarks.md"

export PATH="$HOME/.mix/escripts:$PATH"

command -v protoc >/dev/null || { echo "protoc not found on PATH" >&2; exit 1; }
command -v protoc-gen-elixir >/dev/null || {
  echo "protoc-gen-elixir not found (try: mix escript.install hex protobuf)" >&2
  exit 1
}

echo "==> regenerating proto artifacts" >&2
protoc --descriptor_set_out=proto/pb_bench.binpb --include_imports \
       --proto_path=proto proto/pb_bench.proto
protoc --elixir_out=lib --proto_path=proto proto/pb_bench.proto

echo "==> fetching deps and compiling" >&2
mix deps.get >&2
mix compile >&2

echo "==> running suite (this takes a few minutes at full time)" >&2
# Capture stdout only — Benchee's formatted tables and the correctness gate.
# Compiler/dep noise goes to stderr and is left on the terminal.
RESULTS="$(mix run pb_vs_protobuf.exs)"

echo "==> splicing results into $(basename "$PAGE")" >&2
tmp="$(mktemp)"
RESULTS="$RESULTS" awk '
  /<!-- BENCHMARK RESULTS START -->/ {
    print
    print "```text"
    printf "%s\n", ENVIRON["RESULTS"]
    print "```"
    skip = 1
    next
  }
  /<!-- BENCHMARK RESULTS END -->/ { skip = 0; print; next }
  skip != 1 { print }
' "$PAGE" > "$tmp"
mv "$tmp" "$PAGE"

echo "==> done" >&2
