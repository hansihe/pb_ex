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
# An edition 2024 file that imports buf/validate/validate.proto with `import
# option`, which buf never includes in the set.
buf build proto/validate_option_import.proto --as-file-descriptor-set -o test/fixtures/schema/validate_option_import.binpb

# The same sets without buf/validate/validate.proto (and the files only it
# imports), as a set built without its imports lacks it. The set for
# validate_custom_predefined keeps google/protobuf/wrappers.proto, which the type
# of one of its extensions comes from, taken from the set with imports. A
# FileDescriptorSet is one repeated field, so two sets written one after the
# other read as one set with the files of both.
buf build proto/validate_structural.proto --as-file-descriptor-set --exclude-imports -o test/fixtures/schema/validate_structural_no_imports.binpb
{
  buf build proto/validate_custom_predefined.proto -o - |
    buf build -#format=binpb --path google/protobuf/wrappers.proto --as-file-descriptor-set -o -
  buf build proto/validate_custom_predefined.proto --as-file-descriptor-set --exclude-imports -o -
} > test/fixtures/schema/validate_custom_predefined_no_imports.binpb
