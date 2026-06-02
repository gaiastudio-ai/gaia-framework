#!/usr/bin/env bats
# migrate-config-split.bats — unit tests for plugins/gaia/scripts/migrate-config-split.sh
# (E28-S143 / Task 6)
#
# Covers 6 fixtures defined in the story's Task 6:
#   Fixture 1 — minimal mixed global.yaml
#   Fixture 2 — local-only global.yaml
#   Fixture 3 — shared-only global.yaml
#   Fixture 4 — pre-existing project-config.yaml (assert refusal + --force)
#   Fixture 5 — missing yq on PATH
#   Fixture 6 — round-trip equivalence via resolve-config.sh

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/migrate-config-split.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/migrate-config-split"
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml"
  # Stage per-test writable copies so the script can modify them without
  # touching the checked-in fixtures.
  WORK="$TEST_TMP/work"
  mkdir -p "$WORK/_gaia/_config" "$WORK/config"
  GLOBAL_PATH="$WORK/_gaia/_config/global.yaml"
  SHARED_PATH="$WORK/config/project-config.yaml"
}
teardown() { common_teardown; }

# Helper — detect whether yq is available; tests that mutate files need it.
_has_yq() { command -v yq >/dev/null 2>&1; }

@test "script: is executable and pins set -euo pipefail" {
  [ -x "$SCRIPT" ]
  run head -30 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"set -euo pipefail"* ]]
  [[ "$output" == *"#!/usr/bin/env bash"* ]]
}

@test "script: --help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--global-yaml"* ]]
  [[ "$output" == *"--out-shared"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

# ---------- Fixture 5 — missing yq on PATH ----------
# This test must run even when yq IS available in the outer env, so we
# scrub PATH to a minimum that lacks yq.

@test "Fixture 5: missing yq on PATH exits non-zero with clear error" {
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  # Build a stub PATH with bash available but NO yq. We copy bash into a
  # per-test sandbox and point PATH at it — yq discovery must fail.
  SANDBOX="$TEST_TMP/no-yq-bin"
  mkdir -p "$SANDBOX"
  ln -s "$(command -v bash)" "$SANDBOX/bash"
  ln -s "$(command -v env)" "$SANDBOX/env" 2>/dev/null || true
  ln -s "$(command -v sed)" "$SANDBOX/sed"
  ln -s "$(command -v date)" "$SANDBOX/date"
  ln -s "$(command -v cp)" "$SANDBOX/cp"
  ln -s "$(command -v mv)" "$SANDBOX/mv"
  ln -s "$(command -v mkdir)" "$SANDBOX/mkdir"
  ln -s "$(command -v dirname)" "$SANDBOX/dirname"
  ln -s "$(command -v basename)" "$SANDBOX/basename"
  run env -i HOME="$HOME" PATH="$SANDBOX" \
      "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -ne 0 ]
  # Error message should mention yq.
  [[ "$output" == *"yq"* || "$stderr" == *"yq"* ]] || {
    # bats run populates $output; stderr is merged in the default mode.
    [[ "$output" == *"yq"* ]]
  }
}

# ---------- Fixture 1 — mixed global.yaml, happy path ----------

@test "Fixture 1: mixed global.yaml splits cleanly (shared file contains shared keys)" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]
  [ -f "$SHARED_PATH" ]
  # Shared file must contain the team-shared keys…
  grep -qE "^project_path:" "$SHARED_PATH"
  grep -qE "^user_name:" "$SHARED_PATH"
  grep -qE "^communication_language:" "$SHARED_PATH"
  grep -qE "^framework_version:" "$SHARED_PATH"
  grep -qE "^date:" "$SHARED_PATH"
  # …and must NOT carry any machine-local keys.
  ! grep -qE "^installed_path:" "$SHARED_PATH"
  ! grep -qE "^memory_path:" "$SHARED_PATH"
  ! grep -qE "^checkpoint_path:" "$SHARED_PATH"
}

@test "Fixture 1: rewritten global.yaml retains machine-local keys only" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]
  # Rewritten global keeps the local keys…
  grep -qE "^installed_path:" "$GLOBAL_PATH"
  grep -qE "^memory_path:" "$GLOBAL_PATH"
  grep -qE "^checkpoint_path:" "$GLOBAL_PATH"
  # …and strips every team-shared key the schema classifies as moved.
  ! grep -qE "^project_path:" "$GLOBAL_PATH"
  ! grep -qE "^user_name:" "$GLOBAL_PATH"
  ! grep -qE "^communication_language:" "$GLOBAL_PATH"
  ! grep -qE "^framework_version:" "$GLOBAL_PATH"
  ! grep -qE "^date:" "$GLOBAL_PATH"
}

@test "Fixture 1: backup file is created with timestamp suffix" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]
  # Backup file must exist with .bak.{timestamp} suffix
  ls "$GLOBAL_PATH".bak.* >/dev/null 2>&1
  [ $? -eq 0 ]
  # Script should echo the backup path
  [[ "$output" == *".bak."* ]]
}

@test "Fixture 1: shared file includes generated header comment" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]
  head -3 "$SHARED_PATH" | grep -qE "migrate-config-split"
}

@test "Fixture 1: rewritten global.yaml includes machine-local header comment" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]
  head -3 "$GLOBAL_PATH" | grep -qiE "machine-local"
}

# ---------- Fixture 2 — local-only global.yaml ----------

@test "Fixture 2: local-only global.yaml produces minimal shared file" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/local-only-global.yaml" "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]
  [ -f "$SHARED_PATH" ]
  # No team-shared keys should appear in the shared file (all local).
  ! grep -qE "^project_path:" "$SHARED_PATH"
  ! grep -qE "^user_name:" "$SHARED_PATH"
  ! grep -qE "^framework_version:" "$SHARED_PATH"
}

# ---------- Fixture 3 — shared-only global.yaml ----------

@test "Fixture 3: shared-only global.yaml produces minimal rewritten global" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/shared-only-global.yaml" "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]
  # All keys moved to shared; rewritten global carries none of them.
  ! grep -qE "^project_path:" "$GLOBAL_PATH"
  ! grep -qE "^user_name:" "$GLOBAL_PATH"
  ! grep -qE "^framework_version:" "$GLOBAL_PATH"
  # Shared file should have the shared keys.
  grep -qE "^project_path:" "$SHARED_PATH"
}

# ---------- Fixture 4 — pre-existing shared file ----------

@test "Fixture 4: pre-existing project-config.yaml without --force refuses to overwrite" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  # Pre-create the shared target.
  printf '# pre-existing\nproject_path: keep-me\n' > "$SHARED_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--force"* ]]
  # Shared file must not be overwritten.
  grep -q "keep-me" "$SHARED_PATH"
}

@test "Fixture 4: pre-existing project-config.yaml with --force overwrites" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  printf '# pre-existing\nproject_path: keep-me\n' > "$SHARED_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH" --force
  [ "$status" -eq 0 ]
  # Shared file now reflects the migrated content, not the pre-existing sentinel.
  ! grep -q "keep-me" "$SHARED_PATH"
  grep -qE "^project_path:" "$SHARED_PATH"
}

# ---------- Fixture 6 — round-trip equivalence via resolve-config.sh ----------

@test "Fixture 6: round-trip equivalence — split + resolve-config.sh matches pre-split resolve" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"

  # Pre-split resolve — treat the original global.yaml as a single-file config.
  # For the pre-split baseline we need all required fields; copy the fixture to
  # a skill-dir shared location so resolve-config.sh treats it as the whole config.
  PRESPLIT_SKILL="$TEST_TMP/presplit_skill"
  mkdir -p "$PRESPLIT_SKILL/config"
  cp "$FIX/mixed-global.yaml" "$PRESPLIT_SKILL/config/project-config.yaml"
  # Add project_root (required field — fixture doesn't need to carry it by
  # default, this aligns resolve-config.sh required-field check).
  printf 'project_root: "/srv/ci/gaia-public"\n' >> "$PRESPLIT_SKILL/config/project-config.yaml"
  cp "$SCHEMA" "$PRESPLIT_SKILL/config/project-config.schema.yaml"
  run env CLAUDE_SKILL_DIR="$PRESPLIT_SKILL" "$SCRIPTS_DIR/resolve-config.sh"
  [ "$status" -eq 0 ]
  pre_output="$output"

  # Run the migration — need the same extra project_root in the input.
  printf 'project_root: "/srv/ci/gaia-public"\n' >> "$GLOBAL_PATH"
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH"
  [ "$status" -eq 0 ]

  # Post-split resolve — point resolve-config.sh at both files.
  # Copy the schema next to the shared file so schema enforcement applies.
  cp "$SCHEMA" "$(dirname "$SHARED_PATH")/project-config.schema.yaml"
  run "$SCRIPTS_DIR/resolve-config.sh" --shared "$SHARED_PATH" --local "$GLOBAL_PATH"
  [ "$status" -eq 0 ]
  post_output="$output"

  # Round-trip equivalence: both resolve to the same output.
  [ "$pre_output" = "$post_output" ]
}

# ---------- --dry-run mode ----------

@test "scenario 6 — --dry-run prints planned split without writing any files" {
  _has_yq || skip "yq not installed — cannot run migration"
  cp "$FIX/mixed-global.yaml" "$GLOBAL_PATH"
  # Capture content hash before so we are immune to filesystem mtime
  # resolution quirks (some CI runners only report seconds, and rapid
  # successive `cp` + script invocation can land in the same second).
  pre_sha=$(shasum -a 256 "$GLOBAL_PATH" | awk '{print $1}')
  run "$SCRIPT" --global-yaml "$GLOBAL_PATH" --out-shared "$SHARED_PATH" --dry-run
  [ "$status" -eq 0 ]
  # No shared file written.
  [ ! -f "$SHARED_PATH" ]
  # No backup written.
  ! ls "$GLOBAL_PATH".bak.* >/dev/null 2>&1
  # Global was not modified — content hash is the authoritative check.
  post_sha=$(shasum -a 256 "$GLOBAL_PATH" | awk '{print $1}')
  [ "$pre_sha" = "$post_sha" ]
  # Output describes the planned split.
  [[ "$output" == *"shared"* ]] || [[ "$output" == *"local"* ]]
}
