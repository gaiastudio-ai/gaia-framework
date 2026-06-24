#!/usr/bin/env bats
# sprint-state-ssot-parity.bats — divergence-guard + edge-parity tests
#
# Verifies that sprint-state.sh delegates story-level edge validation to the
# shared story-state-machine.sh SSOT and carries no inline adjacency table,
# AND that transition-story-status.sh produces identical pass/fail verdicts
# for the same edge matrix.
#
# Public functions covered: validate_transition (via cmd_transition --story),
# validate_story_transition (via transition-story-status.sh).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-state.sh"
  TSS="$SCRIPTS_DIR/transition-story-status.sh"
  LIB="$SCRIPTS_DIR/lib/story-state-machine.sh"
  WRAPPER_LIB="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/lib/story-state-machine.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  PLAN="$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$ART" "$PLAN"
}
teardown() { common_teardown; }

@test "the dev-story wrapper lib is a real file (not a symlink) and byte-identical to the canonical SSOT (AC1)" {
  # The wrapper copy of sprint-state.sh sources lib/story-state-machine.sh
  # relative to its own dir, so a real copy must live alongside it. It MUST be
  # a regular file (symlinks are not portable to every CI runner) and MUST stay
  # byte-identical to the canonical SSOT so the two never drift.
  [ -f "$WRAPPER_LIB" ]
  [ ! -L "$WRAPPER_LIB" ]
  diff "$LIB" "$WRAPPER_LIB"
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

## Definition of Done

### Acceptance

- [x] All acceptance criteria verified and checked off
- [x] All subtasks marked complete

### Testing

- [x] All tests pass (unit, integration, e2e as applicable)
- [x] No linting or formatting errors

### Code Quality & CI

- [x] Code compiles / builds without errors
- [x] Code follows project conventions
- [x] No hardcoded secrets or credentials
- [x] PR merged to staging with all CI checks passing

### Documentation

- [x] Documentation updated (if applicable)
EOF
}

seed_yaml() {
  cat > "$ART/sprint-status.yaml" <<EOF
sprint_id: "sprint-test"
stories:
  - key: "$1"
    title: "Fake"
    status: "$2"
EOF
}

# ============================================================
# Previously-rejected edge now accepted (AC2)
# ============================================================

@test "sprint-state.sh accepts backlog -> ready-for-dev (AC2)" {
  seed_story P1 backlog
  seed_yaml P1 backlog
  run "$SCRIPT" transition --story P1 --to ready-for-dev
  [ "$status" -eq 0 ]
  grep -q '^status: ready-for-dev' "$ART/P1-fake.md"
}

# ============================================================
# Full edge-matrix parity between sprint-state.sh and SSOT (AC2)
# ============================================================

@test "sprint-state.sh and SSOT agree on every legal edge (AC2)" {
  # Source the shared lib to get the SSOT edge list.
  # shellcheck source=../scripts/lib/story-state-machine.sh
  source "$LIB"

  local fail_list=""
  local edge from to
  for edge in "${STORY_ALLOWED_EDGES[@]}"; do
    from="${edge%%|*}"
    to="${edge#*|}"
    # Seed story + yaml in the from-state.
    seed_story PA "$from"
    seed_yaml PA "$from"
    run "$SCRIPT" transition --story PA --to "$to"
    if [ "$status" -ne 0 ]; then
      fail_list="${fail_list}  REJECT: ${from} -> ${to}\n"
    fi
  done

  if [ -n "$fail_list" ]; then
    printf 'sprint-state.sh rejected edges that the SSOT accepts:\n%b' "$fail_list" >&2
    return 1
  fi
}

@test "sprint-state.sh and SSOT agree on every illegal edge (AC2)" {
  # Source the shared lib to get the SSOT states + edges.
  # shellcheck source=../scripts/lib/story-state-machine.sh
  source "$LIB"

  # Build the full illegal-edge complement.
  local fail_list=""
  local from to edge found
  for from in "${STORY_CANONICAL_STATES[@]}"; do
    for to in "${STORY_CANONICAL_STATES[@]}"; do
      [ "$from" = "$to" ] && continue
      # Skip if this is a legal edge.
      found=0
      for edge in "${STORY_ALLOWED_EDGES[@]}"; do
        if [ "$edge" = "${from}|${to}" ]; then
          found=1
          break
        fi
      done
      [ "$found" -eq 1 ] && continue

      # This edge should be REJECTED by sprint-state.sh.
      seed_story PB "$from"
      seed_yaml PB "$from"
      run "$SCRIPT" transition --story PB --to "$to"
      if [ "$status" -eq 0 ]; then
        fail_list="${fail_list}  ACCEPT: ${from} -> ${to} (should be illegal)\n"
      fi
    done
  done

  if [ -n "$fail_list" ]; then
    printf 'sprint-state.sh accepted edges that the SSOT forbids:\n%b' "$fail_list" >&2
    return 1
  fi
}

# ============================================================
# Divergence guard: no inline edge table in sprint-state.sh (AC3)
# ============================================================

@test "sprint-state.sh contains no inline ALLOWED_EDGES array (AC3)" {
  # The script must NOT declare its own ALLOWED_EDGES=( ... ) array.
  if grep -qE '^[[:space:]]*ALLOWED_EDGES=\(' "$SCRIPT"; then
    printf 'sprint-state.sh still contains an inline ALLOWED_EDGES array declaration\n' >&2
    return 1
  fi
}

# ============================================================
# Illegal edge still rejected (TS-4)
# ============================================================

@test "sprint-state.sh rejects backlog -> done (TS-4)" {
  seed_story R1 backlog
  seed_yaml R1 backlog
  run "$SCRIPT" transition --story R1 --to done
  [ "$status" -ne 0 ]
  grep -q '^status: backlog' "$ART/R1-fake.md"
}

# ============================================================
# Self-transition idempotent no-op check (TS-5)
# ============================================================

@test "sprint-state.sh self-transition is detected (TS-5)" {
  seed_story S1 backlog
  seed_yaml S1 backlog
  run "$SCRIPT" transition --story S1 --to backlog
  # Self-transition exits non-zero (current behavior: die "already in state")
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
}

# ============================================================
# Correct-course defer path: ready-for-dev -> backlog (AC1)
# ============================================================

@test "sprint-state.sh accepts ready-for-dev -> backlog (AC1)" {
  seed_story DF1 ready-for-dev
  seed_yaml DF1 ready-for-dev
  run "$SCRIPT" transition --story DF1 --to backlog
  [ "$status" -eq 0 ]
  grep -q '^status: backlog' "$ART/DF1-fake.md"
}

# ============================================================
# Cross-script parity: transition-story-status.sh key edges (AC2)
# ============================================================

# Helper: seed a complete project fixture for transition-story-status.sh.
# TSS needs story file + sprint-status.yaml + epics-and-stories.md + index.
seed_tss_project() {
  local key="$1" status="$2"
  seed_story "$key" "$status"
  seed_yaml "$key" "$status"
  cat > "$PLAN/epics-and-stories.md" <<EPICS
# Epics and Stories

## Epic TSS

### Story ${key}: Parity fixture

- **Status:** ${status}
EPICS
  cat > "$ART/story-index.yaml" <<IDX
# Auto-maintained
stories:
  ${key}:
    status: "${status}"
IDX
}

# Helper: run transition-story-status.sh with the test fixture env.
run_tss() {
  local key="$1" to="$2"
  IMPLEMENTATION_ARTIFACTS="$ART" \
  PLANNING_ARTIFACTS="$PLAN" \
  SPRINT_STATUS_YAML="$ART/sprint-status.yaml" \
  STORY_INDEX_YAML="$ART/story-index.yaml" \
  STORY_STATUS_LOCK="$TEST_TMP/_memory/.story-status.lock" \
    run "$TSS" "$key" --to "$to"
}

@test "transition-story-status.sh accepts ready-for-dev -> backlog (AC2)" {
  seed_tss_project TF1 ready-for-dev
  run_tss TF1 backlog
  [ "$status" -eq 0 ]
  grep -q '^status: backlog' "$ART/TF1-fake.md"
}

@test "transition-story-status.sh rejects review -> in-progress (AC2)" {
  seed_tss_project TF2 review
  run_tss TF2 in-progress
  [ "$status" -ne 0 ]
}

@test "transition-story-status.sh accepts backlog -> ready-for-dev (AC2)" {
  seed_tss_project TF3 backlog
  run_tss TF3 ready-for-dev
  [ "$status" -eq 0 ]
  grep -q '^status: ready-for-dev' "$ART/TF3-fake.md"
}

@test "both scripts agree on key legal edges (AC2)" {
  # shellcheck source=../scripts/lib/story-state-machine.sh
  source "$LIB"

  # Drive a representative subset of legal edges through BOTH scripts and
  # assert identical accept verdicts.
  local key_edges=(
    "backlog|ready-for-dev"
    "backlog|in-progress"
    "ready-for-dev|backlog"
    "ready-for-dev|in-progress"
    "in-progress|review"
    "in-progress|blocked"
    "blocked|in-progress"
    "validating|ready-for-dev"
  )
  local fail_list="" edge from to
  for edge in "${key_edges[@]}"; do
    from="${edge%%|*}"
    to="${edge#*|}"

    # sprint-state.sh
    seed_story KE "$from"
    seed_yaml KE "$from"
    run "$SCRIPT" transition --story KE --to "$to"
    local ss_rc="$status"

    # transition-story-status.sh
    seed_tss_project KE2 "$from"
    run_tss KE2 "$to"
    local tss_rc="$status"

    if [ "$ss_rc" -ne 0 ] || [ "$tss_rc" -ne 0 ]; then
      fail_list="${fail_list}  ${from}->${to}: sprint-state=$ss_rc tss=$tss_rc\n"
    fi
  done

  if [ -n "$fail_list" ]; then
    printf 'Scripts disagree on legal edges:\n%b' "$fail_list" >&2
    return 1
  fi
}

@test "both scripts agree on key illegal edges (AC2)" {
  local illegal_edges=(
    "backlog|done"
    "review|in-progress"
    "done|backlog"
    "done|in-progress"
    "in-progress|backlog"
    "review|backlog"
  )
  local fail_list="" edge from to
  for edge in "${illegal_edges[@]}"; do
    from="${edge%%|*}"
    to="${edge#*|}"

    seed_story IL "$from"
    seed_yaml IL "$from"
    run "$SCRIPT" transition --story IL --to "$to"
    local ss_rc="$status"

    seed_tss_project IL2 "$from"
    run_tss IL2 "$to"
    local tss_rc="$status"

    if [ "$ss_rc" -eq 0 ] || [ "$tss_rc" -eq 0 ]; then
      fail_list="${fail_list}  ${from}->${to}: sprint-state=$ss_rc tss=$tss_rc (expected both non-zero)\n"
    fi
  done

  if [ -n "$fail_list" ]; then
    printf 'Scripts disagree on illegal edges:\n%b' "$fail_list" >&2
    return 1
  fi
}
