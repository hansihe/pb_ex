#!/bin/bash
set -xe

mkdir -p test/fixtures/schema

buf build proto/bootstrap.proto --as-file-descriptor-set --exclude-source-info -o priv/bootstrap.binpb
buf build proto/main.proto --as-file-descriptor-set --exclude-source-info -o priv/main.binpb
# buf 1.72 has a bug: with descriptor.proto in the import graph, it drops
# `message_set_wire_format = true` and caps `extensions 4 to max` at 536870912
# rather than 2147483647. That hits MessageSetCorrect from protobuf's
# test_messages_proto2*.proto here; PB doesn't implement MessageSet, so nothing
# depends on it.
buf build proto/test.proto --as-file-descriptor-set -o test/fixtures/schema/test.binpb
buf build proto/imports.proto --as-file-descriptor-set -o test/fixtures/schema/imports.binpb

# buf never includes the files a file imports with edition 2024's `import
# option`, so this set, which must contain them, is built with protoc.
protoc -I . --include_imports --descriptor_set_out=test/fixtures/schema/option_imports.binpb proto/option_imports.proto
