#!/usr/bin/env bats
# transition-story-status-sweep.bats — E64-S6 startup orphan-tmp sweep for
#                                      transition-story-status.sh.
#
# Verifies AC1, AC4, AC5, AC6, AC7, AC8 of E64-S6 against transition-story-status.sh:
#   AC1 — script runs `find ... -mmin +60 -delete` at startup, scoped to
#         ${PLANNING_ARTIFACTS}/epics and ${IMPLEMENTATION_ARTIFACTS},
#         -maxdepth 2, -name '*.tmp.??????'.
#   AC4 — sweep paths are bounded to the documented allowlist (no /tmp,
#         no $HOME, no PROJECT_PATH root).
#   AC5 — sweep uses `-mmin +60` (in-flight tmps preserved).
#   AC6 — orphan older than 60 min is deleted; orphan younger than 60 min
#         is preserved.
#   AC7 — sweep emits zero stdout (silent garbage collection).
#   AC8 — GAIA_SKIP_ORPHAN_SWEEP=1 skips the sweep entirely.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/transition-story-status.sh"

  ART="$TEST_TMP/docs/implementation-artifacts"
  PLAN="$TEST_TMP/docs/planning-artifacts"
  EPICS_DIR="$PLAN/epics"
  mkdir -p "$ART" "$PLAN" "$EPICS_DIR" "$TEST_TMP/_memory"

  STORY_KEY="TSS-SWEEP-01"
  STORY_FILE="$ART/${STORY_KEY}-fixture.md"
  SPRINT_YAML="$ART/sprint-status.yaml"
  EPICS_MD="$PLAN/epics-and-stories.md"
  INDEX_YAML="$ART/story-index.yaml"
  LOCK_FILE="$TEST_TMP/_memory/.story-status.lock"

  cat >"$STORY_FILE" <<'EOF'
---
template: 'story'
key: "TSS-SWEEP-01"
title: "Sweep fixture"
epic: "TSS"
status: backlog
priority: "P2"
risk: "low"
author: "test"
---

# Story: Sweep fixture

> **Status:** backlog
EOF

  cat >"$SPRINT_YAML" <<'EOF'
sprint_id: "fixture-sprint"
stories:
  - key: TSS-SWEEP-01
    status: "backlog"
EOF

  cat >"$EPICS_MD" <<'EOF'
# Epics and Stories

## Epic TSS — Sweep fixture epic

### Story TSS-SWEEP-01: Sweep fixture

- **Status:** backlog
EOF

  cat >"$INDEX_YAML" <<'EOF'
last_updated: "2026-05-05T00:00:00Z"
stories:
  TSS-SWEEP-01:
    status: "backlog"
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$ART"
  export PLANNING_ARTIFACTS="$PLAN"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
  export EPICS_AND_STORIES="$EPICS_MD"
  export STORY_INDEX_YAML="$INDEX_YAML"
  export STORY_STATUS_LOCK="$LOCK_FILE"
}

teardown() { common_teardown; }

# Create an orphan tmp file with a specific mtime via `touch -t`.
# When age_minutes > 60 the orphan should be deleted by the sweep;
# when <= 60 it should be preserved.
seed_orphan_tmp() {
  local dir="$1" age_minutes="$2"
  mkdir -p "$dir"
  local fname
  fname=$(mktemp -u "$dir/sample.tmp.XXXXXX") || return 1
  : >"$fname"
  # Compute a timestamp `age_minutes` minutes in the past, in [[CC]YY]MMDDhhmm
  # format compatible with macOS and GNU `touch -t`.
  local stamp
  if date -v-"${age_minutes}"M +"%Y%m%d%H%M" >/dev/null 2>&1; then
    stamp=$(date -v-"${age_minutes}"M +"%Y%m%d%H%M")
  else
    stamp=$(date -d "-${age_minutes} minutes" +"%Y%m%d%H%M")
  fi
  touch -t "$stamp" "$fname"
  printf '%s\n' "$fname"
}

# ---------- AC1, AC6: orphan older than 60 min is deleted ----------

@test "transition-story-status.sh: orphan tmp older than 60 min in IMPLEMENTATION_ARTIFACTS is deleted (AC6)" {
  local orphan
  orphan=$(seed_orphan_tmp "$ART" 90)
  [ -e "$orphan" ]
  run "$SCRIPT" "$STORY_KEY" --to validating
  [ ! -e "$orphan" ]
}

@test "transition-story-status.sh: orphan tmp older than 60 min in PLANNING_ARTIFACTS/epics is deleted (AC1)" {
  local orphan
  orphan=$(seed_orphan_tmp "$EPICS_DIR" 90)
  [ -e "$orphan" ]
  run "$SCRIPT" "$STORY_KEY" --to validating
  [ ! -e "$orphan" ]
}

# ---------- AC5, AC6: orphan younger than 60 min is preserved ----------

@test "transition-story-status.sh: orphan tmp younger than 60 min is preserved (AC5/AC6)" {
  local orphan
  orphan=$(seed_orphan_tmp "$ART" 10)
  [ -e "$orphan" ]
  run "$SCRIPT" "$STORY_KEY" --to validating
  [ -e "$orphan" ]
}

# ---------- AC8: GAIA_SKIP_ORPHAN_SWEEP=1 skips the sweep entirely ----------

@test "transition-story-status.sh: GAIA_SKIP_ORPHAN_SWEEP=1 preserves old orphan (AC8)" {
  local orphan
  orphan=$(seed_orphan_tmp "$ART" 90)
  [ -e "$orphan" ]
  GAIA_SKIP_ORPHAN_SWEEP=1 run "$SCRIPT" "$STORY_KEY" --to validating
  [ -e "$orphan" ]
}

# ---------- AC7: sweep is silent on stdout ----------

@test "transition-story-status.sh: sweep emits zero stdout when no script work follows (AC7)" {
  # Sentinel: seed an orphan, then call --help so the script exits before
  # the transition body. Any sweep output would be visible in stdout.
  seed_orphan_tmp "$ART" 90 >/dev/null
  # Invoke --help (still triggers the startup sweep at script entry).
  run "$SCRIPT" --help
  # --help writes usage to stdout, so we just assert no `sweep` / `removed`
  # / `delete` chatter from the sweep itself appears.
  [[ "$output" != *sweep* ]]
  [[ "$output" != *removed* ]]
  [[ "$output" != *deleted* ]]
}

# ---------- AC4: allowlist boundedness — sweep does NOT touch /tmp or $HOME ----------

@test "transition-story-status.sh: sweep does not delete tmps outside allowlist (AC4)" {
  # Drop an old tmp in PROJECT_PATH root (outside allowlist) and assert
  # the sweep ignores it.
  local outside
  outside=$(seed_orphan_tmp "$TEST_TMP" 90)
  [ -e "$outside" ]
  run "$SCRIPT" "$STORY_KEY" --to validating
  [ -e "$outside" ]
}
