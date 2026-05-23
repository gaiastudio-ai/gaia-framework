#!/usr/bin/env bats
# backup-integrity.bats — E98-S6 (SR-84, ADR-114 §(g), FR-528, TC-ARM-6/7/8 + TC-MSN-4)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  VERIFY="$PLUGIN_DIR/scripts/verify-backup-integrity.sh"
  MIGRATE="$PLUGIN_DIR/scripts/lib/auto-rename-migration.sh"
  TUTORIAL="$PLUGIN_DIR/templates/tutorials/ci-migration-backup-retention.md"
  PROJECT_ROOT="$TEST_TMP/project"
  WORKDIR="$PROJECT_ROOT/.github/workflows"
  mkdir -p "$WORKDIR"
}

teardown() { common_teardown; }

# ---------- TC-ARM-6: tutorial contains '.gaia-backup/' literal ----------

@test "TC-ARM-6: tutorial contains the literal '.gaia-backup/' string" {
  [ -f "$TUTORIAL" ]
  grep -q '\.gaia-backup/' "$TUTORIAL"
}

# ---------- TC-MSN-4: tutorial contains '30 day' or '30-day' ----------

@test "TC-MSN-4: tutorial contains '30-day' or '30 day' retention reference" {
  [ -f "$TUTORIAL" ]
  grep -qE '30[ -]day' "$TUTORIAL"
}

# ---------- AC1/TC-ARM-7: .sha256-manifest written for every backed-up file ----------

@test "TC-ARM-7: backup directory contains .sha256-manifest with one line per backed-up file" {
  printf 'name: ci\n' > "$WORKDIR/ci.yml"
  printf 'name: deploy\n' > "$WORKDIR/deploy.yml"
  run env GAIA_MIGRATE_DECISION_ci_yml=y GAIA_MIGRATE_DECISION_deploy_yml=n \
    bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  [ "$status" -eq 0 ]
  backup_dir=$(find "$PROJECT_ROOT/.gaia-backup" -maxdepth 1 -type d -name 'ci-regen-*' | head -1)
  [ -n "$backup_dir" ]
  [ -f "$backup_dir/.sha256-manifest" ]
  # Manifest has 2 entries (one per backed-up file); each line is "<64hex>  <relpath>"
  line_count=$(grep -c '^' "$backup_dir/.sha256-manifest")
  [ "$line_count" = "2" ]
  while IFS= read -r line; do
    echo "$line" | grep -qE '^[a-f0-9]{64}  [^ ]+$'
  done < "$backup_dir/.sha256-manifest"
}

# ---------- AC2/AC3: verify-backup-integrity.sh helper ----------

@test "AC2: verify-backup-integrity.sh exits 0 on clean backup" {
  printf 'name: ci\n' > "$WORKDIR/ci.yml"
  env GAIA_MIGRATE_DECISION_ci_yml=y bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  backup_dir=$(find "$PROJECT_ROOT/.gaia-backup" -maxdepth 1 -type d -name 'ci-regen-*' | head -1)
  run bash "$VERIFY" "$backup_dir"
  [ "$status" -eq 0 ]
}

# ---------- TC-ARM-8: silent corruption detected ----------

@test "TC-ARM-8: verify-backup-integrity.sh detects byte-level corruption" {
  printf 'name: ci\non: [push]\n' > "$WORKDIR/ci.yml"
  env GAIA_MIGRATE_DECISION_ci_yml=y bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  backup_dir=$(find "$PROJECT_ROOT/.gaia-backup" -maxdepth 1 -type d -name 'ci-regen-*' | head -1)
  # Flip one byte in the backed-up file
  printf 'X' >> "$backup_dir/ci.yml"
  run bash "$VERIFY" "$backup_dir"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'tampered|mismatch|drift|integrity'
  echo "$output" | grep -q 'ci.yml'
}

@test "AC3: verify failure emits the canonical SR-84 HALT message" {
  printf 'name: ci\n' > "$WORKDIR/ci.yml"
  env GAIA_MIGRATE_DECISION_ci_yml=y bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  backup_dir=$(find "$PROJECT_ROOT/.gaia-backup" -maxdepth 1 -type d -name 'ci-regen-*' | head -1)
  printf 'X' >> "$backup_dir/ci.yml"
  run bash "$VERIFY" "$backup_dir"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'HALT: backup integrity check failed'
}

# ---------- Usage / edge cases ----------

@test "verify-backup-integrity.sh: usage on missing argument" {
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'usage'
}

@test "verify-backup-integrity.sh: missing manifest emits clear error" {
  mkdir -p "$TEST_TMP/no-manifest"
  printf 'data\n' > "$TEST_TMP/no-manifest/foo.yml"
  run bash "$VERIFY" "$TEST_TMP/no-manifest"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'manifest|not found'
}

@test "verify-backup-integrity.sh: detects file added since manifest (extra-file drift)" {
  printf 'name: ci\n' > "$WORKDIR/ci.yml"
  env GAIA_MIGRATE_DECISION_ci_yml=y bash -c "source '$MIGRATE' && PROJECT_ROOT='$PROJECT_ROOT' gaia_auto_rename_migration"
  backup_dir=$(find "$PROJECT_ROOT/.gaia-backup" -maxdepth 1 -type d -name 'ci-regen-*' | head -1)
  printf 'tampered-extra\n' > "$backup_dir/extra.yml"
  run bash "$VERIFY" "$backup_dir"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'extra|unexpected|drift|tampered'
}
