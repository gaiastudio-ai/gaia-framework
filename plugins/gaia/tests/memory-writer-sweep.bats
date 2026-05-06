#!/usr/bin/env bats
# memory-writer-sweep.bats — E64-S6 startup orphan-tmp sweep for memory-writer.sh.
#
# Verifies AC3, AC4, AC5, AC6, AC7, AC8 of E64-S6 against memory-writer.sh:
#   AC3 — sweep at startup, scoped to ${MEMORY_PATH} only
#         (-maxdepth 2, -name '*.tmp.??????', -mmin +60, -delete).
#   AC4 — sweep paths bounded to allowlist (no /tmp, no $HOME, no PROJECT_PATH root).
#   AC5 — sweep uses `-mmin +60`.
#   AC6 — orphan older than 60 min deleted; younger preserved.
#   AC7 — silent stdout.
#   AC8 — GAIA_SKIP_ORPHAN_SWEEP=1 skips the sweep.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/memory-writer.sh"

  MEMORY="$TEST_TMP/_memory"
  mkdir -p "$MEMORY/sm-sidecar"

  # Minimal config.yaml so resolve_sidecar_rel finds the agent.
  cat >"$MEMORY/config.yaml" <<'EOF'
agents:
  sm:
    sidecar: sm-sidecar
EOF

  export MEMORY_PATH="$MEMORY"
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

# ---------- AC3, AC6: orphan older than 60 min in MEMORY_PATH is deleted ----------

@test "memory-writer.sh: orphan tmp older than 60 min in MEMORY_PATH is deleted (AC3/AC6)" {
  local orphan
  orphan=$(seed_orphan_tmp "$MEMORY/sm-sidecar" 90)
  [ -e "$orphan" ]
  run "$SCRIPT" --agent sm --type decision \
                --content "test" --source "test-suite"
  [ ! -e "$orphan" ]
}

# ---------- AC5, AC6: orphan younger than 60 min is preserved ----------

@test "memory-writer.sh: orphan tmp younger than 60 min is preserved (AC5/AC6)" {
  local orphan
  orphan=$(seed_orphan_tmp "$MEMORY/sm-sidecar" 10)
  [ -e "$orphan" ]
  run "$SCRIPT" --agent sm --type decision \
                --content "test" --source "test-suite"
  [ -e "$orphan" ]
}

# ---------- AC8: GAIA_SKIP_ORPHAN_SWEEP=1 skips the sweep ----------

@test "memory-writer.sh: GAIA_SKIP_ORPHAN_SWEEP=1 preserves old orphan (AC8)" {
  local orphan
  orphan=$(seed_orphan_tmp "$MEMORY/sm-sidecar" 90)
  [ -e "$orphan" ]
  GAIA_SKIP_ORPHAN_SWEEP=1 run "$SCRIPT" --agent sm --type decision \
                --content "test" --source "test-suite"
  [ -e "$orphan" ]
}

# ---------- AC4: allowlist boundedness — sweep ignores PROJECT_PATH root ----------

@test "memory-writer.sh: sweep does not delete tmps outside allowlist (AC4)" {
  local outside
  outside=$(seed_orphan_tmp "$TEST_TMP" 90)
  [ -e "$outside" ]
  run "$SCRIPT" --agent sm --type decision \
                --content "test" --source "test-suite"
  [ -e "$outside" ]
}

# ---------- AC7: silent stdout from sweep ----------

@test "memory-writer.sh: sweep emits no chatter on stdout (AC7)" {
  seed_orphan_tmp "$MEMORY/sm-sidecar" 90 >/dev/null
  run "$SCRIPT" --help
  [[ "$output" != *sweep* ]]
  [[ "$output" != *deleted* ]]
}
