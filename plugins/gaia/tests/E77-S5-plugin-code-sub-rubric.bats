#!/usr/bin/env bats
# E77-S5-plugin-code-sub-rubric.bats — contract test for the plugin-code
# sub-rubric (FR-407, ADR-088, NFR-PLUGIN-2).
#
# Coverage:
#   AC1 — Sub-rubric file exists and is valid JSON conforming to
#         rubric.schema.json.
#   AC2 — `when:` predicate gates activation by `project_kind`.
#   AC3 — 80% coverage threshold default is encoded as a discoverable rule.
#   AC4 — Allowlist override mechanism is documented in metadata so
#         downstream review skills can read the override schema.
#   AC5 — Two-tier SKILL.md token budget enforcement: WARNING at >1500
#         tokens, CRITICAL at >=2000 tokens (per NFR-PLUGIN-2).
#   AC6 — Backward compatibility: non-plugin projects exclude plugin-code
#         from the merged rubric output.
#   AC7 — /gaia-validate-rubric / validate-rubric.sh PASSes the file.
#
# Story: E77-S5 (Tier 1 — plugin-code sub-rubric)
# =============================================================================

set -euo pipefail

setup() {
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOADER="$PLUGIN_DIR/scripts/rubric-loader.sh"
  VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
  SUB_RUBRIC="$PLUGIN_DIR/rubrics/sub-rubrics/plugin-code.json"
  TMP_CONFIG="$BATS_TEST_TMPDIR/project-config.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — Sub-rubric file exists and is schema-valid
# ---------------------------------------------------------------------------
@test "AC1: plugin-code sub-rubric file exists at the canonical location" {
  [ -f "$SUB_RUBRIC" ] \
    || { echo "AC1 FAIL: plugin-code sub-rubric not found at $SUB_RUBRIC" >&2; return 1; }
}

@test "AC1: plugin-code sub-rubric is well-formed JSON" {
  jq empty "$SUB_RUBRIC" \
    || { echo "AC1 FAIL: plugin-code sub-rubric is not well-formed JSON" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2 — `when:` predicate gates activation
# ---------------------------------------------------------------------------
@test "AC2: plugin-code sub-rubric carries when: {project_kind: claude-code-plugin}" {
  local kind
  kind=$(jq -r '.when.project_kind // empty' "$SUB_RUBRIC")
  [ "$kind" = "claude-code-plugin" ] \
    || { echo "AC2 FAIL: expected when.project_kind=claude-code-plugin, got=$kind" >&2; return 1; }
}

@test "AC2: plugin-code rules INCLUDED for project_kind=claude-code-plugin" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: claude-code-plugin
EOF
  local out
  out=$("$LOADER" --skill code --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  echo "$out" | jq -e '.severity_rules[]? | select(.id == "plugin-code-skill-md-token-budget-warning")' >/dev/null \
    || { echo "AC2 FAIL: expected plugin-code SKILL.md WARNING rule INCLUDED" >&2; return 1; }
}

@test "AC2: plugin-code rules EXCLUDED for project_kind=web-app" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: web-app
EOF
  local out
  out=$("$LOADER" --skill code --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out" | jq -e '.severity_rules[]? | select(.id == "plugin-code-skill-md-token-budget-warning")' >/dev/null \
    || { echo "AC2 FAIL: expected plugin-code rules EXCLUDED for non-plugin project" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC3 — 80% coverage threshold default
# ---------------------------------------------------------------------------
@test "AC3: plugin-code sub-rubric encodes 80% coverage threshold default" {
  local pct
  pct=$(jq -r '.metadata.coverage.threshold_default_percent // empty' "$SUB_RUBRIC")
  [ "$pct" = "80" ] \
    || { echo "AC3 FAIL: expected metadata.coverage.threshold_default_percent=80, got=$pct" >&2; return 1; }
}

@test "AC3: plugin-code sub-rubric carries a coverage rule" {
  jq -e '.severity_rules[] | select(.category == "coverage")' "$SUB_RUBRIC" >/dev/null \
    || { echo "AC3 FAIL: expected at least one rule with category=coverage" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC4 — Allowlist override mechanism documented in metadata
# ---------------------------------------------------------------------------
@test "AC4: plugin-code sub-rubric documents allowlist override config key" {
  local key
  key=$(jq -r '.metadata.coverage.allowlist_override_config_key // empty' "$SUB_RUBRIC")
  [ "$key" = "plugin-code.coverage_allowlist" ] \
    || { echo "AC4 FAIL: expected metadata.coverage.allowlist_override_config_key=plugin-code.coverage_allowlist, got=$key" >&2; return 1; }
}

@test "AC4: plugin-code sub-rubric documents per-path allowlist schema" {
  jq -e '.metadata.coverage.allowlist_schema | type == "object"' "$SUB_RUBRIC" >/dev/null \
    || { echo "AC4 FAIL: expected metadata.coverage.allowlist_schema object" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC5 — SKILL.md token budget two-tier enforcement
# ---------------------------------------------------------------------------
@test "AC5: SKILL.md WARNING rule fires at >1500 tokens" {
  local rule
  rule=$(jq -c '.severity_rules[] | select(.id == "plugin-code-skill-md-token-budget-warning")' "$SUB_RUBRIC")
  [ -n "$rule" ] \
    || { echo "AC5 FAIL: expected plugin-code-skill-md-token-budget-warning rule" >&2; return 1; }
  local sev
  sev=$(printf '%s' "$rule" | jq -r '.severity')
  [ "$sev" = "Medium" ] || [ "$sev" = "High" ] \
    || { echo "AC5 FAIL: expected WARNING-tier severity (Medium|High), got=$sev" >&2; return 1; }
  printf '%s' "$rule" | jq -r '.pattern' | grep -q '1500' \
    || { echo "AC5 FAIL: WARNING pattern must reference 1500-token threshold" >&2; return 1; }
}

@test "AC5: SKILL.md CRITICAL rule fires at >=2000 tokens" {
  local rule
  rule=$(jq -c '.severity_rules[] | select(.id == "plugin-code-skill-md-token-budget-critical")' "$SUB_RUBRIC")
  [ -n "$rule" ] \
    || { echo "AC5 FAIL: expected plugin-code-skill-md-token-budget-critical rule" >&2; return 1; }
  local sev
  sev=$(printf '%s' "$rule" | jq -r '.severity')
  [ "$sev" = "Critical" ] \
    || { echo "AC5 FAIL: expected severity=Critical, got=$sev" >&2; return 1; }
  printf '%s' "$rule" | jq -r '.pattern' | grep -q '2000' \
    || { echo "AC5 FAIL: CRITICAL pattern must reference 2000-token threshold" >&2; return 1; }
}

@test "AC5: SKILL.md token budget rules cite NFR-PLUGIN-2 in references" {
  jq -e '.severity_rules[] | select(.id == "plugin-code-skill-md-token-budget-critical") | .references | index("NFR-PLUGIN-2")' "$SUB_RUBRIC" >/dev/null \
    || { echo "AC5 FAIL: expected NFR-PLUGIN-2 reference on critical token-budget rule" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC6 — Backward compatibility (no project_kind set)
# ---------------------------------------------------------------------------
@test "AC6: plugin-code rules EXCLUDED when project_kind unset" {
  cat >"$TMP_CONFIG" <<'EOF'
{}
EOF
  local out
  out=$("$LOADER" --skill code --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out" | jq -e '.severity_rules[]? | select(.id == "plugin-code-skill-md-token-budget-warning")' >/dev/null \
    || { echo "AC6 FAIL: plugin-code rules must be EXCLUDED when project_kind is unset" >&2; return 1; }
}

@test "AC6: base code rules survive intact when plugin-code is excluded" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: web-app
EOF
  local out
  out=$("$LOADER" --skill code --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  echo "$out" | jq -e '.severity_rules[]? | select(.id == "code-solid-001")' >/dev/null \
    || { echo "AC6 FAIL: base code rules must remain when plugin-code is excluded" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC7 — Schema validation passes
# ---------------------------------------------------------------------------
@test "AC7: plugin-code sub-rubric passes validate-rubric.sh schema check" {
  run "$VALIDATOR" "$SUB_RUBRIC"
  [ "$status" -eq 0 ] \
    || { echo "AC7 FAIL: validate-rubric.sh exited $status — output: $output" >&2; return 1; }
}
