#!/bin/bash
set -xe

cd "$(dirname "$0")"
mkdir -p test/fixtures/schema

buf build proto/cel.proto --as-file-descriptor-set --exclude-source-info -o priv/cel.binpb
buf build proto/test.proto --as-file-descriptor-set -o test/fixtures/schema/test.binpb
