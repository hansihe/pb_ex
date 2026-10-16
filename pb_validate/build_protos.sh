#!/bin/bash
set -xe

mkdir -p test/fixtures/schema

buf build proto/validate.proto --as-file-descriptor-set -o priv/validate.binpb
buf build proto/test.proto --as-file-descriptor-set -o test/fixtures/schema/test.binpb
buf build proto/protovalidate_probe.proto --as-file-descriptor-set -o test/fixtures/schema/protovalidate_probe.binpb
buf build proto/validate_phase2.proto --as-file-descriptor-set -o test/fixtures/schema/validate_phase2.binpb
buf build proto/validate_phase2_invalid.proto --as-file-descriptor-set -o test/fixtures/schema/validate_phase2_invalid.binpb
buf build proto/validate_predefined.proto --as-file-descriptor-set -o test/fixtures/schema/validate_predefined.binpb
buf build proto/validate_any_invalid.proto --as-file-descriptor-set -o test/fixtures/schema/validate_any_invalid.binpb
buf build proto/validate_rule_family_float_invalid.proto --as-file-descriptor-set -o test/fixtures/schema/validate_rule_family_float_invalid.binpb
buf build proto/validate_rule_family_duration_invalid.proto --as-file-descriptor-set -o test/fixtures/schema/validate_rule_family_duration_invalid.binpb
buf build proto/validate_custom_predefined.proto --as-file-descriptor-set -o test/fixtures/schema/validate_custom_predefined.binpb
buf build proto/validate_structural.proto --as-file-descriptor-set -o test/fixtures/schema/validate_structural.binpb
buf build proto/validate_structural_oneof_duplicate_invalid.proto --as-file-descriptor-set -o test/fixtures/schema/validate_structural_oneof_duplicate_invalid.binpb
buf build proto/validate_structural_oneof_zero_invalid.proto --as-file-descriptor-set -o test/fixtures/schema/validate_structural_oneof_zero_invalid.binpb

# The same sets without buf/validate/validate.proto (and the files only it
# imports), as a set built without --include_imports lacks it, keeping the
# well-known types the protos use.
for name in validate_structural validate_custom_predefined; do
  (cd ../pb && mix run scripts/subset_descriptor_set.exs \
    "../pb_validate/test/fixtures/schema/$name.binpb" "proto/$name.proto" \
    "../pb_validate/test/fixtures/schema/${name}_no_imports.binpb" \
    --drop buf/validate/validate.proto \
    --drop google/protobuf/descriptor.proto \
    --drop google/protobuf/duration.proto \
    --drop google/protobuf/field_mask.proto \
    --drop google/protobuf/timestamp.proto)
done
