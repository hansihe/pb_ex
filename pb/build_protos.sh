#!/bin/bash
set -xe

mkdir -p test/fixtures/schema

buf build proto/bootstrap.proto --as-file-descriptor-set --exclude-source-info -o priv/bootstrap.binpb
buf build proto/main.proto --as-file-descriptor-set --exclude-source-info -o priv/main.binpb
buf build proto/test.proto --as-file-descriptor-set -o test/fixtures/schema/test.binpb
buf build proto/imports.proto --as-file-descriptor-set -o test/fixtures/schema/imports.binpb

# buf never includes the files a file imports with edition 2024's `import
# option`, so this set, which must contain them, is built with protoc.
protoc -I . --include_imports --descriptor_set_out=test/fixtures/schema/option_imports.binpb proto/option_imports.proto
