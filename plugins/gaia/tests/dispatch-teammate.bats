#!/usr/bin/env bats
# dispatch-teammate.bats — unit tests for scripts/lib/dispatch-teammate.sh
#
# Covers the 6-function Mode B dispatch library: spawn_teammate, drive_turn,
# await_reply, relay_to_team_lead, shutdown_teammate, shutdown_all.
#
# Substrate-honest: tests exercise the bash plumbing (registry, ceiling,
# provenance, frontmatter parse, transcript append, shutdown bookkeeping).
# Live SendMessage / background Agent round-trips are NOT asserted — the
# fallback detection path is tested instead.

load 'test_helper.bash'

setup() {
  common_setup

  LIB_DIR="$SCRIPTS_DIR/lib"
  LIB="$LIB_DIR/dispatch-teammate.sh"

  # Session-scoped directories for the library under test.
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  # Force substrate unavailable by default — tests exercise plumbing, not
  # live Agent/SendMessage round-trips.
  export GAIA_MODE_B_SUBSTRATE="${GAIA_MODE_B_SUBSTRATE:-unavailable}"
}

teardown() { common_teardown; }

# ============================================================
# AC1 — Six-function export contract
# ============================================================

@test "sourcing the library exports spawn_teammate (AC1)" {
  source "$LIB"
  declare -F spawn_teammate
}

@test "sourcing the library exports drive_turn (AC1)" {
  source "$LIB"
  declare -F drive_turn
}

@test "sourcing the library exports await_reply (AC1)" {
  source "$LIB"
  declare -F await_reply
}

@test "sourcing the library exports relay_to_team_lead (AC1)" {
  source "$LIB"
  declare -F relay_to_team_lead
}

@test "sourcing the library exports shutdown_teammate (AC1)" {
  source "$LIB"
  declare -F shutdown_teammate
}

@test "sourcing the library exports shutdown_all (AC1)" {
  source "$LIB"
  declare -F shutdown_all
}

@test "each function accepts at least 1 argument without exit 127 (AC1)" {
  source "$LIB"
  for fn in spawn_teammate drive_turn await_reply relay_to_team_lead shutdown_teammate shutdown_all; do
    run bash -c "source '$LIB' && export GAIA_SESSION_DIR='$GAIA_SESSION_DIR' GAIA_PROVENANCE_LOG='$GAIA_PROVENANCE_LOG' GAIA_SESSION_TRANSCRIPT='$GAIA_SESSION_TRANSCRIPT' GAIA_MODE_B_SUBSTRATE=unavailable && $fn --help 2>&1; echo EXIT:\$?"
    [[ "$output" =~ EXIT: ]]
    # Extract exit code — must not be 127 (command not found)
    local ec
    ec="$(echo "$output" | grep -oE 'EXIT:[0-9]+' | head -1 | cut -d: -f2)"
    [ "$ec" -ne 127 ]
  done
}

@test "sourcing does not create files under session dir (AC1)" {
  local before
  before="$(find "$GAIA_SESSION_DIR" -type f 2>/dev/null | wc -l)"
  source "$LIB"
  local after
  after="$(find "$GAIA_SESSION_DIR" -type f 2>/dev/null | wc -l)"
  [ "$before" -eq "$after" ]
}

@test "sourcing twice is idempotent — no warnings on stderr (AC1)" {
  run bash -c "export GAIA_SESSION_DIR='$GAIA_SESSION_DIR' GAIA_PROVENANCE_LOG='$GAIA_PROVENANCE_LOG' GAIA_SESSION_TRANSCRIPT='$GAIA_SESSION_TRANSCRIPT' GAIA_MODE_B_SUBSTRATE=unavailable && source '$LIB' && source '$LIB' 2>&1"
  [[ ! "$output" =~ "already defined" ]]
  [ "$status" -eq 0 ]
}

# ============================================================
# AC2 — spawn_teammate: provenance and context payload
# ============================================================

@test "spawn_teammate records dispatched_via:teammate in provenance log (AC2)" {
  source "$LIB"
  spawn_teammate "gaia:qa" --context "payload" >/dev/null
  [ -f "$GAIA_PROVENANCE_LOG" ]
  grep -qF "dispatched_via:teammate" "$GAIA_PROVENANCE_LOG"
}

@test "spawn_teammate provenance entry includes the persona name (AC2)" {
  source "$LIB"
  spawn_teammate "gaia:qa" --context "payload" >/dev/null
  grep -qF "gaia:qa" "$GAIA_PROVENANCE_LOG"
}

@test "spawn_teammate passes context payload verbatim to the provenance log (AC2)" {
  source "$LIB"
  local ctx="sprint-context: sprint-68, story: test-story"
  spawn_teammate "gaia:qa" --context "$ctx" >/dev/null
  grep -qF "$ctx" "$GAIA_PROVENANCE_LOG"
}

@test "spawn_teammate exits 0 and emits a non-empty handle on stdout (AC2)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:qa")"
  [ -n "$handle" ]
}

@test "spawn_teammate provenance entry has ISO-8601 timestamp (AC2)" {
  source "$LIB"
  spawn_teammate "gaia:architect" >/dev/null
  # ISO-8601: YYYY-MM-DDTHH:MM:SS
  grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$GAIA_PROVENANCE_LOG"
}

# ============================================================
# AC3 — 8-teammate ceiling enforcement
# ============================================================

@test "exactly 8 teammates is permitted (AC3)" {
  source "$LIB"
  local i
  for i in $(seq 1 8); do
    spawn_teammate "gaia:agent-$i" >/dev/null
  done
  # Verify count
  local count
  count="$(_dt_active_count)"
  [ "$count" -eq 8 ]
}

@test "9th spawn_teammate fails non-zero citing the 8-teammate ceiling (AC3)" {
  source "$LIB"
  local i
  for i in $(seq 1 8); do
    spawn_teammate "gaia:agent-$i" >/dev/null
  done
  run spawn_teammate "gaia:agent-9"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "8" ]] || [[ "$output" =~ "ceiling" ]]
}

@test "ceiling resets after shutdown — freed slot allows new spawn (AC3)" {
  source "$LIB"
  local handle last_handle
  local i
  for i in $(seq 1 8); do
    last_handle="$(spawn_teammate "gaia:agent-$i")"
  done
  # Shut down the last one
  shutdown_teammate "$last_handle"
  # Spawn a new one — should succeed
  spawn_teammate "gaia:sm" >/dev/null
  local count
  count="$(_dt_active_count)"
  [ "$count" -eq 8 ]
}

@test "ceiling error message contains no internal traceability IDs (AC3)" {
  source "$LIB"
  local i
  for i in $(seq 1 8); do
    spawn_teammate "gaia:agent-$i" >/dev/null
  done
  run spawn_teammate "gaia:agent-9"
  [[ ! "$output" =~ FR- ]]
  [[ ! "$output" =~ ADR- ]]
  [[ ! "$output" =~ E[0-9]+-S ]]
}

# ============================================================
# AC4 — SKILL.md frontmatter roster:/topology: resolution
# ============================================================

_write_skill_fixture() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SKILLEOF'
---
SKILLEOF
  # Append caller-provided YAML lines
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$path"
  done
  cat >> "$path" <<'SKILLEOF'
---
# Test Skill

Body text.
SKILLEOF
}

@test "roster with hub topology resolves persona names from frontmatter (AC4)" {
  source "$LIB"
  local fixture="$TEST_TMP/skills/test-skill/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-skill" \
    "roster:" \
    "  - name: qa" \
    "    persona: gaia:qa" \
    "  - name: architect" \
    "    persona: gaia:architect" \
    "topology: hub"

  run _dt_parse_frontmatter "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "gaia:qa" ]]
  [[ "$output" =~ "gaia:architect" ]]
  [[ "$output" =~ "hub" ]]
}

@test "mesh topology is accepted without error (AC4)" {
  source "$LIB"
  local fixture="$TEST_TMP/skills/test-skill/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-skill" \
    "roster:" \
    "  - name: qa" \
    "    persona: gaia:qa" \
    "topology: mesh"

  run _dt_parse_frontmatter "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "mesh" ]]
}

@test "missing roster falls back to explicit persona argument (AC4)" {
  source "$LIB"
  local fixture="$TEST_TMP/skills/test-skill/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-skill" \
    "topology: hub"

  # No roster — spawning with explicit persona should work
  spawn_teammate "gaia:qa" >/dev/null
}

@test "unknown topology emits warning and defaults to hub (AC4)" {
  source "$LIB"
  local fixture="$TEST_TMP/skills/test-skill/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-skill" \
    "roster:" \
    "  - name: qa" \
    "    persona: gaia:qa" \
    "topology: unknown-value"

  run _dt_parse_frontmatter "$fixture"
  [ "$status" -eq 0 ]
  # Warning mentions the unrecognised value
  [[ "$output" =~ "unknown-value" ]]
  # Effective topology defaults to hub
  [[ "$output" =~ "hub" ]]
}

# ============================================================
# AC5 — relay_to_team_lead: verbatim relay and transcript append
# ============================================================

@test "relay_to_team_lead writes output verbatim to transcript (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:qa")"
  local payload
  payload="$(printf 'Line 1\nLine 2\nLine 3\nLine 4\nLine 5')"

  relay_to_team_lead "$handle" "$payload"

  [ -f "$GAIA_SESSION_TRANSCRIPT" ]
  grep -qF "Line 1" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "Line 5" "$GAIA_SESSION_TRANSCRIPT"
}

@test "relay appends to existing transcript without overwriting (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:qa")"

  # Seed transcript with prior content
  printf '## Prior entry 1\nfoo\n\n## Prior entry 2\nbar\n' > "$GAIA_SESSION_TRANSCRIPT"
  local before
  before="$(wc -l < "$GAIA_SESSION_TRANSCRIPT")"

  relay_to_team_lead "$handle" "new-output"

  local after
  after="$(wc -l < "$GAIA_SESSION_TRANSCRIPT")"
  [ "$after" -gt "$before" ]
  # Prior content preserved
  grep -qF "Prior entry 1" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "Prior entry 2" "$GAIA_SESSION_TRANSCRIPT"
  # New content appended
  grep -qF "new-output" "$GAIA_SESSION_TRANSCRIPT"
}

@test "relay transcript entry includes source teammate attribution (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:qa")"

  relay_to_team_lead "$handle" "analysis complete"

  grep -qF "$handle" "$GAIA_SESSION_TRANSCRIPT"
}

@test "relay with empty output is a no-op — no blank entry appended (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:qa")"

  # Seed transcript
  printf '## Prior entry\nfoo\n' > "$GAIA_SESSION_TRANSCRIPT"
  local before
  before="$(wc -l < "$GAIA_SESSION_TRANSCRIPT")"

  relay_to_team_lead "$handle" ""

  local after
  after="$(wc -l < "$GAIA_SESSION_TRANSCRIPT")"
  [ "$before" -eq "$after" ]
}

# ============================================================
# AC6 — shutdown_all: full teardown and count reset
# ============================================================

@test "shutdown_all with 3 active teammates resets count to zero (AC6)" {
  source "$LIB"
  spawn_teammate "gaia:qa" >/dev/null
  spawn_teammate "gaia:architect" >/dev/null
  spawn_teammate "gaia:sm" >/dev/null

  local count
  count="$(_dt_active_count)"
  [ "$count" -eq 3 ]

  shutdown_all

  count="$(_dt_active_count)"
  [ "$count" -eq 0 ]
}

@test "shutdown_all on empty registry exits 0 without error (AC6)" {
  source "$LIB"
  run shutdown_all
  [ "$status" -eq 0 ]
}

@test "shutdown_all tolerates a single bad handle — partial failure (AC6)" {
  source "$LIB"
  spawn_teammate "gaia:qa" >/dev/null
  spawn_teammate "gaia:architect" >/dev/null
  spawn_teammate "gaia:sm" >/dev/null

  # Corrupt handle 2 in the registry to simulate an unreachable teammate
  _dt_corrupt_handle 2

  run shutdown_all
  # Non-zero to signal partial failure
  [ "$status" -ne 0 ]

  # Count reflects only the unresolved entry
  local count
  count="$(_dt_active_count)"
  [ "$count" -eq 1 ]
}

# ============================================================
# Substrate fallback — MODE_B_FALLBACK detection
# ============================================================

@test "spawn_teammate emits MODE_B_FALLBACK when substrate is unavailable (fallback)" {
  source "$LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local handle stderr_out
  stderr_out="$TEST_TMP/stderr.txt"
  handle="$(spawn_teammate "gaia:qa" 2>"$stderr_out")"
  [ -n "$handle" ]
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "drive_turn emits MODE_B_FALLBACK when substrate is unavailable (fallback)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:qa" 2>/dev/null)"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  drive_turn "$handle" "do analysis" 2>"$stderr_out" || true
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "await_reply emits MODE_B_FALLBACK when substrate is unavailable (fallback)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:qa" 2>/dev/null)"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  await_reply "$handle" 2>"$stderr_out" || true
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}
