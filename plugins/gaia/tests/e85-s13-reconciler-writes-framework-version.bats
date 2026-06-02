#!/usr/bin/env bats
# e85-s13-reconciler-writes-framework-version.bats — E85-S13
#
# AC1 — gaia-reconcile-v2.sh apply writes framework_version at end of run
# AC2 — uses config-yaml-editor.sh replace (no inline yq -i)
# AC3 — config-hydration.sh:96 comment no longer claims resolve-config.sh writes framework_version
# AC4 — TC-RV2-56 bats coverage (this file)
# AC5 — second-run idempotency (byte-identical config)

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  RECONCILER="$SCRIPTS_DIR/gaia-reconcile-v2.sh"
  HYDRATION_LIB="$SCRIPTS_DIR/lib/config-hydration.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/config"
  export PROJECT_ROOT
  # Pin plugin root to a synthetic location.
  export CLAUDE_PLUGIN_ROOT="$TEST_TMP/plugin"
  mkdir -p "$CLAUDE_PLUGIN_ROOT/schemas"
  mkdir -p "$CLAUDE_PLUGIN_ROOT/scripts/lib"
  mkdir -p "$CLAUDE_PLUGIN_ROOT/.claude-plugin"
  # Symlink the real hydration helper + yaml editor in.
  ln -sf "$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/config-hydration.sh" \
    "$CLAUDE_PLUGIN_ROOT/scripts/lib/config-hydration.sh"
  ln -sf "$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/config-yaml-editor.sh" \
    "$CLAUDE_PLUGIN_ROOT/scripts/config-yaml-editor.sh"
  # Write a synthetic plugin.json with a pinned version.
  cat > "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "gaia",
  "version": "1.152.0"
}
JSON
  # Defaults for env-var interface.
  export MODE="apply"
  export DRY_RUN="false"
  export ASSUME_YES="false"
}
teardown() { common_teardown; }

write_schema() {
  cat > "$1" <<JSON
{
  "\$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Test schema v$2",
  "type": "object",
  "properties": {
    "schema_version":    { "type": "string" },
    "config_phase":      { "type": "string", "enum": ["minimal", "partial", "full"] },
    "framework_version": { "type": "string" },
    "project_name":      { "type": "string" },
    "stacks":            { "type": "array" }
  }
}
JSON
}

write_minimal_config() {
  # Args: <path> <schema_ver> <fw_ver>
  local path="$1" sver="$2" fwver="$3"
  cat > "$path" <<YAML
schema_version: "$sver"
config_phase: full
project_name: test-project
project_root: /tmp/test
project_path: gaia-framework
memory_path: _memory
checkpoint_path: _memory/checkpoints
installed_path: ~/.claude/plugins/cache/gaia
framework_version: "$fwver"
date: "2026-05-14"

stacks:
  - typescript
YAML
}

# ───────────────────────── AC1 — Reconciler writes framework_version ─────────────────────────

# TC-RV2-56 part (a)
@test "AC1 (TC-RV2-56): apply writes framework_version from plugin.json into config" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.0.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" "1.127.2-rc.1"
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # Plugin.json pins version 1.152.0 (setup fixture); reconciler must write it.
  grep -qE '^framework_version:[[:space:]]*"?1\.152\.0"?' "$PROJECT_ROOT/config/project-config.yaml"
}

@test "AC1: framework_version write preserves YAML comments outside the section" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.0.0"
  local cfg="$PROJECT_ROOT/config/project-config.yaml"
  cat > "$cfg" <<'YAML'
# Header comment — must survive.
schema_version: "2.0.0"
config_phase: full
project_name: test-project
project_root: /tmp/test
project_path: gaia-framework
memory_path: _memory
checkpoint_path: _memory/checkpoints
installed_path: ~/.claude/plugins/cache/gaia
framework_version: "1.127.2-rc.1"  # inline comment — must survive
date: "2026-05-14"

stacks:
  - typescript
# Trailing comment — must survive.
YAML
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  # All comments preserved.
  grep -qE '^# Header comment' "$cfg"
  grep -qE '^# Trailing comment' "$cfg"
  # Version updated.
  grep -qE '^framework_version:[[:space:]]*"?1\.152\.0"?' "$cfg"
}

# ───────────────────────── AC2 — No inline yq -i ─────────────────────────

# TC-RV2-56b — invariant
@test "AC2 (TC-RV2-56b): reconciler does not invoke yq with -i flag" {
  # Static-source check: the reconciler MUST NOT use `yq -i` anywhere — it
  # MUST dispatch via config-yaml-editor.sh (ADR-101 §6 reconciler-as-caller).
  ! grep -E 'yq[[:space:]]+-i\b|yq[[:space:]]+--in-place' "$RECONCILER"
}

@test "AC2: reconciler invokes config-yaml-editor.sh replace for the framework_version write" {
  grep -qE 'config-yaml-editor\.sh.+(replace|insert).+framework_version|config_yaml_editor.+framework_version' "$RECONCILER" \
    || grep -qE 'framework_version.+config-yaml-editor\.sh' "$RECONCILER"
}

# ───────────────────────── AC3 — Stale comment removed/reworded ─────────────────────────

# TC-RV2-56c — content
@test "AC3 (TC-RV2-56c): config-hydration.sh:96 no longer claims framework_version is written by resolve-config.sh" {
  # The stale "Computed path/identity (7): written by resolve-config.sh at runtime"
  # comment block applies to a list that includes framework_version. Per Val F-2,
  # framework_version is NOT written by resolve-config.sh (only read). The comment
  # must be split, deleted, or reworded so the writer-of-record for framework_version
  # is gaia-reconcile-v2.sh apply, not resolve-config.sh at runtime.
  #
  # Acceptable post-fix shapes:
  #   (a) framework_version moved out of the "Computed path/identity (7)" group,
  #   (b) the comment block reworded to clarify framework_version is reconciler-written,
  #   (c) the misleading "written by resolve-config.sh at runtime" line removed entirely
  #       for the group containing framework_version.
  #
  # We assert (c) at minimum: no comment line in the hydration helper claims
  # framework_version is written by resolve-config.sh at runtime.
  ! awk '
    BEGIN { in_block=0 }
    /Computed path\/identity/ { in_block=1; next }
    in_block && /^_CONFIG_HYDRATION_MANAGED_ELSEWHERE/ { in_block=0 }
    in_block && /written by resolve-config\.sh at runtime/ { print "STALE COMMENT: " $0; found=1 }
    END { if (found) exit 1 }
  ' "$HYDRATION_LIB"
}

@test "AC3: config-hydration.sh mentions gaia-reconcile-v2.sh apply as the framework_version writer" {
  grep -qE 'framework_version.*reconcile|reconcile.*framework_version' "$HYDRATION_LIB"
}

# ───────────────────────── AC5 — Idempotency ─────────────────────────

# TC-RV2-56 part (b/c) — second-run byte-identical
@test "AC5 (TC-RV2-56b): second apply run yields byte-identical config (idempotent)" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.0.0"
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" "1.127.2-rc.1"

  # First run — version write happens.
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  local sha_first
  sha_first="$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')"

  # Second run — no-op (versions match now); config byte-identical.
  run "$RECONCILER"
  [ "$status" -eq 0 ]
  local sha_second
  sha_second="$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')"

  [ "$sha_first" = "$sha_second" ]
}

@test "AC5: when framework_version already matches plugin version, apply is no-op for this field" {
  write_schema "$CLAUDE_PLUGIN_ROOT/schemas/project-config.schema.json" "2.0.0"
  # Config already at plugin's version (1.152.0).
  write_minimal_config "$PROJECT_ROOT/config/project-config.yaml" "2.0.0" "1.152.0"
  local sha_pre
  sha_pre="$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')"

  run "$RECONCILER"
  [ "$status" -eq 0 ]

  local sha_post
  sha_post="$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')"
  [ "$sha_pre" = "$sha_post" ]
  # And the value is still 1.152.0.
  grep -qE '^framework_version:[[:space:]]*"?1\.152\.0"?' "$PROJECT_ROOT/config/project-config.yaml"
}
