#!/usr/bin/env bats
# e28-s141-schema-coverage.bats — schema and migration doc coverage tests
# for E28-S141 (Define config/project-config.yaml schema).
#
# Validates:
#   AC1 — every legacy global.yaml field has exactly one disposition row
#   AC2 — shared set includes required keys
#   AC3 — local set (stays-in-global) includes required keys
#   AC4 — precedence rule stated identically in schema header and MIGRATION doc
#   AC5 — round-trip fixture resolves through resolve-config.sh

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

# Repo-rooted paths (relative to this file's tests/ directory).
CONFIG_DIR="$(cd "$BATS_TEST_DIRNAME/../config" && pwd)"
SCHEMA="$CONFIG_DIR/project-config.schema.yaml"
MIGRATION="$CONFIG_DIR/MIGRATION-from-global-yaml.md"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/round-trip"
# LEGACY_GLOBAL lives in the developer's project-root workspace (outside the
# gaia-public checkout). In CI the plugin repo is checked out standalone so
# the _gaia/_config/global.yaml mirror is not present — resolve lazily and
# skip the disposition test when unavailable.
_legacy_parent="$BATS_TEST_DIRNAME/../../../../_gaia/_config"
if [ -d "$_legacy_parent" ]; then
  LEGACY_GLOBAL="$(cd "$_legacy_parent" && pwd)/global.yaml"
else
  LEGACY_GLOBAL=""
fi
SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"

# The canonical precedence sentence — must appear identically in both artifacts (AC4).
PRECEDENCE_SENTENCE="When the same key appears in both \`global.yaml\` (local) and \`config/project-config.yaml\` (shared), the local value wins."

@test "AC1: MIGRATION doc exists and is non-empty" {
  [ -f "$MIGRATION" ]
  [ -s "$MIGRATION" ]
}

@test "AC1: every top-level field in legacy global.yaml appears in MIGRATION disposition table" {
  # CI skip: the legacy global.yaml lives in the developer workspace outside
  # the plugin repo. The plugin-ci.yml job checks out gaia-public standalone
  # so the _gaia/_config mirror is absent — skip the disposition cross-check
  # when the fixture cannot be located.
  if [ -z "$LEGACY_GLOBAL" ] || [ ! -f "$LEGACY_GLOBAL" ]; then
    skip "legacy _gaia/_config/global.yaml not present in this checkout"
  fi
  [ -f "$MIGRATION" ]

  # Extract top-level YAML keys from legacy global.yaml
  # (zero-indent "name:" lines, skipping comments and blanks).
  legacy_fields=$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
      k=$0; sub(/:.*/,"",k); print k
    }
  ' "$LEGACY_GLOBAL")

  missing=""
  for field in $legacy_fields; do
    # Field must appear in MIGRATION table (as backtick-wrapped key in a table row).
    if ! grep -qE "\| \`${field}\` \|" "$MIGRATION"; then
      missing="$missing $field"
    fi
  done

  if [ -n "$missing" ]; then
    echo "Missing disposition rows for:$missing" >&2
    return 1
  fi
}

@test "AC2: schema declares required shared fields" {
  [ -f "$SCHEMA" ]
  # AC2 required shared keys (per feature brief P20-S1)
  grep -qE "^  project_path:" "$SCHEMA"
  grep -qE "^  user_name:" "$SCHEMA"
  grep -qE "^  communication_language:" "$SCHEMA"
  grep -qE "^  sprint:" "$SCHEMA"
  grep -qE "^  review_gate:" "$SCHEMA"
  grep -qE "^  team_conventions:" "$SCHEMA"
  grep -qE "^  agent_customizations:" "$SCHEMA"
}

@test "AC3: MIGRATION doc documents local fields (stays-in-global)" {
  [ -f "$MIGRATION" ]
  # AC3 required local keys: installed_path + machine-specific paths
  grep -qE "\| \`installed_path\` \|" "$MIGRATION"
  # Must have a stays-in-global section or disposition
  grep -qE "stays-in-global" "$MIGRATION"
}

@test "AC4: precedence rule appears identically in schema header" {
  [ -f "$SCHEMA" ]
  grep -qF "$PRECEDENCE_SENTENCE" "$SCHEMA"
}

@test "AC4: precedence rule appears identically in MIGRATION doc" {
  [ -f "$MIGRATION" ]
  grep -qF "$PRECEDENCE_SENTENCE" "$MIGRATION"
}

@test "AC4: MIGRATION doc has worked example for local-override pattern" {
  [ -f "$MIGRATION" ]
  # Worked example must show a shared-default with local-override.
  # Heuristic: heading + code fence demonstrating override.
  grep -qE "Worked [Ee]xample|worked example" "$MIGRATION"
}

@test "AC5: round-trip fixtures exist" {
  [ -f "$FIXTURES/shared-project-config.yaml" ]
  [ -f "$FIXTURES/local-global.yaml" ]
  [ -f "$FIXTURES/expected-resolved.yaml" ]
  [ -f "$FIXTURES/README.md" ]
}

@test "AC5: expected-resolved fixture shows project_path as local value (local overrides shared)" {
  [ -f "$FIXTURES/expected-resolved.yaml" ]
  [ -f "$FIXTURES/shared-project-config.yaml" ]
  [ -f "$FIXTURES/local-global.yaml" ]

  # Shared declares project_path with one value; local overrides with another.
  # Expected resolution must carry the LOCAL value (AC4: local overrides shared).
  shared_value=$(grep -E "^project_path:" "$FIXTURES/shared-project-config.yaml" | head -1 | sed -E 's/^project_path:[[:space:]]*//')
  local_value=$(grep -E "^project_path:" "$FIXTURES/local-global.yaml" | head -1 | sed -E 's/^project_path:[[:space:]]*//')
  expected_value=$(grep -E "^project_path:" "$FIXTURES/expected-resolved.yaml" | head -1 | sed -E 's/^project_path:[[:space:]]*//')

  [ -n "$shared_value" ]
  [ -n "$local_value" ]
  [ "$shared_value" != "$local_value" ]
  [ "$expected_value" = "$local_value" ]
}

@test "AC5: expected-resolved fixture passes resolve-config.sh without errors" {
  [ -f "$FIXTURES/expected-resolved.yaml" ]
  [ -x "$SCRIPTS_DIR/resolve-config.sh" ]

  # Stage the expected-resolved fixture as a skill-dir project-config.yaml
  # and run resolve-config.sh against it. This proves AC5 scenario 7:
  # "no resolver code changes required" — the resolver handles the merged
  # output shape generically per ADR-044.
  mkdir -p "$TEST_TMP/skill/config"
  cp "$FIXTURES/expected-resolved.yaml" "$TEST_TMP/skill/config/project-config.yaml"
  # Copy the live schema so schema enforcement applies.
  cp "$SCHEMA" "$TEST_TMP/skill/config/project-config.schema.yaml"

  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPTS_DIR/resolve-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_path="* ]]
}

@test "AC5: README in fixtures directory explains the round-trip contract" {
  [ -f "$FIXTURES/README.md" ]
  grep -qE "E28-S141" "$FIXTURES/README.md"
  grep -qiE "local overrides shared|local.*wins" "$FIXTURES/README.md"
}
