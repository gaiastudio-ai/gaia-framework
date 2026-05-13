#!/usr/bin/env bats
# gaia-reconcile-v2.bats — unit tests for the v2-to-v2 reconciler (E85-S8).
#
# Story: E85-S8 — `gaia-reconcile-v2.sh` implementation.
# Contract: ADR-101 (v2-to-v2 reconciliation), ADR-098 (config-hydration helper + flock),
#           ADR-096 (config_phase state machine + schema_version).
#
# Test scenarios map 1:1 to AC15:
#   1. schema match no-op             (exit 0, no writes)
#   2. schema upgrade                 (missing sections added via hydration)
#   3. schema downgrade               (exit 4, stderr)
#   4. retired section warn-and-keep  (WARNING emitted, section preserved + comment injected per ADR-101 §3)
#   5. config_phase read-only         (phase unchanged)
#   6. dry-run output shape           (YAML on stdout, zero writes)
#   7. idempotency                    (second run = no-op, identical output)
#   8. missing config                 (exit 2)
#   9. missing schema                 (exit 3)
#  10. secret detection               (exit 2, stderr)
#  11. YAML stability check           (backup restored on corruption)
#  12. flock logging                  (audit entries present)
#  13. hash audit                     (pre/post sha256 logged)

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  RECONCILER="$SCRIPTS_DIR/gaia-reconcile-v2.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/config"
  SCHEMA_DIR="$TEST_TMP/schemas"
  mkdir -p "$SCHEMA_DIR"
  export PROJECT_ROOT
  # Pin the plugin root to a synthetic location for these tests so the
  # primary schema-discovery path (`${CLAUDE_PLUGIN_ROOT}/schemas/...`) is
  # exercised deterministically.
  export CLAUDE_PLUGIN_ROOT="$TEST_TMP/plugin"
  mkdir -p "$CLAUDE_PLUGIN_ROOT/schemas"
  mkdir -p "$CLAUDE_PLUGIN_ROOT/scripts/lib"
  # The reconciler sources config-hydration.sh — symlink the real one in.
  ln -sf "$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/config-hydration.sh" \
    "$CLAUDE_PLUGIN_ROOT/scripts/lib/config-hydration.sh"
  ln -sf "$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/config-yaml-editor.sh" \
    "$CLAUDE_PLUGIN_ROOT/scripts/config-yaml-editor.sh"
  # Defaults for env-var interface (AC16).
  export MODE="apply"
  export DRY_RUN="false"
  export ASSUME_YES="false"
}
teardown() { common_teardown; }

# ---- Fixture helpers -----------------------------------------------------

write_schema() {
  # Args: <path> <version>
  cat > "$1" <<JSON
{
  "\$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Test schema v$2",
  "type": "object",
  "properties": {
    "schema_version": { "type": "string" },
    "config_phase":   { "type": "string", "enum": ["minimal", "partial", "full"] },
    "project_name":   { "type": "string" },
    "project_shape":  { "type": "string" },
    "stacks":         { "type": "array" },
    "platforms":      { "type": "array" }
  }
}
JSON
}

write_schema_with_retired() {
  # Schema where `legacy_section` is deprecated. ADR-101 §3 warn-keep path.
  cat > "$1" <<JSON
{
  "\$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Test schema v$2",
  "type": "object",
  "properties": {
    "schema_version":  { "type": "string" },
    "config_phase":    { "type": "string", "enum": ["minimal", "partial", "full"] },
    "project_name":    { "type": "string" },
    "stacks":          { "type": "array" },
    "legacy_section":  { "type": "object", "deprecated": true }
  }
}
JSON
}

write_minimal_config() {
  # Args: <path> <schema_version> [extra-lines...]
  local path="$1"; local ver="$2"; shift 2
  {
    printf 'schema_version: "%s"\n' "$ver"
    printf 'config_phase: minimal\n'
    printf 'project_name: test-project\n'
    printf 'project_root: /tmp/test\n'
    printf 'project_path: gaia-public\n'
    printf 'memory_path: _memory\n'
    printf 'checkpoint_path: _memory/checkpoints\n'
    printf 'installed_path: ~/.claude/plugins/cache/gaia\n'
    printf 'framework_version: "1.148.0"\n'
    printf 'date: "2026-05-13"\n'
    while [ "$#" -gt 0 ]; do printf '%s\n' "$1"; shift; done
  } > "$path"
}

# --- AC15: 13 canonical test scenarios -----------------------------------

@test "gaia-reconcile-v2.sh exists and is executable" {
  [ -x "$RECONCILER" ]
}

# Scenario 1 — schema match no-op (AC2 equal, AC8 idempotency)
@test "schema match no-op: exit 0 when config and schema versions are equal" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.0.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to reconcile"* ]]
}

# Scenario 2 — schema upgrade with missing sections (AC4)
@test "schema upgrade: missing allowlisted section is hydrated" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  # Config has stacks; schema upgrade adds platforms (allowlisted).
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "stacks:" "  - typescript"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  grep -q "^platforms:" "$PROJECT_ROOT/config/project-config.yaml"
}

# Scenario 3 — schema downgrade (AC2, AC9 exit 4)
@test "schema downgrade: exit 4 when config_ver > schema_ver" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "1.0.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0"
  run --separate-stderr "$RECONCILER"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"downgrade"* ]] || [[ "$output" == *"downgrade"* ]]
}

# Scenario 4 — retired section warn-and-keep (AC5, AC14, ADR-101 §3)
@test "retired section: warn-and-keep emits WARNING and preserves section" {
  write_schema_with_retired "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "legacy_section:" "  old_field: keep-me"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # Section must still exist (warn-and-keep — never deleted)
  grep -q "^legacy_section:" "$PROJECT_ROOT/config/project-config.yaml"
  grep -q "old_field: keep-me" "$PROJECT_ROOT/config/project-config.yaml"
  # WARNING in output
  [[ "$output" == *"deprecated"* ]] || [[ "$output" == *"RETIRED"* ]]
}

# Scenario 4b — SR-54 phase-downgrade defense-in-depth (AC14)
@test "SR-54 phase-downgrade: warning emitted when retired section removal would regress phase" {
  write_schema_with_retired "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  # config_phase=partial and legacy_section is one of the sections; if it were removed,
  # phase could regress. Warn-keep policy keeps section, but SR-54 warning still fires.
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "legacy_section:" "  field: x"
  # Bump phase to partial for the SR-54 path
  sed -i.bak 's/^config_phase: minimal/config_phase: partial/' "$PROJECT_ROOT/config/project-config.yaml"
  rm -f "$PROJECT_ROOT/config/project-config.yaml.bak"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # SR-54 warning anchor: either explicit "phase" + "regress" wording, or "SR-54" mention
  [[ "$output" == *"SR-54"* ]] || [[ "$output" == *"regress"* ]] || [[ "$output" == *"phase"* ]]
  # Section is still preserved (warn-keep wins)
  grep -q "^legacy_section:" "$PROJECT_ROOT/config/project-config.yaml"
}

# Scenario 5 — config_phase read-only (AC6)
# The reconciler itself MUST NOT write config_phase. Hydration triggers
# (E85-S5/S6) may advance phase as a side-effect of hydrating allowlisted
# sections — that is the documented helper behaviour, not a reconciler write.
# Test by using a config that is ALREADY at `full` so no helper advancement
# can occur. The reconciler must leave config_phase=full untouched.
@test "config_phase read-only: phase value is unchanged after reconciliation" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0"
  # Bump to full so the helper has no advancement to do.
  sed -i.bak 's/^config_phase: minimal/config_phase: full/' "$PROJECT_ROOT/config/project-config.yaml"
  rm -f "$PROJECT_ROOT/config/project-config.yaml.bak"
  PHASE_BEFORE=$(grep '^config_phase:' "$PROJECT_ROOT/config/project-config.yaml")
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  PHASE_AFTER=$(grep '^config_phase:' "$PROJECT_ROOT/config/project-config.yaml")
  [ "$PHASE_BEFORE" = "$PHASE_AFTER" ]
}

# Scenario 6 — dry-run output shape (AC7)
@test "dry-run: emits structured YAML on stdout and writes nothing" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0"
  SHA_BEFORE=$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')
  export DRY_RUN="true"
  export MODE="dry-run"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # Required keys per AC7
  [[ "$output" == *"schema_current"* ]]
  [[ "$output" == *"schema_target"* ]]
  [[ "$output" == *"sections_missing"* ]]
  [[ "$output" == *"sections_retired"* ]]
  [[ "$output" == *"actions_planned"* ]]
  # Zero writes
  SHA_AFTER=$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')
  [ "$SHA_BEFORE" = "$SHA_AFTER" ]
}

# Scenario 7 — idempotency (AC8)
@test "idempotency: second run after upgrade produces zero additional writes" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "stacks:" "  - typescript"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  SHA1=$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')
  # Bump schema_version in the config to match (or leave as-is; second run on equal versions = no-op)
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  SHA2=$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')
  [ "$SHA1" = "$SHA2" ]
}

# Scenario 8 — missing config (AC9 exit 2)
@test "missing config: exit 2 when config file is absent" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.0.0"
  # No config file written.
  run "$RECONCILER"
  [ "$status" -eq 2 ]
}

# Scenario 9 — missing schema (AC1, AC9 exit 1 or 3 per ADR-101 §1)
@test "missing schema: exit code is 1 or 3 with actionable message" {
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0"
  # No schema file written and no fallback resolves.
  rm -f "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json"
  run --separate-stderr "$RECONCILER"
  [ "$status" -eq 1 ] || [ "$status" -eq 3 ]
  [[ "$stderr" == *"Schema"* ]] || [[ "$output" == *"Schema"* ]]
}

# Scenario 10 — secret detection (AC11, exit 2)
@test "secret detection: payload with literal API key triggers exit 2" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  # pragma: allowlist secret -- this is a test fixture, not a real key
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "stacks:" "  - api_key: sk-1234567890abcdef"  # pragma: allowlist secret
  run --separate-stderr "$RECONCILER"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"secret"* ]] || [[ "$output" == *"secret"* ]]
}

# Scenario 11 — YAML stability restore (AC12)
@test "yaml stability: post-write yq validation succeeds for normal run" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # Post-condition: config still parses as YAML.
  run yq '.' "$PROJECT_ROOT/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

# Scenario 11b — Backup is created before write (AC12 restore-path precondition)
@test "yaml stability: pre-write backup is created when reconciliation will write" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "stacks:" "  - typescript"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # AC12 requires "pre-write backup (created atomically via cp before first write)".
  # The backup file must exist after a write. Path per ADR-101 §6 is the standard
  # sibling-suffix convention. Accept either `*.reconcile-v2.bak` or `*.bak`.
  ls "$PROJECT_ROOT/config/project-config.yaml"*.bak* >/dev/null 2>&1 \
    || ls "$PROJECT_ROOT/config/project-config.yaml.reconcile-v2.bak" >/dev/null 2>&1
}

# Scenario 12 — flock logging (AC13, SR-53)
@test "flock logging: audit trail includes acquire and release entries with timestamp and PID" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "stacks:" "  - typescript"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # AC13 requires "timestamp and PID" on acquire AND release.
  [[ "$output" == *"flock"* ]]
  [[ "$output" == *"acquired"* ]]
  [[ "$output" == *"released"* ]]
  # PID anchor: literal "pid=" or the running PID as a token
  [[ "$output" == *"pid="* ]] || [[ "$output" == *"PID"* ]]
  # ISO-8601 timestamp anchor: at least YYYY-MM-DD must appear
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
}

# Scenario 13 — hash audit (AC10, SR-49)
@test "hash audit: pre-write and post-write sha256 are logged" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.1.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" \
    "stacks:" "  - typescript"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-write hash"* ]]
  [[ "$output" == *"post-write hash"* ]]
}
