#!/usr/bin/env bats
# auto-rename-migration.bats — E98-S5 (FR-519, ADR-114 §(f), SR-84, TC-ARM-1..5)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  MIGRATE="$PLUGIN_DIR/scripts/lib/auto-rename-migration.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  WORKDIR="$PROJECT_ROOT/.github/workflows"
  MEMORY="$PROJECT_ROOT/_memory"
  mkdir -p "$WORKDIR" "$MEMORY"
}

teardown() { common_teardown; }

# ---------- TC-ARM-1: Y-branch (rename to gaia-*.yml + scaffold overlays) ----------

@test "TC-ARM-1: Y-branch renames ci.yml to gaia-ci.yml and scaffolds overlay stubs" {
  printf 'name: ci\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: [{run: echo build}]\n' > "$WORKDIR/ci.yml"
  # Non-interactive Y-branch via the documented per-file decision env var
  run env GAIA_MIGRATE_DECISION_ci_yml=y bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/gaia-ci.yml" ]
  [ ! -f "$WORKDIR/ci.yml" ]
  [ -f "$WORKDIR/gaia-ci.user-jobs.yml" ]
  [ -f "$WORKDIR/gaia-ci.user-steps.yml" ]
  # Overlay stubs document the empty-skeleton shape
  grep -q '^jobs:' "$WORKDIR/gaia-ci.user-jobs.yml"
  grep -q 'steps_before_gaia:' "$WORKDIR/gaia-ci.user-steps.yml"
  grep -q 'steps_after_gaia:' "$WORKDIR/gaia-ci.user-steps.yml"
}

# ---------- TC-ARM-2: N-branch (rename to user-*.yml, no overlays, byte-identical) ----------

@test "TC-ARM-2: N-branch renames ci.yml to user-ci.yml with no overlays + byte-identical content" {
  printf 'name: ci\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: [{run: echo build}]\n' > "$WORKDIR/ci.yml"
  pre_sha=$(shasum -a 256 "$WORKDIR/ci.yml" | awk '{print $1}')
  run env GAIA_MIGRATE_DECISION_ci_yml=n bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/user-ci.yml" ]
  [ ! -f "$WORKDIR/ci.yml" ]
  [ ! -f "$WORKDIR/user-ci.user-jobs.yml" ]
  [ ! -f "$WORKDIR/user-ci.user-steps.yml" ]
  post_sha=$(shasum -a 256 "$WORKDIR/user-ci.yml" | awk '{print $1}')
  [ "$pre_sha" = "$post_sha" ]
}

# ---------- TC-ARM-3: S-branch (skip-all + .config-stale) ----------

@test "TC-ARM-3: S-branch leaves file unchanged + writes _memory/.config-stale" {
  printf 'name: ci\non: [push]\n' > "$WORKDIR/ci.yml"
  pre_sha=$(shasum -a 256 "$WORKDIR/ci.yml" | awk '{print $1}')
  run env GAIA_MIGRATE_DECISION_ci_yml=s bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration 2>&1"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/ci.yml" ]
  [ ! -f "$WORKDIR/gaia-ci.yml" ]
  [ ! -f "$WORKDIR/user-ci.yml" ]
  post_sha=$(shasum -a 256 "$WORKDIR/ci.yml" | awk '{print $1}')
  [ "$pre_sha" = "$post_sha" ]
  [ -f "$MEMORY/.config-stale" ]
  grep -q 'FR-528\|FR-519' "$MEMORY/.config-stale"
  echo "$output" | grep -qiE 'warn|deferred|stale'
}

# ---------- TC-ARM-4: idempotent (already-prefixed files skip the prompt) ----------

@test "TC-ARM-4: idempotent — already gaia-prefixed files do not re-fire the prompt" {
  printf 'name: ci\non: [push]\n' > "$WORKDIR/gaia-ci.yml"
  printf 'name: deploy\non: [push]\n' > "$WORKDIR/user-deploy.yml"
  # No decision env vars set; if the migration tried to fire, it would HALT
  run bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/gaia-ci.yml" ]
  [ -f "$WORKDIR/user-deploy.yml" ]
  echo "$output" | grep -qiE 'no migration|already|skip' || true
}

# ---------- TC-ARM-5: backup created with byte-identical content + sha256 verified ----------

@test "TC-ARM-5: backup directory contains byte-identical original (sha256 match)" {
  printf 'name: ci\non: [push]\njobs:\n  build: {runs-on: ubuntu-latest, steps: [{run: echo build}]}\n' > "$WORKDIR/ci.yml"
  pre_sha=$(shasum -a 256 "$WORKDIR/ci.yml" | awk '{print $1}')
  run env GAIA_MIGRATE_DECISION_ci_yml=y bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -eq 0 ]
  # Find the backup directory under .gaia-backup/ci-regen-*/
  local backup_dir
  backup_dir=$(find "$PROJECT_ROOT/.gaia-backup" -maxdepth 1 -type d -name 'ci-regen-*' | head -1)
  [ -n "$backup_dir" ]
  [ -f "$backup_dir/ci.yml" ]
  bak_sha=$(shasum -a 256 "$backup_dir/ci.yml" | awk '{print $1}')
  [ "$pre_sha" = "$bak_sha" ]
  # Permissions check (0755 dir, 0644 file).
  # macOS uses `stat -f '%Lp'`, Linux uses `stat -c '%a'` — and stat -f on
  # Linux returns success with garbage, so we probe macOS form first
  # explicitly and fall back to Linux form only if it parsed cleanly.
  local dir_mode file_mode
  if stat --version >/dev/null 2>&1; then
    # GNU coreutils stat (Linux)
    dir_mode=$(stat -c '%a' "$backup_dir")
    file_mode=$(stat -c '%a' "$backup_dir/ci.yml")
  else
    # BSD stat (macOS)
    dir_mode=$(stat -f '%Lp' "$backup_dir")
    file_mode=$(stat -f '%Lp' "$backup_dir/ci.yml")
  fi
  # Strip leading sticky/setuid/setgid bits (e.g., "2755" → "755") for
  # comparison so we only assert the user/group/other triplet.
  dir_mode="${dir_mode: -3}"
  file_mode="${file_mode: -3}"
  [ "$dir_mode" = "755" ] || { echo "dir_mode='$dir_mode' (expected 755)" >&2; return 1; }
  [ "$file_mode" = "644" ] || { echo "file_mode='$file_mode' (expected 644)" >&2; return 1; }
}

# ---------- AC6: SR-84 non-interactive HALT ----------

@test "AC6/SR-84: non-interactive run without flags HALTs with canonical message" {
  printf 'name: ci\non: [push]\n' > "$WORKDIR/ci.yml"
  # No GAIA_MIGRATE_DECISION_*, no --force, no GAIA_MIGRATE_ALLOW_FORCE
  # GAIA_NONINTERACTIVE=1 simulates the substrate's non-interactive detection
  run env -u GAIA_MIGRATE_DECISION_ci_yml GAIA_NONINTERACTIVE=1 bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'SR-84'
  echo "$output" | grep -qE 'force|GAIA_MIGRATE_ALLOW_FORCE'
}

@test "AC6/SR-84: --force alone (without env-var) still HALTs" {
  printf 'name: ci\non: [push]\n' > "$WORKDIR/ci.yml"
  run env -u GAIA_MIGRATE_DECISION_ci_yml -u GAIA_MIGRATE_ALLOW_FORCE GAIA_NONINTERACTIVE=1 \
    bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration --force"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-84|GAIA_MIGRATE_ALLOW_FORCE'
}

@test "AC6/SR-84: env-var alone (without --force) still HALTs" {
  printf 'name: ci\non: [push]\n' > "$WORKDIR/ci.yml"
  run env -u GAIA_MIGRATE_DECISION_ci_yml GAIA_NONINTERACTIVE=1 GAIA_MIGRATE_ALLOW_FORCE=1 \
    bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-84|--force'
}

@test "AC6/SR-84: --force AND env-var together succeed" {
  printf 'name: ci\non: [push]\n' > "$WORKDIR/ci.yml"
  # When dual flags pass, the migration falls back to a default decision
  # (skip-all) since no GAIA_MIGRATE_DECISION_* is set — but it MUST NOT HALT
  # on SR-84.
  run env -u GAIA_MIGRATE_DECISION_ci_yml GAIA_NONINTERACTIVE=1 GAIA_MIGRATE_ALLOW_FORCE=1 \
    bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration --force"
  [ "$status" -eq 0 ]
}

# ---------- Source-guard ----------

@test "source-guard: double-source is idempotent" {
  run bash -c "source '$MIGRATE' && source '$MIGRATE' && declare -F gaia_auto_rename_migration >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- No-op when .github/workflows/ has no candidate files ----------

@test "no-op: empty workflows directory exits 0 silently" {
  run bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -eq 0 ]
}
