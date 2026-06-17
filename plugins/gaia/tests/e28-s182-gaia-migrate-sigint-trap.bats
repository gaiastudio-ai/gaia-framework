#!/usr/bin/env bats
# e28-s182-gaia-migrate-sigint-trap.bats — regression tests for the SIGINT/
# SIGTERM trap handler in gaia-migrate.sh (E28-S182).
#
# Covers ACs:
#   AC1 — gaia-migrate.sh registers a trap handler for SIGINT and SIGTERM.
#   AC2 — On interrupt, the handler prints (a) the backup path, (b) the exact
#         `cp -a` command to restore from it, and (c) a "partial migration"
#         banner.
#   AC3 — The script exits non-zero on interrupt (130 for SIGINT, 143 for
#         SIGTERM under bash).
#   AC4 — AC-EC7 from E28-S170 manual test plan now passes automatically.
#   AC5 — Happy-path migration (no interrupt) remains unaffected.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/gaia-migrate.sh"
  PROJECT="$TEST_TMP/project"
  mkdir -p "$PROJECT/_gaia/_config" \
           "$PROJECT/_memory" \
           "$PROJECT/custom" \
           "$PROJECT/.claude/commands"

  cat > "$PROJECT/_gaia/_config/global.yaml" <<'EOF'
framework_name: "GAIA"
framework_version: "1.127.2-rc.1"
user_name: "tester"
communication_language: "English"
document_output_language: "English"
user_skill_level: "intermediate"
project_name: "test-project"
project_root: "."
project_path: "."
output_folder: "./docs"
planning_artifacts: "./docs/planning-artifacts"
implementation_artifacts: "./docs/implementation-artifacts"
test_artifacts: "./docs/test-artifacts"
creative_artifacts: "./docs/creative-artifacts"
memory_path: "./_memory"
checkpoint_path: "./_memory/checkpoints"
installed_path: "./_gaia"
config_path: "./_gaia/_config"
date: "2026-04-25"
val_integration:
  template_output_review: true
EOF
}

teardown() { common_teardown; }

# When bash starts a child via `&`, POSIX requires the child to have SIGINT
# (and SIGQUIT) set to SIG_IGN — and any in-script `trap` cannot override
# a signal that was already SIG_IGN at shell startup. To exercise the
# script's INT trap we re-establish default SIGINT/SIGTERM dispositions
# via a tiny inline python `os.execvp` wrapper before exec'ing into the
# script. Python 3 ships with macOS (≥10.15) and every modern Linux distro
# so no extra install is needed.
#
# IMPORTANT: the wrapper MUST be inlined at every spawn site rather than
# going through a shell helper function — wrapping it in a function adds
# an extra shell layer between the `&` fork and python's exec, and that
# extra layer can keep SIGINT in the SIG_IGN state inherited from bats.

# _spawn_and_signal SIGNAL OUT_FILE
# Spawns gaia-migrate.sh apply --yes in the background, waits for the backup
# directory to appear (deterministic sync point), then sends the requested
# signal. Returns (via $rc set in caller frame) the script's exit code so
# tests can assert against it without losing the value to bats' set -e.
_spawn_and_signal() {
  local signal="$1" out_file="$2"
  : > "$out_file"
  # Inline the python wrapper at the spawn site (instead of going through a
  # shell function) — calling a function before `&` introduces an extra
  # subshell layer that can keep SIGINT in the SIG_IGN state inherited from
  # bats. The inline form makes python's exec(2) the direct child of the
  # async fork, so the SIG_DFL disposition that python sets right before
  # exec is the disposition bash sees on entry.
  python3 -c "import signal,sys,os; signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGTERM, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])" \
    "$SCRIPT" apply --project-root "$PROJECT" --yes > "$out_file" 2>&1 &
  local pid=$!
  # Poll for backup phase to begin — .gaia-migrate-backup/ is created by
  # _run_backup before the heavy cp -a work. 10s ceiling keeps the test
  # bounded on slow CI runners; the typical wait is <200ms locally.
  local waited=0
  while [[ ! -d "$PROJECT/.gaia-migrate-backup" && $waited -lt 100 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  # Small additional delay so cp -a is mid-flight when the signal lands.
  sleep 0.05
  kill "-$signal" "$pid" 2>/dev/null || true
  # `wait $pid` returns the child's exit status. Under bats' set -e, a
  # non-zero return aborts the test before we can read $? — so capture it
  # via the `|| rc=$?` idiom which both inhibits set -e and preserves the
  # signaled exit code (130/143).
  rc=0
  wait "$pid" || rc=$?
}

# ---------- AC1 — trap registration ----------

@test "gaia-migrate.sh source registers traps for INT and TERM" {
  # Static check: the script MUST install a trap covering BOTH SIGINT and
  # SIGTERM. Allow either form: a single-line `trap '...' INT TERM` or two
  # separate `trap '... INT' INT` and `trap '... TERM' TERM` lines.
  run grep -cE "^trap[[:space:]]+" "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c "grep -E '^trap[[:space:]]+' \"$SCRIPT\" | grep -q 'INT'"
  [ "$status" -eq 0 ]
  run bash -c "grep -E '^trap[[:space:]]+' \"$SCRIPT\" | grep -q 'TERM'"
  [ "$status" -eq 0 ]
}

@test "gaia-migrate.sh defines the _on_interrupt handler function" {
  run grep -E "^_on_interrupt[[:space:]]*\(\)" "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------- AC2/AC3 — SIGINT mid-run prints banner + backup path + restore command, non-zero exit ----------

@test "SIGINT mid-apply prints banner, backup path, restore command, exits non-zero" {
  dd if=/dev/zero of="$PROJECT/_memory/filler.bin" bs=1M count=120 status=none 2>/dev/null

  local rc
  _spawn_and_signal INT "$TEST_TMP/script.out"

  # AC3 — non-zero exit (130 = 128 + SIGINT).
  [ "$rc" -ne 0 ]

  # AC2 — banner + backup path + restore cp -a command must all appear in output.
  grep -q "partial migration" "$TEST_TMP/script.out"
  grep -q "Backup:" "$TEST_TMP/script.out"
  grep -qE "Restore: cp -a" "$TEST_TMP/script.out"
}

@test "SIGINT exit code is exactly 130 (128 + SIGINT)" {
  dd if=/dev/zero of="$PROJECT/_memory/filler.bin" bs=1M count=120 status=none 2>/dev/null

  local rc
  _spawn_and_signal INT "$TEST_TMP/script.out"

  [ "$rc" -eq 130 ]
}

@test "SIGTERM mid-apply prints banner, backup path, restore command, exits non-zero" {
  dd if=/dev/zero of="$PROJECT/_memory/filler.bin" bs=1M count=120 status=none 2>/dev/null

  local rc
  _spawn_and_signal TERM "$TEST_TMP/script.out"

  [ "$rc" -ne 0 ]

  grep -q "partial migration" "$TEST_TMP/script.out"
  grep -q "Backup:" "$TEST_TMP/script.out"
  grep -qE "Restore: cp -a" "$TEST_TMP/script.out"
}

# ---------- AC2 — printed backup path is real and absolute ----------

@test "trap-printed backup path is an absolute path under the project's .gaia-migrate-backup/" {
  dd if=/dev/zero of="$PROJECT/_memory/filler.bin" bs=1M count=120 status=none 2>/dev/null

  local rc
  _spawn_and_signal INT "$TEST_TMP/script.out"

  # Extract the LAST printed Backup: line — the trap handler prints one
  # under the "partial migration" banner. The path must be absolute and
  # rooted at the project's backup dir.
  local backup_line
  backup_line=$(grep '^Backup:' "$TEST_TMP/script.out" | tail -1)
  [ -n "$backup_line" ]
  local backup_path="${backup_line#Backup: }"
  [[ "$backup_path" == /* ]]
  [[ "$backup_path" == "$PROJECT/.gaia-migrate-backup/"* ]]
}

# ---------- AC5 — happy path unaffected ----------

@test "happy-path apply (no interrupt) completes normally and prints no interrupt banner" {
  run "$SCRIPT" apply --project-root "$PROJECT" --yes
  [ "$status" -eq 0 ]
  # Negative assertions — the interrupt banner must NOT appear on the happy path.
  ! grep -q "partial migration" <<< "$output"
  # Success summary still appears.
  [[ "$output" == *"SUCCESS"* ]]
}

@test "happy-path dry-run completes normally and prints no interrupt banner" {
  run "$SCRIPT" dry-run --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  ! grep -q "partial migration" <<< "$output"
}
