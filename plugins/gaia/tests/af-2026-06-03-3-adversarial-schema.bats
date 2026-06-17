#!/usr/bin/env bats
# af-2026-06-03-3-adversarial-schema.bats — E87-S13 / TC-ASJ coverage for the
# adversarial JSON sidecar schema (adversarial-sidecar.schema.json) and the
# NFR-96 byte-identical determinism contract of the S11 emitter.
#
# AF-2026-06-03-3 / ADR-131 / FR-568 / FR-569 / NFR-96.
#
# Test scenarios traced to the story Test Scenarios table / TC-ASJ-1..5:
#   TC-ASJ-1 (AC1/AC9a) — schema is valid JSON + declares draft-2020-12 + $id
#   TC-ASJ-2 (AC4/AC9b) — known-good fixture validates via validate-artifact-schema.sh (backend-guarded)
#   TC-ASJ-3 (AC3/AC9c) — schema FORBIDS timestamp/persona_sig/sentinel_envelope
#   TC-ASJ-4 (AC4)      — off-vocab/forbidden-key sidecar is rejected (backend-guarded)
#   TC-ASJ-5 (NFR-96)   — double-emit via write-adversarial-sidecar.sh produces byte-identical output
#
# Asserts ONLY in-tree gaia-public artifacts. PLUGIN derived from $BATS_TEST_DIRNAME
# (dir-rename resilient per feedback_ci_checkout_dir_flips_on_repo_rename).

load 'test_helper.bash'

setup() {
  common_setup
  # tests/ lives one level under plugins/gaia/, so derive the plugin root from
  # BATS_TEST_DIRNAME (dir-rename resilient — never hard-code the repo name).
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA="$PLUGIN/schemas/adversarial-sidecar.schema.json"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/adversarial-sidecar-valid.json"
  VALIDATOR="$PLUGIN/scripts/lib/validate-artifact-schema.sh"
  EMITTER="$PLUGIN/skills/gaia-adversarial/scripts/write-adversarial-sidecar.sh"
}

teardown() { common_teardown; }

# Detect whether a JSON-schema validator backend is available on this host.
# Mirrors the cascade inside validate-artifact-schema.sh: ajv first, then
# python3+jsonschema. The bare host has neither — validate assertions SKIP.
_has_backend() {
  if command -v ajv >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# TC-ASJ-1 (AC1) — schema is valid JSON, declares draft-2020-12 + canonical $id
# ---------------------------------------------------------------------------

@test "adversarial-sidecar.schema.json exists and is valid JSON" {
  [ -f "$SCHEMA" ]
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json,sys; json.load(open('$SCHEMA'))"
    [ "$status" -eq 0 ]
  else
    run head -c1 "$SCHEMA"
    [ "$output" = "{" ]
  fi
}

@test "schema declares draft-2020-12 and the canonical \$id" {
  grep -q 'json-schema.org/draft/2020-12/schema' "$SCHEMA"
  grep -q '"\$id"' "$SCHEMA"
  # $id is the gaia.studio canonical, mirroring brownfield-gap-entry.schema.json.
  run grep '"\$id"' "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://gaia.studio/schemas/adversarial-sidecar.schema.json"* ]]
}

@test "schema models the exact S11 emitter shape" {
  # review_type const "adversarial".
  grep -q '"const": "adversarial"' "$SCHEMA"
  # status enum is the ADR-037 verdict vocab.
  grep -q '"PASS"' "$SCHEMA"
  grep -q '"WARNING"' "$SCHEMA"
  grep -q '"CRITICAL"' "$SCHEMA"
  # findings finding-level severity enum + the four finding keys.
  grep -q '"INFO"' "$SCHEMA"
  grep -q '"severity"' "$SCHEMA"
  grep -q '"location"' "$SCHEMA"
  # required set at the root names review_type/status/target/findings.
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json; r=json.load(open('$SCHEMA'))['required']; assert set(['review_type','status','target','findings']).issubset(set(r)), r"
    [ "$status" -eq 0 ]
  fi
}

# ---------------------------------------------------------------------------
# TC-ASJ-2 (AC4) — known-good fixture validates against the schema (backend-guarded)
# ---------------------------------------------------------------------------

@test "known-good fixture exists and is valid JSON" {
  [ -f "$FIXTURE" ]
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json; json.load(open('$FIXTURE'))"
    [ "$status" -eq 0 ]
  fi
}

@test "known-good fixture validates via validate-artifact-schema.sh (backend-guarded)" {
  [ -f "$VALIDATOR" ]
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host (ajv|python3+jsonschema)"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-ASJ-3 (AC3 / NFR-96) — schema FORBIDS timestamp/persona_sig/sentinel_envelope
# ---------------------------------------------------------------------------

@test "root is additionalProperties:false and forbidden keys absent from properties" {
  # additionalProperties:false at the root encodes the forbid-everything-else rule.
  grep -q '"additionalProperties": false' "$SCHEMA"
  # The three forbidden provenance/forgery/gate keys MUST NOT appear as schema
  # properties — verify structurally via python3, falling back to a grep guard.
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "
import json
s = json.load(open('$SCHEMA'))
assert s.get('additionalProperties') is False, 'root additionalProperties must be false'
props = set(s.get('properties', {}).keys())
for k in ('timestamp', 'persona_sig', 'sentinel_envelope'):
    assert k not in props, k + ' must not be a property'
"
    [ "$status" -eq 0 ]
  else
    # Property keys appear as quoted object keys; assert none of the forbidden
    # ones are declared. (The descriptions mention them as forbidden, but never
    # as a `\"timestamp\":` property key.)
    ! grep -Eq '^\s*"timestamp"\s*:' "$SCHEMA"
    ! grep -Eq '^\s*"persona_sig"\s*:' "$SCHEMA"
    ! grep -Eq '^\s*"sentinel_envelope"\s*:' "$SCHEMA"
  fi
}

# ---------------------------------------------------------------------------
# TC-ASJ-4 (AC4) — an off-vocab / forbidden-key sidecar is REJECTED (backend-guarded)
# ---------------------------------------------------------------------------

@test "sidecar carrying a forbidden timestamp key is rejected (backend-guarded)" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host (ajv|python3+jsonschema)"
  fi
  local bad="$TEST_TMP/bad-timestamp.json"
  cat > "$bad" <<'JSON'
{
  "review_type": "adversarial",
  "status": "WARNING",
  "target": "adversarial-review-prd-2026-06-03",
  "timestamp": "2026-06-03T00:00:00Z",
  "findings": []
}
JSON
  run bash "$VALIDATOR" "$SCHEMA" "$bad"
  [ "$status" -eq 1 ]
}

@test "sidecar with an off-vocab status is rejected (backend-guarded)" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host (ajv|python3+jsonschema)"
  fi
  local bad="$TEST_TMP/bad-status.json"
  cat > "$bad" <<'JSON'
{
  "review_type": "adversarial",
  "status": "STRONG",
  "target": "adversarial-review-prd-2026-06-03",
  "findings": []
}
JSON
  run bash "$VALIDATOR" "$SCHEMA" "$bad"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# TC-ASJ-5 (NFR-96) — byte-identical determinism: double-emit via the writer + diff
# ---------------------------------------------------------------------------

@test "write-adversarial-sidecar.sh emits byte-identical output on repeat" {
  [ -x "$EMITTER" ] || [ -f "$EMITTER" ]
  command -v jq >/dev/null 2>&1 || skip "jq not on host (emitter requires jq)"

  local envelope='{"status":"WARNING","summary":"sample","next":"act","findings":[{"severity":"INFO","id":"ADV-002","title":"b","location":"x"},{"severity":"CRITICAL","id":"ADV-001","title":"a","location":"y"}]}'

  local md1="$TEST_TMP/run1/adversarial-review-prd-2026-06-03.md"
  local md2="$TEST_TMP/run2/adversarial-review-prd-2026-06-03.md"

  run bash -c "printf '%s' '$envelope' | bash '$EMITTER' --md-path '$md1' --envelope-stdin"
  [ "$status" -eq 0 ]
  local sc1="$output"

  run bash -c "printf '%s' '$envelope' | bash '$EMITTER' --md-path '$md2' --envelope-stdin"
  [ "$status" -eq 0 ]
  local sc2="$output"

  [ -f "$sc1" ]
  [ -f "$sc2" ]
  # Byte-identical content across the two emissions (NFR-96).
  run diff "$sc1" "$sc2"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emitted sidecar omits timestamp/persona_sig/sentinel_envelope" {
  command -v jq >/dev/null 2>&1 || skip "jq not on host (emitter requires jq)"
  local envelope='{"status":"PASS","summary":"clean","next":"none","findings":[]}'
  local md="$TEST_TMP/emit/adversarial-review-arch-2026-06-03.md"
  run bash -c "printf '%s' '$envelope' | bash '$EMITTER' --md-path '$md' --envelope-stdin"
  [ "$status" -eq 0 ]
  local sc="$output"
  [ -f "$sc" ]
  run jq -e 'has("timestamp") or has("persona_sig") or has("sentinel_envelope")' "$sc"
  # jq -e returns 1 when the boolean result is false — i.e. none of the forbidden
  # keys are present, which is the assertion we want.
  [ "$status" -eq 1 ]
}
