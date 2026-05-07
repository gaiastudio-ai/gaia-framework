#!/usr/bin/env bats
# E77-S4-rubric-loader-regression.bats — full regression bats suite for
# non-plugin projects (FR-406, ADR-088, AC9, AC10).
#
# Purpose: prove zero behavioral regression for every existing project
# shape that the legacy loader handled. Every base skill rubric, with and
# without the regime overlay, must round-trip through the migrated loader
# unchanged when no sub-rubric directory is present (the "non-plugin"
# default — sub-rubrics is opt-in and empty by default).
#
# Coverage:
#   AC9  — full regression suite passes for non-plugin projects
#   AC10 — regression suite ships with this story (>= 10 @test entries)
#
# Story: E77-S4 (Tier 1 — Sub-rubric loader pipeline migration)
# =============================================================================

set -euo pipefail

setup() {
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOADER="$PLUGIN_DIR/scripts/rubric-loader.sh"
  MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"
  RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
  RUBRICS_REGIMES="$PLUGIN_DIR/rubrics/regimes"
}

# AC9.1 — every base skill loads byte-identically with no regimes/domain/project.
@test "AC9.1: base-only load is identity-merge for skill=code" {
  local out expected
  out=$("$LOADER" --skill code \
                  --rubrics-root "$PLUGIN_DIR/rubrics" \
                  --regimes "" --no-domain --no-project)
  expected=$(jq --sort-keys . "$RUBRICS_BASE/code.json")
  [ "$out" = "$expected" ]
}

@test "AC9.2: base-only load is identity-merge for skill=qa" {
  local out expected
  out=$("$LOADER" --skill qa \
                  --rubrics-root "$PLUGIN_DIR/rubrics" \
                  --regimes "" --no-domain --no-project)
  expected=$(jq --sort-keys . "$RUBRICS_BASE/qa.json")
  [ "$out" = "$expected" ]
}

@test "AC9.3: base-only load is identity-merge for skill=test" {
  local out expected
  out=$("$LOADER" --skill test \
                  --rubrics-root "$PLUGIN_DIR/rubrics" \
                  --regimes "" --no-domain --no-project)
  expected=$(jq --sort-keys . "$RUBRICS_BASE/test.json")
  [ "$out" = "$expected" ]
}

@test "AC9.4: base-only load is identity-merge for skill=security" {
  local out expected
  out=$("$LOADER" --skill security \
                  --rubrics-root "$PLUGIN_DIR/rubrics" \
                  --regimes "" --no-domain --no-project)
  expected=$(jq --sort-keys . "$RUBRICS_BASE/security.json")
  [ "$out" = "$expected" ]
}

@test "AC9.5: base-only load is identity-merge for skill=perf" {
  local out expected
  out=$("$LOADER" --skill perf \
                  --rubrics-root "$PLUGIN_DIR/rubrics" \
                  --regimes "" --no-domain --no-project)
  expected=$(jq --sort-keys . "$RUBRICS_BASE/perf.json")
  [ "$out" = "$expected" ]
}

@test "AC9.6: base-only load is identity-merge for skill=a11y" {
  local out expected
  out=$("$LOADER" --skill a11y \
                  --rubrics-root "$PLUGIN_DIR/rubrics" \
                  --regimes "" --no-domain --no-project)
  expected=$(jq --sort-keys . "$RUBRICS_BASE/a11y.json")
  [ "$out" = "$expected" ]
}

# AC9.7 — base + regime overlay (HIPAA + code).
@test "AC9.7: base + HIPAA regime overlay merges byte-identically vs direct merger call" {
  [ -f "$RUBRICS_REGIMES/hipaa.json" ] || skip "hipaa regime not present"
  local out_loader out_merger
  out_loader=$("$LOADER" --skill code \
                         --rubrics-root "$PLUGIN_DIR/rubrics" \
                         --regimes "hipaa" --no-domain --no-project)
  out_merger=$("$MERGER" "$RUBRICS_BASE/code.json" "$RUBRICS_REGIMES/hipaa.json")
  [ "$out_loader" = "$out_merger" ]
}

# AC9.8 — multiple regimes in declaration order.
@test "AC9.8: base + multi-regime overlay (PCI then SOC2) preserves declaration order" {
  [ -f "$RUBRICS_REGIMES/pci-dss.json" ] || skip "pci-dss regime not present"
  [ -f "$RUBRICS_REGIMES/soc2.json" ] || skip "soc2 regime not present"
  local out_loader out_merger
  out_loader=$("$LOADER" --skill security \
                         --rubrics-root "$PLUGIN_DIR/rubrics" \
                         --regimes "pci-dss,soc2" --no-domain --no-project)
  out_merger=$("$MERGER" "$RUBRICS_BASE/security.json" \
                         "$RUBRICS_REGIMES/pci-dss.json" \
                         "$RUBRICS_REGIMES/soc2.json")
  [ "$out_loader" = "$out_merger" ]
}

# AC9.9 — empty sub-rubrics directory must produce the same output as no
# sub-rubrics directory at all (default backward-compat invariant).
@test "AC9.9: empty sub-rubrics directory is a no-op (backward-compat)" {
  local sandbox="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$sandbox/base" "$sandbox/sub-rubrics"
  cp "$RUBRICS_BASE/code.json" "$sandbox/base/code.json"
  local with_dir without_dir
  with_dir=$("$LOADER" --skill code --rubrics-root "$sandbox" \
                       --regimes "" --no-domain --no-project)
  rmdir "$sandbox/sub-rubrics"
  without_dir=$("$LOADER" --skill code --rubrics-root "$sandbox" \
                          --regimes "" --no-domain --no-project)
  [ "$with_dir" = "$without_dir" ]
}

# AC9.10 — missing project_kind in config must NOT include any sub-rubric
# whose `when:` predicate references project_kind. This protects projects
# that never set project_kind (the typical brownfield case).
@test "AC9.10: missing project_kind in config excludes project_kind-gated sub-rubrics" {
  local sandbox="$BATS_TEST_TMPDIR/sandbox-no-pk"
  mkdir -p "$sandbox/base" "$sandbox/sub-rubrics"
  cp "$RUBRICS_BASE/code.json" "$sandbox/base/code.json"
  cat >"$sandbox/sub-rubrics/plugin-only.json" <<'EOF'
{
  "schema_version": "1.0",
  "skill": "code",
  "when": {"project_kind": "claude-code-plugin"},
  "metadata": {"plugin_marker": "should-not-appear"},
  "severity_rules": []
}
EOF
  local config="$BATS_TEST_TMPDIR/empty-config.yaml"
  printf 'compliance:\n  regimes: []\n' >"$config"
  local out
  out=$("$LOADER" --skill code --rubrics-root "$sandbox" \
                  --regimes "" --no-domain --no-project --config "$config")
  ! echo "$out" | jq -e '.metadata.plugin_marker' >/dev/null \
    || { echo "AC9.10 FAIL: project_kind-gated sub-rubric leaked when project_kind unset" >&2; return 1; }
}

# AC9.11 — null `when:` (or missing `when:`) means unconditional include.
@test "AC9.11: sub-rubric with no when: is included unconditionally" {
  local sandbox="$BATS_TEST_TMPDIR/sandbox-uncond"
  mkdir -p "$sandbox/base" "$sandbox/sub-rubrics"
  cp "$RUBRICS_BASE/code.json" "$sandbox/base/code.json"
  cat >"$sandbox/sub-rubrics/uncond.json" <<'EOF'
{
  "schema_version": "1.0",
  "skill": "code",
  "metadata": {"uncond_marker": "always"},
  "severity_rules": []
}
EOF
  local config="$BATS_TEST_TMPDIR/anycfg.yaml"
  printf 'project_kind: web-app\n' >"$config"
  local out
  out=$("$LOADER" --skill code --rubrics-root "$sandbox" \
                  --regimes "" --no-domain --no-project --config "$config")
  echo "$out" | jq -e '.metadata.uncond_marker == "always"' >/dev/null \
    || { echo "AC9.11 FAIL: unconditional (no when:) sub-rubric not included" >&2; return 1; }
}

# AC10 — regression suite presence and minimum density.
@test "AC10: regression suite ships in this story with >= 10 @test entries" {
  local file="$PLUGIN_DIR/tests/E77-S4-rubric-loader-regression.bats"
  [ -f "$file" ]
  local count
  count=$(grep -c '^@test ' "$file")
  [ "$count" -ge 10 ] \
    || { echo "AC10 FAIL: expected >= 10 @test entries, got $count" >&2; return 1; }
}
