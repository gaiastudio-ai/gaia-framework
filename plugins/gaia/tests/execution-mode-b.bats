#!/usr/bin/env bats
# execution-mode-b.bats — Mode B readiness tests for the 9 execution/sprint
# heavy-procedural skills.
#
# Covers the execution-lifecycle Mode B migration:
#   AC1 — dev-story persists the stack-developer teammate across phases
#   AC2 — sprint-plan spawns the sm subagent via the shared library seam
#   AC3 — run-all-reviews keeps reviewers one-shot (clean-room invariant)
#   AC4 — existing skill bats remain green (exercised by separate suites)
#   AC5 — shutdown is called at skill exit (no leaked panes)

load 'test_helper.bash'

setup() {
  common_setup

  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  LIB_DIR="$SCRIPTS_DIR/lib"
  DT_LIB="$LIB_DIR/dispatch-teammate.sh"
  EMB_LIB="$LIB_DIR/execution-mode-b-bridge.sh"

  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

  # The 9 execution/sprint skills under migration.
  EXECUTION_SKILLS=(
    gaia-dev-story
    gaia-sprint-plan
    gaia-run-all-reviews
    gaia-add-feature
    gaia-quick-spec
    gaia-quick-dev
    gaia-readiness-check
    gaia-atdd
    gaia-sprint-review
  )

  # Session dirs for dispatch-teammate.
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  # Force substrate unavailable — tests exercise plumbing + fallback.
  export GAIA_MODE_B_SUBSTRATE="${GAIA_MODE_B_SUBSTRATE:-unavailable}"
}

teardown() { common_teardown; }

# ============================================================
# Bridge library reachability + public seam
# ============================================================

@test "execution bridge library exists at canonical lib path" {
  [ -f "$EMB_LIB" ]
}

@test "execution bridge sources dispatch-teammate library" {
  grep -qF "dispatch-teammate.sh" "$EMB_LIB"
}

@test "execution bridge exposes execution_spawn_subagent function (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  declare -F execution_spawn_subagent
}

@test "execution bridge exposes execution_relay_turn function" {
  source "$DT_LIB"
  source "$EMB_LIB"
  declare -F execution_relay_turn
}

@test "execution bridge exposes execution_shutdown function (AC5)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  declare -F execution_shutdown
}

# ============================================================
# AC1 — spawn seam routes through spawn_teammate
# ============================================================

@test "execution_spawn_subagent calls spawn_teammate and returns a handle (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "execution_spawn_subagent registers in dispatch-teammate registry (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" >/dev/null 2>&1
  local count
  count="$(_dt_active_count)"
  [ "$count" -ge 1 ]
}

@test "execution_spawn_subagent records teammate dispatch provenance (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" >/dev/null 2>&1
  grep -qF "dispatched_via:teammate" "$GAIA_PROVENANCE_LOG"
}

@test "execution_spawn_subagent rejects reviewer persona via clean-room gate (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  run execution_spawn_subagent "validator" "gaia-run-all-reviews"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

# ============================================================
# AC1 (doc) — each of the 9 skills declares Mode B readiness
# ============================================================

@test "each execution skill declares a Mode B Readiness section (AC1)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$md" ] || { echo "missing SKILL.md: $skill"; return 1; }
    grep -qiF "Mode B Readiness" "$md" || { echo "no Mode B Readiness in $skill"; return 1; }
  done
}

@test "each execution skill names the shared bridge library (AC1)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "execution-mode-b-bridge.sh" "$md" || { echo "no bridge ref in $skill"; return 1; }
  done
}

@test "each execution skill names the spawn seam (AC1)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "execution_spawn_subagent" "$md" || { echo "no spawn seam in $skill"; return 1; }
  done
}

@test "each execution skill names the shutdown seam (AC5)" {
  for skill in "${EXECUTION_SKILLS[@]}"; do
    local md="$SKILLS_DIR/$skill/SKILL.md"
    grep -qF "execution_shutdown" "$md" || { echo "no shutdown seam in $skill"; return 1; }
  done
}

# ============================================================
# AC1 — dev-story persists the stack-developer across phases
# ============================================================

@test "dev-story spawn under Mode B yields a handle for the stack developer (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:python-dev" ]
}

@test "dev-story single teammate drives multiple phase turns without re-spawn (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" 2>/dev/null)"
  drive_turn "$handle" "plan phase" 2>/dev/null || true
  execution_relay_turn "$handle" "plan complete" 2>/dev/null
  drive_turn "$handle" "implement phase" 2>/dev/null || true
  execution_relay_turn "$handle" "implement complete" 2>/dev/null
  drive_turn "$handle" "test phase" 2>/dev/null || true
  execution_relay_turn "$handle" "test complete" 2>/dev/null
  # Still exactly one active teammate — no re-spawn across phases.
  [ "$(_dt_active_count)" -eq 1 ]
}

# ============================================================
# AC2 — sprint-plan spawns the sm subagent via the seam
# ============================================================

@test "sprint-plan spawn under Mode B yields a handle for the sm subagent (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" 2>/dev/null)"
  [ -n "$handle" ]
  local persona
  persona="$(_dt_read_persona "$handle")"
  [ "$persona" = "gaia:sm" ]
}

@test "sprint-plan relay carries planning output verbatim into transcript (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local handle
  handle="$(execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" 2>/dev/null)"
  drive_turn "$handle" "plan sprint" 2>/dev/null || true
  execution_relay_turn "$handle" "$(printf '## Sprint\n- selected: story-A')" 2>/dev/null
  grep -qF "## Sprint" "$GAIA_SESSION_TRANSCRIPT"
  grep -qF "selected: story-A" "$GAIA_SESSION_TRANSCRIPT"
}

# ============================================================
# AC3 — run-all-reviews clean-room invariant (reviewers one-shot)
# ============================================================

@test "run-all-reviews declares NO reviewer persona in any teammate roster (AC3)" {
  local md="$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  # Pull any persona declared on a roster: line (Mode B teammate roster).
  local rosters
  rosters="$(grep -E '^\s+persona:' "$md" 2>/dev/null || true)"
  # No roster lines at all is the strongest form of compliance.
  if [ -z "$rosters" ]; then
    return 0
  fi
  # If any roster line exists, it must NOT name a reviewer persona.
  local reviewers
  reviewers="$(grep -vE '^\s*#' "$SKILLS_DIR/../knowledge/reviewer-personas.txt" | grep -vE '^\s*$')"
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if printf '%s' "$rosters" | grep -qiE "persona:[[:space:]]*(gaia:)?${entry}([[:space:]]|$)"; then
      echo "run-all-reviews declares reviewer teammate: $entry"
      return 1
    fi
  done <<< "$reviewers"
  return 0
}

@test "run-all-reviews Mode B section states reviewers stay one-shot/clean-room (AC3)" {
  local md="$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  grep -qiE "one-shot" "$md"
  grep -qiE "clean-room|clean room" "$md"
}

@test "execution bridge clean-room gate blocks every reviewer persona (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  local reviewers
  reviewers="$(grep -vE '^\s*#' "$SKILLS_DIR/../knowledge/reviewer-personas.txt" | grep -vE '^\s*$')"
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    run execution_spawn_subagent "$entry" "gaia-run-all-reviews"
    [ "$status" -ne 0 ] || { echo "reviewer NOT blocked: $entry"; return 1; }
  done <<< "$reviewers"
}

# ============================================================
# AC5 — shutdown at skill exit (no leaked panes)
# ============================================================

@test "execution_shutdown clears all active teammates (AC5)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" >/dev/null 2>&1
  execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" >/dev/null 2>&1
  [ "$(_dt_active_count)" -ge 2 ]
  execution_shutdown 2>/dev/null
  [ "$(_dt_active_count)" -eq 0 ]
}

@test "execution_shutdown is idempotent with no active teammates (AC5)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  run execution_shutdown
  [ "$status" -eq 0 ]
}

# ============================================================
# AC1/AC5 — fallback honesty (substrate-gated)
# ============================================================

@test "execution_spawn_subagent emits MODE_B_FALLBACK when substrate absent — substrate-gated (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" >"$TEST_TMP/handle.txt" 2>"$stderr_out"
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "execution drive_turn is bookkeeping-only — no send, no MODE_B_FALLBACK (AC1)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local handle
  handle="$(execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" 2>/dev/null)"
  local stderr_out="$TEST_TMP/stderr.txt"
  run drive_turn "$handle" "plan" 2>"$stderr_out"
  [ "$status" -eq 0 ]
  # drive_turn never sends (the orchestrator's SendMessage does) so it never
  # falls back — regression guard for the old fallback-emitting stub.
  ! grep -qF "MODE_B_FALLBACK" "$stderr_out"
  await_reply "$handle"
}

# ============================================================
# No leaked IDs in the new bridge (regression gate)
# ============================================================

@test "execution-mode-b-bridge.sh contains no leaked internal IDs (regression)" {
  local f="$EMB_LIB"
  run grep -cE '(FR|NFR|ADR|TC)-[0-9]' "$f"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'E[0-9]+-S[0-9]+' "$f"
  [ "${output:-0}" -eq 0 ]
}

# ============================================================
# Per-handle relay attribution and the programmatic fallback
# ============================================================

@test "the bridge spawn seam accepts a story key and returns a keyed handle (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  [ "$handle" = "tm-gaia-python-dev-K1-K1" ]
  [ "$(_dt_read_story_key "$handle")" = "K1-K1" ]
}

@test "a relayed turn is attributed to its own story (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  execution_relay_turn "$handle" "implement complete" 2>/dev/null
  # The attribution written by the relay must be readable back through the
  # bridge's own accessor — a record nothing reads is dead state.
  [ "$(execution_attribution_for "$handle")" = "K1-K1" ]
}

@test "concurrent relays from two teammates keep separate attribution (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local a b
  a="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  b="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K2" 2>/dev/null)"
  [ "$a" != "$b" ]
  bash -c '
    source "'"$DT_LIB"'"
    source "'"$EMB_LIB"'"
    execution_relay_turn "'"$a"'" "from the first story" 2>/dev/null
  ' &
  bash -c '
    source "'"$DT_LIB"'"
    source "'"$EMB_LIB"'"
    execution_relay_turn "'"$b"'" "from the second story" 2>/dev/null
  ' &
  wait
  [ "$(execution_attribution_for "$a")" = "K1-K1" ]
  [ "$(execution_attribution_for "$b")" = "K1-K2" ]
}

@test "concurrent relays to one handle preserve every relay count (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  local i
  for i in 1 2 3 4 5 6; do
    bash -c '
      source "'"$DT_LIB"'"
      source "'"$EMB_LIB"'"
      execution_relay_turn "'"$handle"'" "turn '"$i"'" 2>/dev/null
    ' &
  done
  wait
  # A lost update under interleaving makes the counter short of the number
  # of relays actually performed.
  local relays
  relays="$(sed -n 's/^relays://p' "$GAIA_SESSION_DIR/relay-attribution/$handle")"
  [ "$relays" -eq 6 ]
}

@test "the bridge tracks no single last-active teammate (AC-EC3)" {
  # A single session-wide last-active scalar cannot attribute concurrent
  # relays; the per-handle map replaces it and the scalar must be gone.
  #
  # The sweep covers EVERY library and bridge, not just this one file: the
  # scalar's removal is only safe if nothing anywhere still reads it, and a
  # single-file check would miss a consumer in a sibling bridge — which is
  # precisely the reader this criterion requires be proven absent.
  local scripts_root="$BATS_TEST_DIRNAME/../scripts"
  local skills_root="$BATS_TEST_DIRNAME/../skills"
  local hits
  hits="$(
    { find "$scripts_root" -name '*.sh' -type f 2>/dev/null
      find "$skills_root" -path '*/scripts/*' -name '*.sh' -type f 2>/dev/null
    } | while IFS= read -r candidate; do
      if [ "$(grep -c '_EMB_LAST_ACTIVE_HANDLE' "$candidate" 2>/dev/null || true)" -ne 0 ]; then
        printf '%s\n' "$candidate"
      fi
    done
  )"
  [ -z "$hits" ] \
    || { echo "the removed last-active scalar is still referenced in:"; echo "$hits"; return 1; }

  # The sweep must actually have inspected files, or an empty result would be
  # a vacuous pass over nothing.
  local swept
  swept="$(find "$scripts_root" -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$swept" -gt 0 ] \
    || { echo "the sweep inspected no files — it cannot prove zero readers"; return 1; }
}

@test "every relay record carries its story key (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local a b
  a="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  b="$(execution_spawn_subagent "gaia:sm" "gaia-sprint-plan" "K1-K2" 2>/dev/null)"
  execution_relay_turn "$a" "first payload" 2>/dev/null
  execution_relay_turn "$b" "second payload" 2>/dev/null
  assert_file_contains "$GAIA_SESSION_DIR/relay-attribution/$a" "story_key:K1-K1"
  assert_file_contains "$GAIA_SESSION_DIR/relay-attribution/$b" "story_key:K1-K2"
}

@test "the bridge propagates the documented fallback code to its caller (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  run execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1"
  [ "$status" -eq 7 ]
}

@test "a caller can read why the dispatch fell back (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  # Call the spawn directly rather than under `run`: `run` executes in a
  # subshell, which would discard an in-process store and silently constrain
  # the implementation to a cross-process one.
  set +e
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" \
    >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 7 ]
  # The machine-readable record must be parsed and surfaced, not merely
  # emitted — an unparsed format is dead state.
  run execution_fallback_reason
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"substrate-unavailable"* ]]
}

@test "two concurrent relays are attributed to their own stories in the transcript (AC2, AC6)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local a b
  a="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  b="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K2" 2>/dev/null)"
  bash -c '
    source "'"$DT_LIB"'"
    source "'"$EMB_LIB"'"
    execution_relay_turn "'"$a"'" "payload from the first story" 2>/dev/null
  ' &
  bash -c '
    source "'"$DT_LIB"'"
    source "'"$EMB_LIB"'"
    execution_relay_turn "'"$b"'" "payload from the second story" 2>/dev/null
  ' &
  wait
  # Concurrent transcript appends are NOT serialised (this story scopes its
  # lock to the attribution map), so no line-adjacency ordering may be
  # assumed. Assert association through whole-file invariants instead: each
  # story contributed exactly one metadata comment, and every comment binds
  # exactly one story key.
  local comments
  comments="$(grep -c 'story_key:K1-K1' "$GAIA_SESSION_TRANSCRIPT" || true)"
  [ "$comments" -eq 1 ] \
    || { echo "expected exactly one entry for the first story, got [$comments]"; return 1; }
  comments="$(grep -c 'story_key:K1-K2' "$GAIA_SESSION_TRANSCRIPT" || true)"
  [ "$comments" -eq 1 ] \
    || { echo "expected exactly one entry for the second story, got [$comments]"; return 1; }
  # No single metadata comment may name both stories (cross-attribution).
  local both
  both="$(grep -c 'story_key:K1-K1.*K1-K2\|story_key:K1-K2.*K1-K1' \
    "$GAIA_SESSION_TRANSCRIPT" || true)"
  [ "$both" -eq 0 ] \
    || { echo "a metadata comment names both stories: [$both]"; return 1; }
  # Each relay payload reached the transcript exactly once.
  assert_file_contains "$GAIA_SESSION_TRANSCRIPT" "payload from the first story"
  assert_file_contains "$GAIA_SESSION_TRANSCRIPT" "payload from the second story"
  # Handle-to-story binding is asserted on the attribution map, which IS
  # serialised and therefore safe to associate per handle.
  [ "$(execution_attribution_for "$a")" = "K1-K1" ]
  [ "$(execution_attribution_for "$b")" = "K1-K2" ]
}

@test "a relay after a fallback is refused and adds no attribution (AC-EC5)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  run execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1"
  [ "$status" -eq 7 ]
  local never="tm-gaia-python-dev-K1-K1"
  local before=0
  if [ -f "$GAIA_SESSION_TRANSCRIPT" ]; then
    before="$(wc -c < "$GAIA_SESSION_TRANSCRIPT")"
  fi
  run execution_relay_turn "$never" "payload for a teammate never spawned"
  [ "$status" -eq 7 ]
  [ ! -f "$GAIA_SESSION_DIR/relay-attribution/$never" ]
  local after=0
  if [ -f "$GAIA_SESSION_TRANSCRIPT" ]; then
    after="$(wc -c < "$GAIA_SESSION_TRANSCRIPT")"
  fi
  [ "$after" -eq "$before" ]
}

@test "two same-persona stories and a forced fallback hold all three properties together (AC6)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  local a b
  a="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  b="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K2" 2>/dev/null)"
  # Property one: same persona, two stories, two distinct story-keyed handles.
  [ "$a" != "$b" ]
  [ "$a" = "tm-gaia-python-dev-K1-K1" ]
  [ "$b" = "tm-gaia-python-dev-K1-K2" ]
  execution_relay_turn "$a" "first payload" 2>/dev/null
  execution_relay_turn "$b" "second payload" 2>/dev/null
  # Property two: each relay is attributed to its own story.
  [ "$(execution_attribution_for "$a")" = "K1-K1" ]
  [ "$(execution_attribution_for "$b")" = "K1-K2" ]
  # Property three: a fallback later in the SAME session still returns the
  # documented code, and the earlier handles keep their attribution.
  export GAIA_MODE_B_SUBSTRATE=unavailable
  run execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K3"
  [ "$status" -eq 7 ]
  [ "$(execution_attribution_for "$a")" = "K1-K1" ]
  [ "$(execution_attribution_for "$b")" = "K1-K2" ]
}

@test "a relay that fails in the shared library reports its failure (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  # An empty handle is refused by the shared relay itself, not by the
  # bridge's unregistered-handle guard (which only screens non-empty
  # handles), so this drives a genuine failure inside the library.
  local rc=0
  execution_relay_turn "" "payload for nobody" >/dev/null 2>&1 || rc=$?
  # The seam must report the relay's own status. Reporting success for a
  # relay that failed would hide a lost reply from the caller.
  [ "$rc" -eq 1 ] \
    || { echo "expected the failed relay's status 1, got [$rc]"; return 1; }
  # And bookkeeping must not invent a record for a relay that never happened.
  # The whole attribution directory is asserted absent, not just one handle's
  # record: each test gets its own session directory, so nothing else can have
  # written here, and checking the directory also catches a record filed under
  # some other name.
  [ ! -e "$GAIA_SESSION_DIR/relay-attribution/" ] \
    || { echo "attribution written for a relay that failed"; return 1; }
}

# ============================================================
# AC2 / AC3 — Per-story fallback reasons, relay-guard separability,
#             keyless relay cost, and caller shell-flag hygiene
# ============================================================

@test "three concurrent keyed fallbacks record three separate reasons (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  set +e
  # A single session-global reason file would let the last writer win and
  # leave two of these three stories reading a reason that is not theirs.
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" >/dev/null 2>&1 &
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K2" >/dev/null 2>&1 &
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K3" >/dev/null 2>&1 &
  wait
  set -e
  local k
  for k in K1-K1 K1-K2 K1-K3; do
    run execution_fallback_reason "$k"
    [ "$status" -eq 0 ] \
      || { echo "no reason recorded for $k"; return 1; }
    [ "$output" = "substrate-unavailable" ] \
      || { echo "wrong reason for $k: [$output]"; return 1; }
  done

  # Three SEPARATE records, each naming its own story. A single shared file
  # would satisfy the reads above (all three reasons happen to be identical)
  # while still having lost which story each belonged to.
  local count
  count="$(find "$GAIA_SESSION_DIR/mode-b-fallback-reason" -type f | wc -l | tr -d ' ')"
  [ "$count" -eq 3 ] \
    || { echo "expected 3 per-story reason records, found $count"; return 1; }
  for k in K1-K1 K1-K2 K1-K3; do
    run grep -c "^story_key:$k\$" "$GAIA_SESSION_DIR/mode-b-fallback-reason/$k"
    [ "$output" -eq 1 ] \
      || { echo "record for $k does not name its own story"; return 1; }
  done
}

@test "a successful keyed spawn clears only its own stale reason (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  set +e
  export GAIA_MODE_B_SUBSTRATE=unavailable
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" >/dev/null 2>&1
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K2" >/dev/null 2>&1
  # The story now runs; a reason left behind would report a live story as
  # degraded for the rest of the session.
  export GAIA_MODE_B_SUBSTRATE=available
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" >/dev/null 2>&1
  set -e
  run execution_fallback_reason "K1-K1"
  [ "$status" -ne 0 ] \
    || { echo "a stale reason survived a successful spawn: [$output]"; return 1; }
  # The other story's reason is untouched — clearing is per story, not global.
  run execution_fallback_reason "K1-K2"
  [ "$status" -eq 0 ] && [ "$output" = "substrate-unavailable" ] \
    || { echo "an unrelated story's reason was cleared: [$status] [$output]"; return 1; }
}

@test "a refused relay is distinguishable from a substrate fallback (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  set +e
  # Both conditions return the same exit code, so the code alone cannot tell
  # "degrade to sequential work" from "a relay was dropped". First make a
  # substrate fallback happen, so a stale reason is available to be wrongly
  # reported by the relay guard.
  export GAIA_MODE_B_SUBSTRATE=unavailable
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" >/dev/null 2>&1
  export GAIA_MODE_B_SUBSTRATE=available
  execution_relay_turn "tm-python-dev-GHOST" "payload" >/dev/null 2>&1
  local relay_rc=$?
  set -e
  [ "$relay_rc" -eq 7 ] \
    || { echo "relay guard did not return the fallback code: [$relay_rc]"; return 1; }
  run execution_fallback_reason "tm-python-dev-GHOST"
  [ "$status" -eq 0 ] \
    || { echo "relay guard recorded no reason"; return 1; }
  [ "$output" = "unregistered-handle" ] \
    || { echo "relay refusal reported as [$output], not its own cause"; return 1; }
}

@test "a keyless relay writes no attribution record (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  set +e
  # A keyless teammate has no story, so attribution can say nothing about it.
  # Writing one anyway costs every long-standing keyless caller a lock and a
  # read-modify-write per turn for a record carrying an empty story key.
  local handle
  handle="$(spawn_teammate "gaia:analyst" 2>/dev/null)"
  execution_relay_turn "$handle" "keyless payload" >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || { echo "a keyless relay failed: [$rc]"; return 1; }
  [ ! -f "$GAIA_SESSION_DIR/relay-attribution/$handle" ] \
    || { echo "an attribution record was written for a keyless handle: [$(cat "$GAIA_SESSION_DIR/relay-attribution/$handle")]"; return 1; }
  # No lock was taken either — a leftover lock path proves the bookkeeping ran.
  [ ! -e "$GAIA_SESSION_DIR/relay-attribution/$handle.lock" ] \
    || { echo "a lock was taken for a keyless relay"; return 1; }
  # The relay itself must still reach the transcript unchanged.
  run grep -c 'keyless payload' "$GAIA_SESSION_TRANSCRIPT"
  [ "$output" -eq 1 ] \
    || { echo "the keyless relay did not reach the transcript"; return 1; }
}

@test "a keyed relay still records attribution after the keyless skip (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  set +e
  # The positive control for the guard above: skipping keyless work must not
  # have skipped the keyed bookkeeping the story exists to provide.
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  execution_relay_turn "$handle" "keyed payload" >/dev/null 2>&1
  set -e
  [ "$(execution_attribution_for "$handle")" = "K1-K1" ] \
    || { echo "keyed attribution lost: [$(execution_attribution_for "$handle")]"; return 1; }
  run grep -c '^relays:1$' "$GAIA_SESSION_DIR/relay-attribution/$handle"
  [ "$output" -eq 1 ] \
    || { echo "keyed relay counter not incremented: [$(cat "$GAIA_SESSION_DIR/relay-attribution/$handle")]"; return 1; }
}

@test "a relay leaves the caller's errexit as it found it (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  # The bridge loads its dependencies lazily, and those libraries set their own
  # shell options at source time. A caller that deliberately ran `set +e` to
  # branch on the fallback code must not find errexit switched on underneath it.
  run bash -c "
    source '$DT_LIB'
    source '$EMB_LIB'
    set +e
    h=\"\$(execution_spawn_subagent 'gaia:python-dev' 'gaia-dev-story' 'K1-K1' 2>/dev/null)\"
    execution_relay_turn \"\$h\" 'payload' >/dev/null 2>&1
    case \"\$-\" in *e*) echo ERREXIT_ON ;; *) echo ERREXIT_OFF ;; esac
  "
  [ "$output" = "ERREXIT_OFF" ] \
    || { echo "relay leaked errexit into a set +e caller: [$output]"; return 1; }
}

@test "a relay keeps errexit on for a caller that had it on (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  # The restore must be symmetric: it may only put the flag back, never clear
  # it for a caller that was relying on it.
  run bash -c "
    source '$DT_LIB'
    source '$EMB_LIB'
    set -e
    h=\"\$(execution_spawn_subagent 'gaia:python-dev' 'gaia-dev-story' 'K1-K1' 2>/dev/null)\"
    execution_relay_turn \"\$h\" 'payload' >/dev/null 2>&1
    case \"\$-\" in *e*) echo ERREXIT_ON ;; *) echo ERREXIT_OFF ;; esac
  "
  [ "$output" = "ERREXIT_ON" ] \
    || { echo "relay cleared errexit for a set -e caller: [$output]"; return 1; }
}

@test "the attribution reader refuses a traversal handle (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  # The write path already refuses one; a reader that silently accepts `..`
  # would hand a future caller an arbitrary-file read.
  printf 'story_key:PWNED\n' > "$TEST_TMP/planted"
  run execution_attribution_for "../../planted"
  [ "$status" -ne 0 ] \
    || { echo "traversal handle accepted by the attribution reader"; return 1; }
  [ "$output" != "PWNED" ] \
    || { echo "traversal handle read a file outside the attribution store"; return 1; }
}

@test "the attribution lock timeout is configurable (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  set +e
  # Under heavy same-handle contention a waiter that times out drops its
  # attribution increment, so the wait must be tunable rather than fixed.
  # An override must be honoured and must not disturb the normal path.
  export GAIA_MODE_B_ATTRIBUTION_LOCK_TIMEOUT=1
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  execution_relay_turn "$handle" "payload" >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || { echo "relay failed under an overridden lock timeout: [$rc]"; return 1; }
  [ "$(execution_attribution_for "$handle")" = "K1-K1" ] \
    || { echo "attribution lost under an overridden lock timeout"; return 1; }
  # The override is actually read rather than ignored.
  run grep -c 'GAIA_MODE_B_ATTRIBUTION_LOCK_TIMEOUT:-5' "$EMB_LIB"
  [ "$output" -eq 1 ] \
    || { echo "the lock timeout is not sourced from the documented override"; return 1; }
}

@test "a session carrying the earlier single-file reason store still records (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  # The reason store used to be one FILE at this path and is now a directory.
  # A session carried across that change must not lose its reasons to a failing
  # mkdir — the failure mode is silent, so it is pinned here.
  printf 'substrate-unavailable\n' > "$GAIA_SESSION_DIR/mode-b-fallback-reason"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  set +e
  execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 7 ] \
    || { echo "spawn did not report the documented fallback code: [$rc]"; return 1; }
  [ -d "$GAIA_SESSION_DIR/mode-b-fallback-reason" ] \
    || { echo "the stale single-file store was not replaced by the per-story store"; return 1; }
  run execution_fallback_reason "K1-K1"
  [ "$status" -eq 0 ] \
    || { echo "the reason was lost to the stale store layout"; return 1; }
  [ "$output" = "substrate-unavailable" ] \
    || { echo "unexpected reason after the store migration: [$output]"; return 1; }
}

@test "the spawn seam restores errexit for a caller that reaches it directly (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  # The seam must be called UNSUBSTITUTED. Every other call site here captures
  # its output with "$(...)", and a command substitution confines a leaked
  # `set +e` to the subshell — so a missing restore would be invisible.
  # A fallback spawn is used because it exercises the seam's non-zero path,
  # which is exactly where the errexit lift is taken.
  run bash -c "
    source '$DT_LIB'
    source '$EMB_LIB'
    export GAIA_SESSION_DIR='$GAIA_SESSION_DIR'
    set -e
    execution_spawn_subagent 'gaia:python-dev' 'gaia-dev-story' 'K1-K1' >/dev/null 2>&1 || true
    case \"\$-\" in *e*) echo ERREXIT_ON ;; *) echo ERREXIT_OFF ;; esac
  "
  [ "$output" = "ERREXIT_ON" ] \
    || { echo "the spawn seam cleared errexit for a set -e caller: [$output]"; return 1; }
}

@test "the spawn seam leaves errexit off for a set +e caller that reaches it directly (AC3)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  # The symmetric direction: a caller that deliberately disabled errexit to
  # branch on the fallback code must not find it switched on underneath.
  run bash -c "
    source '$DT_LIB'
    source '$EMB_LIB'
    export GAIA_SESSION_DIR='$GAIA_SESSION_DIR'
    set +e
    execution_spawn_subagent 'gaia:python-dev' 'gaia-dev-story' 'K1-K1' >/dev/null 2>&1
    case \"\$-\" in *e*) echo ERREXIT_ON ;; *) echo ERREXIT_OFF ;; esac
  "
  [ "$output" = "ERREXIT_OFF" ] \
    || { echo "the spawn seam switched errexit on under a set +e caller: [$output]"; return 1; }
}

@test "a direct relay call restores errexit for a set -e caller (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  # execution_relay_turn is called for its side effects, so a real caller
  # reaches it unsubstituted — the shape under which a lost restore actually
  # escapes into the caller's shell.
  run bash -c "
    source '$DT_LIB'
    source '$EMB_LIB'
    export GAIA_SESSION_DIR='$GAIA_SESSION_DIR'
    export GAIA_SESSION_TRANSCRIPT='$GAIA_SESSION_TRANSCRIPT'
    h=\"\$(execution_spawn_subagent 'gaia:python-dev' 'gaia-dev-story' 'K1-K1' 2>/dev/null)\"
    set -e
    execution_relay_turn \"\$h\" 'payload' >/dev/null 2>&1
    case \"\$-\" in *e*) echo ERREXIT_ON ;; *) echo ERREXIT_OFF ;; esac
  "
  [ "$output" = "ERREXIT_ON" ] \
    || { echo "a direct relay cleared errexit for a set -e caller: [$output]"; return 1; }
}

@test "an errexit caller still aborts on a failure after a direct relay (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  # The consequence that matters, asserted rather than inferred from $-: with
  # errexit lost, the caller sails past a failing command instead of aborting.
  run bash -c "
    source '$DT_LIB'
    source '$EMB_LIB'
    export GAIA_SESSION_DIR='$GAIA_SESSION_DIR'
    export GAIA_SESSION_TRANSCRIPT='$GAIA_SESSION_TRANSCRIPT'
    h=\"\$(execution_spawn_subagent 'gaia:python-dev' 'gaia-dev-story' 'K1-K1' 2>/dev/null)\"
    set -e
    execution_relay_turn \"\$h\" 'payload' >/dev/null 2>&1
    false
    echo REACHED
  "
  [ "$status" -ne 0 ] \
    || { echo "an errexit caller did not abort after the relay: [$status] [$output]"; return 1; }
  [ "$output" != "REACHED" ] \
    || { echo "execution continued past a failing command — errexit was lost"; return 1; }
}

@test "a handle spawned through the library is attributed on relay (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  set +e
  # Spawn via the shared library DIRECTLY rather than through this bridge's
  # seam, so nothing seeds the attribution record beforehand. The bump must
  # take identity from the registry — reading it from the file it is about to
  # rewrite yields an empty story_key:/persona: and loses the attribution the
  # relay exists to record.
  local handle
  handle="$(spawn_teammate "gaia:python-dev" --story-key "K1-K1" 2>/dev/null)"
  execution_relay_turn "$handle" "payload" >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || { echo "the relay failed: [$rc]"; return 1; }
  [ "$(execution_attribution_for "$handle")" = "K1-K1" ] \
    || { echo "attribution empty for a library-spawned handle: [$(cat "$GAIA_SESSION_DIR/relay-attribution/$handle" 2>/dev/null)]"; return 1; }
  # The persona must be recorded too, not just the story key.
  run grep -c '^persona:gaia:python-dev$' "$GAIA_SESSION_DIR/relay-attribution/$handle"
  [ "$output" -eq 1 ] \
    || { echo "persona missing from the record: [$(cat "$GAIA_SESSION_DIR/relay-attribution/$handle")]"; return 1; }
  run grep -c '^relays:1$' "$GAIA_SESSION_DIR/relay-attribution/$handle"
  [ "$output" -eq 1 ] \
    || { echo "relay counter wrong: [$(cat "$GAIA_SESSION_DIR/relay-attribution/$handle")]"; return 1; }
}

@test "repeated relays keep identity while accumulating the counter (AC2)" {
  source "$DT_LIB"
  source "$EMB_LIB"
  export GAIA_MODE_B_SUBSTRATE=available
  set +e
  # Seeding identity from the registry on every bump must not reset the one
  # field that genuinely accumulates.
  local handle
  handle="$(execution_spawn_subagent "gaia:python-dev" "gaia-dev-story" "K1-K1" 2>/dev/null)"
  execution_relay_turn "$handle" "first" >/dev/null 2>&1
  execution_relay_turn "$handle" "second" >/dev/null 2>&1
  execution_relay_turn "$handle" "third" >/dev/null 2>&1
  set -e
  [ "$(execution_attribution_for "$handle")" = "K1-K1" ] \
    || { echo "story key lost across relays"; return 1; }
  run grep -c '^relays:3$' "$GAIA_SESSION_DIR/relay-attribution/$handle"
  [ "$output" -eq 1 ] \
    || { echo "counter did not accumulate across three relays: [$(cat "$GAIA_SESSION_DIR/relay-attribution/$handle")]"; return 1; }
}
