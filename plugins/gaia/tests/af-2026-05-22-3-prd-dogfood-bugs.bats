#!/usr/bin/env bats
# AF-2026-05-22-3: bundled fix for 5 PRD-dogfooding bugs.
#
# Bug 1: orchestration prelude awk eaten by Claude Code's $N interpolation
#        (42 SKILL.md files swept; awk replaced with sed sub).
# Bug 2: gaia-init SKILL.md says config/project-config.yaml; generate-config.sh
#        writes to .gaia/config/project-config.yaml (post-ADR-111 canonical).
# Bug 3: prd-template H2 numeric prefixes (## 1. Overview) broke finalize.sh
#        heading_present grep (now tolerates the numeric outline prefix).
# Bug 4: prd-template missing 5 sections required by the checklist (User
#        Journeys, Data Requirements, Integration Requirements, Constraints,
#        Success Criteria).
# Bug 5: gaia-create-ux finalize SV-01 display string hard-coded the legacy
#        docs/ path.
# Minor: 25 SKILL.md files used relative !scripts/write-checkpoint.sh.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- Bug 1: sentinel awk fix (no $N tokens) ---

@test "gaia-init prelude uses sed (no \$N token vulnerable to Claude Code interpolation)" {
  grep -qF "sed -n 's/^SURFACE-WARNING: //p'" "$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
  ! grep -qF "awk '/^SURFACE-WARNING: /{print" "$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
}

@test "gaia-create-prd prelude uses sed (no \$N)" {
  grep -qF "sed -n 's/^SURFACE-WARNING: //p'" "$PLUGIN_ROOT/skills/gaia-create-prd/SKILL.md"
}

@test "framework-wide — zero SKILL.md files still use the broken awk pattern (any variant)" {
  # Val F2 (AF-22-3 review): the prior fixed-grep `awk '/^SURFACE-WARNING:` missed
  # the `awk -F': '` variant in gaia-sprint-review/SKILL.md. Use a broader regex
  # that tolerates ANY awk flags between `awk` and the SURFACE-WARNING pattern.
  ! grep -rqE "awk[[:space:]].*SURFACE-WARNING" "$PLUGIN_ROOT/skills/" 2>/dev/null
}

@test "sed extraction produces the bare path (no SURFACE-WARNING: prefix)" {
  local result
  result=$(printf 'SURFACE-WARNING: /tmp/path/to/sentinel.txt\n' | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  [ "$result" = "/tmp/path/to/sentinel.txt" ]
}

# --- Bug 2: gaia-init config path canonical ---

@test "gaia-init SKILL.md references canonical .gaia/config/project-config.yaml" {
  ! grep -qE "(^|[^.])config/project-config\.yaml" "$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
  grep -qF ".gaia/config/project-config.yaml" "$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
}

@test "generate-config.sh writes to .gaia/config/ (canonical agreement)" {
  grep -qF 'cfg_path="$target/.gaia/config/project-config.yaml"' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}

# --- Bug 3: heading_present tolerates numeric outline prefix ---

@test "prd-template H2s use numeric outline prefix (## 1. Overview, etc.)" {
  grep -qE '^## 1\. Overview' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
  grep -qE '^## 2\. Goals and Non-Goals' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
}

@test "finalize.sh heading_present regex accepts numeric outline prefix" {
  grep -qF '[0-9]+(\.[0-9]+)*\.?' "$PLUGIN_ROOT/skills/gaia-create-prd/scripts/finalize.sh"
}

# --- Bug 4: prd-template has all 12 checklist sections ---

@test "prd-template has User Journeys section" {
  grep -qE '^##[[:space:]]+[0-9]+\.[[:space:]]+User Journeys' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
}

@test "prd-template has Data Requirements section" {
  grep -qE '^##[[:space:]]+[0-9]+\.[[:space:]]+Data Requirements' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
}

@test "prd-template has Integration Requirements section" {
  grep -qE '^##[[:space:]]+[0-9]+\.[[:space:]]+Integration Requirements' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
}

@test "prd-template has Constraints section" {
  grep -qE '^##[[:space:]]+[0-9]+\.[[:space:]]+Constraints' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
}

@test "prd-template has Success Criteria section" {
  grep -qE '^##[[:space:]]+[0-9]+\.[[:space:]]+Success Criteria' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
}

@test "prd-template now satisfies all 12 .. heading_present checks against the framework's own finalize.sh" {
  # End-to-end: simulate the finalize.sh regex against the template for every
  # checklist H2 the script greps for. None may fail.
  local heading
  for heading in "Overview" "Goals" "User Stories" "Functional Requirements" "Non-Functional Requirements" "User Journeys" "Data Requirements" "Integration Requirements" "Out of Scope" "Constraints" "Success Criteria" "Dependencies"; do
    grep -Ei "^##[[:space:]]+([0-9]+(\.[0-9]+)*\.?[[:space:]]+)?${heading}([[:space:]]|\$|[[:punct:]])" \
      "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md" >/dev/null \
      || { echo "FAIL: section '${heading}' not found in prd-template.md" >&2; return 1; }
  done
}

# --- Bug 5: gaia-create-ux SV-01 display string ---

@test "gaia-create-ux finalize uses resolved-path display (not hard-coded docs/)" {
  grep -qF 'item_check "SV-01" "Output file exists at resolved path' "$PLUGIN_ROOT/skills/gaia-create-ux/scripts/finalize.sh"
  ! grep -qF '"Output file exists at docs/planning-artifacts/ux-design.md"' "$PLUGIN_ROOT/skills/gaia-create-ux/scripts/finalize.sh"
}

# --- Minor: relative checkpoint path → ${CLAUDE_PLUGIN_ROOT} ---

@test "minor: zero SKILL.md files use the bare relative !scripts/write-checkpoint.sh path" {
  # Match the BARE relative form only — !scripts/... NOT preceded by ${CLAUDE_PLUGIN_ROOT}/
  # Use a negative-lookahead-style check: find any `!scripts/write-checkpoint` then verify
  # none of those hits are bare (i.e., none lack the ${CLAUDE_PLUGIN_ROOT} prefix on the same line).
  ! grep -rqE '[^/]!scripts/write-checkpoint\.sh\b' "$PLUGIN_ROOT/skills/" 2>/dev/null
}

@test "minor: checkpoint dispatches now use \${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh" {
  # At least one occurrence should exist (sample: gaia-init Step 4 writes a checkpoint).
  grep -rqF '!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh' "$PLUGIN_ROOT/skills/"
}
