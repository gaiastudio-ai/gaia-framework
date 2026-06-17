#!/usr/bin/env bats
# assert-agent-envelope.bats — coverage for scripts/lib/assert-agent-envelope.sh
#
# Story: E87-S1 — Shared assert-agent-envelope.sh helper + ADR-104 anchor + memory scaffold
# Anchor: ADR-104 — Val Bridge Migration — Main-Turn Agent Dispatch Across Val-Consuming Skills
#
# Coverage:
#   TC-VBR-1   valid sentinel JSON (agent=val + persona_sig) passes (exit 0, no stderr)
#   TC-VBR-2   missing sentinel file HALTs (exit 1, canonical error on stderr)
#   TC-VBR-3   malformed JSON HALTs (exit 1, canonical error)
#   TC-VBR-4   forged sentinel (agent=val, no persona_sig) HALTs — proves NFR-064
#   TC-VBR-1b  double-source idempotent — second source returns 0, function not redefined
#   TC-VBR-1c  script header references ADR-104 — covers AC7
#
# The helper file under test is intentionally not yet present during the Red
# phase. All six tests should fail until /gaia-dev-story Step 6 Green
# authors gaia-public/plugins/gaia/scripts/lib/assert-agent-envelope.sh.

load 'test_helper.bash'

# Resolve the helper path once. LIB_DIR is one level up from tests/ at scripts/lib/.
HELPER="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" 2>/dev/null && pwd || echo "")/assert-agent-envelope.sh"
FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures/assert-agent-envelope"

# Canonical HALT error string — must match the helper's stderr emission verbatim.
# Path placeholder is interpolated at runtime; tests only assert the prefix.
HALT_PREFIX='HALT: Val agent envelope assertion failed'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# ---------------- TC-VBR-1: valid sentinel passes ----------------
@test "valid sentinel JSON passes assert_agent_envelope" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  run assert_agent_envelope "$FIXTURES_DIR/valid.json"
  [ "$status" -eq 0 ]
  # bats `run` merges stdout+stderr into $output. Valid sentinel must emit nothing.
  [ -z "$output" ]
}

# ---------------- TC-VBR-2: missing sentinel HALTs ----------------
@test "missing sentinel file HALTs with canonical error" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  local missing="$TEST_TMP/does-not-exist.json"
  run assert_agent_envelope "$missing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-3: malformed JSON HALTs ----------------
@test "malformed JSON HALTs with canonical error" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  run assert_agent_envelope "$FIXTURES_DIR/malformed.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-4: forged sentinel HALTs (NFR-064) ----------------
@test "forged sentinel (no persona_sig) HALTs — proves forgery resistance" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  run assert_agent_envelope "$FIXTURES_DIR/forged.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-1b: double-source idempotent ----------------
@test "double-source returns 0 without redefining the function" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  # Source once
  source "$HELPER"
  type assert_agent_envelope >/dev/null
  local first_def
  first_def="$(type assert_agent_envelope)"
  # Source again — must not redefine
  source "$HELPER"
  local second_def
  second_def="$(type assert_agent_envelope)"
  [ "$first_def" = "$second_def" ]
  # Confirm the source guard is set
  [ -n "${_ASSERT_AGENT_ENVELOPE_SH_SOURCED:-}" ]
}

# ---------------- TC-VBR-1c: Val-bridge migration contract documented in header ----------------
@test "helper script header documents the Val-bridge migration context" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  # The header must document the sentinel-write context: the orchestrator
  # main-turn writer (write-val-envelope.sh) and why the writer was shifted.
  grep -q 'write-val-envelope' "$HELPER"
}

# ---------------- Anti-red sanity: helper exists after Green ----------------
@test "post-Green: helper file exists at expected path" {
  [ -f "$HELPER" ]
}

# ============================================================================
# E90-S1 — TC-MVB-1..6: --expected-agent flag generalization (ADR-104).
# ============================================================================

# ---------------- TC-MVB-1: no flag continues to assert agent=val ----------------
@test "invocation without flag continues to assert agent=val (backward-compat)" {
  source "$HELPER"
  local sentinel="$TEST_TMP/val-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel"
  [ "$status" -eq 0 ]
}

# ---------------- TC-MVB-2a: --expected-agent pm rejects val sentinel ----------------
@test "expected-agent pm rejects a val sentinel (HALT)" {
  source "$HELPER"
  local sentinel="$TEST_TMP/val-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --expected-agent pm
  [ "$status" -ne 0 ]
  # Canonical substring (agent token varies; downstream consumers grep the constant tail).
  [[ "$output" == *"agent envelope assertion failed — sentinel absent, malformed, or forged at"* ]]
  # Leading token capitalized: 'Pm'.
  [[ "$output" == *"HALT: Pm "* ]]
}

# ---------------- TC-MVB-2b: --expected-agent pm accepts pm sentinel ----------------
@test "expected-agent pm accepts a pm sentinel (return 0)" {
  source "$HELPER"
  local sentinel="$TEST_TMP/pm-sentinel.json"
  printf '%s\n' '{"agent": "pm", "persona_sig": "pm-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --expected-agent pm
  [ "$status" -eq 0 ]
}

# ---------------- TC-MVB-3: persona_sig presence check agent-agnostic ----------------
@test "empty persona_sig HALTs regardless of agent id" {
  source "$HELPER"
  local sentinel="$TEST_TMP/pm-no-persona.json"
  printf '%s\n' '{"agent": "pm", "persona_sig": ""}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --expected-agent pm
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed"* ]]
}

# ---------------- TC-MVB-4: unknown flag HALTs ----------------
@test "unknown flag HALTs" {
  source "$HELPER"
  local sentinel="$TEST_TMP/val-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --frobnicate quux
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed"* ]]
}

# ---------------- TC-MVB-5: --expected-agent=val inline form ----------------
@test "expected-agent=val inline form is supported" {
  source "$HELPER"
  local sentinel="$TEST_TMP/val-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --expected-agent=val
  [ "$status" -eq 0 ]
}

# ---------------- TC-MVB-6: HALT substring constancy across failure modes ----------------
@test "canonical HALT substring preserved across all 4 failure modes" {
  source "$HELPER"
  local missing="$TEST_TMP/does-not-exist.json"
  run assert_agent_envelope "$missing" --expected-agent pm
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed — sentinel absent, malformed, or forged at"* ]]

  local malformed="$TEST_TMP/malformed.json"
  printf '%s' '{ this is not json' > "$malformed"
  run assert_agent_envelope "$malformed" --expected-agent pm
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed — sentinel absent, malformed, or forged at"* ]]

  local wrong_agent="$TEST_TMP/wrong-agent.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "x"}' > "$wrong_agent"
  run assert_agent_envelope "$wrong_agent" --expected-agent pm
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed — sentinel absent, malformed, or forged at"* ]]

  local no_persona="$TEST_TMP/no-persona.json"
  printf '%s\n' '{"agent": "pm", "persona_sig": ""}' > "$no_persona"
  run assert_agent_envelope "$no_persona" --expected-agent pm
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed — sentinel absent, malformed, or forged at"* ]]
}

# ---------------- TC-MVB-7: header references --expected-agent ----------------
@test "helper header documents --expected-agent flag" {
  [ "$(grep -c 'expected-agent' "$HELPER")" -ge 3 ]
}

# ============================================================================
# E87-S8 / AF-2026-06-03-2 / ADR-130 — TC-OSV-3, TC-OSV-4, TC-OSV-5 (assert
# half): OPTIONAL `original_status` field. NFR-95 golden invariant —
# original_status MUST NOT be added to any required set; assertion passes
# (exit 0) whether the field is present or absent.
# ============================================================================

# TC-OSV-3: asserter passes when sentinel carries original_status (optional).
@test "asserter passes with original_status present (exit 0)" {
  source "$HELPER"
  local sentinel="$TEST_TMP/osv3-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-osv3", "original_status": "WARNING"}' > "$sentinel"
  run assert_agent_envelope "$sentinel"
  [ "$status" -eq 0 ]
}

# TC-OSV-4: asserter passes when sentinel lacks original_status (back-compat).
@test "asserter passes without original_status (exit 0, back-compat)" {
  source "$HELPER"
  local sentinel="$TEST_TMP/osv4-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-osv4"}' > "$sentinel"
  run assert_agent_envelope "$sentinel"
  [ "$status" -eq 0 ]
}

# TC-OSV-5 (assert half): NFR-95 — original_status is NOT required. A sentinel
# missing it asserts identically to one carrying it; both exit 0. Pins the
# invariant against a future strict-required-set regression.
@test "with and without original_status both assert exit 0" {
  source "$HELPER"
  local with="$TEST_TMP/osv5-with.json"
  local without="$TEST_TMP/osv5-without.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-osv5", "original_status": "PASS"}' > "$with"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-osv5"}' > "$without"
  run assert_agent_envelope "$with"
  [ "$status" -eq 0 ]
  run assert_agent_envelope "$without"
  [ "$status" -eq 0 ]
}

# TC-OSV-6: helper header documents original_status as an OPTIONAL field
# so the additive contract is locked against future regression.
@test "helper header documents original_status as optional (non-required)" {
  grep -q 'original_status' "$HELPER"
  # The header must state the asserter is agnostic to the field's presence.
  grep -q 'agnostic to its presence' "$HELPER"
}

# ---------------- TC-MVB-8: validator.md + ADR-104 shard cross-refs ----------------
@test "validator.md and shard reference expected-agent generalization" {
  # validator.md cross-reference required.
  local validator_md="$BATS_TEST_DIRNAME/../agents/validator.md"
  [ -f "$validator_md" ]
  grep -q 'expected-agent' "$validator_md"
  # ADR-104 shard cross-reference. Project-root path:
  # docs/planning-artifacts/architecture/02-2-architecture-decisions.md
  # (the legacy monolith is not present per memory feedback_check_monolith_and_shards.md).
  local adr_shard="$BATS_TEST_DIRNAME/../../../../docs/planning-artifacts/architecture/02-2-architecture-decisions.md"
  if [ -f "$adr_shard" ]; then
    grep -q 'expected-agent' "$adr_shard"
  fi
}
