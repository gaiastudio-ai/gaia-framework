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
# authors gaia-framework/plugins/gaia/scripts/lib/assert-agent-envelope.sh.

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
@test "TC-VBR-1: valid sentinel JSON passes assert_agent_envelope" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  run assert_agent_envelope "$FIXTURES_DIR/valid.json"
  [ "$status" -eq 0 ]
  # bats `run` merges stdout+stderr into $output. Valid sentinel must emit nothing.
  [ -z "$output" ]
}

# ---------------- TC-VBR-2: missing sentinel HALTs ----------------
@test "TC-VBR-2: missing sentinel file HALTs with canonical error" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  local missing="$TEST_TMP/does-not-exist.json"
  run assert_agent_envelope "$missing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-3: malformed JSON HALTs ----------------
@test "TC-VBR-3: malformed JSON HALTs with canonical error" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  run assert_agent_envelope "$FIXTURES_DIR/malformed.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-4: forged sentinel HALTs (NFR-064) ----------------
@test "TC-VBR-4: forged sentinel (no persona_sig) HALTs — proves NFR-064 forgery resistance" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  source "$HELPER"
  run assert_agent_envelope "$FIXTURES_DIR/forged.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-1b: double-source idempotent ----------------
@test "TC-VBR-1b: double-source returns 0 without redefining the function" {
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

# ---------------- TC-VBR-1c: ADR-104 reference in header ----------------
@test "TC-VBR-1c: helper script header references ADR-104 (AC7)" {
  [ -f "$HELPER" ] || skip "helper not authored yet (Red phase)"
  grep -q 'ADR-104' "$HELPER"
}

# ---------------- Anti-red sanity: helper exists after Green ----------------
@test "post-Green: helper file exists at expected path" {
  [ -f "$HELPER" ]
}

# ============================================================================
# E90-S1 — TC-MVB-1..6: --expected-agent flag generalization (ADR-104).
# ============================================================================

# ---------------- TC-MVB-1: no flag continues to assert agent=val ----------------
@test "TC-MVB-1: invocation without flag continues to assert agent=val (backward-compat)" {
  source "$HELPER"
  local sentinel="$TEST_TMP/val-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel"
  [ "$status" -eq 0 ]
}

# ---------------- TC-MVB-2a: --expected-agent pm rejects val sentinel ----------------
@test "TC-MVB-2a: --expected-agent pm rejects a val sentinel (HALT)" {
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
@test "TC-MVB-2b: --expected-agent pm accepts a pm sentinel (return 0)" {
  source "$HELPER"
  local sentinel="$TEST_TMP/pm-sentinel.json"
  printf '%s\n' '{"agent": "pm", "persona_sig": "pm-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --expected-agent pm
  [ "$status" -eq 0 ]
}

# ---------------- TC-MVB-3: persona_sig presence check agent-agnostic ----------------
@test "TC-MVB-3: empty persona_sig HALTs regardless of agent id" {
  source "$HELPER"
  local sentinel="$TEST_TMP/pm-no-persona.json"
  printf '%s\n' '{"agent": "pm", "persona_sig": ""}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --expected-agent pm
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed"* ]]
}

# ---------------- TC-MVB-4: unknown flag HALTs ----------------
@test "TC-MVB-4: unknown flag HALTs" {
  source "$HELPER"
  local sentinel="$TEST_TMP/val-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --frobnicate quux
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent envelope assertion failed"* ]]
}

# ---------------- TC-MVB-5: --expected-agent=val inline form ----------------
@test "TC-MVB-5: --expected-agent=val inline form is supported" {
  source "$HELPER"
  local sentinel="$TEST_TMP/val-sentinel.json"
  printf '%s\n' '{"agent": "val", "persona_sig": "val-dev-test"}' > "$sentinel"
  run assert_agent_envelope "$sentinel" --expected-agent=val
  [ "$status" -eq 0 ]
}

# ---------------- TC-MVB-6: HALT substring constancy across failure modes ----------------
@test "TC-MVB-6: canonical HALT substring preserved across all 4 failure modes" {
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
@test "TC-MVB-7: helper header documents --expected-agent flag" {
  [ "$(grep -c 'expected-agent' "$HELPER")" -ge 3 ]
}

# ---------------- TC-MVB-8: validator.md + ADR-104 shard cross-refs ----------------
@test "TC-MVB-8: validator.md and ADR-104 shard reference expected-agent generalization" {
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
