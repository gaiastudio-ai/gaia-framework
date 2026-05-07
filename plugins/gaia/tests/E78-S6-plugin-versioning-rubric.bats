#!/usr/bin/env bats
# E78-S6-plugin-versioning-rubric.bats — contract test for the plugin-versioning
# Tier 3 sub-rubric (FR-428) and adapter.schema.json category enum hygiene
# (FR-429, ADR-088, TC-PLUGIN-SEMVER-1..6, TC-PLUGIN-SCHEMA-1..2).
#
# Coverage:
#   AC1 — Sub-rubric file exists at the canonical location and is schema-valid
#         JSON. Carries the six bump-rule severity entries (skill-description,
#         skill-removed, command-or-agent-removed-or-renamed, manifest-schema,
#         frontmatter-required-field-added, bug-fix).
#   AC2 — Contract-change-without-bump pattern is encoded as a Critical/High
#         severity finding so the verdict-resolver maps it to FAILED.
#   AC3 — Correct-bump-present pattern is encoded so a contract change WITH a
#         matching bump produces no finding (rule pattern documents the silent
#         pass).
#   AC4 — Bug-fix-only pattern is encoded as Info severity so the rubric infers
#         patch.
#   AC5 — Composite pre-deploy gate maps any non-APPROVE composite (which is
#         what UNVERIFIED collapses to upstream of the aggregator) to BLOCKED.
#         The pre-deploy-gate.sh test seam is verified end-to-end.
#   AC6 — plugin-versioning rules are EXCLUDED for non-plugin projects and
#         when project_kind is unset.
#   AC7 — adapter.schema.json category enum contains "deploy" (the 14th value)
#         so script-deploy/adapter.json passes validation without relying on
#         additionalProperties.
#   AC8 — Unknown-category warning rule is encoded with severity Medium so the
#         hygiene scanner reports it as a WARNING, not an error.
#   AC9 — Valid-category rule encodes the 14-value canonical enum and is silent
#         pass for any in-enum value.
#
# Story: E78-S6 (Tier 3 — plugin-versioning semver rubric + adapter.schema.json
# enum hygiene, FR-428, FR-429)
# =============================================================================

set -euo pipefail

setup() {
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOADER="$PLUGIN_DIR/scripts/rubric-loader.sh"
  VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
  SUB_RUBRIC="$PLUGIN_DIR/rubrics/sub-rubrics/plugin-versioning.json"
  ADAPTER_SCHEMA="$PLUGIN_DIR/scripts/adapters/_schema/adapter.schema.json"
  SCRIPT_DEPLOY_ADAPTER="$PLUGIN_DIR/scripts/adapters/script-deploy/adapter.json"
  PRE_DEPLOY_GATE="$PLUGIN_DIR/skills/gaia-deploy/scripts/pre-deploy-gate.sh"
  TMP_CONFIG="$BATS_TEST_TMPDIR/project-config.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — Sub-rubric file exists, schema-valid, carries six bump rules
# ---------------------------------------------------------------------------
@test "AC1: plugin-versioning sub-rubric file exists at the canonical location" {
  [ -f "$SUB_RUBRIC" ] \
    || { echo "AC1 FAIL: plugin-versioning sub-rubric not found at $SUB_RUBRIC" >&2; return 1; }
}

@test "AC1: plugin-versioning sub-rubric is well-formed JSON" {
  jq empty "$SUB_RUBRIC" \
    || { echo "AC1 FAIL: plugin-versioning sub-rubric is not well-formed JSON" >&2; return 1; }
}

@test "AC1: plugin-versioning sub-rubric carries skill=code" {
  local skill
  skill=$(jq -r '.skill // empty' "$SUB_RUBRIC")
  [ "$skill" = "code" ] \
    || { echo "AC1 FAIL: expected .skill=code, got=$skill" >&2; return 1; }
}

@test "AC1: plugin-versioning carries when.project_kind=claude-code-plugin" {
  local kind
  kind=$(jq -r '.when.project_kind // empty' "$SUB_RUBRIC")
  [ "$kind" = "claude-code-plugin" ] \
    || { echo "AC1 FAIL: expected when.project_kind=claude-code-plugin, got=$kind" >&2; return 1; }
}

@test "AC1: plugin-versioning encodes the six bump-rule mappings" {
  for id in \
    plugin-versioning-skill-description-changed-minor \
    plugin-versioning-skill-removed-major \
    plugin-versioning-command-or-agent-removed-or-renamed-major \
    plugin-versioning-manifest-schema-changed-major \
    plugin-versioning-frontmatter-required-field-added-major \
    plugin-versioning-bug-fix-patch
  do
    jq -e --arg id "$id" '.severity_rules[] | select(.id == $id)' "$SUB_RUBRIC" >/dev/null \
      || { echo "AC1 FAIL: expected severity rule id=$id in plugin-versioning rubric" >&2; return 1; }
  done
}

@test "AC1: plugin-versioning sub-rubric passes validate-rubric.sh schema check" {
  run "$VALIDATOR" "$SUB_RUBRIC"
  [ "$status" -eq 0 ] \
    || { echo "AC1 FAIL: validate-rubric.sh exited $status — output: $output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2 — Contract change without bump → Critical/High severity (FAILED verdict)
# ---------------------------------------------------------------------------
@test "AC2: skill-removed rule is severity Critical (forces FAILED verdict)" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.id == "plugin-versioning-skill-removed-major") | .severity' "$SUB_RUBRIC")
  [ "$sev" = "Critical" ] \
    || { echo "AC2 FAIL: expected severity=Critical for skill-removed-major, got=$sev" >&2; return 1; }
}

@test "AC2: command-or-agent-removed-or-renamed rule is severity Critical" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.id == "plugin-versioning-command-or-agent-removed-or-renamed-major") | .severity' "$SUB_RUBRIC")
  [ "$sev" = "Critical" ] \
    || { echo "AC2 FAIL: expected severity=Critical for command/agent-removed-major, got=$sev" >&2; return 1; }
}

@test "AC2: manifest-schema-changed rule is severity Critical" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.id == "plugin-versioning-manifest-schema-changed-major") | .severity' "$SUB_RUBRIC")
  [ "$sev" = "Critical" ] \
    || { echo "AC2 FAIL: expected severity=Critical for manifest-schema-changed, got=$sev" >&2; return 1; }
}

@test "AC2: frontmatter-required-field-added rule is severity Critical" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.id == "plugin-versioning-frontmatter-required-field-added-major") | .severity' "$SUB_RUBRIC")
  [ "$sev" = "Critical" ] \
    || { echo "AC2 FAIL: expected severity=Critical for frontmatter-required-field, got=$sev" >&2; return 1; }
}

@test "AC2: bump-rule pattern names the required bump level" {
  jq -r '.severity_rules[] | select(.id == "plugin-versioning-skill-removed-major") | .pattern' "$SUB_RUBRIC" \
    | grep -qi 'major' \
      || { echo "AC2 FAIL: skill-removed-major pattern must reference 'major' bump" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC3 — Correct bump present → no finding (silent pass documented in pattern)
# ---------------------------------------------------------------------------
@test "AC3: bump-rule patterns document the 'without a corresponding bump' guard" {
  # Each contract-change rule's pattern MUST include the conditional clause
  # "without ... bump" so the rule fires only on missing bumps. A PR with the
  # correct bump satisfies the pattern's negative-clause and produces no
  # finding (silent pass).
  for id in \
    plugin-versioning-skill-description-changed-minor \
    plugin-versioning-skill-removed-major \
    plugin-versioning-command-or-agent-removed-or-renamed-major \
    plugin-versioning-manifest-schema-changed-major \
    plugin-versioning-frontmatter-required-field-added-major
  do
    jq -r --arg id "$id" '.severity_rules[] | select(.id == $id) | .pattern' "$SUB_RUBRIC" \
      | grep -qi 'without' \
        || { echo "AC3 FAIL: rule $id pattern must document 'without ... bump' guard" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# AC4 — Bug fix only → patch (Info severity)
# ---------------------------------------------------------------------------
@test "AC4: bug-fix-patch rule is severity Info (advisory, non-blocking)" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.id == "plugin-versioning-bug-fix-patch") | .severity' "$SUB_RUBRIC")
  [ "$sev" = "Info" ] \
    || { echo "AC4 FAIL: expected severity=Info for bug-fix-patch, got=$sev" >&2; return 1; }
}

@test "AC4: bug-fix-patch pattern names 'patch' bump level" {
  jq -r '.severity_rules[] | select(.id == "plugin-versioning-bug-fix-patch") | .pattern' "$SUB_RUBRIC" \
    | grep -qi 'patch' \
      || { echo "AC4 FAIL: bug-fix-patch pattern must reference 'patch' bump" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC5 — Composite pre-deploy gate blocks non-APPROVE composite
# ---------------------------------------------------------------------------
@test "AC5: pre-deploy-gate.sh BLOCKS on non-APPROVE composite (UNVERIFIED collapses to BLOCKED upstream)" {
  local fixture="$BATS_TEST_TMPDIR/composite.json"
  cat >"$fixture" <<'EOF'
{
  "composite": "BLOCKED",
  "reviews": [
    {"name": "code", "status": "UNVERIFIED"}
  ]
}
EOF
  GAIA_DEPLOY_COMPOSITE_FILE="$fixture" run "$PRE_DEPLOY_GATE" --story-key E78-S6
  [ "$status" -ne 0 ] \
    || { echo "AC5 FAIL: pre-deploy-gate must exit non-zero for non-APPROVE composite" >&2; return 1; }
}

@test "AC5: pre-deploy-gate.sh PASSES on APPROVE composite" {
  local fixture="$BATS_TEST_TMPDIR/composite-ok.json"
  cat >"$fixture" <<'EOF'
{
  "composite": "APPROVE",
  "reviews": [
    {"name": "code", "status": "PASSED"}
  ]
}
EOF
  GAIA_DEPLOY_COMPOSITE_FILE="$fixture" run "$PRE_DEPLOY_GATE" --story-key E78-S6
  [ "$status" -eq 0 ] \
    || { echo "AC5 FAIL: pre-deploy-gate must exit 0 for APPROVE composite, got=$status output=$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC6 — project_kind guard
# ---------------------------------------------------------------------------
@test "AC6: plugin-versioning rules INCLUDED for project_kind=claude-code-plugin" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: claude-code-plugin
EOF
  local out
  out=$("$LOADER" --skill code --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  echo "$out" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-versioning-"))' >/dev/null \
    || { echo "AC6 FAIL: expected plugin-versioning-* rules INCLUDED for plugin project" >&2; return 1; }
}

@test "AC6: plugin-versioning rules EXCLUDED for project_kind=web-app" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: web-app
EOF
  local out
  out=$("$LOADER" --skill code --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-versioning-"))' >/dev/null \
    || { echo "AC6 FAIL: expected plugin-versioning rules EXCLUDED for non-plugin project" >&2; return 1; }
}

@test "AC6: plugin-versioning rules EXCLUDED when project_kind unset" {
  cat >"$TMP_CONFIG" <<'EOF'
{}
EOF
  local out
  out=$("$LOADER" --skill code --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-versioning-"))' >/dev/null \
    || { echo "AC6 FAIL: plugin-versioning rules must be EXCLUDED when project_kind is unset" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC7 — adapter.schema.json category enum contains "deploy" (14 values)
# ---------------------------------------------------------------------------
@test "AC7: adapter.schema.json category enum contains 'deploy'" {
  jq -e '.properties.category.enum | index("deploy") != null' "$ADAPTER_SCHEMA" >/dev/null \
    || { echo "AC7 FAIL: adapter.schema.json category enum must include 'deploy'" >&2; return 1; }
}

@test "AC7: adapter.schema.json category enum has exactly 14 canonical values" {
  local count
  count=$(jq '.properties.category.enum | length' "$ADAPTER_SCHEMA")
  [ "$count" -eq 14 ] \
    || { echo "AC7 FAIL: expected 14 category enum values, got=$count" >&2; return 1; }
}

@test "AC7: script-deploy/adapter.json has category=deploy and is in the enum" {
  [ -f "$SCRIPT_DEPLOY_ADAPTER" ] \
    || { echo "AC7 FAIL: script-deploy adapter.json missing at $SCRIPT_DEPLOY_ADAPTER" >&2; return 1; }
  local cat
  cat=$(jq -r '.category' "$SCRIPT_DEPLOY_ADAPTER")
  [ "$cat" = "deploy" ] \
    || { echo "AC7 FAIL: script-deploy/adapter.json category must be 'deploy', got=$cat" >&2; return 1; }
  jq -e --arg c "$cat" '.properties.category.enum | index($c) != null' "$ADAPTER_SCHEMA" >/dev/null \
    || { echo "AC7 FAIL: script-deploy category=$cat not in adapter.schema.json enum" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC8 — Unknown adapter category → WARNING finding (severity Medium)
# ---------------------------------------------------------------------------
@test "AC8: adapter-category-hygiene rule exists with severity Medium (WARNING)" {
  local rule
  rule=$(jq -c '.severity_rules[] | select(.id == "plugin-versioning-adapter-category-unknown-warning")' "$SUB_RUBRIC")
  [ -n "$rule" ] \
    || { echo "AC8 FAIL: expected adapter-category-unknown-warning rule" >&2; return 1; }
  local sev
  sev=$(printf '%s' "$rule" | jq -r '.severity')
  [ "$sev" = "Medium" ] \
    || { echo "AC8 FAIL: expected severity=Medium, got=$sev" >&2; return 1; }
}

@test "AC8: adapter-category-hygiene rule pattern references the canonical 14-value enum" {
  local pattern
  pattern=$(jq -r '.severity_rules[] | select(.id == "plugin-versioning-adapter-category-unknown-warning") | .pattern' "$SUB_RUBRIC")
  printf '%s' "$pattern" | grep -q '14' \
    || { echo "AC8 FAIL: pattern must reference the 14-value canonical enum" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC9 — Valid adapter category → silent pass (rule documents the canonical enum)
# ---------------------------------------------------------------------------
@test "AC9: adapter-category-hygiene rule documents the 14 canonical enum values in references or pattern" {
  # Each canonical enum value MUST be discoverable from the rule's pattern,
  # description, or references — the rubric is the ground-truth document the
  # reviewer reads to know what categories are valid.
  local rule
  rule=$(jq -c '.severity_rules[] | select(.id == "plugin-versioning-adapter-category-unknown-warning")' "$SUB_RUBRIC")
  for v in linter formatter type-checker sast secret-scan dep-audit dast \
           e2e-runner perf-tool a11y-scanner mobile-static mobile-dynamic \
           device-farm deploy
  do
    printf '%s' "$rule" | jq -r '.pattern, .description, (.references // [] | join(","))' \
      | grep -q "$v" \
      || { echo "AC9 FAIL: canonical enum value '$v' must appear in rule pattern/description/references" >&2; return 1; }
  done
}

@test "AC9: rule references FR-429" {
  jq -e '.severity_rules[] | select(.id == "plugin-versioning-adapter-category-unknown-warning") | .references | index("FR-429")' "$SUB_RUBRIC" >/dev/null \
    || { echo "AC9 FAIL: expected FR-429 reference on adapter-category-hygiene rule" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Cross-check: FR-428 reference on the bump-rule rules
# ---------------------------------------------------------------------------
@test "FR-428 reference present on every bump-rule" {
  # The 6 bump-rule rules each MUST cite FR-428. The 7th rule
  # (adapter-category-unknown-warning) cites FR-429 and is excluded by id-prefix.
  for id in \
    plugin-versioning-skill-description-changed-minor \
    plugin-versioning-skill-removed-major \
    plugin-versioning-command-or-agent-removed-or-renamed-major \
    plugin-versioning-manifest-schema-changed-major \
    plugin-versioning-frontmatter-required-field-added-major \
    plugin-versioning-bug-fix-patch
  do
    jq -e --arg id "$id" '.severity_rules[] | select(.id == $id) | .references | index("FR-428")' "$SUB_RUBRIC" >/dev/null \
      || { echo "FAIL: rule $id missing FR-428 reference" >&2; return 1; }
  done
}
