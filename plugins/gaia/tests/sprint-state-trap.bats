#!/usr/bin/env bats
# sprint-state-trap.bats — E64-S5 script-level EXIT/INT/TERM trap for
#                          atomic-write tmp cleanup in sprint-state.sh.
#
# Verifies AC1, AC2, AC4, AC6, AC7, AC8 of E64-S5 against sprint-state.sh:
#   AC1 / AC2 — _GAIA_TMP_PATHS array + _cleanup_tmps function +
#               trap '_cleanup_tmps' EXIT INT TERM exists at script-level
#               BEFORE the first mktemp.
#   AC4      — all 4 atomic-write mktemp call sites register in
#              _GAIA_TMP_PATHS and clear their slot after successful mv.
#   AC6 / AC7 — SIGINT / SIGTERM mid-write removes tmp.
#   AC8      — error-path: trap fires on script exit, tmp is removed.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-state.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART" "$MEMORY_PATH" "$TEST_TMP/stub-bin"
}
teardown() { common_teardown; }

seed_story() {
  local key="$1" status="$2" verdict="${3:-PASSED}"
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
| Code Review | $verdict | — |
| QA Tests | $verdict | — |
| Security Review | $verdict | — |
| Test Automation | $verdict | — |
| Test Review | $verdict | — |
| Performance Review | $verdict | — |
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

count_orphan_tmps() {
  find "$ART" -type f -name '*.tmp.??????' 2>/dev/null | wc -l | tr -d ' '
}

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

@test "sprint-state.sh: declares _GAIA_TMP_PATHS array at top-level scope" {
  grep -E '^_GAIA_TMP_PATHS=\(\)' "$SCRIPT"
}

@test "sprint-state.sh: defines _cleanup_tmps function" {
  grep -E '^_cleanup_tmps\s*\(\)|^_cleanup_tmps\(\)' "$SCRIPT"
}

@test "sprint-state.sh: sets trap _cleanup_tmps EXIT INT TERM" {
  grep -E "trap[[:space:]]+['\"]_cleanup_tmps['\"][[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM" "$SCRIPT"
}

@test "sprint-state.sh: trap is set BEFORE first atomic-write mktemp call" {
  local trap_line first_mktemp_line
  trap_line=$(grep -nE "trap[[:space:]]+['\"]_cleanup_tmps['\"][[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM" "$SCRIPT" | head -1 | cut -d: -f1)
  first_mktemp_line=$(grep -nE 'mktemp[[:space:]]+"\$\{?file' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$trap_line" ]
  [ -n "$first_mktemp_line" ]
  [ "$trap_line" -lt "$first_mktemp_line" ]
}

# ---------- AC4: all 4 atomic-write mktemp sites are wired ----------

@test "sprint-state.sh: every atomic-write mktemp registers in _GAIA_TMP_PATHS" {
  # Count atomic-write mktemp call sites (those using ${file}.tmp.XXXXXX pattern).
  # E64-S7: the lint_err_file mktemp at sprint-state.sh:1782 is now also
  # registered in _GAIA_TMP_PATHS — it was previously excepted as a
  # "transient stderr capture", but interrupting lint-dependencies between
  # mktemp and the inline rm -f leaks an orphan *.lint-err.?????? file.
  local mktemp_count register_count
  mktemp_count=$(grep -cE 'mktemp[[:space:]]+"\$\{?file\}?\.tmp\.XXXXXX"' "$SCRIPT" || true)
  register_count=$(grep -cE '_GAIA_TMP_PATHS\+=\(' "$SCRIPT" || true)
  [ "$mktemp_count" -ge 4 ]
  [ "$register_count" -ge "$mktemp_count" ]
}

# ---------- E64-S7: lint_err_file mktemp registers in _GAIA_TMP_PATHS ----------

@test "sprint-state.sh: lint_err_file mktemp is registered in _GAIA_TMP_PATHS (E64-S7)" {
  # The lint_err_file mktemp uses the .lint-err.XXXXXX suffix — distinct from
  # the .tmp.XXXXXX atomic-write pattern. It must now be registered so
  # _cleanup_tmps catches it on EXIT/INT/TERM.
  local lint_err_mktemp_line lint_err_register_line
  lint_err_mktemp_line=$(grep -nE 'mktemp[[:space:]]+"\$\{?SPRINT_STATUS_YAML\}?\.lint-err\.XXXXXX"' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$lint_err_mktemp_line" ]
  # The next _GAIA_TMP_PATHS+=("$lint_err_file") must appear within 10 lines
  # of the mktemp call (registration is the immediate follow-up step,
  # allowing for an inline comment block describing the rationale).
  lint_err_register_line=$(grep -nE '_GAIA_TMP_PATHS\+=\("\$lint_err_file"\)' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$lint_err_register_line" ]
  [ "$lint_err_register_line" -gt "$lint_err_mktemp_line" ]
  [ $((lint_err_register_line - lint_err_mktemp_line)) -le 10 ]
}

@test "sprint-state.sh: lint_err_file slot cleared after rm -f (E64-S7)" {
  # Both rm -f "$lint_err_file" sites (success path + die path) must be
  # followed by a _GAIA_TMP_PATHS[$_lint_err_idx]="" slot-clear so the trap
  # does not double-rm a freed inode.
  local clear_count
  clear_count=$(grep -cE '_GAIA_TMP_PATHS\[\$_lint_err_idx\]=""' "$SCRIPT" || true)
  [ "$clear_count" -ge 2 ]
}

@test "sprint-state.sh: every atomic-write mv clears its array slot" {
  local clear_count mktemp_count
  clear_count=$(grep -cE '_GAIA_TMP_PATHS\[\$_tmp_idx\]=""' "$SCRIPT" || true)
  mktemp_count=$(grep -cE 'mktemp[[:space:]]+"\$\{?file\}?\.tmp\.XXXXXX"' "$SCRIPT" || true)
  [ "$clear_count" -ge "$mktemp_count" ]
}

# ---------- AC6: SIGINT mid-write removes tmp ----------

@test "sprint-state.sh: SIGINT mid-write cleans tmp (AC6)" {
  seed_story T1 backlog
  seed_yaml T1 backlog
  local marker="$TEST_TMP/awk-started"
  install_slow_mv_stub "$marker" "2"
  PATH="$TEST_TMP/stub-bin:$PATH" "$SCRIPT" transition --story T1 --to validating &
  local pid=$!
  local waited=0
  while [ ! -e "$marker" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$marker" ]
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  local orphans
  orphans=$(count_orphan_tmps)
  [ "$orphans" = "0" ]
}

# ---------- AC7: SIGTERM mid-write removes tmp ----------

@test "sprint-state.sh: SIGTERM mid-write cleans tmp (AC7)" {
  seed_story T2 backlog
  seed_yaml T2 backlog
  local marker="$TEST_TMP/awk-started"
  install_slow_mv_stub "$marker" "2"
  PATH="$TEST_TMP/stub-bin:$PATH" "$SCRIPT" transition --story T2 --to validating &
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

# ---------- AC8: error path triggers trap cleanup ----------

@test "sprint-state.sh: invalid transition error path leaves no orphan tmp (AC8)" {
  # Force an invalid transition so the script exits non-zero. With set -e and
  # the new script-level trap, any orphan tmp from a prior mktemp must be
  # cleaned up by _cleanup_tmps.
  seed_story T3 backlog
  seed_yaml T3 backlog
  run "$SCRIPT" transition --story T3 --to done
  [ "$status" -ne 0 ]
  local orphans
  orphans=$(count_orphan_tmps)
  [ "$orphans" = "0" ]
}
