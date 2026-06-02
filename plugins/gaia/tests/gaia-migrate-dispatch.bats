#!/usr/bin/env bats
# gaia-migrate-dispatch.bats — exit-code 11 dispatch from gaia-migrate.sh
# to gaia-reconcile-v2.sh (E85-S9).
#
# Story: E85-S9 — `gaia-migrate.sh` dispatch — exit-code 11 + `exec` to
#                  `gaia-reconcile-v2.sh`.
# ADRs: ADR-100 (return-code semantics extension), ADR-101 (v2-to-v2
#       reconciliation contract — exec dispatch).
#
# Strategy:
#   The `exec` in the dispatch block overwrites the parent shell. To make
#   this testable, every test stages a stub `gaia-reconcile-v2.sh` in a
#   per-test temp `scripts/` mirror and runs `gaia-migrate.sh` from that
#   staged location. The stub writes a marker file plus the captured env
#   vars to `$TEST_TMP/reconciler-called.txt` so the assertion can read it
#   back without competing with the exec'd process.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  STAGED_SCRIPTS="$TEST_TMP/scripts"
  mkdir -p "$STAGED_SCRIPTS"
  cp "$SCRIPTS_DIR/gaia-migrate.sh" "$STAGED_SCRIPTS/gaia-migrate.sh"
  cat > "$STAGED_SCRIPTS/gaia-reconcile-v2.sh" <<'STUB'
#!/usr/bin/env bash
{
  printf 'reconciler-stub-called\n'
  printf 'MODE=%s\n'         "${MODE:-<unset>}"
  printf 'PROJECT_ROOT=%s\n' "${PROJECT_ROOT:-<unset>}"
  printf 'DRY_RUN=%s\n'      "${DRY_RUN:-<unset>}"
  printf 'ASSUME_YES=%s\n'   "${ASSUME_YES:-<unset>}"
} > "${TEST_TMP}/reconciler-called.txt"
exit 0
STUB
  chmod +x "$STAGED_SCRIPTS/gaia-reconcile-v2.sh"
  MIGRATE="$STAGED_SCRIPTS/gaia-migrate.sh"
  FIXTURE_ROOT="$TEST_TMP/project"
  mkdir -p "$FIXTURE_ROOT"
  export TEST_TMP
}
teardown() { common_teardown; }

write_v2_config() {
  mkdir -p "$FIXTURE_ROOT/config"
  cat > "$FIXTURE_ROOT/config/project-config.yaml" <<YAML
schema_version: "2.0.0"
config_phase: full
project_name: test
project_root: $FIXTURE_ROOT
project_path: gaia-framework
memory_path: _memory
checkpoint_path: _memory/checkpoints
installed_path: ~/.claude/plugins/cache/gaia
framework_version: "1.148.0"
date: "2026-05-13"
YAML
}

make_v1_layout() {
  mkdir -p "$FIXTURE_ROOT/_gaia/_config" "$FIXTURE_ROOT/_memory" "$FIXTURE_ROOT/custom"
  printf 'project_root: %s\n' "$FIXTURE_ROOT" > "$FIXTURE_ROOT/_gaia/_config/global.yaml"
}

# Scenario 1 — exit-10 path (v2 schema only, no state dirs)
@test "exit-10: v2 schema only with no state dirs exits 0 with 'nothing to migrate' log" {
  write_v2_config
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]]
  [ ! -f "$TEST_TMP/reconciler-called.txt" ]
}

# Scenario 2 — exit-11 path (v2 schema + _memory/)
@test "exit-11: v2 schema + _memory/ triggers exec dispatch to reconciler" {
  write_v2_config
  mkdir -p "$FIXTURE_ROOT/_memory"
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"v2 install detected"* ]] || [[ "$output" == *"dispatching"* ]]
  [ -f "$TEST_TMP/reconciler-called.txt" ]
  grep -q "reconciler-stub-called" "$TEST_TMP/reconciler-called.txt"
}

# Scenario 3 — exit-11 path via docs/planning-artifacts/
@test "exit-11: v2 schema + docs/planning-artifacts/ triggers exec dispatch" {
  write_v2_config
  mkdir -p "$FIXTURE_ROOT/docs/planning-artifacts"
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/reconciler-called.txt" ]
}

# Scenario 4 — v1 markers present (no regression — no dispatch)
@test "v1-markers-present: _gaia/ exists -> existing migration path, no dispatch" {
  make_v1_layout
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ ! -f "$TEST_TMP/reconciler-called.txt" ]
}

# Scenario 5 — env-var forwarding
@test "env-var forwarding: MODE PROJECT_ROOT DRY_RUN ASSUME_YES reach reconciler" {
  write_v2_config
  mkdir -p "$FIXTURE_ROOT/_memory"
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/reconciler-called.txt" ]
  grep -q "^MODE=dry-run$"                "$TEST_TMP/reconciler-called.txt"
  grep -q "^PROJECT_ROOT=$FIXTURE_ROOT$"  "$TEST_TMP/reconciler-called.txt"
  grep -q "^DRY_RUN="                     "$TEST_TMP/reconciler-called.txt"
  grep -q "^ASSUME_YES="                  "$TEST_TMP/reconciler-called.txt"
}

# Scenario 6 — AC5 dispatch-table comment row
@test "AC5: header exit-code table documents exit code 11" {
  grep -E '^#[[:space:]]+11[[:space:]]*[—-]' "$SCRIPTS_DIR/gaia-migrate.sh"
}

# E85-S12 (AF-2026-05-13-3): `custom/` is a v2-era surface (FR-RSV2-10 +
# BOUNDARIES.md), not a v1 marker. The three gates below must no longer
# require `has_custom=0`.

# TC-RV2-53 — reconcile path (return 11) with custom/adapters/ + _memory/ + v2 config
@test "TC-RV2-53: v2 config + custom/adapters/ + _memory/ -> exit-11 dispatch" {
  write_v2_config
  mkdir -p "$FIXTURE_ROOT/_memory" "$FIXTURE_ROOT/custom/adapters/foo"
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/reconciler-called.txt" ]
  grep -q "reconciler-stub-called" "$TEST_TMP/reconciler-called.txt"
  [[ "$output" != *"Migration already complete"* ]]
}

# TC-RV2-54 — idempotent success (return 10) with custom/adapters/ + v2 config only
@test "TC-RV2-54: v2 config + custom/adapters/ only -> exit-10 idempotent success" {
  write_v2_config
  mkdir -p "$FIXTURE_ROOT/custom/adapters/foo"
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]] || [[ "$output" == *"already on v2"* ]]
  [ ! -f "$TEST_TMP/reconciler-called.txt" ]
  [[ "$output" != *"Migration already complete"* ]]
}

# TC-RV2-55 — partial-install HALT (return 1) with ONLY custom/ (Val F10 narrow-gate guard)
@test "TC-RV2-55: ONLY custom/adapters/ (no v1, no v2, no _memory) -> exit-1 partial-install HALT" {
  mkdir -p "$FIXTURE_ROOT/custom/adapters/foo"
  run --separate-stderr "$MIGRATE" dry-run --project-root "$FIXTURE_ROOT"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"partial"* ]] || [[ "$output" == *"partial"* ]] || [[ "$stderr" == *"No v1 installation"* ]] || [[ "$output" == *"No v1 installation"* ]]
  [ ! -f "$TEST_TMP/reconciler-called.txt" ]
}
