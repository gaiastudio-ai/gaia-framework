#!/usr/bin/env bats
# e36-s5-shared-writer-delegation.bats
#
# Acceptance tests for E36-S5 — Swap inline action-items-increment.sh for the
# canonical shared retro writer helper (retro-sidecar-write.sh, ADR-052).
#
# AC1: action-items-increment.sh is replaced by a thin delegation that sources
#      the E36-S2 shared writer (retro-sidecar-write.sh).
# AC2: No duplicate YAML-bootstrap or AI-{n} increment logic remains outside
#      the shared writer (i.e., increment.sh imports primitives from the
#      shared writer rather than duplicating allowlist/normalization helpers).
# AC3: Existing /gaia-retro bats coverage passes unchanged (covered by
#      e36-s1-cross-retro-learning.bats and e36-s2-memory-velocity-persistence.bats).
# AC4: TODO (E36-S2 swap-in) markers are removed from all call sites.
#
# Refs: ADR-052, E36-S1, E36-S2.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

INC="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts" && pwd)/action-items-increment.sh"
WRITER="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/retro-sidecar-write.sh"

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

mk_action_items_yaml_with_entry() {
  local path="$1" id="$2" sprint="$3" text="$4" hash="$5"
  mkdir -p "$(dirname "$path")"
  {
    printf -- "# Action Items\nitems:\n"
    printf -- "  - id: %s\n    sprint_id: \"%s\"\n    text: \"%s\"\n    theme_hash: \"sha256:%s\"\n    escalation_count: 0\n" \
      "$id" "$sprint" "$text" "$hash"
  } > "$path"
}

# ===========================================================================
# AC1 — Delegation marker: action-items-increment.sh sources the shared writer
# ===========================================================================

@test "action-items-increment.sh sources retro-sidecar-write.sh" {
  [ -f "$INC" ]
  # The delegation wrapper must explicitly source the shared writer so its
  # helper functions (allowlist_match, resolve_real, normalize_payload) are
  # the single source of truth. A bare comment reference is insufficient.
  # Acceptable: a `source` / `.` directive whose argument resolves at runtime
  # to `retro-sidecar-write.sh` (path or variable).
  grep -qE 'retro-sidecar-write\.sh' "$INC"
  grep -qE '^[[:space:]]*(\.|source)[[:space:]]+' "$INC"
}

@test "shared writer remains executable after delegation refactor" {
  [ -x "$WRITER" ]
  # Sanity: shared writer's --help still works (CLI body intact).
  run "$WRITER" --help
  [ "$status" -eq 0 ]
}

@test "shared writer can be sourced as a library without side effects" {
  # When sourced (BASH_SOURCE != 0), the CLI body must not run; the script
  # must expose helper functions only. Otherwise sourcing crashes with a
  # missing-args exit and the delegation pattern is impossible.
  run bash -c "set +e; source '$WRITER'; declare -F allowlist_match resolve_real normalize_payload"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "allowlist_match"
  echo "$output" | grep -q "resolve_real"
  echo "$output" | grep -q "normalize_payload"
}

# ===========================================================================
# AC2 — No duplicate allowlist / normalization logic in increment.sh
# ===========================================================================

@test "action-items-increment.sh does not duplicate allowlist enforcement" {
  [ -f "$INC" ]
  # Inline pre-swap script had its own basename allowlist; after delegation
  # the allowlist comes from the shared writer's allowlist_match helper.
  ! grep -qE 'case "\$\(basename "\$AI_FILE"\)"' "$INC"
}

@test "action-items-increment.sh delegates allowlist to shared writer" {
  [ -f "$INC" ]
  # The wrapper must reference the shared writer's allowlist primitive so the
  # NFR-RIM-2 boundary is enforced exactly once.
  grep -qE 'allowlist_match' "$INC"
}

# ===========================================================================
# AC3 — CLI contract preservation (idempotency, allowlist, increment)
# ===========================================================================

@test "CLI rejects non-action-items.yaml targets via shared allowlist" {
  [ -x "$INC" ]
  local bad="$TEST_TMP/not-action-items.txt"
  printf '# nope\n' > "$bad"
  run "$INC" --file "$bad" --theme-hash "deadbeef" --sprint-id "sprint-1"
  [ "$status" -ne 0 ]
}

@test "CLI bumps escalation_count on first invocation" {
  [ -x "$INC" ]
  local ai_yaml="$TEST_TMP/action-items.yaml"
  mk_action_items_yaml_with_entry "$ai_yaml" "AI-1" "sprint-1" "Theme A" "abc123"

  run "$INC" --file "$ai_yaml" --theme-hash "abc123" --sprint-id "sprint-9"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 1" "$ai_yaml"
}

@test "CLI is idempotent per (sprint_id, theme_hash)" {
  [ -x "$INC" ]
  local ai_yaml="$TEST_TMP/action-items.yaml"
  mk_action_items_yaml_with_entry "$ai_yaml" "AI-1" "sprint-1" "Theme A" "abc123"

  run "$INC" --file "$ai_yaml" --theme-hash "abc123" --sprint-id "sprint-9"
  [ "$status" -eq 0 ]
  # Same (sprint, hash) again — must NOT bump.
  run "$INC" --file "$ai_yaml" --theme-hash "abc123" --sprint-id "sprint-9"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 1" "$ai_yaml"
  # Different sprint — bumps.
  run "$INC" --file "$ai_yaml" --theme-hash "abc123" --sprint-id "sprint-10"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 2" "$ai_yaml"
}

@test "CLI is a silent no-op when target file is missing" {
  [ -x "$INC" ]
  # action-items.yaml not yet created — increment is a non-fatal warning.
  run "$INC" --file "$TEST_TMP/missing/action-items.yaml" --theme-hash "abc" --sprint-id "sprint-1"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# AC4 — TODO (E36-S2 swap-in) markers are removed from all call sites
# ===========================================================================

@test "no 'TODO ( swap-in)' markers remain in plugin tree" {
  local plugin_root
  plugin_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Search excludes this very test file (which references the marker as an
  # acceptance assertion) and the story artifact directory.
  run grep -rn --exclude-dir=tests "E36-S2 swap-in" "$plugin_root"
  [ "$status" -ne 0 ]
}
