#!/usr/bin/env bats
# e107-chain-integration.bats — E107 end-to-end chain integration
#
# The per-story suites (e107-s1..s4) are unit/contract tests over each script
# in isolation. This suite proves the four stories COMPOSE into the intended
# JIT-materialization + planned-sprint lifecycle, threading real data through
# every script in production order:
#
#   S2  backlog-select-lint.sh   — validate the candidate set's deps from the roster
#   S1  sprint-state.sh init      — seed the sprint in the `planned` state
#   S3  materialize-sprint-stories.sh — scaffold the selected stories (→ backlog)
#   S4  planned-active-gate.sh    — REFUSE activation while a story is not ready
#       transition-story-status.sh — activate each story → ready-for-dev
#   S4  planned-active-gate.sh    — now PASS (every story materialized + ready)
#   S1  sprint-state.sh transition --sprint --to active — flip planned → active
#
# Everything runs against a temp tree built in $BATS_TEST_TMPDIR; the live
# project tree is never touched.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/plugins/gaia/scripts"
  SS="$SCRIPTS/sprint-state.sh"
  LINT="$SCRIPTS/backlog-select-lint.sh"
  MATERIALIZE="$SCRIPTS/materialize-sprint-stories.sh"
  GATE="$SCRIPTS/planned-active-gate.sh"
  TRANSITION="$SCRIPTS/transition-story-status.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/e107chain-$$"
  IMPL="$TEST_TMP/impl"
  TA="$TEST_TMP/test-artifacts"
  STATE="$TEST_TMP/.gaia/state"
  PLANNING="$TEST_TMP/planning"
  mkdir -p "$IMPL" "$TA" "$STATE" "$PLANNING"

  # epics-and-stories.md lives under PLANNING_ARTIFACTS so transition-story-status.sh
  # can resolve the per-epic story-index.yaml and update the registry surfaces.
  EPICS="$PLANNING/epics-and-stories.md"
  SPRINT_YAML="$STATE/sprint-status.yaml"

  # Path environment that points every chain script at the temp tree (never the
  # live project). transition-story-status.sh honours these; the others take
  # explicit --flags but inherit IMPLEMENTATION_ARTIFACTS for resolve-story-file.
  CHAIN_ENV=(
    "IMPLEMENTATION_ARTIFACTS=$IMPL"
    "PLANNING_ARTIFACTS=$PLANNING"
    "EPICS_AND_STORIES=$EPICS"
    "GAIA_STATE_DIR=$STATE"
    "SPRINT_STATUS_YAML=$SPRINT_YAML"
  )

  # Minimal self-contained roster: two low-risk stories, S2 hard-depends on S1
  # (co-selected, so the lint must pass). Low risk so the S4 gate's ATDD branch
  # is not required.
  cat > "$EPICS" <<'EOF'
# Epics and Stories

## E900 — Chain Fixture Epic

| Story | Title | Size | Points | Risk | Depends on | Blocks |
|-------|-------|------|--------|------|------------|--------|
| E900-S1 | Foundation | M | 5 | low | none | E900-S2 |
| E900-S2 | Builds on S1 | M | 5 | low | E900-S1 | none |

### Story E900-S1: Foundation

- **Epic:** E900 — Chain Fixture Epic
- **Priority:** P2
- **Size:** M (5 pts)
- **Risk:** low
- **Status:** backlog
- **Sprint:** null
- **Priority flag:** null
- **Description:** As a fixture, I want a foundation story.
- **Acceptance Criteria:**
  - AC1: Given a fixture, when used, then it works.
- **Depends on:** []
- **Blocks:** [E900-S2]
- **Traces to:** none

---

### Story E900-S2: Builds on S1

- **Epic:** E900 — Chain Fixture Epic
- **Priority:** P2
- **Size:** M (5 pts)
- **Risk:** low
- **Status:** backlog
- **Sprint:** null
- **Priority flag:** null
- **Description:** As a fixture, I want a story that depends on S1.
- **Acceptance Criteria:**
  - AC1: Given S1 is selected, when used, then it works.
- **Depends on:** [E900-S1]
- **Blocks:** []
- **Traces to:** none

---
EOF

  CANDIDATES="E900-S1,E900-S2"
}

teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# Read a story file's frontmatter status (source of truth).
story_status() { # $1=key
  local sf
  sf="$(IMPLEMENTATION_ARTIFACTS="$IMPL" bash "$REPO_ROOT/plugins/gaia/scripts/resolve-story-file.sh" "$1" 2>/dev/null)"
  [ -n "$sf" ] || { echo "UNMATERIALIZED"; return 0; }
  awk -F'"' '/^status:/ {gsub(/status:[[:space:]]*/,"",$0); gsub(/"/,"",$0); print $0; exit}' "$sf"
}

# ---------------------------------------------------------------------------
# Stage-by-stage assertions (each proves one hand-off works)
# ---------------------------------------------------------------------------

@test "S2: backlog-select-lint passes for a candidate set whose hard dep is co-selected" {
  run bash "$LINT" --epics "$EPICS" --candidates "$CANDIDATES"
  [ "$status" -eq 0 ]
}

@test "S2: backlog-select-lint HARD-BLOCKS when a hard dep is neither done nor co-selected" {
  # Select only S2 — its hard dep S1 is absent from --candidates and --done.
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S2"
  [ "$status" -eq 2 ]
}

@test "S1: sprint-state.sh init seeds the sprint in the planned state" {
  run env "${CHAIN_ENV[@]}" bash "$SS" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  grep -Eq '^status:[[:space:]]*planned' "$SPRINT_YAML"
}

@test "S3: materialize-sprint-stories scaffolds the selected stories (at backlog)" {
  run bash "$MATERIALIZE" --keys "$CANDIDATES" --epics "$EPICS" --impl-root "$IMPL"
  [ "$status" -eq 0 ]
  [ "$(story_status E900-S1)" = "backlog" ]
  [ "$(story_status E900-S2)" = "backlog" ]
}

# ---------------------------------------------------------------------------
# The full chain — the actual integration proof
# ---------------------------------------------------------------------------

@test "INTEGRATION: full E107 chain plan→materialize→gate-refuse→activate→gate-pass→active" {
  # --- S2: dependency lint on the candidate set ---
  run bash "$LINT" --epics "$EPICS" --candidates "$CANDIDATES"
  [ "$status" -eq 0 ]

  # --- S1: seed the sprint as planned ---
  env "${CHAIN_ENV[@]}" bash "$SS" init --sprint-id sprint-900
  grep -Eq '^status:[[:space:]]*planned' "$SPRINT_YAML"

  # Bind the two selected stories into the sprint roster (stories[] block the
  # gate reads). Append a minimal roster — the gate keys off `- key:` lines.
  cat >> "$SPRINT_YAML" <<'EOF'
stories:
  - key: "E900-S1"
    status: "backlog"
  - key: "E900-S2"
    status: "backlog"
EOF

  # --- S3: materialize the selected stories (→ backlog) ---
  bash "$MATERIALIZE" --keys "$CANDIDATES" --epics "$EPICS" --impl-root "$IMPL"
  [ "$(story_status E900-S1)" = "backlog" ]
  [ "$(story_status E900-S2)" = "backlog" ]

  # --- S4: readiness gate REFUSES while stories are still backlog ---
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 2 ]
  echo "$output" | grep -Eiq 'E900-S1|E900-S2|not.?ready|ready-for-dev'

  # --- activate each story: backlog → ready-for-dev (the E107-S5 transition) ---
  env "${CHAIN_ENV[@]}" bash "$TRANSITION" E900-S1 --to ready-for-dev
  env "${CHAIN_ENV[@]}" bash "$TRANSITION" E900-S2 --to ready-for-dev
  [ "$(story_status E900-S1)" = "ready-for-dev" ]
  [ "$(story_status E900-S2)" = "ready-for-dev" ]

  # --- S4: readiness gate now PASSES (every story materialized + ready-for-dev) ---
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 0 ]

  # --- S1: flip planned → active now that the gate is satisfied ---
  env "${CHAIN_ENV[@]}" bash "$SS" transition --sprint sprint-900 --to active
  grep -Eq '^status:[[:space:]]*active' "$SPRINT_YAML"
}

@test "INTEGRATION negative: gate stays REFUSED if only one of two stories is activated" {
  env "${CHAIN_ENV[@]}" bash "$SS" init --sprint-id sprint-900
  cat >> "$SPRINT_YAML" <<'EOF'
stories:
  - key: "E900-S1"
    status: "backlog"
  - key: "E900-S2"
    status: "backlog"
EOF
  bash "$MATERIALIZE" --keys "$CANDIDATES" --epics "$EPICS" --impl-root "$IMPL"

  # Activate only S1; S2 stays backlog.
  env "${CHAIN_ENV[@]}" bash "$TRANSITION" E900-S1 --to ready-for-dev
  [ "$(story_status E900-S1)" = "ready-for-dev" ]
  [ "$(story_status E900-S2)" = "backlog" ]

  # Gate must still refuse — naming the un-ready story.
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'E900-S2'
}
