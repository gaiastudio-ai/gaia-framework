#!/usr/bin/env bats
# stacks-schema.bats — E85-S14 coverage for the stacks[] 4-field schema delta.
#
# Story: E85-S14 (stacks[] 4-field schema delta + /gaia-init questionnaire +
#         /gaia-config-stack editor extension)
# ADR:   ADR-126 (multi-stack monorepo path partitioning), ADR-120 (bypass vocab)
# FR:    FR-546, SR-86, SR-87
#
# Validates the schema delta with the canonical project validator (ajv-cli@5,
# --strict=false) per the existing cluster-1 idiom, plus the ADR-120
# bypass-reason (SR-86) enforcement via parse-bypass-flag.sh, plus the
# AC-X2 CRUD-menu disclaimer obligation on both touched SKILL.md files.

load 'test_helper.bash'

setup() {
  common_setup
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)/project-config.schema.json"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/stacks-schema"
  SKILLS="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  LIB="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  export SCHEMA FIXTURES SKILLS LIB
}

teardown() {
  common_teardown
}

# Convert a YAML fixture to JSON so ajv can consume it (mirrors the
# cluster-1/project-config-schema-validation.bats idiom). default=str keeps
# any date objects as strings so json.dumps does not raise.
yaml_to_json() {
  python3 -c "
import sys, json, yaml
print(json.dumps(yaml.safe_load(sys.stdin), default=str))
" < "$1" > "$2"
}

ajv_validate() {
  local fixture="$1"
  local json="$TEST_TMP/doc.json"
  yaml_to_json "$fixture" "$json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$json" --strict=false
}

# ---------------------------------------------------------------------------
# AC1 — schema gains the 4 optional properties with correct types/defaults
# ---------------------------------------------------------------------------

@test "E85-S14 AC1: stacks.items declares the 4 new optional properties" {
  for prop in path excludes cross_refs ignore_nested_manifests; do
    run jq -e --arg p "$prop" '.properties.stacks.items.properties[$p]' "$SCHEMA"
    [ "$status" -eq 0 ] || { echo "missing property: $prop"; return 1; }
  done
}

@test "E85-S14 AC1: path is string, excludes/cross_refs are arrays-of-string, ignore_nested_manifests is boolean" {
  run jq -r '.properties.stacks.items.properties.path.type' "$SCHEMA"
  [ "$output" = "string" ]
  run jq -r '.properties.stacks.items.properties.excludes.type' "$SCHEMA"
  [ "$output" = "array" ]
  run jq -r '.properties.stacks.items.properties.excludes.items.type' "$SCHEMA"
  [ "$output" = "string" ]
  run jq -r '.properties.stacks.items.properties.cross_refs.type' "$SCHEMA"
  [ "$output" = "array" ]
  run jq -r '.properties.stacks.items.properties.cross_refs.items.type' "$SCHEMA"
  [ "$output" = "string" ]
  run jq -r '.properties.stacks.items.properties.ignore_nested_manifests.type' "$SCHEMA"
  [ "$output" = "boolean" ]
}

@test "E85-S14 AC1: ignore_nested_manifests default is true" {
  run jq -r '.properties.stacks.items.properties.ignore_nested_manifests.default' "$SCHEMA"
  [ "$output" = "true" ]
}

@test "E85-S14 AC1: new fields stay OPTIONAL — required remains exactly [name, language, paths]" {
  run jq -c '.properties.stacks.items.required' "$SCHEMA"
  [ "$output" = '["name","language","paths"]' ]
}

# ---------------------------------------------------------------------------
# AC1 / AC6 — additionalProperties:false preserved on stacks.items.
# (The ROOT schema is intentionally additionalProperties:true to tolerate
#  forward-compatible config sections — AC1's "root" wording is imprecise;
#  only the items schema is closed. We assert the items schema only.)
# ---------------------------------------------------------------------------

@test "E85-S14 AC1: additionalProperties:false preserved on stacks.items" {
  run jq -r '.properties.stacks.items.additionalProperties' "$SCHEMA"
  [ "$output" = "false" ]
}

# ---------------------------------------------------------------------------
# AC6 — TC-MSP-1 / TC-MSP-2
# ---------------------------------------------------------------------------

@test "E85-S14 TC-MSP-1: pre-deploy stacks[] fixture validates byte-compatible after bump" {
  ajv_validate "$FIXTURES/pre-deploy.yaml"
  [ "$status" -eq 0 ]
}

@test "E85-S14 TC-MSP-2: 4-field stacks[] entry validates with additionalProperties:false preserved" {
  ajv_validate "$FIXTURES/four-field.yaml"
  [ "$status" -eq 0 ]
}

@test "E85-S14: single-stack fixture (no path field) validates unchanged" {
  ajv_validate "$FIXTURES/single-stack.yaml"
  [ "$status" -eq 0 ]
}

@test "E85-S14: multi-stack 3-stack monorepo fixture validates with all new fields" {
  ajv_validate "$FIXTURES/multi-stack.yaml"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Per-field type boundaries — negative cases (MUST be rejected)
# ---------------------------------------------------------------------------

@test "E85-S14: path as array is rejected by the path TYPE keyword (must be string)" {
  ajv_validate "$FIXTURES/bad-path-type.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"properties/stacks/items/properties/path/type"* ]]
}

@test "E85-S14: excludes as string is rejected by the excludes TYPE keyword (array of string)" {
  ajv_validate "$FIXTURES/bad-excludes-type.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"properties/stacks/items/properties/excludes/type"* ]]
}

@test "E85-S14: cross_refs as string is rejected by the cross_refs TYPE keyword (array of string)" {
  ajv_validate "$FIXTURES/bad-cross-refs-type.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"properties/stacks/items/properties/cross_refs/type"* ]]
}

@test "E85-S14: ignore_nested_manifests as string is rejected by the TYPE keyword (boolean)" {
  ajv_validate "$FIXTURES/bad-ignore-nested-type.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"properties/stacks/items/properties/ignore_nested_manifests/type"* ]]
}

@test "E85-S14: unknown property on stacks item is rejected (additionalProperties:false trap)" {
  ajv_validate "$FIXTURES/bad-unknown-field.yaml"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — SR-86 bypass-reason validation via parse-bypass-flag.sh
# (Test Scenarios 8, 9, 10). The parser enforces min-10 / max-500 and
# requires --reason when --bypass is present; it accepts arbitrary bypass
# keywords (no allowlist gate), so cross-stack-refs is a recognized keyword.
# ---------------------------------------------------------------------------

@test "E85-S14 AC5 (scenario 8): cross-stack-refs bypass with 14-char reason is accepted" {
  run bash "$LIB/parse-bypass-flag.sh" --bypass cross-stack-refs --reason "fix-CVE-2024-X"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BYPASS_SKILL=cross-stack-refs"* ]]
  [[ "$output" == *"BYPASS_REASON=fix-CVE-2024-X"* ]]
}

@test "E85-S14 AC5 (scenario 9): too-short reason (3 chars) is rejected under SR-86 min-length 10" {
  run bash "$LIB/parse-bypass-flag.sh" --bypass cross-stack-refs --reason "fix"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at least 10"* ]]
}

@test "E85-S14 AC5 (scenario 10): missing --reason is rejected with no-anonymous-bypass error" {
  run bash "$LIB/parse-bypass-flag.sh" --bypass cross-stack-refs
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --reason"* ]]
}

@test "E85-S14 AC5: max-length 500 boundary — 501-char reason is rejected" {
  local long
  long="$(printf 'a%.0s' $(seq 1 501))"
  run bash "$LIB/parse-bypass-flag.sh" --bypass cross-stack-refs --reason "$long"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most 500"* ]]
}

# ---------------------------------------------------------------------------
# AC-X2 — canonical CRUD-menu disclaimer + ADR-093 on both touched skills.
# (E71-S8 drift-sweep only covers gaia-config-*; this asserts gaia-init too,
#  per Val F2 — CI-self-enforced here.)
# ---------------------------------------------------------------------------

@test "E85-S14 AC-X2: gaia-config-stack SKILL.md carries the CRUD-menu disclaimer + orchestration_class" {
  run grep -F "LLM-driven interaction pattern under Claude Code main-turn orchestration" "$SKILLS/gaia-config-stack/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F "orchestration_class" "$SKILLS/gaia-config-stack/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "E85-S14 AC-X2: gaia-init SKILL.md carries the CRUD-menu disclaimer + orchestration_class" {
  run grep -F "LLM-driven interaction pattern under Claude Code main-turn orchestration" "$SKILLS/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F "orchestration_class" "$SKILLS/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 / AC3 — SKILL.md wiring assertions (the prompt-gating + editor verbs
# are LLM-driven prose; assert the canonical anchors are present).
# ---------------------------------------------------------------------------

@test "E85-S14 AC2: gaia-init gates the per-stack path prompt on multi-stack" {
  run grep -Ei "more than one stack|multi-stack|len\(stacks\) ?> ?1|> 1" "$SKILLS/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "E85-S14 AC4: gaia-init offers the SR-87 default secret-exclude patterns" {
  run grep -F ".env" "$SKILLS/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F "*.pem" "$SKILLS/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F "*.key" "$SKILLS/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "E85-S14 AC3: gaia-config-stack documents set/show/clear for the 4 new fields" {
  for field in path excludes cross_refs ignore_nested_manifests; do
    run grep -F "$field" "$SKILLS/gaia-config-stack/SKILL.md"
    [ "$status" -eq 0 ] || { echo "field not documented: $field"; return 1; }
  done
}
