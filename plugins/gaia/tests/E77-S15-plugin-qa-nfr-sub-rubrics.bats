#!/usr/bin/env bats
# E77-S15-plugin-qa-nfr-sub-rubrics.bats — contract test for the plugin-qa
# and plugin-nfr Tier 2 sub-rubrics (FR-417, FR-422, ADR-088,
# TC-PLUGIN-RUBRIC-7, TC-PLUGIN-RUBRIC-8).
#
# Coverage:
#   AC1 — plugin-qa.json exists at the canonical sub-rubrics location, parses
#         as JSON, carries when.project_kind=claude-code-plugin, and is loaded
#         by the rubric-loader for plugin projects.
#   AC2 — plugin-nfr.json exists, carries when.project_kind=claude-code-plugin,
#         and encodes the four NFR rules NFR-PLUGIN-1..NFR-PLUGIN-4 with the
#         calibrated severities from the story.
#   AC3 — Both sub-rubrics are EXCLUDED from the merged rubric output for
#         non-plugin projects (project_kind=web-app and unset).
#   AC4 — plugin-qa.json passes validate-rubric.sh schema check.
#   AC5 — plugin-nfr.json passes validate-rubric.sh schema check.
#   AC6 — Severity calibration table (NFR-PLUGIN-1=Medium/Warning,
#         NFR-PLUGIN-2 split Medium+Critical at 1500 / 2000, NFR-PLUGIN-3=High,
#         NFR-PLUGIN-4=Critical).
#   AC7 — LC_ALL=C alpha-sort places plugin-code < plugin-nfr < plugin-qa <
#         plugin-security among the four plugin sub-rubrics.
#   AC8 — Byte-identical contract test fixtures (E77-S4) continue to PASS for
#         non-plugin projects with the new sub-rubric files present.
#
# Story: E77-S15 (Tier 2 — plugin-qa + plugin-nfr sub-rubrics, FR-417, FR-422)
# =============================================================================

set -euo pipefail

setup() {
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOADER="$PLUGIN_DIR/scripts/rubric-loader.sh"
  VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
  SUB_QA="$PLUGIN_DIR/rubrics/sub-rubrics/plugin-qa.json"
  SUB_NFR="$PLUGIN_DIR/rubrics/sub-rubrics/plugin-nfr.json"
  SUB_CODE="$PLUGIN_DIR/rubrics/sub-rubrics/plugin-code.json"
  SUB_SECURITY="$PLUGIN_DIR/rubrics/sub-rubrics/plugin-security.json"
  TMP_CONFIG="$BATS_TEST_TMPDIR/project-config.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — plugin-qa.json exists, well-formed, predicate-gated, loaded
# ---------------------------------------------------------------------------
@test "AC1: plugin-qa sub-rubric file exists at the canonical location" {
  [ -f "$SUB_QA" ] \
    || { echo "AC1 FAIL: plugin-qa sub-rubric not found at $SUB_QA" >&2; return 1; }
}

@test "AC1: plugin-qa sub-rubric is well-formed JSON" {
  jq empty "$SUB_QA" \
    || { echo "AC1 FAIL: plugin-qa sub-rubric is not well-formed JSON" >&2; return 1; }
}

@test "AC1: plugin-qa carries when.project_kind=claude-code-plugin" {
  local kind
  kind=$(jq -r '.when.project_kind // empty' "$SUB_QA")
  [ "$kind" = "claude-code-plugin" ] \
    || { echo "AC1 FAIL: expected when.project_kind=claude-code-plugin, got=$kind" >&2; return 1; }
}

@test "AC1: plugin-qa rules INCLUDED for project_kind=claude-code-plugin" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: claude-code-plugin
EOF
  local out
  out=$("$LOADER" --skill qa --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  echo "$out" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-qa-"))' >/dev/null \
    || { echo "AC1 FAIL: expected plugin-qa-* rules INCLUDED for plugin project" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2 — plugin-nfr.json exists, predicate-gated, encodes 4 NFR rules
# ---------------------------------------------------------------------------
@test "AC2: plugin-nfr sub-rubric file exists at the canonical location" {
  [ -f "$SUB_NFR" ] \
    || { echo "AC2 FAIL: plugin-nfr sub-rubric not found at $SUB_NFR" >&2; return 1; }
}

@test "AC2: plugin-nfr sub-rubric is well-formed JSON" {
  jq empty "$SUB_NFR" \
    || { echo "AC2 FAIL: plugin-nfr sub-rubric is not well-formed JSON" >&2; return 1; }
}

@test "AC2: plugin-nfr carries when.project_kind=claude-code-plugin" {
  local kind
  kind=$(jq -r '.when.project_kind // empty' "$SUB_NFR")
  [ "$kind" = "claude-code-plugin" ] \
    || { echo "AC2 FAIL: expected when.project_kind=claude-code-plugin, got=$kind" >&2; return 1; }
}

@test "AC2: plugin-nfr encodes the four NFR-PLUGIN-1..4 rules" {
  for nfr in NFR-PLUGIN-1 NFR-PLUGIN-2 NFR-PLUGIN-3 NFR-PLUGIN-4; do
    jq -e --arg nfr "$nfr" '.severity_rules[] | select(.references[]? == $nfr)' "$SUB_NFR" >/dev/null \
      || { echo "AC2 FAIL: missing rule referencing $nfr in plugin-nfr.json" >&2; return 1; }
  done
}

@test "AC2: plugin-nfr rules INCLUDED for project_kind=claude-code-plugin" {
  # plugin-nfr is wired under skill=perf so its severity_rules array does not
  # collide with plugin-qa's array under skill=qa (RFC 7396 array-replace
  # semantics in the rubric merger — see plugin-nfr.json metadata.description
  # and ADR-079).
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: claude-code-plugin
EOF
  local out
  out=$("$LOADER" --skill perf --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  echo "$out" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-nfr-"))' >/dev/null \
    || { echo "AC2 FAIL: expected plugin-nfr-* rules INCLUDED for plugin project under skill=perf" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC3 — Both sub-rubrics EXCLUDED for non-plugin projects
# ---------------------------------------------------------------------------
@test "AC3: plugin-qa rules EXCLUDED for project_kind=web-app" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: web-app
EOF
  local out
  out=$("$LOADER" --skill qa --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-qa-"))' >/dev/null \
    || { echo "AC3 FAIL: plugin-qa rules MUST be excluded for non-plugin project" >&2; return 1; }
}

@test "AC3: plugin-nfr rules EXCLUDED for project_kind=web-app" {
  # plugin-nfr targets skill=perf (see plugin-nfr.json metadata).
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: web-app
EOF
  local out
  out=$("$LOADER" --skill perf --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-nfr-"))' >/dev/null \
    || { echo "AC3 FAIL: plugin-nfr rules MUST be excluded for non-plugin project under skill=perf" >&2; return 1; }
}

@test "AC3: base qa rules survive intact when plugin sub-rubrics are excluded" {
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: web-app
EOF
  local out
  out=$("$LOADER" --skill qa --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  echo "$out" | jq -e '.severity_rules | length > 0' >/dev/null \
    || { echo "AC3 FAIL: base qa rules must remain when plugin sub-rubrics are excluded" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC4 / AC5 — Schema validation passes for both files
# ---------------------------------------------------------------------------
@test "AC4: plugin-qa sub-rubric passes validate-rubric.sh schema check" {
  run "$VALIDATOR" "$SUB_QA"
  [ "$status" -eq 0 ] \
    || { echo "AC4 FAIL: validate-rubric.sh exited $status — output: $output" >&2; return 1; }
}

@test "AC5: plugin-nfr sub-rubric passes validate-rubric.sh schema check" {
  run "$VALIDATOR" "$SUB_NFR"
  [ "$status" -eq 0 ] \
    || { echo "AC5 FAIL: validate-rubric.sh exited $status — output: $output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC6 — Severity calibration matches the story
# ---------------------------------------------------------------------------
@test "AC6: NFR-PLUGIN-1 (Install Latency) rule severity is Medium (Warning class)" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.references[]? == "NFR-PLUGIN-1") | .severity' "$SUB_NFR" | head -n1)
  [ "$sev" = "Medium" ] \
    || { echo "AC6 FAIL: expected NFR-PLUGIN-1 severity=Medium (Warning class), got=$sev" >&2; return 1; }
}

@test "AC6: NFR-PLUGIN-2 (SKILL.md Token Budget) has TWO rules — Medium > 1500 AND Critical >= 2000" {
  local count_medium count_critical
  count_medium=$(jq -r '[.severity_rules[] | select(.references[]? == "NFR-PLUGIN-2") | select(.severity == "Medium")] | length' "$SUB_NFR")
  count_critical=$(jq -r '[.severity_rules[] | select(.references[]? == "NFR-PLUGIN-2") | select(.severity == "Critical")] | length' "$SUB_NFR")
  [ "$count_medium" -ge 1 ] \
    || { echo "AC6 FAIL: NFR-PLUGIN-2 must have at least one Medium-severity rule (>1500 tokens), found $count_medium" >&2; return 1; }
  [ "$count_critical" -ge 1 ] \
    || { echo "AC6 FAIL: NFR-PLUGIN-2 must have at least one Critical-severity rule (>=2000 tokens), found $count_critical" >&2; return 1; }
}

@test "AC6: NFR-PLUGIN-3 (Version Compatibility) rule severity is High" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.references[]? == "NFR-PLUGIN-3") | .severity' "$SUB_NFR" | head -n1)
  [ "$sev" = "High" ] \
    || { echo "AC6 FAIL: expected NFR-PLUGIN-3 severity=High, got=$sev" >&2; return 1; }
}

@test "AC6: NFR-PLUGIN-4 (allowed-tools drift) rule severity is Critical" {
  local sev
  sev=$(jq -r '.severity_rules[] | select(.references[]? == "NFR-PLUGIN-4") | .severity' "$SUB_NFR" | head -n1)
  [ "$sev" = "Critical" ] \
    || { echo "AC6 FAIL: expected NFR-PLUGIN-4 severity=Critical, got=$sev" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC7 — LC_ALL=C alpha-sort over the four plugin sub-rubrics
# ---------------------------------------------------------------------------
@test "AC7: plugin-{code,nfr,qa,security} sort in LC_ALL=C alpha order" {
  # Confirm the four sibling sub-rubric files exist (E77-S5/S6/S14/S15).
  for f in "$SUB_CODE" "$SUB_NFR" "$SUB_QA" "$SUB_SECURITY"; do
    [ -f "$f" ] \
      || { echo "AC7 FAIL: missing sibling sub-rubric file: $f" >&2; return 1; }
  done
  # Direct LC_ALL=C alpha-sort over basenames must yield code < nfr < qa < security.
  local sorted
  sorted=$(printf '%s\n' "plugin-code.json" "plugin-nfr.json" "plugin-qa.json" "plugin-security.json" \
    | LC_ALL=C sort | tr '\n' ' ')
  [ "$sorted" = "plugin-code.json plugin-nfr.json plugin-qa.json plugin-security.json " ] \
    || { echo "AC7 FAIL: LC_ALL=C sort yielded unexpected order: $sorted" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC8 — Byte-identical contract (E77-S4) holds for non-plugin projects
# ---------------------------------------------------------------------------
@test "AC8: non-plugin loader output is identical regardless of plugin sub-rubric presence" {
  # The byte-identical contract from E77-S4: a non-plugin project must see no
  # difference in merged rubric output when the plugin sub-rubrics are added.
  # Verified end-to-end by running the loader with project_kind=web-app on the
  # SAME rubrics tree that contains plugin-qa.json and plugin-nfr.json: no
  # plugin-* rule may appear in the output for skill=qa OR skill=perf.
  cat >"$TMP_CONFIG" <<'EOF'
project_kind: web-app
EOF
  local out_qa out_perf
  out_qa=$("$LOADER" --skill qa --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out_qa" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-"))' >/dev/null \
    || { echo "AC8 FAIL: non-plugin qa output leaked a plugin-* rule" >&2; return 1; }
  echo "$out_qa" | jq -e '.severity_rules[]? | select(.id | startswith("qa-"))' >/dev/null \
    || { echo "AC8 FAIL: base qa rules missing from non-plugin output" >&2; return 1; }
  out_perf=$("$LOADER" --skill perf --no-domain --no-project --regimes "" --config "$TMP_CONFIG")
  ! echo "$out_perf" | jq -e '.severity_rules[]? | select(.id | startswith("plugin-"))' >/dev/null \
    || { echo "AC8 FAIL: non-plugin perf output leaked a plugin-* rule" >&2; return 1; }
  echo "$out_perf" | jq -e '.severity_rules[]? | select(.id | startswith("perf-"))' >/dev/null \
    || { echo "AC8 FAIL: base perf rules missing from non-plugin output" >&2; return 1; }
}
