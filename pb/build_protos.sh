#!/bin/bash
set -xe

mkdir -p test/fixtures/schema

buf build proto/bootstrap.proto --as-file-descriptor-set --exclude-source-info -o priv/bootstrap.binpb
buf build proto/main.proto --as-file-descriptor-set -o priv/main.binpb
buf build proto/test.proto --as-file-descriptor-set -o test/fixtures/schema/test.binpb
buf build proto/imports.proto --as-file-descriptor-set -o test/fixtures/schema/imports.binpb
