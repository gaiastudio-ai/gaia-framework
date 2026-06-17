#!/usr/bin/env bats
# e44-s12-phase1-document-rulesets.bats — E44-S12 acceptance coverage.
#
# Asserts the canonical document-rulesets for the four Phase 1 artifact
# types (brainstorm, market-research, domain-research, technical-research)
# are registered in gaia-document-rulesets/SKILL.md and surfaced in
# gaia-val-validate/SKILL.md Step 2 type-detection.
#
# Test strategy: the rulesets are prose contracts consumed JIT by Val.
# Bats coverage asserts the SECTION markers, the slug-to-ruleset mapping,
# and the positive/negative fixture invariants per artifact type. Per the
# story Critical Rules guidance we use grep -F (fixed strings) to keep
# the patterns portable between BSD grep (macOS) and GNU grep (Linux CI).
#
# AC mapping:
# - AC1 (structural validation runs): slug-mapping table presence, Step 2
#   slug-precedence wording.
# - AC2 (CRITICAL/WARNING on missing required section): each ruleset
#   declares CRITICAL or WARNING severity for missing sections.
# - AC3 (sections, frontmatter, traceability): each ruleset declares
#   Required Sections + traceability References footer.
# - AC4 (positive + negative bats per artifact type): four positive +
#   four negative fixture-shape assertions below.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILLS_DIR="$BATS_TEST_DIRNAME/../skills"
RULESETS_MD="$SKILLS_DIR/gaia-document-rulesets/SKILL.md"
VAL_VALIDATE_MD="$SKILLS_DIR/gaia-val-validate/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# -------------------------------------------------------------------------
# AC1 / AC3 — SECTION markers exist for each Phase 1 artifact type.
# -------------------------------------------------------------------------

@test "brainstorm-rules SECTION marker is present in document-rulesets" {
  run grep -F -- "<!-- SECTION: brainstorm-rules -->" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "market-research-rules SECTION marker is present in document-rulesets" {
  run grep -F -- "<!-- SECTION: market-research-rules -->" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "domain-research-rules SECTION marker is present in document-rulesets" {
  run grep -F -- "<!-- SECTION: domain-research-rules -->" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "technical-research-rules SECTION marker is present in document-rulesets" {
  run grep -F -- "<!-- SECTION: technical-research-rules -->" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC1 — sections frontmatter list includes all four Phase 1 ruleset IDs.
# -------------------------------------------------------------------------

@test "sections frontmatter lists brainstorm-rules" {
  run grep -F -- "brainstorm-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "sections frontmatter lists market-research-rules" {
  run grep -F -- "market-research-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "sections frontmatter lists domain-research-rules" {
  run grep -F -- "domain-research-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "sections frontmatter lists technical-research-rules" {
  run grep -F -- "technical-research-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC1 — Artifact-Type Slug Mapping table exists with all four Phase 1 slugs.
# -------------------------------------------------------------------------

@test "Artifact-Type Slug Mapping section is documented" {
  run grep -F -- "Artifact-Type Slug Mapping" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "slug map declares brainstorm -> brainstorm-rules" {
  run grep -F -- "| \`brainstorm\` | brainstorm-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "slug map declares market-research -> market-research-rules" {
  run grep -F -- "| \`market-research\` | market-research-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "slug map declares domain-research -> domain-research-rules" {
  run grep -F -- "| \`domain-research\` | domain-research-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "slug map declares technical-research -> technical-research-rules" {
  run grep -F -- "| \`technical-research\` | technical-research-rules" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC1 — gaia-val-validate Step 2 references the slug precedence and the
# four Phase 1 types so structural validation actually runs (not just
# factual-claim).
# -------------------------------------------------------------------------

@test "val-validate Step 2 documents Upstream artifact_type slug precedence" {
  run grep -F -- "Upstream \`artifact_type\` slug" "$VAL_VALIDATE_MD"
  [ "$status" -eq 0 ]
}

@test "val-validate enum lists brainstorm" {
  run grep -F -- "\`brainstorm\`" "$VAL_VALIDATE_MD"
  [ "$status" -eq 0 ]
}

@test "val-validate enum lists market-research" {
  run grep -F -- "\`market-research\`" "$VAL_VALIDATE_MD"
  [ "$status" -eq 0 ]
}

@test "val-validate enum lists domain-research" {
  run grep -F -- "\`domain-research\`" "$VAL_VALIDATE_MD"
  [ "$status" -eq 0 ]
}

@test "val-validate enum lists technical-research" {
  run grep -F -- "\`technical-research\`" "$VAL_VALIDATE_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC2 — each Phase 1 ruleset declares at least one CRITICAL or WARNING
# severity classification (so missing required sections produce findings,
# not silent passes).
# -------------------------------------------------------------------------

@test "brainstorm-rules section declares severity classifications" {
  run awk '
    /<!-- SECTION: brainstorm-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0 }
    in_section && (/CRITICAL/ || /WARNING/) { count++ }
    END { print count + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "market-research-rules section declares severity classifications" {
  run awk '
    /<!-- SECTION: market-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0 }
    in_section && (/CRITICAL/ || /WARNING/) { count++ }
    END { print count + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "domain-research-rules section declares severity classifications" {
  run awk '
    /<!-- SECTION: domain-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0 }
    in_section && (/CRITICAL/ || /WARNING/) { count++ }
    END { print count + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "technical-research-rules section declares severity classifications" {
  run awk '
    /<!-- SECTION: technical-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0 }
    in_section && (/CRITICAL/ || /WARNING/) { count++ }
    END { print count + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

# -------------------------------------------------------------------------
# AC3 — each Phase 1 ruleset declares Required Sections AND a References
# footer (traceability hook back to E42 / E44 stories).
# -------------------------------------------------------------------------

@test "brainstorm-rules declares Required Sections" {
  run awk '
    /<!-- SECTION: brainstorm-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /^### Required Sections/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "market-research-rules declares Required Sections" {
  run awk '
    /<!-- SECTION: market-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /^### Required Sections/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "domain-research-rules declares Required Sections" {
  run awk '
    /<!-- SECTION: domain-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /^### Required Sections/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "technical-research-rules declares Required Sections" {
  run awk '
    /<!-- SECTION: technical-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /^### Required Sections/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "brainstorm-rules declares References footer" {
  run awk '
    /<!-- SECTION: brainstorm-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /\*\*References:\*\*/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "market-research-rules declares References footer" {
  run awk '
    /<!-- SECTION: market-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /\*\*References:\*\*/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "domain-research-rules declares References footer" {
  run awk '
    /<!-- SECTION: domain-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /\*\*References:\*\*/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "technical-research-rules declares References footer" {
  run awk '
    /<!-- SECTION: technical-research-rules -->/ { in_section = 1; next }
    in_section && /<!-- END SECTION -->/ { in_section = 0; exit }
    in_section && /\*\*References:\*\*/ { found = 1 }
    END { print found + 0 }
  ' "$RULESETS_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# -------------------------------------------------------------------------
# AC4 — positive fixtures contain every Required Section the ruleset
# declares (proxy assertion that the ruleset is self-consistent with the
# canonical artifact shape).
# -------------------------------------------------------------------------

@test "positive: brainstorm-complete fixture contains all required sections" {
  local fixture="$FIXTURES/brainstorm-complete.md"
  for section in "## Vision Summary" "## Target Users" "## Pain Points" \
                 "## Differentiators" "## Competitive Landscape" \
                 "## Opportunity Areas" "## Parking Lot" "## Next Steps"; do
    grep -F -- "$section" "$fixture" >/dev/null || {
      echo "missing in fixture: $section" >&2
      return 1
    }
  done
}

@test "positive: market-research-complete fixture contains all required sections" {
  local fixture="$FIXTURES/market-research-complete.md"
  for section in "## Executive Summary" "## Market Definition" \
                 "## Competitive Analysis" "## Customer Segments" \
                 "## Market Sizing" "## Key Findings" \
                 "## Strategic Recommendations"; do
    grep -F -- "$section" "$fixture" >/dev/null || {
      echo "missing in fixture: $section" >&2
      return 1
    }
  done
}

@test "positive: domain-research-complete fixture contains all required sections" {
  local fixture="$FIXTURES/domain-research-complete.md"
  for section in "## Domain Overview" "## Key Players" \
                 "## Regulatory Landscape" "## Trends" \
                 "## Terminology Glossary" "## Risk Assessment" \
                 "## Recommendations"; do
    grep -F -- "$section" "$fixture" >/dev/null || {
      echo "missing in fixture: $section" >&2
      return 1
    }
  done
}

@test "positive: tech-research-complete fixture contains all required sections" {
  local fixture="$FIXTURES/tech-research-complete.md"
  for section in "## Technology Overview" "## Evaluation Matrix" \
                 "## Trade-off Analysis" "## Recommendation" \
                 "## Migration / Adoption Considerations"; do
    grep -F -- "$section" "$fixture" >/dev/null || {
      echo "missing in fixture: $section" >&2
      return 1
    }
  done
}

# -------------------------------------------------------------------------
# AC4 — negative fixtures intentionally omit the section that drives the
# CRITICAL gate per ruleset. These assertions document the contract:
# the negative fixture is the witness for the ruleset's CRITICAL finding.
# -------------------------------------------------------------------------

@test "negative: brainstorm-missing-opportunities fixture has fewer than 3 opportunities" {
  local fixture="$FIXTURES/brainstorm-missing-opportunities.md"
  run awk '
    /^## Opportunity Areas/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^[0-9]+\./ { count++ }
    END { print count + 0 }
  ' "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" -lt 3 ]
}

@test "negative: market-research-missing-tam-assumptions fixture omits TAM assumptions" {
  local fixture="$FIXTURES/market-research-missing-tam-assumptions.md"
  run grep -F -- "TAM assumptions" "$fixture"
  [ "$status" -ne 0 ]
}

@test "negative: domain-research-missing-glossary fixture omits Terminology Glossary header" {
  # The fixture's leading > comment intentionally NAMES the omitted section
  # for debuggability. Assert that no real H2 heading exists — line begins
  # with "## " and the rest is exactly "Terminology Glossary".
  local fixture="$FIXTURES/domain-research-missing-glossary.md"
  run awk '
    /^## Terminology Glossary[[:space:]]*$/ { found = 1 }
    END { print found + 0 }
  ' "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "negative: tech-research-missing-alternatives fixture compares only one alternative" {
  local fixture="$FIXTURES/tech-research-missing-alternatives.md"
  run awk '
    /^## Trade-off Analysis/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^\*\*[A-Za-z][A-Za-z0-9 ]* — Pros\*\*/ { count++ }
    END { print count + 0 }
  ' "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" -lt 2 ]
}

# -------------------------------------------------------------------------
# Non-regression: pre-existing rulesets survive E44-S12 edits.
# -------------------------------------------------------------------------

@test "Non-regression: prd-rules SECTION marker still present" {
  run grep -F -- "<!-- SECTION: prd-rules -->" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "Non-regression: arch-rules SECTION marker still present" {
  run grep -F -- "<!-- SECTION: arch-rules -->" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}

@test "Non-regression: two-pass-logic SECTION marker still present" {
  run grep -F -- "<!-- SECTION: two-pass-logic -->" "$RULESETS_MD"
  [ "$status" -eq 0 ]
}
