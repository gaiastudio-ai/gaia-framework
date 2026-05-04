#!/usr/bin/env bats
# transition-story-status-trap.bats — E64-S5 script-level EXIT/INT/TERM trap
#                                       for atomic-write tmp cleanup.
#
# Verifies AC1, AC2, AC3, AC6, AC7, AC8 of E64-S5:
#   AC1 / AC2 — _GAIA_TMP_PATHS array + _cleanup_tmps function +
#               trap '_cleanup_tmps' EXIT INT TERM exists at script-level
#               BEFORE the first mktemp.
#   AC3      — register-then-clear pattern: every mktemp call registers in
#              _GAIA_TMP_PATHS; every successful mv -f clears the slot.
#   AC6      — SIGINT mid-write removes the tmp file.
#   AC7      — SIGTERM mid-write removes the tmp file.
#   AC8      — awk-failure path: trap fires on script exit, tmp is removed.
#
# Usage:
#   bats plugins/gaia/tests/transition-story-status-trap.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/tss-trap-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$TEST_TMP/_memory"
  mkdir -p "$TEST_TMP/stub-bin"

  STORY_KEY="TSS-TRAP-01"
  STORY_FILE="$TEST_TMP/docs/implementation-artifacts/${STORY_KEY}-fixture.md"
  SPRINT_YAML="$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml"
  EPICS_MD="$TEST_TMP/docs/planning-artifacts/epics-and-stories.md"
  INDEX_YAML="$TEST_TMP/docs/implementation-artifacts/story-index.yaml"
  LOCK_FILE="$TEST_TMP/_memory/.story-status.lock"

  cat >"$STORY_FILE" <<'EOF'
---
template: 'story'
key: "TSS-TRAP-01"
title: "Trap fixture"
epic: "TSS"
status: backlog
priority: "P2"
risk: "low"
author: "test"
---

# Story: Trap fixture

> **Status:** backlog
EOF

  cat >"$SPRINT_YAML" <<'EOF'
sprint_id: "fixture-sprint"
stories:
  - key: TSS-TRAP-01
    status: "backlog"
EOF

  cat >"$EPICS_MD" <<'EOF'
# Epics and Stories

## Epic TSS — Trap fixture epic

### Story TSS-TRAP-01: Trap fixture

- **Status:** backlog
EOF

  cat >"$INDEX_YAML" <<'EOF'
last_updated: "2026-05-05T00:00:00Z"
stories:
  TSS-TRAP-01:
    status: "backlog"
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
  export EPICS_AND_STORIES="$EPICS_MD"
  export STORY_INDEX_YAML="$INDEX_YAML"
  export STORY_STATUS_LOCK="$LOCK_FILE"
}

teardown() {
  chmod -R u+w "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Count *.tmp.?????? files (orphan tmps) in implementation/planning artifact dirs.
count_orphan_tmps() {
  find "$TEST_TMP/docs" -type f \( -name '*.tmp.??????' -o -name '*.newsec.??????' \) 2>/dev/null | wc -l | tr -d ' '
}

# Install a stub `mv` on PATH that sleeps BEFORE delegating to /bin/mv.
# This pauses the script AFTER mktemp + awk redirect (the tmp file is on
# disk with full contents) but BEFORE the rename to the final destination.
# In this window, the existing function-scoped RETURN trap has NOT fired
# (the function has not returned), and the existing manual `rm -f` paths
# do NOT cover this race (they only fire on awk failure or mv failure).
# Only the new script-level EXIT/INT/TERM trap can clean an orphan here.
install_slow_mv_stub() {
  local marker="$1" sleep_secs="$2"
  cat >"$TEST_TMP/stub-bin/mv" <<EOF
#!/usr/bin/env bash
touch "$marker"
sleep $sleep_secs
exec /bin/mv "\$@"
EOF
  chmod +x "$TEST_TMP/stub-bin/mv"
}

# ---------- AC1 / AC2: trap and array exist ----------

@test "transition-story-status.sh: declares _GAIA_TMP_PATHS array at top-level scope" {
  grep -E '^_GAIA_TMP_PATHS=\(\)' "$TRANSITION"
}

@test "transition-story-status.sh: defines _cleanup_tmps function" {
  grep -E '^_cleanup_tmps\s*\(\)|^_cleanup_tmps\(\)' "$TRANSITION"
}

@test "transition-story-status.sh: sets trap _cleanup_tmps EXIT INT TERM" {
  grep -E "trap[[:space:]]+['\"]_cleanup_tmps['\"][[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM" "$TRANSITION"
}

@test "transition-story-status.sh: trap is set BEFORE first mktemp call" {
  local trap_line first_mktemp_line
  trap_line=$(grep -nE "trap[[:space:]]+['\"]_cleanup_tmps['\"][[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM" "$TRANSITION" | head -1 | cut -d: -f1)
  first_mktemp_line=$(grep -nE 'mktemp[[:space:]]+["]?\$\{?file' "$TRANSITION" | head -1 | cut -d: -f1)
  [ -n "$trap_line" ]
  [ -n "$first_mktemp_line" ]
  [ "$trap_line" -lt "$first_mktemp_line" ]
}

# ---------- AC3: register-then-clear pattern at every mktemp call site ----------

@test "transition-story-status.sh: every mktemp call site registers in _GAIA_TMP_PATHS" {
  local mktemp_count register_count
  mktemp_count=$(grep -cE 'mktemp[[:space:]]+"\$\{?(file|yaml)' "$TRANSITION" || true)
  register_count=$(grep -cE '_GAIA_TMP_PATHS\+=\(' "$TRANSITION" || true)
  [ "$mktemp_count" -ge 4 ]
  [ "$register_count" -ge "$mktemp_count" ]
}

@test "transition-story-status.sh: every successful mv clears its array slot" {
  # After each `mv -f "$tmp" "$file"` we expect a `_GAIA_TMP_PATHS[$_tmp_idx]=""`
  # or equivalent assignment to clear the slot. Count must match mktemp count.
  local clear_count mktemp_count
  clear_count=$(grep -cE '_GAIA_TMP_PATHS\[\$_tmp_idx\]=""' "$TRANSITION" || true)
  mktemp_count=$(grep -cE 'mktemp[[:space:]]+"\$\{?(file|yaml)' "$TRANSITION" || true)
  [ "$clear_count" -ge "$mktemp_count" ]
}

# ---------- AC6: SIGINT mid-write removes tmp ----------

@test "transition-story-status.sh: SIGINT mid-write cleans tmp (AC6)" {
  local marker="$TEST_TMP/awk-started"
  install_slow_mv_stub "$marker" "2"
  # Run the script in background with stub awk on PATH.
  PATH="$TEST_TMP/stub-bin:$PATH" "$TRANSITION" "$STORY_KEY" --to validating &
  local pid=$!
  # Wait for awk to fire the marker (script reached the rewrite_frontmatter awk pass).
  local waited=0
  while [ ! -e "$marker" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$marker" ]
  # Kill -INT the script while awk is sleeping.
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # Assert no orphan tmp survived.
  local orphans
  orphans=$(count_orphan_tmps)
  [ "$orphans" = "0" ]
}

# ---------- AC7: SIGTERM mid-write removes tmp ----------

@test "transition-story-status.sh: SIGTERM mid-write cleans tmp (AC7)" {
  local marker="$TEST_TMP/awk-started"
  install_slow_mv_stub "$marker" "2"
  PATH="$TEST_TMP/stub-bin:$PATH" "$TRANSITION" "$STORY_KEY" --to validating &
  local pid=$!
  local waited=0
  while [ ! -e "$marker" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$marker" ]
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  local orphans
  orphans=$(count_orphan_tmps)
  [ "$orphans" = "0" ]
}

# ---------- AC8: awk-failure path triggers trap cleanup ----------

@test "transition-story-status.sh: awk failure path cleans tmp via trap (AC8)" {
  # Corrupt the story file so the awk rewrite passes return non-zero.
  # Specifically: remove the closing --- frontmatter delimiter so the awk
  # in rewrite_frontmatter exits with rc=2 (no status: line in the body).
  cat >"$STORY_FILE" <<'EOF'
---
template: 'story'
key: "TSS-TRAP-01"
title: "Malformed - no status field"
epic: "TSS"
priority: "P2"
risk: "low"
---

# Story: Malformed
EOF
  run "$TRANSITION" "$STORY_KEY" --to validating
  # Expect non-zero exit (4 = malformed frontmatter).
  [ "$status" -ne 0 ]
  # No orphan tmp left behind.
  local orphans
  orphans=$(count_orphan_tmps)
  [ "$orphans" = "0" ]
}
