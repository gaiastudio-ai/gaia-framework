#!/usr/bin/env bats
# AF-2026-05-27 — Test04 Bundle D: noise & housekeeping (lows).
#
#   F-001: generate-config.sh emits a NOTICE when it seeds the default local env
#          on an operator who declared no environments (behavior kept).
#   F-004: orchestration-warning.sh copy reflects the session-id-dependent dedupe.
#   F-005: memory-loader.sh stays silent on greenfield (no legacy _memory/),
#          warns only on a genuine incomplete migration.
#   F-006: orchestration-warning.sh GCs stale sentinels (>1 day).
#   F-009: gaia-bridge-enable documents why scaffold-then-flip is two steps.
#   F-026: retro finalize.sh documents the mtime-sentinel fragility.
#   F-027: test-strategy finalize.sh emits a transparent mutation NOTICE + an
#          opt-out env var.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- F-001: default-env inject emits a NOTICE ---

@test "F-001: generate-config NOTICE fires when environments declared empty at full phase" {
  local out
  out="$(printf '%s' '{"project_shape":"single backend","stacks":[{"name":"api","language":"node","paths":["src"]}],"compliance":{"ui_present":true},"environments":[]}' \
    | bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path "$TEST_TMP" --name demo --phase full 2>&1 >/dev/null || true)"
  printf '%s\n' "$out" | grep -qF "NOTICE — no environments were declared"
}

@test "F-001: the default local env is still seeded (behavior preserved)" {
  printf '%s' '{"project_shape":"single backend","stacks":[{"name":"api","language":"node","paths":["src"]}],"compliance":{"ui_present":true},"environments":[]}' \
    | bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path "$TEST_TMP" --name demo --phase full >/dev/null 2>&1
  local cfg
  cfg="$(find "$TEST_TMP" -name project-config.yaml | head -1)"
  grep -qE '^[[:space:]]*url:[[:space:]]*"http://localhost"' "$cfg"
}

# --- F-004: copy reflects session-id-dependent dedupe ---

@test "F-004: orchestration-warning copy qualifies 'once per session' with session-id caveat" {
  grep -qF 'when a stable session id is available' "$PLUGIN_ROOT/scripts/orchestration-warning.sh"
}

# --- F-005: greenfield silent (the read-only-until-migration logic was removed
#     in AF-2026-05-27-3 with the legacy _memory/ consolidation migration; a
#     stray _memory/ now triggers the hygiene warning, NOT a read-only halt) ---

@test "F-005: memory-loader is silent on greenfield (.gaia/memory, no stray _memory)" {
  mkdir -p "$TEST_TMP/.gaia/memory"
  run env MEMORY_PATH="$TEST_TMP/.gaia/memory" bash -c '
    eval "$(awk "/^_gaia_stray_legacy_memory_warn\\(\\) \\{/,/^}/" "'"$PLUGIN_ROOT"'/scripts/memory-loader.sh")"
    _gaia_stray_legacy_memory_warn 2>&1'
  [ -z "$output" ]
}

@test "F-005: read-only-until-migration logic is gone (no _GAIA_SESSION_LOAD_READ_ONLY producer)" {
  # AF-2026-05-27-3: the .migration-manifest sentinel + the read-only producer
  # were removed with the Family A migration. The function must be gone, and the
  # read-only var must no longer be SET/exported (a documentary comment mention
  # is fine). Assert no executable producer remains.
  ! grep -qF '_gaia_session_load_sentinel_check' "$PLUGIN_ROOT/scripts/memory-loader.sh"
  ! grep -qE '(export|^[[:space:]]*)_GAIA_SESSION_LOAD_READ_ONLY=' "$PLUGIN_ROOT/scripts/memory-loader.sh"
  # No active .migration-manifest read (a comment reference is acceptable).
  ! grep -qE '(\[|-f|cat|read|awk).*\.migration-manifest' "$PLUGIN_ROOT/scripts/memory-loader.sh"
}

@test "F-005: stray _memory/ coexisting with .gaia/memory/ now triggers the hygiene warning" {
  mkdir -p "$TEST_TMP/.gaia/memory" "$TEST_TMP/_memory"
  run env MEMORY_PATH="$TEST_TMP/.gaia/memory" bash -c '
    eval "$(awk "/^_gaia_stray_legacy_memory_warn\\(\\) \\{/,/^}/" "'"$PLUGIN_ROOT"'/scripts/memory-loader.sh")"
    _gaia_stray_legacy_memory_warn 2>&1'
  printf '%s\n' "$output" | grep -qF 'coexists with the canonical .gaia/memory/'
}

# --- F-006: GC sweep present ---

@test "F-006: orchestration-warning GCs stale sentinels (find -mmin +1440 -delete)" {
  grep -qF "orchestration-warning-*' -mmin +1440 -delete" "$PLUGIN_ROOT/scripts/orchestration-warning.sh"
}

# --- F-009: two-step scaffold-then-flip documented ---

@test "F-009: bridge-enable documents why scaffold-then-flip is two steps" {
  grep -qF 'Why scaffold-then-flip is two steps (F-009' "$PLUGIN_ROOT/skills/gaia-bridge-enable/SKILL.md"
}

# --- F-026: mtime-sentinel fragility documented ---

@test "F-026: retro finalize documents the mtime-sentinel fragility + future ledger" {
  grep -qF 'KNOWN FRAGILITY of the mtime-based sentinel' "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
  grep -qF '(workflow, run_id) -> decision_id ledger' "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
}

# --- F-027: transparent mutation notice + opt-out ---

@test "F-027: test-strategy finalize names mutated sections + revert + opt-out" {
  grep -qF 'auto-stub-hydration MUTATED' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF 'GAIA_TEST_STRATEGY_NO_AUTOSTUB=1' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}

@test "F-027: GAIA_TEST_STRATEGY_NO_AUTOSTUB=1 short-circuits the hydration branch" {
  grep -qF 'GAIA_TEST_STRATEGY_NO_AUTOSTUB:-0}" = "1"' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}
