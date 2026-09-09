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
  spawn_teammate "gaia:analyst" --context "payload" >/dev/null
  [ -f "$GAIA_PROVENANCE_LOG" ]
  grep -qF "dispatched_via:teammate" "$GAIA_PROVENANCE_LOG"
}

@test "spawn_teammate provenance entry includes the persona name (AC2)" {
  source "$LIB"
  spawn_teammate "gaia:analyst" --context "payload" >/dev/null
  grep -qF "gaia:analyst" "$GAIA_PROVENANCE_LOG"
}

@test "spawn_teammate passes context payload verbatim to the provenance log (AC2)" {
  source "$LIB"
  local ctx="sprint-context: sprint-68, story: test-story"
  spawn_teammate "gaia:analyst" --context "$ctx" >/dev/null
  grep -qF "$ctx" "$GAIA_PROVENANCE_LOG"
}

@test "spawn_teammate exits 0 and emits a non-empty handle on stdout (AC2)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst")"
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
    "  - name: analyst" \
    "    persona: gaia:analyst" \
    "  - name: architect" \
    "    persona: gaia:architect" \
    "topology: hub"

  run _dt_parse_frontmatter "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "gaia:analyst" ]]
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
  spawn_teammate "gaia:analyst" >/dev/null
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
  handle="$(spawn_teammate "gaia:analyst")"
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
  handle="$(spawn_teammate "gaia:analyst")"

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
  handle="$(spawn_teammate "gaia:analyst")"

  relay_to_team_lead "$handle" "analysis complete"

  grep -qF "$handle" "$GAIA_SESSION_TRANSCRIPT"
}

@test "relay with empty output is a no-op — no blank entry appended (AC5)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst")"

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
  spawn_teammate "gaia:analyst" >/dev/null
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
  spawn_teammate "gaia:analyst" >/dev/null
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
  handle="$(spawn_teammate "gaia:analyst" 2>"$stderr_out")"
  [ -n "$handle" ]
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "drive_turn is pre-send bookkeeping only — no send, no MODE_B_FALLBACK" {
  # drive_turn records turn-counter + relay-pending; it never sends (the
  # orchestrator's SendMessage tool call does that) so it never falls back —
  # not even with the substrate forced unavailable. (Regression guard for the
  # old stub that mis-emitted MODE_B_FALLBACK and implied a bash send.)
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  run drive_turn "$handle" "do analysis" 2>"$stderr_out"
  [ "$status" -eq 0 ]
  ! grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "drive_turn raises relay-pending (bookkeeping effect)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"
  drive_turn "$handle" "do analysis" >/dev/null 2>&1
  # await_reply reports relay-pending state — exit 0 means pending.
  run await_reply "$handle"
  [ "$status" -eq 0 ]
}

@test "await_reply is a relay-pending state query, not a fetch — clears after relay" {
  # Replies auto-deliver to the orchestrator; await_reply does NOT block or
  # fetch and does NOT emit MODE_B_FALLBACK. It returns 0 while relay-pending,
  # 1 once the turn has been relayed.
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  drive_turn "$handle" "do analysis" >/dev/null 2>&1
  local stderr_out="$TEST_TMP/stderr.txt"
  run await_reply "$handle" 2>"$stderr_out"     # pending after drive
  [ "$status" -eq 0 ]
  ! grep -qF "MODE_B_FALLBACK" "$stderr_out"
  relay_to_team_lead "$handle" "analyst: done" >/dev/null 2>&1
  run await_reply "$handle"                      # not pending after relay
  [ "$status" -ne 0 ]
}

# ============================================================
# Gate-2 substrate-availability resolution
# (default Mode A; experimental opt-in makes Mode B actually run)
# ============================================================

@test "substrate is UNAVAILABLE by default — no opt-in, no override (Mode A default)" {
  source "$LIB"
  # Clear both the inherited test override and the experimental opt-in.
  unset GAIA_MODE_B_SUBSTRATE CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
  run _dt_substrate_available
  [ "$status" -ne 0 ]
}

@test "substrate is AVAILABLE when the experimental Agent-Teams flag is opted in (Mode B runs)" {
  source "$LIB"
  unset GAIA_MODE_B_SUBSTRATE
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  run _dt_substrate_available
  [ "$status" -eq 0 ]
}

@test "GAIA_MODE_B_SUBSTRATE=unavailable override wins even with the opt-in flag set (roster-cost path)" {
  source "$LIB"
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  export GAIA_MODE_B_SUBSTRATE=unavailable
  run _dt_substrate_available
  [ "$status" -ne 0 ]
}

@test "GAIA_MODE_B_SUBSTRATE=available override forces the live path (no opt-in flag needed)" {
  source "$LIB"
  unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
  export GAIA_MODE_B_SUBSTRATE=available
  run _dt_substrate_available
  [ "$status" -eq 0 ]
}

@test "spawn_teammate does NOT emit MODE_B_FALLBACK when the experimental flag is opted in (Mode B live)" {
  source "$LIB"
  unset GAIA_MODE_B_SUBSTRATE
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  local stderr_out="$TEST_TMP/stderr.txt"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>"$stderr_out")"
  [ -n "$handle" ]
  # Under the opted-in live path, the fallback token must NOT appear.
  ! grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "the clean-room gate STILL blocks reviewers under the live (opted-in) path" {
  source "$LIB"
  unset GAIA_MODE_B_SUBSTRATE
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  run spawn_teammate "gaia:validator"
  [ "$status" -ne 0 ]
}

# ============================================================
# Story-keyed handles, retry contract, and the programmatic
# fallback signal
# ============================================================

@test "story-keyed spawn returns a handle built from persona and story key (AC1)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(spawn_teammate "bash-dev" --story-key "K1-K1" 2>/dev/null)"
  [ "$handle" = "tm-bash-dev-K1-K1" ]
}

@test "two same-persona spawns for different stories return distinct handles (AC1)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local a b
  a="$(spawn_teammate "bash-dev" --story-key "K1-K1" 2>/dev/null)"
  b="$(spawn_teammate "bash-dev" --story-key "K1-K2" 2>/dev/null)"
  [ "$a" != "$b" ]
  [ "$a" = "tm-bash-dev-K1-K1" ]
  [ "$b" = "tm-bash-dev-K1-K2" ]
  # Neither handle may carry the shell's process id: within one session the
  # process id is constant, so a process-derived handle collides by design.
  case "$a" in *"$$"*) echo "handle carries the process id: $a"; return 1 ;; esac
  case "$b" in *"$$"*) echo "handle carries the process id: $b"; return 1 ;; esac
}

@test "each story-keyed handle maps back to its own story key (AC1)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local a b
  a="$(spawn_teammate "bash-dev" --story-key "K1-K1" 2>/dev/null)"
  b="$(spawn_teammate "bash-dev" --story-key "K1-K2" 2>/dev/null)"
  [ "$(_dt_read_story_key "$a")" = "K1-K1" ]
  [ "$(_dt_read_story_key "$b")" = "K1-K2" ]
}

@test "handle contains no process identifier on the story-keyed path (AC1)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(spawn_teammate "gaia:analyst" --story-key "K1-K1" 2>/dev/null)"
  [ -n "$handle" ]
  case "$handle" in
    *"$$"*) echo "process id leaked into story-keyed handle: $handle"; return 1 ;;
  esac
  # Positive half: the handle is composed of persona and key, nothing else.
  [ "$handle" = "tm-gaia-analyst-K1-K1" ]
}

@test "a keyless spawn keeps the existing handle shape (AC4)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "bash-dev" 2>/dev/null)"
  [ "$handle" = "$(printf 'tm-bash-dev-%05d' "$$")" ]
}

@test "a story key with punctuation is sanitised into a usable handle (AC-EC1)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(spawn_teammate "bash-dev" --story-key "k1.k2_k3" 2>/dev/null)"
  [ "$handle" = "tm-bash-dev-k1-k2-k3" ]
  [ -f "$GAIA_SESSION_DIR/registry/$handle" ]
}

@test "an overlong story key is truncated to a bounded handle (AC-EC1)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local long_key
  long_key="$(printf 'k%.0s' $(seq 1 300))"
  local handle
  handle="$(spawn_teammate "bash-dev" --story-key "$long_key" 2>/dev/null)"
  # The handle is derived from the key (so a bound is not satisfied vacuously
  # by ignoring the key), and the derived part is capped rather than unbounded.
  [ "$handle" = "tm-bash-dev-$(printf 'k%.0s' $(seq 1 64))" ]
  [ "${#handle}" -le 80 ]
  [ -f "$GAIA_SESSION_DIR/registry/$handle" ]
}

@test "a story key of only punctuation is refused (AC-EC1)" {
  source "$LIB"
  # The substrate must be present, or the absent-substrate contract would
  # return its own non-zero code before the key guard is ever reached.
  export GAIA_MODE_B_SUBSTRATE=available
  run spawn_teammate "bash-dev" --story-key "..__.."
  # Pin the refusal itself: a status borrowed from any other contract must
  # not be mistaken for the key guard.
  [ "$status" -eq 1 ] \
    || { echo "expected the key refusal status 1, got [$status]: [$output]"; return 1; }
  [[ "$output" == *"sanitises to nothing"* ]] \
    || { echo "no sanitises-to-nothing refusal emitted: [$output]"; return 1; }
  # A key that sanitises to nothing must yield no handle at all — an empty
  # token would collapse distinct stories onto one lineage.
  [[ "$output" != *"tm-bash-dev"* ]] \
    || { echo "a handle was emitted for an empty sanitised key: [$output]"; return 1; }
  # Nothing may be registered for a key that sanitises to nothing.
  [ "$(_dt_active_count)" -eq 0 ]
}

@test "retrying the same persona and story key reuses the one handle (AC5)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local first second
  run spawn_teammate "bash-dev" --story-key "K1-K1"
  [ "$status" -eq 0 ]
  first="$output"
  run spawn_teammate "bash-dev" --story-key "K1-K1"
  [ "$status" -eq 0 ]
  second="$output"
  [ "$first" = "$second" ]
}

@test "a retried spawn leaves exactly one registry entry (AC5)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  spawn_teammate "bash-dev" --story-key "K1-K1" >/dev/null 2>&1
  spawn_teammate "bash-dev" --story-key "K1-K1" >/dev/null 2>&1
  [ "$(_dt_active_count)" -eq 1 ]
}

@test "two different story keys that normalise alike are refused (AC-EC2)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local first
  first="$(spawn_teammate "bash-dev" --story-key "k1.k1" 2>/dev/null)"
  [ -n "$first" ]
  # A different raw key that sanitises to the same token must not silently
  # adopt the first story's handle and attribution lineage.
  run spawn_teammate "bash-dev" --story-key "k1_k1"
  [ "$status" -ne 0 ]
  [ "$(_dt_active_count)" -eq 1 ]
}

@test "an unavailable substrate returns the documented fallback code (AC3)" {
  source "$LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  run spawn_teammate "bash-dev" --story-key "K1-K1"
  [ "$status" -eq 7 ]
}

@test "a fallback emits a machine-readable record and no handle (AC3)" {
  source "$LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stdout_file="$TEST_TMP/fallback-stdout.txt"
  local stderr_file="$TEST_TMP/fallback-stderr.txt"
  set +e
  spawn_teammate "bash-dev" --story-key "K1-K1" >"$stdout_file" 2>"$stderr_file"
  local rc=$?
  set -e
  [ "$rc" -eq 7 ]
  # The record carries the story key and a reason, and is NOT a handle.
  assert_file_contains "$stdout_file" "mode_b_fallback"
  assert_file_contains "$stdout_file" "story_key:K1-K1"
  assert_file_contains "$stdout_file" "reason:"
  assert_file_excludes "$stdout_file" "tm-bash-dev"
  # The human-readable token stays on stderr for existing consumers.
  assert_file_contains "$stderr_file" "MODE_B_FALLBACK"
}

@test "a fallback on the story-keyed path registers no teammate (AC-EC5)" {
  source "$LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  run spawn_teammate "bash-dev" --story-key "K1-K1"
  [ "$status" -eq 7 ]
  # No half-live handle may be left behind for a teammate never spawned.
  [ "$(_dt_active_count)" -eq 0 ]
  [ ! -f "$GAIA_SESSION_DIR/registry/tm-bash-dev-K1-K1" ]
}

@test "the story key is never mistaken for the persona (AC1)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(spawn_teammate --story-key "K1-K1" "bash-dev" 2>/dev/null)"
  # The flag arm must consume BOTH the flag and its value, so the persona is
  # the positional argument and the key never lands in the persona slot.
  [ "$handle" = "tm-bash-dev-K1-K1" ]
  [ "$(_dt_read_persona "$handle")" = "bash-dev" ]
  [ "$(_dt_read_story_key "$handle")" = "K1-K1" ]
}

@test "the story key appears in the transcript entry for a relayed turn (AC2)" {
  source "$LIB"
  # A story-keyed spawn only returns a handle when the substrate is
  # present; the absent-substrate contract is covered separately.
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(spawn_teammate "bash-dev" --story-key "K1-K1" 2>/dev/null)"
  drive_turn "$handle" "implement phase" >/dev/null 2>&1 || true
  relay_to_team_lead "$handle" "implement complete" >/dev/null 2>&1
  assert_file_contains "$GAIA_SESSION_TRANSCRIPT" "story_key:K1-K1"
  # The pre-existing metadata fields keep their place.
  assert_file_contains "$GAIA_SESSION_TRANSCRIPT" "persona:bash-dev"
}

@test "a relay still reaches the transcript when attribution cannot be locked (AC2)" {
  source "$LIB"
  source "$LIB_DIR/execution-mode-b-bridge.sh"
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(spawn_teammate "bash-dev" --story-key "K1-K1" 2>/dev/null)"
  local attr_lock="$GAIA_SESSION_DIR/relay-attribution/$handle.lock"
  mkdir -p "$GAIA_SESSION_DIR/relay-attribution"
  # Hold the per-handle attribution lock from a separate process for longer
  # than the relay's acquisition timeout.
  bash -c '
    source "'"$LIB_DIR"'/acquire-lock.sh"
    acquire_lock "'"$attr_lock"'" 5 9 || exit 1
    sleep 7
  ' &
  local holder=$!
  sleep 1
  # bats' run merges the command's stderr into $output, so the warning is
  # asserted there rather than in a redirected file.
  run execution_relay_turn "$handle" "implement complete"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  # Bookkeeping degrades; the delivered reply still reaches the transcript.
  [ "$status" -eq 0 ]
  assert_file_contains "$GAIA_SESSION_TRANSCRIPT" "implement complete"
  [[ "$output" == *attribution* ]] \
    || { echo "no attribution-degraded warning emitted: [$output]"; return 1; }
  # The reply must have reached the transcript BEFORE the bookkeeping stalled,
  # so the transcript append cannot be sequenced behind the lock: while the
  # holder still owns the lock, the entry is already durable.
  local held_lock_still=0
  [ -f "$attr_lock" ] && held_lock_still=1
  [ "$held_lock_still" -eq 1 ] \
    || { echo "lock file vanished — contention was not actually exercised"; return 1; }
  # And no attribution record was fabricated for a relay whose bookkeeping
  # never completed.
  [ ! -s "$GAIA_SESSION_DIR/relay-attribution/$handle" ] \
    || [ "$(sed -n 's/^relays://p' "$GAIA_SESSION_DIR/relay-attribution/$handle")" = "0" ] \
    || { echo "attribution counted a relay whose locked update never ran"; return 1; }
}

@test "a keyless relay records no story key without breaking the entry (AC4)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"
  drive_turn "$handle" "analyse" >/dev/null 2>&1 || true
  relay_to_team_lead "$handle" "analysis complete" >/dev/null 2>&1
  # Legacy handles keep every existing field and carry an explicit
  # no-story marker rather than a bare or malformed one.
  assert_file_contains "$GAIA_SESSION_TRANSCRIPT" "persona:gaia:analyst"
  assert_file_contains "$GAIA_SESSION_TRANSCRIPT" "story_key:none"
  run grep -cE '<!-- persona:[^ ]+ spawn_ts:[^ ]+ turn:[0-9]+ story_key:[^ ]+ -->' \
    "$GAIA_SESSION_TRANSCRIPT"
  [ "$output" -ge 1 ]
}

@test "the usage text advertises the story-key option and the fallback code (AC3)" {
  source "$LIB"
  run spawn_teammate --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--story-key"* ]]
  # Pin the code in context so documenting the wrong code cannot pass on a
  # stray digit elsewhere in the usage text.
  [[ "$output" == *"exit $_DT_FALLBACK_EXIT_CODE"* ]] \
    || { echo "usage text does not document the fallback exit code: [$output]"; return 1; }
  [[ "$output" == *"exit 7"* ]] \
    || { echo "documented fallback code drifted from 7: [$output]"; return 1; }
}

@test "the fallback exit code is unused elsewhere in the dispatch chain (AC-EC4)" {
  source "$LIB"
  # The code must be distinct: no other site in the dispatch library, the
  # cohort bridges, or the roster-cost probe may return or exit with it,
  # apart from the single named constant and the returns that reference it.
  local chain=(
    "$LIB_DIR/dispatch-teammate.sh"
    "$LIB_DIR/execution-mode-b-bridge.sh"
    "$LIB_DIR/planning-mode-b-bridge.sh"
    "$LIB_DIR/research-mode-b-bridge.sh"
    "$LIB_DIR/conversational-mode-b-bridge.sh"
    "$LIB_DIR/roster-cost.sh"
  )
  local f stray=0
  for f in "${chain[@]}"; do
    [ -f "$f" ] || continue
    local hits
    hits="$(grep -cE '^[[:space:]]*(return|exit)[[:space:]]+7[[:space:]]*(#.*)?$' "$f" || true)"
    if [ "$hits" -ne 0 ]; then
      echo "literal fallback code returned outside the named constant in $f ($hits)"
      stray=$((stray + hits))
    fi
  done
  [ "$stray" -eq 0 ]
  # And the constant itself is the documented value.
  [ "$_DT_FALLBACK_EXIT_CODE" -eq 7 ]
}

@test "the fail-safe capture for an unrelayed turn carries the story key last (AC2)" {
  source "$LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(spawn_teammate "bash-dev" --story-key "K1-K1" 2>/dev/null)"
  # A turn that is driven but never relayed is captured by the fail-safe on
  # shutdown — the second site that builds a metadata comment.
  drive_turn "$handle" "implement phase" >/dev/null 2>&1 || true
  shutdown_teammate "$handle" >/dev/null 2>&1 || true
  # Pin the whole comment shape, so moving the field or renaming its default
  # cannot pass: every pre-existing field keeps its position and the story
  # key is appended last.
  run grep -cE \
    '<!-- persona:bash-dev spawn_ts:[^ ]+ turn:[0-9]+ story_key:K1-K1 -->' \
    "$GAIA_SESSION_TRANSCRIPT"
  [ "$output" -eq 1 ] \
    || { echo "fail-safe comment does not end with the story key: [$(grep -o '<!--[^>]*-->' "$GAIA_SESSION_TRANSCRIPT")]"; return 1; }
}

@test "the fail-safe capture marks a keyless turn with no story (AC4)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"
  drive_turn "$handle" "analyse" >/dev/null 2>&1 || true
  shutdown_teammate "$handle" >/dev/null 2>&1 || true
  # A legacy handle gets the explicit no-story marker in the same last
  # position, never a bare or differently-named default.
  run grep -cE \
    '<!-- persona:gaia:analyst spawn_ts:[^ ]+ turn:[0-9]+ story_key:none -->' \
    "$GAIA_SESSION_TRANSCRIPT"
  [ "$output" -eq 1 ] \
    || { echo "fail-safe comment lacks the no-story marker: [$(grep -o '<!--[^>]*-->' "$GAIA_SESSION_TRANSCRIPT")]"; return 1; }
}
