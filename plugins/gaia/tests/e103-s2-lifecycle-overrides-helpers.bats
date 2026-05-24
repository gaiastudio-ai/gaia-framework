#!/usr/bin/env bats
# e103-s2-lifecycle-overrides-helpers.bats
# Story: E103-S2 — .gaia/state/lifecycle-overrides.yaml schema + CLI vocabulary + helpers.
# Origin: AF-2026-05-24-3. Traces to: FR-536, ADR-120, TC-LOE-2.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  LIB="$REPO_ROOT/gaia-public/plugins/gaia/scripts/lib/lifecycle-overrides.sh"
  SCHEMA="$REPO_ROOT/gaia-public/plugins/gaia/schemas/lifecycle-overrides.schema.json"
  PARSER="$REPO_ROOT/gaia-public/plugins/gaia/scripts/lib/parse-bypass-flag.sh"
  TMP_ROOT="$(mktemp -d)"
  export LIFECYCLE_OVERRIDES_FILE="$TMP_ROOT/.gaia/state/lifecycle-overrides.yaml"
  export LIFECYCLE_OVERRIDES_LOCK="$TMP_ROOT/.gaia/state/lifecycle-overrides.yaml.lock"
  mkdir -p "$(dirname "$LIFECYCLE_OVERRIDES_FILE")"
}

teardown() {
  rm -rf "$TMP_ROOT" 2>/dev/null || true
  common_teardown
}

# ---------------------------------------------------------------------------
# TC-LOE-2a — schema exists; jq validates minimal record's required fields
# ---------------------------------------------------------------------------

@test "TC-LOE-2a: schema file exists and declares required fields" {
  [ -f "$SCHEMA" ]
  # Confirm the 5 required fields are declared in the schema.
  jq -e '.properties.bypasses.items.required' "$SCHEMA" >/dev/null
  required_count="$(jq '.properties.bypasses.items.required | length' "$SCHEMA")"
  [ "$required_count" -eq 5 ]
}

# ---------------------------------------------------------------------------
# TC-LOE-2b — read on absent file returns {bypasses: []}
# ---------------------------------------------------------------------------

@test "TC-LOE-2b: lifecycle_read_bypasses on absent file returns empty bypasses" {
  # File doesn't exist yet; should not be created by read.
  [ ! -f "$LIFECYCLE_OVERRIDES_FILE" ]
  out="$(bash "$LIB" read)"
  count="$(printf '%s' "$out" | jq '.bypasses | length')"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-LOE-2c — append rejects missing --reason
# ---------------------------------------------------------------------------

@test "TC-LOE-2c: append rejects missing --reason" {
  run bash "$LIB" append --skill /gaia-trace --sprint-id sprint-52
  [ "$status" -ne 0 ]
  [[ "$output" == *"--reason is required"* ]]
}

# ---------------------------------------------------------------------------
# TC-LOE-2d — append rejects --reason <10 chars
# ---------------------------------------------------------------------------

@test "TC-LOE-2d: append rejects short --reason" {
  run bash "$LIB" append --skill /gaia-trace --reason short --sprint-id sprint-52
  [ "$status" -ne 0 ]
  [[ "$output" == *"at least 10 chars"* ]]
}

# ---------------------------------------------------------------------------
# TC-LOE-2e — append bootstraps file and idempotently appends
# ---------------------------------------------------------------------------

@test "TC-LOE-2e: append bootstraps absent file then appends second record" {
  bash "$LIB" append --skill /gaia-trace --reason "first valid reason ten" --sprint-id sprint-52
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  bash "$LIB" append --skill /gaia-threat-model --reason "second valid reason text" --sprint-id sprint-52
  count="$(bash "$LIB" read | jq '.bypasses | length')"
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# TC-LOE-2f — 10 parallel appends produce 10 entries (no lost updates)
# ---------------------------------------------------------------------------

@test "TC-LOE-2f: 10 parallel appends produce 10 unique entries" {
  pids=()
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash "$LIB" append --skill "/gaia-trace-$i" --reason "parallel reason number $i abc" --sprint-id sprint-52 &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  count="$(bash "$LIB" read | jq '.bypasses | length')"
  [ "$count" -eq 10 ]
  unique="$(bash "$LIB" read | jq '[.bypasses[].skill] | unique | length')"
  [ "$unique" -eq 10 ]
}

# ---------------------------------------------------------------------------
# TC-LOE-2g — list filters by sprint and emits table format
# ---------------------------------------------------------------------------

@test "TC-LOE-2g: list filters by sprint and emits table format" {
  bash "$LIB" append --skill /gaia-trace --reason "reason in sprint 52 a" --sprint-id sprint-52
  bash "$LIB" append --skill /gaia-tm --reason "reason in sprint 52 b" --sprint-id sprint-52
  bash "$LIB" append --skill /gaia-trace --reason "reason in sprint 51 c" --sprint-id sprint-51
  out="$(bash "$LIB" list sprint-52)"
  # Header + separator + 2 rows = 4 lines minimum
  line_count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  [ "$line_count" -ge 4 ]
  [[ "$out" == *"sprint 52 a"* ]]
  [[ "$out" == *"sprint 52 b"* ]]
  [[ "$out" != *"sprint 51 c"* ]]
}

# ---------------------------------------------------------------------------
# TC-LOE-2h — --format json emits valid JSON
# ---------------------------------------------------------------------------

@test "TC-LOE-2h: list --format json emits valid JSON parseable by jq" {
  bash "$LIB" append --skill /gaia-trace --reason "reason for json test" --sprint-id sprint-52
  out="$(bash "$LIB" list sprint-52 --format json)"
  count="$(printf '%s' "$out" | jq '.bypasses | length')"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# parse-bypass-flag.sh — minimum coverage for AC3 contract
# ---------------------------------------------------------------------------

@test "TC-LOE-2i: parse-bypass-flag rejects --bypass without --reason" {
  run bash "$PARSER" --bypass /gaia-trace
  [ "$status" -ne 0 ]
  [[ "$output" == *"--reason"* ]]
}

@test "TC-LOE-2j: parse-bypass-flag exports BYPASS_SKILL and BYPASS_REASON" {
  out="$(bash "$PARSER" --bypass /gaia-trace --reason "valid reason ten" some other arg)"
  [[ "$out" == *"BYPASS_SKILL=/gaia-trace"* ]]
  [[ "$out" == *"BYPASS_REASON="* ]]
  # %q may escape spaces; round-trip via eval to recover the literal.
  eval "$out"
  [ "$BYPASS_REASON" = "valid reason ten" ]
}
