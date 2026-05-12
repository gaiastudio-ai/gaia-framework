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
