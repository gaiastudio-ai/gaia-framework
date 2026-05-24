#!/usr/bin/env bats
# migration-safety-net.bats — E99-S6 (FR-528, TC-MSN-1/2/3, TC-EKD-5)
#
# Validates the config-migration-status helper that drives:
#  - drift detector .config-stale marker on pre-migration configs (AC1)
#  - /gaia-config-validate WARNING text on pre-migration configs (AC2/AC4)
#  - clean migrated configs emit no warning (AC3)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  STATUS="$PLUGIN_DIR/scripts/lib/config-migration-status.sh"
  VALIDATE_SKILL="$PLUGIN_DIR/skills/gaia-config-validate/SKILL.md"
  CONFIG="$TEST_TMP/project-config.yaml"
  PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/_memory"
}

teardown() { common_teardown; }

# ---------- TC-MSN-1: clean migrated config emits no warning ----------

@test "TC-MSN-1: clean config with both kind: and distribution: emits no warning" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
  - id: marketplace
    kind: branch-only
distribution:
  channel: claude-marketplace
  registry: https://anthropic.com/marketplace
  manifest: plugin.json
  release_workflow: gaia-release.yml
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_status '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "TC-MSN-1 variant: all-deployable historical project (no distribution needed) emits no warning" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
  - id: production
    kind: deployable
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_status '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

# ---------- TC-MSN-2 / TC-EKD-5: pre-migration config (no kind, no distribution) emits warning ----------

@test "TC-MSN-2: pre-migration config (no kind, no distribution) emits warning" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
  - id: production
    branch: main
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_status '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "pre-migration" ]
}

@test "TC-EKD-5: pre-migration config produces actionable WARNING text" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_warning_text '$CONFIG'"
  [ "$status" -eq 0 ]
  # Warning MUST cite the migration command + the canonical FR / ADR refs
  echo "$output" | grep -qi 'warning'
  echo "$output" | grep -qE 'environments.*kind|distribution:'
  echo "$output" | grep -qE 'FR-528|E99|migration'
}

# ---------- TC-MSN-3: partial migration enumerates missing pieces ----------

@test "TC-MSN-3: partial migration (kind: present, distribution: absent) enumerates missing distribution:" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: marketplace
    kind: branch-only
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_status '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "partial-missing-distribution" ]
  run bash -c "source '$STATUS' && gaia_config_migration_warning_text '$CONFIG'"
  echo "$output" | grep -qi 'distribution'
  ! echo "$output" | grep -qE 'kind:.*missing'
}

@test "TC-MSN-3: partial migration (distribution: present, no kind:) enumerates missing kind:" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_status '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "partial-missing-kind" ]
  run bash -c "source '$STATUS' && gaia_config_migration_warning_text '$CONFIG'"
  echo "$output" | grep -qi 'kind'
}

# ---------- AC1: drift detector .config-stale marker writer ----------

@test "AC1: drift-marker write — pre-migration triggers stale-flag write" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_stale_flag_write '$CONFIG' '$PROJECT_ROOT/_memory'"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/_memory/.config-stale" ]
  grep -qE 'FR-528|E99|kind.*distribution' "$PROJECT_ROOT/_memory/.config-stale"
}

@test "AC1: clean config does NOT write a stale-flag" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
YAML
  rm -f "$PROJECT_ROOT/_memory/.config-stale"
  run bash -c "source '$STATUS' && gaia_config_migration_stale_flag_write '$CONFIG' '$PROJECT_ROOT/_memory'"
  [ "$status" -eq 0 ]
  [ ! -f "$PROJECT_ROOT/_memory/.config-stale" ]
}

# ---------- AC2: /gaia-config-validate SKILL.md cites the migration warning ----------

@test "AC2: /gaia-config-validate SKILL.md cites the E99 migration warning path" {
  grep -qE 'E99-S6|config-migration-status|FR-528' "$VALIDATE_SKILL"
}

# ---------- Edge cases ----------

@test "edge: no environments[] at all → unknown (caller falls back)" {
  cat > "$CONFIG" <<'YAML'
project_name: example
YAML
  run bash -c "source '$STATUS' && gaia_config_migration_status '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ---------- Source-guard ----------

@test "source-guard: double-source is idempotent" {
  run bash -c "source '$STATUS' && source '$STATUS' && declare -F gaia_config_migration_status >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- Usage ----------

@test "usage: missing config arg fails" {
  run bash -c "source '$STATUS' && gaia_config_migration_status"
  [ "$status" -ne 0 ]
}
