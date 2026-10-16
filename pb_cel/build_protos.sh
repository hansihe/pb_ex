#!/bin/bash
set -xe

mkdir -p test/fixtures/schema

buf build proto/test.proto --as-file-descriptor-set -o test/fixtures/schema/test.binpb
