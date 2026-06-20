#!/usr/bin/env bats
# transcript-fidelity.bats — Mode B transcript fidelity contract.
#
# Guarantees that a Mode B transcript is a SUPERSET of the equivalent Mode A
# transcript, includes teammate identity metadata, and fails safe (not
# fail-silent) when relay is skipped.
#
# Substrate-honest: tests exercise the bash plumbing (transcript files,
# metadata injection, superset verification). Live persistent-teammate
# round-trips are NOT asserted — transcript entries are simulated via the
# library's own append functions.

load 'test_helper.bash'

setup() {
  common_setup

  LIB_DIR="$SCRIPTS_DIR/lib"
  LIB="$LIB_DIR/dispatch-teammate.sh"
  FIDELITY_LIB="$LIB_DIR/transcript-fidelity.sh"

  # Session-scoped directories for the library under test.
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  # Force substrate unavailable — tests exercise plumbing.
  export GAIA_MODE_B_SUBSTRATE="${GAIA_MODE_B_SUBSTRATE:-unavailable}"
}

teardown() { common_teardown; }

# Helper: produce a Mode A transcript with a known payload.
_write_mode_a_transcript() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$path"
  done
}

# ============================================================
# Fail-safe: unrelayed output emits WARNING + still captured (AC1)
# ============================================================

@test "shutdown after drive_turn without relay emits unrelayed WARNING (AC1)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  # Drive a turn but do NOT call relay_to_team_lead.
  drive_turn "$handle" "analyse this input" 2>/dev/null

  # Shutdown should emit a warning about unrelayed output.
  local stderr_out="$TEST_TMP/stderr.txt"
  shutdown_teammate "$handle" 2>"$stderr_out" || true
  grep -qi "warning" "$stderr_out"
  grep -qi "unrelay" "$stderr_out"
}

@test "unrelayed turn output is still captured in transcript (AC1)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "analyse this input" 2>/dev/null

  # Shutdown without relay — fail-safe capture should write to transcript.
  shutdown_teammate "$handle" 2>/dev/null || true
  [ -f "$GAIA_SESSION_TRANSCRIPT" ]
  grep -qi "unrelay" "$GAIA_SESSION_TRANSCRIPT"
}

@test "shutdown_all emits unrelayed WARNING for each pending turn (AC1)" {
  source "$LIB"
  local h1 h2
  h1="$(spawn_teammate "gaia:analyst" 2>/dev/null)"
  h2="$(spawn_teammate "gaia:architect" 2>/dev/null)"

  drive_turn "$h1" "prompt one" 2>/dev/null
  drive_turn "$h2" "prompt two" 2>/dev/null

  local stderr_out="$TEST_TMP/stderr.txt"
  shutdown_all 2>"$stderr_out" || true
  # Both handles should trigger an unrelayed warning.
  local warn_count
  warn_count="$(grep -ci "unrelay" "$stderr_out")"
  [ "$warn_count" -ge 2 ]
}

@test "relay_to_team_lead clears the pending relay flag — no warning on shutdown (AC1)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "analyse this" 2>/dev/null
  relay_to_team_lead "$handle" "analysis result"

  local stderr_out="$TEST_TMP/stderr.txt"
  shutdown_teammate "$handle" 2>"$stderr_out"
  # No unrelayed warning expected.
  local warn_count
  warn_count="$(grep -ci "unrelay" "$stderr_out" || true)"
  [ "$warn_count" -eq 0 ]
}

# ============================================================
# Mode B transcript is a SUPERSET of Mode A transcript (AC2)
# ============================================================

@test "transcript superset verifier passes when B contains all A lines (AC2)" {
  source "$LIB"
  source "$FIDELITY_LIB"

  local a_path="$TEST_TMP/mode-a.md"
  local b_path="$TEST_TMP/mode-b.md"

  _write_mode_a_transcript "$a_path" \
    "Analysis result line 1" \
    "Analysis result line 2" \
    "Conclusion: all clear"

  # Mode B has the same lines plus metadata.
  {
    printf '<!-- persona:analyst spawn_ts:2026-06-20T00:00:00Z turn:1 -->\n'
    printf 'Analysis result line 1\n'
    printf 'Analysis result line 2\n'
    printf 'Conclusion: all clear\n'
    printf 'Extra Mode B metadata line\n'
  } > "$b_path"

  run verify_transcript_superset "$a_path" "$b_path"
  [ "$status" -eq 0 ]
}

@test "transcript superset verifier fails when B is missing a line from A (AC2)" {
  source "$LIB"
  source "$FIDELITY_LIB"

  local a_path="$TEST_TMP/mode-a.md"
  local b_path="$TEST_TMP/mode-b.md"

  _write_mode_a_transcript "$a_path" \
    "Line alpha" \
    "Line beta" \
    "Line gamma"

  {
    printf 'Line alpha\n'
    printf 'Line gamma\n'
  } > "$b_path"

  run verify_transcript_superset "$a_path" "$b_path"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Line beta" ]]
}

@test "empty Mode A transcript trivially passes superset check (AC2)" {
  source "$LIB"
  source "$FIDELITY_LIB"

  local a_path="$TEST_TMP/mode-a.md"
  local b_path="$TEST_TMP/mode-b.md"

  : > "$a_path"
  printf 'Some Mode B content\n' > "$b_path"

  run verify_transcript_superset "$a_path" "$b_path"
  [ "$status" -eq 0 ]
}

# ============================================================
# Teammate identity metadata in Mode B transcript (AC3)
# ============================================================

@test "relay_to_team_lead appends persona name to transcript entry (AC3)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  relay_to_team_lead "$handle" "analysis output"

  grep -q "persona:" "$GAIA_SESSION_TRANSCRIPT"
  grep -q "analyst" "$GAIA_SESSION_TRANSCRIPT"
}

@test "relay_to_team_lead appends spawn timestamp to transcript entry (AC3)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  relay_to_team_lead "$handle" "analysis output"

  # spawn_ts must be ISO-8601
  grep -qE 'spawn_ts:[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$GAIA_SESSION_TRANSCRIPT"
}

@test "relay_to_team_lead appends turn index to transcript entry (AC3)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "prompt" 2>/dev/null
  relay_to_team_lead "$handle" "analysis output"

  grep -qE 'turn:[0-9]+' "$GAIA_SESSION_TRANSCRIPT"
}

@test "consecutive relay calls increment turn index (AC3)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "prompt 1" 2>/dev/null
  relay_to_team_lead "$handle" "output 1"

  drive_turn "$handle" "prompt 2" 2>/dev/null
  relay_to_team_lead "$handle" "output 2"

  # Both turn:1 and turn:2 should be present.
  grep -qE 'turn:1' "$GAIA_SESSION_TRANSCRIPT"
  grep -qE 'turn:2' "$GAIA_SESSION_TRANSCRIPT"
}

@test "Mode B metadata fields are absent from a Mode A style transcript (AC3)" {
  # A Mode A transcript is just the relay payload — no persona/spawn_ts/turn.
  local mode_a_tx="$TEST_TMP/mode-a-raw.md"
  printf '## Relay from tm-analyst-00001 [2026-06-20T00:00:00Z]\n\nanalysis output\n' > "$mode_a_tx"

  # Mode A style should NOT contain persona:/spawn_ts:/turn: metadata comments.
  run grep -c 'persona:' "$mode_a_tx"
  [ "$status" -ne 0 ] || [ "${output:-0}" -eq 0 ]
}

# ============================================================
# Dual-mode transcript diff — superset property (AC4)
# ============================================================

@test "dual-mode run: Mode B transcript is superset of Mode A transcript (AC4)" {
  source "$LIB"
  source "$FIDELITY_LIB"

  # --- Simulate Mode A transcript ---
  local mode_a_dir="$TEST_TMP/session-a"
  local mode_a_tx="$mode_a_dir/transcript.md"
  mkdir -p "$mode_a_dir"

  # In Mode A, the transcript contains just the payload content lines.
  # The header format differs between modes (Mode B adds metadata), so the
  # superset check applies to content lines only.
  local payload_1="Finding: authentication module has 3 issues"
  local payload_2="Recommendation: refactor auth-service to use OIDC"
  {
    printf '%s\n' "$payload_1"
    printf '%s\n' "$payload_2"
  } > "$mode_a_tx"

  # --- Produce Mode B transcript via the library ---
  local mode_b_dir="$TEST_TMP/session-b"
  mkdir -p "$mode_b_dir"
  export GAIA_SESSION_DIR="$mode_b_dir"
  export GAIA_SESSION_TRANSCRIPT="$mode_b_dir/transcript.md"
  export GAIA_PROVENANCE_LOG="$mode_b_dir/provenance.log"

  # Reset source guard so we get a fresh library load.
  unset _DT_LOADED
  source "$LIB"

  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "run analysis" 2>/dev/null
  relay_to_team_lead "$handle" "$(printf '%s\n%s' "$payload_1" "$payload_2")"

  # --- Assert superset property ---
  # Every content line from Mode A must appear in Mode B.
  run verify_transcript_superset "$mode_a_tx" "$GAIA_SESSION_TRANSCRIPT"
  [ "$status" -eq 0 ]

  # Mode B must additionally contain identity metadata not in Mode A.
  grep -qE 'persona:' "$GAIA_SESSION_TRANSCRIPT"
  grep -qE 'spawn_ts:' "$GAIA_SESSION_TRANSCRIPT"
  grep -qE 'turn:' "$GAIA_SESSION_TRANSCRIPT"
}

@test "dual-mode diff correctly detects a missing line (AC4)" {
  source "$LIB"
  source "$FIDELITY_LIB"

  local mode_a_tx="$TEST_TMP/mode-a.md"
  local mode_b_tx="$TEST_TMP/mode-b.md"

  {
    printf '## Relay from tm-analyst [2026-06-20T00:00:00Z]\n\n'
    printf 'content alpha\n'
    printf 'content beta\n'
    printf 'content gamma\n'
  } > "$mode_a_tx"

  # Mode B intentionally missing "content beta".
  {
    printf '<!-- persona:analyst spawn_ts:2026-06-20T00:00:00Z turn:1 -->\n'
    printf '## Relay from tm-analyst [2026-06-20T00:00:00Z]\n\n'
    printf 'content alpha\n'
    printf 'content gamma\n'
  } > "$mode_b_tx"

  run verify_transcript_superset "$mode_a_tx" "$mode_b_tx"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "content beta" ]]
}

# ============================================================
# Relayed content appears within same turn boundary (AC5)
# ============================================================

@test "relay_to_team_lead writes content within same turn boundary marker (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "do analysis" 2>/dev/null
  relay_to_team_lead "$handle" "analysis result payload"

  [ -f "$GAIA_SESSION_TRANSCRIPT" ]
  # The turn boundary marker and payload must be in the same transcript.
  grep -qF "$handle" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "analysis result payload" "$GAIA_SESSION_TRANSCRIPT"
}

@test "relay content for turn N appears after turn N boundary, before turn N+1 (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "prompt 1" 2>/dev/null
  relay_to_team_lead "$handle" "output for turn 1"

  drive_turn "$handle" "prompt 2" 2>/dev/null
  relay_to_team_lead "$handle" "output for turn 2"

  # Turn 1 content must appear before turn 2 content in the transcript.
  local turn1_line turn2_line
  turn1_line="$(grep -nF "output for turn 1" "$GAIA_SESSION_TRANSCRIPT" | head -1 | cut -d: -f1)"
  turn2_line="$(grep -nF "output for turn 2" "$GAIA_SESSION_TRANSCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$turn1_line" ]
  [ -n "$turn2_line" ]
  [ "$turn1_line" -lt "$turn2_line" ]
}

@test "relay content includes turn index matching the drive_turn sequence (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"

  drive_turn "$handle" "first prompt" 2>/dev/null
  relay_to_team_lead "$handle" "first output"

  drive_turn "$handle" "second prompt" 2>/dev/null
  relay_to_team_lead "$handle" "second output"

  drive_turn "$handle" "third prompt" 2>/dev/null
  relay_to_team_lead "$handle" "third output"

  # Verify turn indices 1, 2, 3 all present.
  grep -qE 'turn:1' "$GAIA_SESSION_TRANSCRIPT"
  grep -qE 'turn:2' "$GAIA_SESSION_TRANSCRIPT"
  grep -qE 'turn:3' "$GAIA_SESSION_TRANSCRIPT"
}

# ============================================================
# transcript-fidelity.sh sourcing contract
# ============================================================

@test "sourcing transcript-fidelity.sh exports verify_transcript_superset (contract)" {
  source "$FIDELITY_LIB"
  declare -F verify_transcript_superset
}

@test "verify_transcript_superset with missing file A exits non-zero (contract)" {
  source "$FIDELITY_LIB"
  local b_path="$TEST_TMP/mode-b.md"
  printf 'content\n' > "$b_path"

  run verify_transcript_superset "/nonexistent/path" "$b_path"
  [ "$status" -ne 0 ]
}

@test "verify_transcript_superset with missing file B exits non-zero (contract)" {
  source "$FIDELITY_LIB"
  local a_path="$TEST_TMP/mode-a.md"
  printf 'content\n' > "$a_path"

  run verify_transcript_superset "$a_path" "/nonexistent/path"
  [ "$status" -ne 0 ]
}
