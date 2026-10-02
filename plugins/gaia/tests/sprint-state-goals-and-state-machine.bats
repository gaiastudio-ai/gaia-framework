#!/usr/bin/env bats
# sprint-state-goals-and-state-machine.bats — E93-S1
#
# Public functions covered: cmd_get_goals, cmd_set_goals, cmd_update_goals,
# cmd_transition_sprint, cmd_set_review_justification (NFR-052 coverage gate).
#
# Covers:
#   TC-SGR-1  goals field round-trip happy path
#   TC-SGR-2  update-goals replaces (not appends)
#   TC-SGR-3  legacy yaml without goals key → get-goals returns empty
#   TC-SGR-4  281-char goal rejected (280-char limit per FR-485 AC6)
#   TC-SGR-11 sprint-level active→review on all-stories-done
#   TC-SGR-12 sprint-level active→review refuses on non-done
#   TC-SGR-13 sprint-level review→correction
#   TC-SGR-14 sprint-level correction→active
#   TC-SGR-15 sprint-level review→closed
#   TC-SGR-16 illegal sprint-level edges (active→closed, closed→*, etc.) refused
#   TC-SGR-17 story-level done back-edges still refused (regression guard, ADR-108 Constraint A)
#
# Tier 1 bats. TC-SGR-42..44 Tier 3 E2E deferred to E93-S5+ (require
# /gaia-sprint-review orchestrator).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-state.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  YAML="$ART/sprint-status.yaml"
  mkdir -p "$ART"
}
teardown() { common_teardown; }

# Seed a sprint yaml with goals: list and one story. Story status configurable.
seed_yaml_with_goals() {
  local sprint_id="$1" story_key="$2" story_status="$3" sprint_status="${4:-active}"
  shift 4
  local goals_lines=""
  for g in "$@"; do
    goals_lines+="  - \"$g\"
"
  done
  cat > "$YAML" <<EOF
sprint_id: "$sprint_id"
status: $sprint_status
goals:
$goals_lines
stories:
  - key: "$story_key"
    title: "Fake"
    status: "$story_status"
EOF
}

# Seed a sprint yaml WITHOUT goals: key (legacy / backward-compat case).
seed_legacy_yaml() {
  local sprint_id="$1" story_key="$2" story_status="$3"
  cat > "$YAML" <<EOF
sprint_id: "$sprint_id"
status: active
stories:
  - key: "$story_key"
    title: "Fake"
    status: "$story_status"
EOF
}

seed_story() {
  local key="$1" status="$2"
  cat > "$ART/${key}-fake.md" <<EOF
---
template: 'story'
key: "$key"
title: "Fake"
status: $status
---

# Story: Fake

> **Status:** $status

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |
EOF
}

# ============================================================
# Goals field round-trip (FR-485)
# ============================================================

@test "sprint-state.sh get-goals reads goals verbatim from yaml" {
  seed_yaml_with_goals sprint-1 S1 done active "Ship the foo refactor" "Reduce p99 latency under 200ms"
  run "$SCRIPT" get-goals --sprint sprint-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ship the foo refactor"* ]]
  [[ "$output" == *"Reduce p99 latency under 200ms"* ]]
}

@test "sprint-state.sh update-goals REPLACES (not appends) goals list" {
  seed_yaml_with_goals sprint-1 S1 done active "Goal A" "Goal B"
  run "$SCRIPT" update-goals --sprint sprint-1 --goals "Goal C|Goal D"
  [ "$status" -eq 0 ]
  # After update: yaml goals: should be ["Goal C", "Goal D"], NOT four entries
  ! grep -q 'Goal A' "$YAML"
  ! grep -q 'Goal B' "$YAML"
  grep -q 'Goal C' "$YAML"
  grep -q 'Goal D' "$YAML"
}

@test "sprint-state.sh get-goals on legacy yaml without goals key returns empty (backward-compat)" {
  seed_legacy_yaml sprint-1 S1 done
  run "$SCRIPT" get-goals --sprint sprint-1
  [ "$status" -eq 0 ]
  # Empty output (or empty list) — must NOT error on missing goals key
  [ -z "${output// /}" ] || [[ "$output" == "[]" ]] || [[ "$output" == "" ]]
}

@test "sprint-state.sh set-goals refuses 281-char goal" {
  seed_yaml_with_goals sprint-1 S1 done active
  # Build a 281-char string
  local long_goal
  long_goal=$(printf 'a%.0s' {1..281})
  run "$SCRIPT" set-goals --sprint sprint-1 --goals "$long_goal"
  [ "$status" -ne 0 ]
  [[ "$output" == *"280"* ]] || [[ "$output" == *"too long"* ]] || [[ "$output" == *"exceeds"* ]]
  # Yaml unchanged
  ! grep -q 'aaaaaaa' "$YAML"
}

# ============================================================
# Sprint-level state machine edges (FR-487, ADR-108 D1)
# ============================================================

@test "sprint-state.sh transition --sprint active→review accepts when all stories done" {
  seed_yaml_with_goals sprint-1 S1 done active "Goal A"
  seed_story S1 done
  run "$SCRIPT" transition --sprint sprint-1 --to review
  [ "$status" -eq 0 ]
  grep -q '^status: review' "$YAML"
}

@test "sprint-state.sh transition --sprint active→review REFUSES when any story not done" {
  seed_yaml_with_goals sprint-1 S1 in-progress active "Goal A"
  seed_story S1 in-progress
  run "$SCRIPT" transition --sprint sprint-1 --to review
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-done"* ]] || [[ "$output" == *"S1"* ]]
  # Sprint status unchanged
  grep -q '^status: active' "$YAML"
}

@test "sprint-state.sh transition --sprint review→correction accepts" {
  seed_yaml_with_goals sprint-1 S1 done review "Goal A"
  seed_story S1 done
  run "$SCRIPT" transition --sprint sprint-1 --to correction
  [ "$status" -eq 0 ]
  grep -q '^status: correction' "$YAML"
}

@test "sprint-state.sh transition --sprint correction→active accepts" {
  seed_yaml_with_goals sprint-1 S1 done correction "Goal A"
  seed_story S1 done
  run "$SCRIPT" transition --sprint sprint-1 --to active
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$YAML"
}

@test "sprint-state.sh transition --sprint review→closed accepts" {
  # AF-2026-05-31-3 / Test14 F-13: review→closed now requires a Val sentinel
  # by default. This test targets the state-machine edge itself (FR-452 +
  # ADR-108 D1), not the sentinel guard — set the escape-hatch env var
  # so the edge accepts without a fixture sentinel. The sentinel guard
  # has its own dedicated bats coverage in af-2026-05-31-3-test14-findings.bats.
  seed_yaml_with_goals sprint-1 S1 done review "Goal A"
  seed_story S1 done
  run env GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1 \
    "$SCRIPT" transition --sprint sprint-1 --to closed
  [ "$status" -eq 0 ]
  grep -q '^status: closed' "$YAML"
}

@test "transition --sprint refuses illegal edges (5 cases)" {
  # active → closed (illegal — must go through review)
  seed_yaml_with_goals sprint-1 S1 done active "G"; seed_story S1 done
  run "$SCRIPT" transition --sprint sprint-1 --to closed
  [ "$status" -ne 0 ]
  grep -q '^status: active' "$YAML"

  # active → correction (illegal)
  run "$SCRIPT" transition --sprint sprint-1 --to correction
  [ "$status" -ne 0 ]

  # review → active (illegal — review goes to closed or correction only)
  seed_yaml_with_goals sprint-1 S1 done review "G"; seed_story S1 done
  run "$SCRIPT" transition --sprint sprint-1 --to active
  [ "$status" -ne 0 ]

  # correction → closed (illegal — correction returns to active first)
  seed_yaml_with_goals sprint-1 S1 done correction "G"; seed_story S1 done
  run "$SCRIPT" transition --sprint sprint-1 --to closed
  [ "$status" -ne 0 ]

  # correction → review (illegal)
  run "$SCRIPT" transition --sprint sprint-1 --to review
  [ "$status" -ne 0 ]
}

# ============================================================
# Regression guard — story-level state machine UNCHANGED (ADR-108 Constraint A)
# ============================================================

@test "story-level state machine — done back-edges still refused" {
  # Confirm that adding sprint-level edges did NOT introduce story-level
  # done → in-progress / done → review / done → ready-for-dev back-edges.
  seed_story S1 done
  cat > "$YAML" <<EOF
sprint_id: "sprint-1"
status: active
stories:
  - key: "S1"
    title: "Fake"
    status: "done"
EOF
  for target in in-progress review ready-for-dev validating backlog; do
    run "$SCRIPT" transition --story S1 --to "$target"
    [ "$status" -ne 0 ]
    # Story status unchanged
    grep -q '^status: done' "$ART/S1-fake.md"
  done
}

# ============================================================
# Sprint-id mismatch guard
# ============================================================

# Helper: seed a minimal yaml without goals (for mismatch tests).
_seed_mismatch_yaml() {
  local sprint_id="$1" sprint_status="${2:-active}"
  cat > "$YAML" <<EOF
sprint_id: "$sprint_id"
status: $sprint_status
stories:
  - key: "S1"
    title: "Fake"
    status: "done"
    points: 3
    risk: medium
EOF
}

# Helper: seed a yaml with no sprint_id field.
_seed_no_sprint_id_yaml() {
  cat > "$YAML" <<EOF
status: active
stories:
  - key: "S1"
    title: "Fake"
    status: "done"
    points: 3
    risk: medium
EOF
}

# Helper: seed a valid review-justification payload.
_seed_review_justification() {
  local file="$1"
  cat > "$file" <<'PAYLOAD'
primary_criterion: C1
qualifying_story_points: 18
total_story_points: 20
qualifying_ratio: 0.90
explanation: |
  This sprint delivered the full sprint-id mismatch guard across every writer
  in sprint-state.sh, hardened close.sh exit-code dispatch, and added
  comprehensive test coverage. All stories met their acceptance criteria and
  the sprint review confirmed no regressions. The qualifying ratio exceeds
  the minimum threshold set by the rubric.
PAYLOAD
}

@test "set-goals with mismatched sprint id is refused" {
  _seed_mismatch_yaml "sprint-82"
  local before
  before="$(cksum < "$YAML")"
  run "$SCRIPT" set-goals --sprint sprint-1 --goals "g1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  [[ "$output" == *"does not match active sprint-status.yaml sprint_id"* ]]
  local after
  after="$(cksum < "$YAML")"
  [ "$before" = "$after" ]
}

@test "update-goals with mismatched sprint id is refused and names update-goals" {
  _seed_mismatch_yaml "sprint-82"
  local before
  before="$(cksum < "$YAML")"
  run "$SCRIPT" update-goals --sprint sprint-1 --goals "g1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"update-goals"* ]]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  local after
  after="$(cksum < "$YAML")"
  [ "$before" = "$after" ]
}

@test "set-shape with mismatched sprint id is refused and leaves no temp files" {
  _seed_mismatch_yaml "sprint-82"
  local before
  before="$(cksum < "$YAML")"
  run "$SCRIPT" set-shape --sprint sprint-1 --shape thrust
  [ "$status" -eq 1 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  local after
  after="$(cksum < "$YAML")"
  [ "$before" = "$after" ]
  # No temp files left behind
  local tmp_count
  tmp_count="$(find "$ART" -name '*.tmp.*' | wc -l)"
  [ "$tmp_count" -eq 0 ]
}

@test "set-review-justification with mismatched sprint id is refused" {
  _seed_mismatch_yaml "sprint-82"
  local payload="$TEST_TMP/justification.yaml"
  _seed_review_justification "$payload"
  local before
  before="$(cksum < "$YAML")"
  run "$SCRIPT" set-review-justification --sprint sprint-1 --file "$payload"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  local after
  after="$(cksum < "$YAML")"
  [ "$before" = "$after" ]
}

@test "transition --sprint with mismatched sprint id exits 2 and names both ids" {
  _seed_mismatch_yaml "sprint-82" "active"
  local before
  before="$(cksum < "$YAML")"
  run "$SCRIPT" transition --sprint sprint-1 --to closed
  [ "$status" -eq 2 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  [[ "$output" == *"does not match active sprint-status.yaml sprint_id"* ]]
  local after
  after="$(cksum < "$YAML")"
  [ "$before" = "$after" ]
}

@test "set-goals against a yaml with no sprint_id field exits 1" {
  _seed_no_sprint_id_yaml
  run "$SCRIPT" set-goals --sprint sprint-1 --goals "g1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no sprint_id"* ]]
}

@test "transition --sprint against a yaml with no sprint_id field exits 2" {
  _seed_no_sprint_id_yaml
  run "$SCRIPT" transition --sprint sprint-1 --to closed
  [ "$status" -eq 2 ]
  [[ "$output" == *"no sprint_id"* ]]
}

# ============================================================
# set-phase rejects sprint flags
# ============================================================

@test "set-phase rejects --sprint" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" set-phase --story S1 --phase 1 --sprint sprint-1
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag for set-phase: --sprint"* ]]
}

@test "set-phase rejects --sprint-id" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" set-phase --story S1 --phase 1 --sprint-id sprint-1
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag for set-phase: --sprint-id"* ]]
}

@test "set-phase rejects --sprint with empty value" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" set-phase --story S1 --phase 1 --sprint ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag for set-phase: --sprint"* ]]
}

@test "set-phase rejects --sprint= (equals form)" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" set-phase --story S1 --phase 1 --sprint=
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag for set-phase: --sprint"* ]]
}

@test "set-phase rejects --sprint-id= (equals form)" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" set-phase --story S1 --phase 1 --sprint-id=
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag for set-phase: --sprint-id"* ]]
}

@test "bare trailing --sprint with no value fails in the parser" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" set-phase --story S1 --phase 1 --sprint
  [ "$status" -eq 1 ]
  [[ "$output" == *"--sprint requires a value"* ]]
}

# ============================================================
# reconcile sprint-id guard
# ============================================================

@test "reconcile --sprint-id mismatch is refused" {
  _seed_mismatch_yaml "sprint-82"
  local before
  before="$(cksum < "$YAML")"
  run "$SCRIPT" reconcile --sprint-id sprint-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  local after
  after="$(cksum < "$YAML")"
  [ "$before" = "$after" ]
}

@test "reconcile --sprint-id mismatch refuses before taking the lock" {
  _seed_mismatch_yaml "sprint-82"
  # Hold the sprint-status lock so a guard placed after cmd_reconcile's
  # acquire_lock would time out instead of returning the mismatch message.
  local lock_file="${YAML}.lock"
  printf '%s %s\n' "$$" "$(date +%s)" > "$lock_file"
  export GAIA_LOCK_FORCE_FALLBACK=1
  run "$SCRIPT" reconcile --sprint-id sprint-1
  rm -f "$lock_file"
  # Must refuse immediately with the mismatch message, not a lock timeout.
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  [[ "$output" == *"does not match active sprint-status.yaml sprint_id"* ]]
  # Must NOT mention lock timeout
  local lock_msg_count
  lock_msg_count="$(printf '%s\n' "$output" | grep -c 'lock timeout' || true)"
  [ "$lock_msg_count" -eq 0 ]
}

@test "reconcile without --sprint-id succeeds" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" reconcile
  [ "$status" -eq 0 ]
}

@test "reconcile with matching --sprint-id succeeds" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" reconcile --sprint-id sprint-82
  [ "$status" -eq 0 ]
}

# ============================================================
# inject sprint-id guard
# ============================================================

@test "inject --sprint-id mismatch names --sprint-id in message" {
  _seed_mismatch_yaml "sprint-82"
  seed_story S1 done
  run "$SCRIPT" inject --story S1 --sprint-id sprint-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--sprint-id"* ]]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
}

@test "inject with --sprint-id on yaml without sprint_id with already-injected story exits 0" {
  # Seed yaml without sprint_id but with S1 already present
  cat > "$YAML" <<EOF
status: active
stories:
  - key: "S1"
    title: "Fake"
    status: "done"
    points: 3
    risk: medium
EOF
  seed_story S1 done
  run "$SCRIPT" inject --story S1 --sprint-id sprint-1
  [ "$status" -eq 0 ]
}

# ============================================================
# Matching sprint id passes through
# ============================================================

@test "set-goals with matching sprint id passes through" {
  _seed_mismatch_yaml "sprint-82"
  run "$SCRIPT" set-goals --sprint sprint-82 --goals "g1|g2"
  [ "$status" -eq 0 ]
  grep -q 'g1' "$YAML"
  grep -q 'g2' "$YAML"
}

@test "set-shape with matching sprint id passes through" {
  _seed_mismatch_yaml "sprint-82"
  run "$SCRIPT" set-shape --sprint sprint-82 --shape thrust
  [ "$status" -eq 0 ]
}

@test "set-review-justification with matching sprint id passes through" {
  _seed_mismatch_yaml "sprint-82"
  local payload="$TEST_TMP/justification.yaml"
  _seed_review_justification "$payload"
  run "$SCRIPT" set-review-justification --sprint sprint-82 --file "$payload"
  [ "$status" -eq 0 ]
}

# ============================================================
# Sentinel isolation — mismatch against a different project root
# ============================================================

@test "mismatched update-goals against sentinel project is refused and file unchanged" {
  local sentinel="$TEST_TMP/sentinel"
  mkdir -p "$sentinel/.gaia/state"
  cat > "$sentinel/.gaia/state/sprint-status.yaml" <<EOF
sprint_id: "sprint-82"
status: active
stories:
  - key: "S1"
    title: "Fake"
    status: "done"
    points: 3
    risk: medium
EOF
  export PROJECT_ROOT="$sentinel" CLAUDE_PROJECT_ROOT="$sentinel"
  local before
  before="$(cksum < "$sentinel/.gaia/state/sprint-status.yaml")"
  run "$SCRIPT" update-goals --sprint sprint-1 --goals "X|Y"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-82"* ]]
  local after
  after="$(cksum < "$sentinel/.gaia/state/sprint-status.yaml")"
  [ "$before" = "$after" ]
}
