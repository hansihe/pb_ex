#!/bin/bash
set -xe

mkdir -p test/fixtures/schema

buf build proto/bootstrap.proto --as-file-descriptor-set --exclude-source-info -o priv/bootstrap.binpb
buf build proto/main.proto --as-file-descriptor-set -o priv/main.binpb
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
