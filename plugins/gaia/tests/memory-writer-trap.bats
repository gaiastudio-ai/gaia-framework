#!/usr/bin/env bats
# memory-writer-trap.bats — E64-S5 script-level EXIT/INT/TERM trap for
#                           atomic-write tmp cleanup in memory-writer.sh.
#
# Verifies AC1, AC2, AC5, AC6, AC7, AC8 of E64-S5 against memory-writer.sh:
#   AC1 / AC2 — _GAIA_TMP_PATHS array + _cleanup_tmps function +
#               trap '_cleanup_tmps' EXIT INT TERM exists at script-level
#               BEFORE the first mktemp.
#   AC5      — both atomic-write mktemp call sites (line 294 .tmp.XXXXXX and
#              line 336 .newsec.XXXXXX) register in _GAIA_TMP_PATHS and clear
#              their slot after successful mv.
#   AC6 / AC7 — SIGINT / SIGTERM mid-write removes tmp.
#   AC8      — error-path: trap fires on script exit, tmp is removed.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/memory-writer.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  mkdir -p "$MEMORY_PATH" "$TEST_TMP/stub-bin"
}
teardown() { common_teardown; }

count_orphan_tmps() {
  find "$MEMORY_PATH" -type f \( -name '*.tmp.??????' -o -name '*.newsec.??????' \) 2>/dev/null | wc -l | tr -d ' '
}

# Stub `mv` so that when memory-writer reaches the rename step, the rename
# pauses long enough for us to send a signal mid-write. The stub touches a
# marker, sleeps, then delegates to /bin/mv.
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

@test "memory-writer.sh: declares _GAIA_TMP_PATHS array at top-level scope" {
  grep -E '^_GAIA_TMP_PATHS=\(\)' "$SCRIPT"
}

@test "memory-writer.sh: defines _cleanup_tmps function" {
  grep -E '^_cleanup_tmps\s*\(\)|^_cleanup_tmps\(\)' "$SCRIPT"
}

@test "memory-writer.sh: sets trap _cleanup_tmps EXIT INT TERM" {
  grep -E "trap[[:space:]]+['\"]_cleanup_tmps['\"][[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM" "$SCRIPT"
}

@test "memory-writer.sh: trap is set BEFORE first atomic-write mktemp call" {
  local trap_line first_mktemp_line
  trap_line=$(grep -nE "trap[[:space:]]+['\"]_cleanup_tmps['\"][[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM" "$SCRIPT" | head -1 | cut -d: -f1)
  first_mktemp_line=$(grep -nE 'mktemp[[:space:]]+"\$\{?(dest|target_file)' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$trap_line" ]
  [ -n "$first_mktemp_line" ]
  [ "$trap_line" -lt "$first_mktemp_line" ]
}

# ---------- AC5: both atomic-write mktemp sites are wired ----------

@test "memory-writer.sh: both atomic-write mktemp sites register in _GAIA_TMP_PATHS" {
  # 2 sites: ${dest}.tmp.XXXXXX and ${target_file}.newsec.XXXXXX
  local register_count
  register_count=$(grep -cE '_GAIA_TMP_PATHS\+=\(' "$SCRIPT" || true)
  [ "$register_count" -ge 2 ]
}

@test "memory-writer.sh: every atomic-write mv/rm clears its array slot" {
  # atomic_replace clears via _tmp_idx; write_ground_truth clears the
  # newsec entry via _newsec_idx after rm -f. Both patterns are accepted.
  local clear_count
  clear_count=$(grep -cE '_GAIA_TMP_PATHS\[\$_(tmp|newsec)_idx\]=""' "$SCRIPT" || true)
  [ "$clear_count" -ge 2 ]
}

# ---------- AC6: SIGINT mid-write removes tmp ----------

@test "memory-writer.sh: SIGINT mid-write cleans tmp (AC6)" {
  local marker="$TEST_TMP/mv-started"
  install_slow_mv_stub "$marker" "2"
  PATH="$TEST_TMP/stub-bin:$PATH" "$SCRIPT" --agent sm --type decision \
    --content "trap-test" --source dev-story &
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

@test "memory-writer.sh: SIGTERM mid-write cleans tmp (AC7)" {
  local marker="$TEST_TMP/mv-started"
  install_slow_mv_stub "$marker" "2"
  PATH="$TEST_TMP/stub-bin:$PATH" "$SCRIPT" --agent sm --type decision \
    --content "trap-test" --source dev-story &
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

# ---------- AC8: error-path triggers trap cleanup ----------

@test "memory-writer.sh: release_lock EXIT trap chains _cleanup_tmps (regression)" {
  # The lock-acquire EXIT trap MUST chain through _cleanup_tmps so that on a
  # clean EXIT, atomic-write tmps are still cleaned. A bare `trap release_lock
  # EXIT` would override the script-level `trap _cleanup_tmps EXIT INT TERM`
  # and silently leak tmps under set -e or signal-during-printf paths.
  grep -E "trap[[:space:]]+'release_lock;[[:space:]]*_cleanup_tmps'[[:space:]]+EXIT" "$SCRIPT"
}

@test "memory-writer.sh: write-failure error path cleans tmp via trap (AC8)" {
  # Make the sidecar directory read-only so the mv into the dest fails.
  # On macOS this requires the parent dir read-only AND the file path to not
  # exist yet. We simulate by pointing MEMORY_PATH at a path whose parent we
  # can chmod 0500. The mktemp succeeds (mktemp creates in the parent dir of
  # the dest file), but the final mv fails — leaving an orphan unless the
  # trap fires.
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  chmod 0500 "$MEMORY_PATH/sm-sidecar"
  run "$SCRIPT" --agent sm --type decision --content "x" --source dev-story
  chmod 0700 "$MEMORY_PATH/sm-sidecar"
  [ "$status" -ne 0 ]
  local orphans
  orphans=$(count_orphan_tmps)
  [ "$orphans" = "0" ]
}
