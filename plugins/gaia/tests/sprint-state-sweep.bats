#!/usr/bin/env bats
# sprint-state-sweep.bats — E64-S6 startup orphan-tmp sweep for sprint-state.sh.
#
# Verifies AC2, AC4, AC5, AC6, AC7, AC8 of E64-S6 against sprint-state.sh:
#   AC2 — sweep at startup, scoped to ${IMPLEMENTATION_ARTIFACTS} only
#         (-maxdepth 2, -name '*.tmp.??????', -mmin +60, -delete).
#   AC4 — sweep paths are bounded to the documented allowlist.
#   AC5 — sweep uses `-mmin +60`.
#   AC6 — orphan older than 60 min deleted; younger preserved.
#   AC7 — silent stdout.
#   AC8 — GAIA_SKIP_ORPHAN_SWEEP=1 skips the sweep.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-state.sh"

  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART" "$TEST_TMP/_memory"

  STORY_KEY="SS-SWEEP-01"
  STORY_FILE="$ART/${STORY_KEY}-fixture.md"
  SPRINT_YAML="$ART/sprint-status.yaml"

  cat >"$STORY_FILE" <<'EOF'
---
template: 'story'
key: "SS-SWEEP-01"
title: "Sweep fixture"
status: backlog
---

# Story: Sweep fixture

> **Status:** backlog

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

  cat >"$SPRINT_YAML" <<'EOF'
sprint_id: "fixture-sprint"
stories:
  - key: SS-SWEEP-01
    status: "backlog"
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$ART"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
}

teardown() { common_teardown; }

seed_orphan_tmp() {
  local dir="$1" age_minutes="$2"
  mkdir -p "$dir"
  local fname
  fname=$(mktemp -u "$dir/sample.tmp.XXXXXX") || return 1
  : >"$fname"
  local stamp
  if date -v-"${age_minutes}"M +"%Y%m%d%H%M" >/dev/null 2>&1; then
    stamp=$(date -v-"${age_minutes}"M +"%Y%m%d%H%M")
  else
    stamp=$(date -d "-${age_minutes} minutes" +"%Y%m%d%H%M")
  fi
  touch -t "$stamp" "$fname"
  printf '%s\n' "$fname"
}

# ---------- AC2, AC6: orphan older than 60 min in IMPLEMENTATION_ARTIFACTS is deleted ----------

@test "sprint-state.sh: orphan tmp older than 60 min in IMPLEMENTATION_ARTIFACTS is deleted (AC2/AC6)" {
  local orphan
  orphan=$(seed_orphan_tmp "$ART" 90)
  [ -e "$orphan" ]
  run "$SCRIPT" get --story "$STORY_KEY"
  [ ! -e "$orphan" ]
}

# ---------- AC5, AC6: orphan younger than 60 min is preserved ----------

@test "sprint-state.sh: orphan tmp younger than 60 min is preserved (AC5/AC6)" {
  local orphan
  orphan=$(seed_orphan_tmp "$ART" 10)
  [ -e "$orphan" ]
  run "$SCRIPT" get --story "$STORY_KEY"
  [ -e "$orphan" ]
}

# ---------- AC8: GAIA_SKIP_ORPHAN_SWEEP=1 skips the sweep ----------

@test "sprint-state.sh: GAIA_SKIP_ORPHAN_SWEEP=1 preserves old orphan (AC8)" {
  local orphan
  orphan=$(seed_orphan_tmp "$ART" 90)
  [ -e "$orphan" ]
  GAIA_SKIP_ORPHAN_SWEEP=1 run "$SCRIPT" get --story "$STORY_KEY"
  [ -e "$orphan" ]
}

# ---------- AC4: allowlist boundedness — sweep ignores PROJECT_PATH root ----------

@test "sprint-state.sh: sweep does not delete tmps outside allowlist (AC4)" {
  local outside
  outside=$(seed_orphan_tmp "$TEST_TMP" 90)
  [ -e "$outside" ]
  run "$SCRIPT" get --story "$STORY_KEY"
  [ -e "$outside" ]
}

# ---------- AC7: silent stdout from sweep ----------

@test "sprint-state.sh: sweep emits no chatter on stdout (AC7)" {
  seed_orphan_tmp "$ART" 90 >/dev/null
  run "$SCRIPT" --help
  [[ "$output" != *sweep* ]]
  [[ "$output" != *deleted* ]]
}
