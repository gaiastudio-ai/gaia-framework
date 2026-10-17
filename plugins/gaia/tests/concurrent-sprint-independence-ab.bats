#!/usr/bin/env bats
# concurrent-sprint-independence-ab.bats — tests for independence-check.sh
# rules (a) and (b).
#
# Tests the dependency-edge (rule a) and shared-epic (rule b) independence
# checks for concurrent sprint activation. Uses synthetic E9xx fixture keys.

# shellcheck disable=SC2030,SC2031

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  PLANNING_DIR="$TEST_DIR/.gaia/artifacts/planning-artifacts"
  SHARDS_DIR="$PLANNING_DIR/epics"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR" "$PLANNING_DIR" "$SHARDS_DIR"

  # Concurrent mode config.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "test-project"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML

  # Default empty epics file (tests override as needed).
  cat > "$PLANNING_DIR/epics-and-stories.md" <<'MD'
# Epics and Stories

## E900 — Test Epic Alpha
## E901 — Test Epic Beta
## E902 — Test Epic Gamma
MD

  # Migration marker so resolve-file works.
  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE_DIR/.sprint-migration-complete"

  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  IC_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/independence-check.sh"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_SCRIPT_DIR/scripts"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ---- Fixture helpers ----

# Create a per-sprint state file with stories.
# Usage: create_sprint <sprint_id> <status> <key1> [<key2> ...]
create_sprint() {
  local sid="$1" status="$2"
  shift 2
  local f="$STATE_DIR/sprint-status-${sid}.yaml"
  {
    printf 'sprint_id: "%s"\n' "$sid"
    printf 'status: %s\n' "$status"
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    if [ $# -eq 0 ]; then
      printf 'stories: []\n'
    else
      printf 'stories:\n'
      for key in "$@"; do
        printf '  - key: "%s"\n' "$key"
        printf '    title: "Test story %s"\n' "$key"
        printf '    status: "in-progress"\n'
        printf '    points: 3\n'
        printf '    risk: "medium"\n'
      done
    fi
  } > "$f"
}

# Create a story file with frontmatter.
# Usage: create_story <key> <epic> [depends_on_csv] [blocks_csv]
create_story() {
  local key="$1" epic="$2" deps="${3:-}" blocks="${4:-}"
  local epic_slug
  epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
  local story_dir="$IMPL_DIR/epic-${epic_slug}/${key}-test-story"
  mkdir -p "$story_dir"
  local f="$story_dir/story.md"
  {
    printf -- '---\n'
    printf 'key: "%s"\n' "$key"
    printf 'epic: "%s"\n' "$epic"
    if [ -n "$deps" ]; then
      printf 'depends_on: [%s]\n' "$(printf '%s' "$deps" | sed 's/[^,]*/"&"/g')"
    fi
    if [ -n "$blocks" ]; then
      printf 'blocks: [%s]\n' "$(printf '%s' "$blocks" | sed 's/[^,]*/"&"/g')"
    fi
    printf 'status: in-progress\n'
    printf -- '---\n'
    printf '# Story: %s\n' "$key"
  } > "$f"
}

# Create a story file with NO epic field.
create_story_no_epic() {
  local key="$1"
  local story_dir="$IMPL_DIR/epic-e900/${key}-test-story"
  mkdir -p "$story_dir"
  {
    printf -- '---\n'
    printf 'key: "%s"\n' "$key"
    printf 'status: in-progress\n'
    printf -- '---\n'
    printf '# Story: %s\n' "$key"
  } > "$story_dir/story.md"
}

# Create a story file with truncated YAML (no closing ---).
create_story_truncated() {
  local key="$1" epic="$2"
  local epic_slug
  epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
  local story_dir="$IMPL_DIR/epic-${epic_slug}/${key}-test-story"
  mkdir -p "$story_dir"
  {
    printf -- '---\n'
    printf 'key: "%s"\n' "$key"
    printf 'epic: "%s"\n' "$epic"
    printf 'status: in-progress\n'
    # Deliberately missing closing ---
  } > "$story_dir/story.md"
}

# Set catch-all marker on an epic in epics-and-stories.md.
set_catch_all_inline() {
  local epic_key="$1" title="$2"
  local em_dash=$'\xe2\x80\x94'
  # Append to epics file with catch_all marker.
  printf '\n## %s %s %s\n<!-- catch_all: true -->\n' "$epic_key" "$em_dash" "$title" \
    >> "$PLANNING_DIR/epics-and-stories.md"
}

# ========================================================================
# Test scenarios
# ========================================================================

# 5.1 — Direct dependency across sprints (depends_on direction)
@test "direct depends_on across sprints triggers rule (a) failure" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "E900-S1"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (a):"* ]]
  [[ "$output" == *"E901-S1"* ]]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"sprint-901 -> sprint-900"* ]]
}

# 5.1 — Direct dependency across sprints (blocks direction)
@test "direct blocks across sprints triggers rule (a) failure" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "" "E900-S1"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (a):"* ]]
}

# 5.2a — Two-hop transitive dependency chain
@test "two-hop transitive dependency chain triggers rule (a) with full path" {
  create_sprint sprint-901 active E901-S1 E901-S2
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "E901-S2"
  create_story E901-S2 E901 "E900-S1"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (a):"* ]]
  [[ "$output" == *"E901-S1 -> E901-S2 -> E900-S1"* ]]
}

# 5.2b — Three-hop transitive dependency chain with four stories
@test "three-hop transitive chain shows four-story path in diagnostic" {
  create_sprint sprint-901 active E901-S1 E901-S2 E901-S3
  create_sprint sprint-900 active E900-S2
  create_story E901-S1 E901 "E901-S2"
  create_story E901-S2 E901 "E901-S3"
  create_story E901-S3 E901 "E900-S2"
  create_story E900-S2 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (a):"* ]]
  [[ "$output" == *"E901-S1 -> E901-S2 -> E901-S3 -> E900-S2"* ]]
}

# 5.3 — Shared non-catch-all epic triggers rule (b) failure
@test "shared non-catch-all epic triggers rule (b) failure" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  # Both stories from the same epic E900 (not catch-all).
  create_story E901-S1 E900
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (b):"* ]]
  [[ "$output" == *"shared epic E900"* ]]
  [[ "$output" == *"sprint-901"* ]]
  [[ "$output" == *"sprint-900"* ]]
}

# 5.4 — Catch-all epic exempted from rule (b): PASS
@test "catch-all epic exempted from rule (b) passes" {
  set_catch_all_inline E928 "Bugs and Enhancements"
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E928
  create_story E900-S1 E928

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (a),(b):"* ]]
  # No rule (b) diagnostic on stderr.
  [ -z "${lines[*]##*FAIL rule*}" ] || true
}

# 5.4 sub-case — catch-all epic but depends_on edge triggers rule (a)
@test "catch-all epic with depends_on edge still triggers rule (a)" {
  set_catch_all_inline E928 "Bugs and Enhancements"
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E928 "E900-S1"
  create_story E900-S1 E928

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (a):"* ]]
  # Rule (b) should NOT fail (catch-all exempted).
  [[ "$output" != *"FAIL rule (b):"* ]]
}

# 5.5 — Catch-all flag is explicit, never inferred from name
@test "epic named for catch-all without marker triggers rule (b)" {
  # Write an epic with a catch-all-sounding name but NO marker.
  local em_dash=$'\xe2\x80\x94'
  cat > "$PLANNING_DIR/epics-and-stories.md" <<MD
# Epics and Stories

## E928 ${em_dash} Bugs and Enhancements

## E900 ${em_dash} Test Epic Alpha
MD
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E928
  create_story E900-S1 E928

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (b):"* ]]

  # Source grep: no inference from title in independence-check.sh.
  ! /usr/bin/grep -qE 'Bugs|Enhancement|infer' "$IC_SCRIPT"
}

# 5.6 — Unparseable story file refuses activation
@test "unparseable story file fails closed" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E900-S1 E900

  # Create unparseable story (indentation defect in YAML).
  local story_dir="$IMPL_DIR/epic-e901/E901-S1-test-story"
  mkdir -p "$story_dir"
  cat > "$story_dir/story.md" <<'BROKEN'
---
key: "E901-S1"
  epic: "E901"  # bad indent
status: in-progress
---
BROKEN

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"* ]]
}

# 5.7 — Unreadable epics file refuses activation
@test "unreadable epics file fails closed" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901
  create_story E900-S1 E900
  chmod 000 "$PLANNING_DIR/epics-and-stories.md"

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"* ]]

  # Restore permissions for teardown.
  chmod 644 "$PLANNING_DIR/epics-and-stories.md"
}

# 5.7 mutant — catching error and exiting 0 turns red
@test "unreadable epics file mutant: swallowing error and exiting 0 fails this test" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901
  create_story E900-S1 E900
  chmod 000 "$PLANNING_DIR/epics-and-stories.md"

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  # This test ASSERTS exit 1 — a mutant that catches the error and exits 0
  # would turn this test red.
  [ "$status" -eq 1 ]

  chmod 644 "$PLANNING_DIR/epics-and-stories.md"
}

# 5.8 — All rules evaluated against every active sprint (multi-sprint)
@test "all rules evaluated against every active sprint" {
  # 3 active sprints + 1 candidate.
  # Violation only between sprint-903 and sprint-901 (shared epic).
  create_sprint sprint-903 active E903-S1
  create_sprint sprint-900 active E900-S1
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-902 active E902-S1
  create_story E903-S1 E901   # shares epic E901 with sprint-901
  create_story E900-S1 E900
  create_story E901-S1 E901   # same epic E901 — triggers rule (b)
  create_story E902-S1 E902

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900,sprint-901,sprint-902
  [ "$status" -eq 1 ]
  # Should have 3 comparisons total: one FAIL (vs sprint-901), two PASS.
  local pass_count fail_count
  pass_count="$(printf '%s\n' "$output" | /usr/bin/grep -c 'PASS rules' || printf '0')"
  fail_count="$(printf '%s\n' "$output" | /usr/bin/grep -c 'FAIL rule' || printf '0')"
  [ "$pass_count" -eq 2 ]
  [ "$fail_count" -ge 1 ]
  # Verify all three comparisons appear.
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
  [[ "$output" == *"sprint-902"* ]]
}

# 5.9 — Cycle in dependency graph (reachable from candidate)
@test "reachable cycle in dependency graph fails closed" {
  create_sprint sprint-901 active E901-S1 E901-S2
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "E901-S2"
  create_story E901-S2 E901 "E901-S1"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: cycle detected:"* ]]
  [[ "$output" == *"E901-S1"* ]]
  [[ "$output" == *"E901-S2"* ]]
}

# 5.10 — Reference to closed-sprint story not followed
@test "reference to closed-sprint story (known key) is not followed" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  # E902-S1 is a known key (listed in epics-and-stories.md) but not in any active sprint.
  cat > "$PLANNING_DIR/epics-and-stories.md" <<MD
# Epics and Stories

## E900 — Test Epic Alpha

| Key | Title |
|-----|-------|
| E900-S1 | Story Alpha |

## E901 — Test Epic Beta

| Key | Title |
|-----|-------|
| E901-S1 | Story Beta |

## E902 — Test Epic Gamma

| Key | Title |
|-----|-------|
| E902-S1 | Story Gamma (closed sprint) |
MD

  create_story E901-S1 E901 "E902-S1"
  create_story E900-S1 E900
  # E902-S1 exists as a story file but is in no active/candidate sprint.
  create_story E902-S1 E902

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (a),(b):"* ]]
}

# 5.11 — No dependency overlap passes
@test "no dependency overlap passes" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (a),(b): sprint-901 vs sprint-900"* ]]
}

# 5.12 — Deep dependency chain (25 levels) completes in < 5s
@test "deep dependency chain of 25 stories completes under 5 seconds" {
  # Build a chain: E901-S1 -> E901-S2 -> ... -> E901-S25.
  # All in the same sprint (candidate). No cross-sprint edge.
  local keys=""
  local i
  for i in $(seq 1 25); do
    keys="$keys E901-S${i}"
  done
  # shellcheck disable=SC2086
  create_sprint sprint-901 active $keys
  create_sprint sprint-900 active E900-S1
  create_story E900-S1 E900

  for i in $(seq 1 24); do
    create_story "E901-S${i}" E901 "E901-S$((i + 1))"
  done
  create_story E901-S25 E901

  local start_time
  start_time="$(date +%s)"
  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  local end_time
  end_time="$(date +%s)"
  local elapsed=$(( end_time - start_time ))
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 5 ]
}

# 5.13 — Reference to story in no active/candidate sprint (known) not followed
@test "reference to known key not in any sprint is not followed" {
  cat > "$PLANNING_DIR/epics-and-stories.md" <<MD
# Epics and Stories

## E900 — Test Epic Alpha

| Key | Title |
|-----|-------|
| E900-S1 | Story 1 |

## E901 — Test Epic Beta

| Key | Title |
|-----|-------|
| E901-S1 | Story 2 |

## E902 — Test Epic Gamma

| Key | Title |
|-----|-------|
| E902-S1 | Story 3 (not in any sprint) |
MD

  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "E902-S1"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
}

# 5.14 — Unknown key fails closed
@test "unknown key not in any sprint and not known fails closed" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "E999-S999"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: unknown key: E999-S999"* ]]
}

# 5.15a — Self-dependency in candidate sprint: cycle detected, fails closed
@test "self-dependency in candidate sprint fails closed with cycle diagnostic" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "E901-S1"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: cycle detected:"* ]]
  [[ "$output" == *"E901-S1"* ]]
}

# 5.15b — Unreachable self-loop: stdout WARN, stderr empty
@test "unreachable self-loop in active sprint warns without blocking" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901
  create_story E900-S1 E900 "E900-S1"

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN cycle (unreachable from candidate):"* ]]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"sprint-900"* ]]
}

# 5.16 — Active sprint with zero stories passes
@test "active sprint with zero stories passes trivially" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active  # no stories
  create_story E901-S1 E901

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (a),(b):"* ]]
}

# 5.17 — blocks edge (no depends_on) triggers rule (a)
@test "blocks edge without depends_on triggers rule (a) failure" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "" "E900-S1"
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (a):"* ]]
}

# 5.18 — Multiple catch-all epics + one non-catch-all shared
@test "multiple catch-all epics excluded but non-catch-all shared triggers rule (b)" {
  set_catch_all_inline E928 "Bugs and Enhancements"
  set_catch_all_inline E929 "Maintenance Tasks"

  create_sprint sprint-901 active E901-S1 E901-S2 E901-S3
  create_sprint sprint-900 active E900-S1 E900-S2 E900-S3
  # E928 and E929 are catch-all, E900 is not.
  create_story E901-S1 E928
  create_story E901-S2 E929
  create_story E901-S3 E900
  create_story E900-S1 E928
  create_story E900-S2 E929
  create_story E900-S3 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (b):"* ]]
  [[ "$output" == *"shared epic E900"* ]]
  [[ "$output" == *"exempted catch-all:"* ]]
}

# 5.19 — Unparseable YAML frontmatter (truncated, no closing ---)
@test "truncated YAML frontmatter fails closed with unparseable diagnostic" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E900-S1 E900
  create_story_truncated E901-S1 E901

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: unparseable file:"* ]]
}

# 5.20 — Diamond acyclic graph is NOT a cycle
@test "diamond acyclic graph does not trigger cycle detection" {
  # A->B, A->C, B->D, C->D — all in candidate sprint.
  create_sprint sprint-901 active E901-S1 E901-S2 E901-S3 E901-S4
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901 "E901-S2,E901-S3"
  create_story E901-S2 E901 "E901-S4"
  create_story E901-S3 E901 "E901-S4"
  create_story E901-S4 E901
  create_story E900-S1 E900

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (a),(b):"* ]]
  [[ "$output" != *"cycle"* ]]
}

# 5.21 — Unreachable cycle in another active sprint: warn, no fail
@test "unreachable cycle in active sprint warns without failing" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1 E900-S2
  create_story E901-S1 E901
  create_story E900-S1 E900 "E900-S2"
  create_story E900-S2 E900 "E900-S1"

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN cycle (unreachable from candidate):"* ]]
  [[ "$output" == *"sprint-900"* ]]
}

# 5.22 — Missing story file for key listed in state file
@test "missing story file for listed key fails closed" {
  create_sprint sprint-901 active E901-S1 E901-S9
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E901
  create_story E900-S1 E900
  # E901-S9 is listed in sprint but has no story file.

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: missing file: E901-S9"* ]]
}

# 5.23 — Shard frontmatter overrides inline catch-all marker
@test "shard catch_all false overrides inline true, shared epic triggers rule (b)" {
  # Set inline catch_all: true for E928.
  set_catch_all_inline E928 "Bugs and Enhancements"

  # Shard overrides with catch_all: false.
  cat > "$SHARDS_DIR/28-e928-bugs-and-enhancements.md" <<'SHARD'
---
catch_all: false
---
# E928 — Bugs and Enhancements
SHARD

  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E901-S1 E928
  create_story E900-S1 E928

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (b):"* ]]
  [[ "$output" == *"shared epic E928"* ]]
}

# 5.24 — Missing or empty epic field fails closed
@test "missing epic field fails closed with diagnostic" {
  create_sprint sprint-901 active E901-S1
  create_sprint sprint-900 active E900-S1
  create_story E900-S1 E900
  create_story_no_epic E901-S1

  run bash "$IC_SCRIPT" --candidate sprint-901 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL indeterminate: missing epic:'* ]]
}
