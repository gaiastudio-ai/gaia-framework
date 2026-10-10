#!/usr/bin/env bats
# design-lifecycle-docs.bats — assert that design lifecycle documentation
# exists, covers all seven stages, carries no leaked identifiers, and is
# wired into the doc-site index and lifecycle diagram.
#
# No project-root .gaia/ access; all fixtures use mktemp.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOC_DIR="$PLUGIN_ROOT/../../documentation"
  DOC_DIR="$(cd "$DOC_DIR" 2>/dev/null && pwd)" || DOC_DIR="$BATS_TEST_DIRNAME/../../documentation"
  # SKILL.md paths for dual-side content assertions (doc page + skill source).
  SKILL_CUX="$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  SKILL_EUX="$PLUGIN_ROOT/skills/gaia-edit-ux/SKILL.md"
  SKILL_DR="$PLUGIN_ROOT/skills/gaia-design-review/SKILL.md"
  SKILL_AF="$PLUGIN_ROOT/skills/gaia-add-feature/SKILL.md"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Leaked-identifier regex — same families as the repo-wide gates.
# ---------------------------------------------------------------------------
_leak_regex() {
  printf '%s' 'FR-[0-9]+|NFR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-|SR-[0-9]+|(AF|AI)-[0-9]{4}|T-DPS-[0-9]+|GitHub #[0-9]+|(^|[^A-Za-z0-9])(T|F)-[0-9]+([^0-9]|$)'
}

# Pinned sidebar links: the 43 unique hrefs in index.html before this story.
# Duplicate occurrences of the same href are collapsed (the sidebar repeats
# some links in multiple navigation sections). Only unique hrefs are pinned.
SIDEBAR_BASELINE=(
  bridge.html
  categories/configuration.html
  categories/creative.html
  categories/deployment.html
  categories/development.html
  categories/discovery-research.html
  categories/documentation.html
  categories/getting-started.html
  categories/internal.html
  categories/planning.html
  categories/reviews.html
  categories/sprint-management.html
  categories/testing.html
  categories/validation.html
  commands/gaia-atdd.html
  commands/gaia-brainstorm.html
  commands/gaia-create-arch.html
  commands/gaia-create-epics.html
  commands/gaia-create-prd.html
  commands/gaia-create-ux.html
  commands/gaia-deploy-checklist.html
  commands/gaia-deploy-post.html
  commands/gaia-deploy.html
  commands/gaia-dev-story.html
  commands/gaia-domain-research.html
  commands/gaia-infra-design.html
  commands/gaia-market-research.html
  commands/gaia-product-brief.html
  commands/gaia-release-plan.html
  commands/gaia-review-all.html
  commands/gaia-sprint-close.html
  commands/gaia-sprint-plan.html
  commands/gaia-sprint-review.html
  commands/gaia-tech-research.html
  commands/gaia-threat-model.html
  commands/gaia-trace.html
  commands/gaia-val-validate.html
  format-contracts.html
  gaia-brain.html
  gaia-run-sprint.html
  glossary.html
  index.html
  lifecycle-diagram.html
  mode-b.html
  recipes.html
  test-environment-yaml.html
  troubleshooting.html
  tutorials/automated-versioning-and-deploy.html
  tutorials/ci-scenarios-by-team-size.html
  tutorials/configuring-ci-pipelines.html
  tutorials/environments-and-promotion.html
  tutorials/first-30-minutes-brownfield.html
  tutorials/first-30-minutes.html
  tutorials/phase-5-for-non-deployable-projects.html
  tutorials/project-shapes-overview.html
  tutorials/shape-cli.html
  tutorials/shape-container-image.html
  tutorials/shape-fullstack.html
  tutorials/shape-library.html
  tutorials/shape-microservices.html
  tutorials/shape-mobile-app.html
  tutorials/shape-plugin.html
  tutorials/shape-single-repo.html
  tutorials/shape-static-site.html
  tutorials/test-strategy-configuration.html
)

# ===========================================================================
# T5.1: design lifecycle page exists and is non-empty
# ===========================================================================

@test "design lifecycle page exists and is non-empty" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: documentation/design-lifecycle.html missing or empty" >&2
    return 1
  }
}

# ===========================================================================
# T5.2-T5.8: page covers each of the seven lifecycle stages
# ===========================================================================

@test "page covers discovery stage" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  grep -qi 'discovery' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'discovery'" >&2
    return 1
  }
}

@test "page covers questionnaire stage" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  grep -qi 'questionnaire' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'questionnaire'" >&2
    return 1
  }
}

@test "page covers publication stage" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  grep -qi 'publi' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'publish' or 'publication'" >&2
    return 1
  }
}

@test "page covers review stage" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  grep -qi 'review' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'review'" >&2
    return 1
  }
}

@test "page covers approval stage" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  grep -qiE 'approv(al|ed)' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'approval' or 'approved'" >&2
    return 1
  }
}

@test "page covers gate and override stage" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  grep -qi 'gate' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'gate'" >&2
    return 1
  }
  grep -qiE 'override|force-design' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'override' or 'force-design'" >&2
    return 1
  }
}

@test "page covers stale-on-change stage" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  grep -qi 'stale' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: design-lifecycle.html does not mention 'stale'" >&2
    return 1
  }
}

# ===========================================================================
# T5.9-T5.11: leaked-identifier gates on published pages
# ===========================================================================

@test "no internal identifier in design-lifecycle page" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: design-lifecycle.html missing" >&2; return 1
  }
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/design-lifecycle.html" || true)"
  # Strip regex character-class lines (e.g. E[0-9]+ as a matching pattern)
  hits="$(echo "$hits" | grep -vE '\[0-9\]' || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in design-lifecycle.html:" >&2
    echo "$hits" >&2
    return 1
  }
}

@test "no internal identifier in lifecycle-diagram changes" {
  [ -f "$DOC_DIR/lifecycle-diagram.html" ] || {
    echo "FAIL: lifecycle-diagram.html not found" >&2; return 1
  }
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/lifecycle-diagram.html" || true)"
  hits="$(echo "$hits" | grep -vE '\[0-9\]' || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in lifecycle-diagram.html:" >&2
    echo "$hits" >&2
    return 1
  }
}

@test "no internal identifier in design-review command page" {
  [ -f "$DOC_DIR/commands/gaia-design-review.html" ] || {
    echo "FAIL: commands/gaia-design-review.html not found" >&2; return 1
  }
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-design-review.html" || true)"
  hits="$(echo "$hits" | grep -vE '\[0-9\]' || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in commands/gaia-design-review.html:" >&2
    echo "$hits" >&2
    return 1
  }
}

# ===========================================================================
# T5.12: lifecycle-diagram shows gate between UX and solutioning
# ===========================================================================

@test "lifecycle-diagram shows gate between UX and solutioning" {
  [ -f "$DOC_DIR/lifecycle-diagram.html" ] || {
    echo "FAIL: lifecycle-diagram.html not found" >&2; return 1
  }
  # The gate node should appear after validate-design-a11y and before the
  # phase 3 solutioning header. Extract the line numbers.
  local a11y_line gate_line phase3_line
  a11y_line="$(grep -n 'validate-design-a11y' "$DOC_DIR/lifecycle-diagram.html" | head -1 | cut -d: -f1 || true)"
  gate_line="$(grep -nE 'design-review|design-approval' "$DOC_DIR/lifecycle-diagram.html" | head -1 | cut -d: -f1 || true)"
  phase3_line="$(grep -n 'ld-phase--3' "$DOC_DIR/lifecycle-diagram.html" | head -1 | cut -d: -f1 || true)"

  [ -n "$gate_line" ] || {
    echo "FAIL: no design gate node found in lifecycle-diagram.html" >&2
    return 1
  }
  [ -n "$a11y_line" ] || {
    echo "FAIL: validate-design-a11y not found in lifecycle-diagram.html" >&2
    return 1
  }
  [ -n "$phase3_line" ] || {
    echo "FAIL: phase 3 header not found in lifecycle-diagram.html" >&2
    return 1
  }
  [ "$gate_line" -gt "$a11y_line" ] || {
    echo "FAIL: gate node (line $gate_line) should be after validate-design-a11y (line $a11y_line)" >&2
    return 1
  }
  [ "$gate_line" -lt "$phase3_line" ] || {
    echo "FAIL: gate node (line $gate_line) should be before phase 3 header (line $phase3_line)" >&2
    return 1
  }
}

# ===========================================================================
# T5.13: lifecycle-diagram gate node uses ld-node--gate class
# ===========================================================================

@test "lifecycle-diagram gate node uses ld-node--gate class" {
  [ -f "$DOC_DIR/lifecycle-diagram.html" ] || {
    echo "FAIL: lifecycle-diagram.html not found" >&2; return 1
  }
  # The design-review/design-approval gate element should have ld-node--gate
  local gate_section
  gate_section="$(grep -A2 'design-review' "$DOC_DIR/lifecycle-diagram.html" | grep 'ld-node--gate' || true)"
  if [ -z "$gate_section" ]; then
    gate_section="$(grep -A2 'design-approval' "$DOC_DIR/lifecycle-diagram.html" | grep 'ld-node--gate' || true)"
  fi
  # Also check if the line with the href itself has ld-node--gate
  local gate_inline
  gate_inline="$(grep 'design-review.*ld-node--gate' "$DOC_DIR/lifecycle-diagram.html" || true)"
  if [ -z "$gate_inline" ]; then
    gate_inline="$(grep 'ld-node--gate.*design-review' "$DOC_DIR/lifecycle-diagram.html" || true)"
  fi
  [ -n "$gate_section" ] || [ -n "$gate_inline" ] || {
    echo "FAIL: design gate node does not use ld-node--gate class" >&2
    return 1
  }
}

# ===========================================================================
# T5.14: lifecycle-diagram does not reorder existing nodes
# ===========================================================================

@test "lifecycle-diagram does not reorder existing nodes" {
  [ -f "$DOC_DIR/lifecycle-diagram.html" ] || {
    echo "FAIL: lifecycle-diagram.html not found" >&2; return 1
  }
  # Extract the command references in order from the diagram
  local current_cmds
  current_cmds="$(grep -oE '/gaia-[a-z0-9-]+' "$DOC_DIR/lifecycle-diagram.html" | awk '!seen[$0]++' )"
  # The baseline order (unique, first occurrence) of pre-existing commands
  # extracted via: grep -oE '/gaia-[a-z0-9-]+' lifecycle-diagram.html | awk '!seen[$0]++'
  # Every pre-existing command must appear in the same relative order.
  local baseline_cmds
  baseline_cmds=$(cat <<'CMDS_END'
/gaia-init
/gaia-brownfield
/gaia-discover
/gaia-add-feature
/gaia-quick-spec
/gaia-resume
/gaia-val-validate
/gaia-val-validate-plan
/gaia-val-save
/gaia-refresh-ground-truth
/gaia-brainstorm
/gaia-market-research
/gaia-domain-research
/gaia-tech-research
/gaia-advanced-elicitation
/gaia-product-brief
/gaia-create-prd
/gaia-adversarial
/gaia-edit-prd
/gaia-create-ux
/gaia-validate-design-a11y
/gaia-create-arch
/gaia-review-api
/gaia-edit-arch
/gaia-test-strategy
/gaia-create-epics
/gaia-atdd
/gaia-create-story
/gaia-threat-model
/gaia-infra-design
/gaia-trace
/gaia-ci-setup
/gaia-readiness-check
/gaia-validate-story
/gaia-fix-story
/gaia-sprint-plan
/gaia-dev-story
/gaia-check-dod
/gaia-review-all
/gaia-check-review-gate
/gaia-sprint-status
/gaia-epic-status
/gaia-correct-course
/gaia-add-stories
/gaia-triage-findings
/gaia-retro
/gaia-action-items
/gaia-release-plan
/gaia-rollback-plan
/gaia-deploy-checklist
/gaia-deploy
/gaia-deploy-post
CMDS_END
)
  local prev_idx=-1
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    local idx=0 found=false
    while IFS= read -r ccmd; do
      if [ "$ccmd" = "$cmd" ]; then
        found=true
        break
      fi
      idx=$((idx + 1))
    done <<< "$current_cmds"
    if ! $found; then
      echo "FAIL: baseline command '$cmd' missing from lifecycle-diagram" >&2
      return 1
    fi
    if [ "$idx" -le "$prev_idx" ]; then
      echo "FAIL: baseline command '$cmd' out of order (idx $idx <= prev $prev_idx)" >&2
      return 1
    fi
    prev_idx=$idx
  done <<< "$baseline_cmds"
}

# ===========================================================================
# T5.15: design-review command page links to design-lifecycle page
# ===========================================================================

@test "design-review command page links to design-lifecycle page" {
  [ -f "$DOC_DIR/commands/gaia-design-review.html" ] || {
    echo "FAIL: commands/gaia-design-review.html not found" >&2; return 1
  }
  grep -q 'design-lifecycle\.html' "$DOC_DIR/commands/gaia-design-review.html" || {
    echo "FAIL: commands/gaia-design-review.html does not link to design-lifecycle.html" >&2
    return 1
  }
}

# ===========================================================================
# T5.16: index.html sidebar contains design-lifecycle.html link
# ===========================================================================

@test "index.html sidebar contains design-lifecycle.html link" {
  [ -f "$DOC_DIR/index.html" ] || {
    echo "FAIL: documentation/index.html not found" >&2; return 1
  }
  grep -q 'href="design-lifecycle\.html"' "$DOC_DIR/index.html" || {
    echo "FAIL: index.html sidebar does not link to design-lifecycle.html" >&2
    return 1
  }
}

# ===========================================================================
# T5.17: index.html sidebar preserves pre-existing entries
# ===========================================================================

@test "index.html sidebar preserves pre-existing entries" {
  [ -f "$DOC_DIR/index.html" ] || {
    echo "FAIL: documentation/index.html not found" >&2; return 1
  }
  # Extract all unique href values from the current index
  local current_hrefs
  current_hrefs="$(grep -oE 'href="[^"]*\.html"' "$DOC_DIR/index.html" | sed 's/href="//;s/"//' | sort -u)"

  local missing=0
  for href in "${SIDEBAR_BASELINE[@]}"; do
    if ! grep -qxF "$href" <<<"$current_hrefs"; then
      echo "MISSING: pre-existing sidebar link '$href'" >&2
      missing=$((missing + 1))
    fi
  done

  [ "$missing" -eq 0 ] || {
    echo "FAIL: $missing pre-existing sidebar link(s) missing from index.html" >&2
    return 1
  }
}

# =========================================================================
# Stale-on-change wording (design-lifecycle.html)
# =========================================================================

@test "design-lifecycle.html does not claim the diagnostic names the triggering change" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || {
    echo "FAIL: design-lifecycle.html missing or empty" >&2; return 1
  }

  # The old wording claimed the diagnostic "names the change" — must be gone
  if grep -qi 'names the change' "$page"; then
    echo "FAIL: design-lifecycle.html still claims the diagnostic names the change that triggered stale" >&2
    return 1
  fi

  # The replacement wording must be present
  grep -qi 're-approved.*review round\|same halt.*non-approved' "$page" || {
    echo "FAIL: design-lifecycle.html should carry the replacement wording about re-approval through a review round" >&2
    return 1
  }
}

# =========================================================================
# (AC1) gaia-dev-story.html documents the override notice
# =========================================================================

@test "(AC1) gaia-dev-story.html documents the override notice" {
  local page="$DOC_DIR/commands/gaia-dev-story.html"
  [ -s "$page" ] || {
    echo "FAIL: gaia-dev-story.html missing or empty" >&2; return 1
  }

  grep -qi 'override' "$page" || {
    echo "FAIL: gaia-dev-story.html should mention 'override'" >&2; return 1
  }
  grep -qiE 'notice|design.state' "$page" || {
    echo "FAIL: gaia-dev-story.html should mention override notice or design state" >&2; return 1
  }
}

# =========================================================================
# (AC2) design-lifecycle.html documents the sprint scope in overrides
# =========================================================================

@test "(AC2) design-lifecycle.html documents the sprint scope in overrides" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || {
    echo "FAIL: design-lifecycle.html missing or empty" >&2; return 1
  }

  grep -qi 'override' "$page" || {
    echo "FAIL: design-lifecycle.html should mention 'override'" >&2; return 1
  }
  grep -qiE 'sprint.scope|sprint_id' "$page" || {
    echo "FAIL: design-lifecycle.html should mention sprint scope or sprint_id in overrides" >&2; return 1
  }
}

# =========================================================================
# (AC1) design-lifecycle.html documents the override notice
# =========================================================================

@test "(AC1) design-lifecycle.html documents the override notice" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || {
    echo "FAIL: design-lifecycle.html missing or empty" >&2; return 1
  }

  grep -qi 'override' "$page" || {
    echo "FAIL: design-lifecycle.html should mention 'override'" >&2; return 1
  }
  grep -qiE 'notice|surfaced' "$page" || {
    echo "FAIL: design-lifecycle.html should mention override notice being surfaced" >&2; return 1
  }
}


# =========================================================================
# Fail-closed approval gate — doc sync
# =========================================================================

@test "(AC3) gaia-design-review.html troubleshooting names both roster locations and /gaia-create-stakeholder" {
  local page="$DOC_DIR/commands/gaia-design-review.html"
  [ -s "$page" ] || {
    echo "FAIL: gaia-design-review.html missing or empty" >&2; return 1
  }

  grep -qF '.gaia/custom/stakeholders' "$page" || {
    echo "FAIL: gaia-design-review.html should name .gaia/custom/stakeholders/ roster location" >&2; return 1
  }
  # Must name the root roster location independently (not just as a substring
  # of .gaia/custom/stakeholders). Extract all custom/stakeholders occurrences
  # and verify at least one is NOT preceded by .gaia/
  local root_roster_count
  root_roster_count="$(grep -oE '([^ <>"]*custom/stakeholders)' "$page" | grep -vcF '.gaia/' || true)"
  [ "$root_roster_count" -gt 0 ] || {
    echo "FAIL: gaia-design-review.html should name root custom/stakeholders/ independently (all occurrences are under .gaia/)" >&2; return 1
  }
  grep -qF '/gaia-create-stakeholder' "$page" || {
    echo "FAIL: gaia-design-review.html should name /gaia-create-stakeholder as remediation" >&2; return 1
  }
}

@test "(AC1) design-lifecycle.html approval section names the roster requirement" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || {
    echo "FAIL: design-lifecycle.html missing or empty" >&2; return 1
  }

  # The approval section must name the roster as a requirement for convergence
  grep -qi 'roster' "$page" || {
    echo "FAIL: design-lifecycle.html should mention the stakeholder roster" >&2; return 1
  }
  grep -qF '/gaia-create-stakeholder' "$page" || {
    echo "FAIL: design-lifecycle.html should name /gaia-create-stakeholder as remediation" >&2; return 1
  }
}

# =========================================================================
# Publication manifest persistence (doc sync)
# =========================================================================

@test "(AC2) create-ux doc page describes manifest persistence after publication" {
  local page="$DOC_DIR/commands/gaia-create-ux.html"
  [ -s "$page" ] || {
    echo "FAIL: gaia-create-ux.html missing or empty" >&2; return 1
  }
  grep -qi 'manifest' "$page" || {
    echo "FAIL: gaia-create-ux.html should mention 'manifest'" >&2; return 1
  }
  grep -qiE 'persist|persisted' "$page" || {
    echo "FAIL: gaia-create-ux.html should mention manifest persistence" >&2; return 1
  }
}

@test "(AC2) design-lifecycle.html publication section describes persisted manifest" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || {
    echo "FAIL: design-lifecycle.html missing or empty" >&2; return 1
  }
  # Check the publication section for persisted-manifest or design-last-published
  local pub_section
  pub_section="$(sed -n '/<section id="publication">/,/<\/section>/p' "$page")"
  [ -n "$pub_section" ] || {
    echo "FAIL: no publication section found in design-lifecycle.html" >&2; return 1
  }
  grep -qiE 'design-last-published|persisted manifest|persist' <<<"$pub_section" || {
    echo "FAIL: publication section should describe the persisted manifest" >&2; return 1
  }
}

# =========================================================================
# Delta sync — doc page describes screen reporting
# =========================================================================

@test "(AC4) design-review doc page describes screen reporting in delta sync" {
  local doc_page="$DOC_DIR/commands/gaia-design-review.html"
  [ -s "$doc_page" ] || {
    echo "FAIL: documentation page missing or empty: $doc_page" >&2; return 1
  }

  # Extract the delta sync step-list item
  local delta_li
  delta_li="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$doc_page" \
    | sed 's/<li>/\n<li>/g' \
    | grep -i 'delta sync' \
    | head -1)"
  [ -n "$delta_li" ] || {
    echo "FAIL: no delta sync step-list item found in design-review doc page" >&2; return 1
  }

  # Must mention "screen" and "reported" (not auto-edited)
  grep -qi 'screen' <<<"$delta_li" || {
    echo "FAIL: delta sync step should mention screen changes: $delta_li" >&2; return 1
  }
  grep -qiE 'report|manual' <<<"$delta_li" || {
    echo "FAIL: delta sync step should mention that screen changes are reported: $delta_li" >&2; return 1
  }
}


@test "(AC1) create-ux Step 10 documents remote-listing hash computation from get_file" {
  local skill_md="$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  [ -s "$skill_md" ] || {
    echo "FAIL: gaia-create-ux SKILL.md missing or empty" >&2; return 1
  }
  # The Publication step block must describe sha256 hash computation from get_file
  local block
  block="$(awk '/^### Step.*Publication/{found=1} found{print} found && /^### Step/ && !/Publication/{exit}' "$skill_md")"
  [ -n "$block" ] || {
    echo "FAIL: no Publication step block in SKILL.md" >&2; return 1
  }
  grep -qiF 'sha256' <<<"$block" || {
    echo "FAIL: Publication step should mention sha256 hash computation" >&2; return 1
  }
  grep -qF 'get_file' <<<"$block" || {
    echo "FAIL: Publication step should mention get_file for hash computation" >&2; return 1
  }
}

# ===========================================================================
# Two-project model: design-lifecycle page content
# ===========================================================================

@test "design-lifecycle describes both projects and token-by-value model" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || {
    echo "FAIL: design-lifecycle.html missing or empty" >&2; return 1
  }

  # Doc-page assertions (pins create-ux SKILL.md project terms)
  grep -qi 'design-system project' "$page" || {
    echo "FAIL: design-lifecycle.html should mention 'design-system project'" >&2; return 1
  }
  grep -qi 'product design project' "$page" || {
    echo "FAIL: design-lifecycle.html should mention 'product design project'" >&2; return 1
  }
  grep -qi 'DesignSync' "$page" || {
    echo "FAIL: design-lifecycle.html should mention 'DesignSync'" >&2; return 1
  }
  grep -qi 'Design artifact' "$page" || {
    echo "FAIL: design-lifecycle.html should mention 'Design artifact' surface" >&2; return 1
  }
  grep -qiE 'token-by-value|:root\{--|CSS custom-property' "$page" || {
    echo "FAIL: design-lifecycle.html should describe the token-by-value model" >&2; return 1
  }
  grep -qi 'artifact-installed' "$page" || {
    echo "FAIL: design-lifecycle.html should mention the reserved artifact-installed mode" >&2; return 1
  }
  grep -qi 'designSystems' "$page" || {
    echo "FAIL: design-lifecycle.html should mention the designSystems canvas list" >&2; return 1
  }
  # Old single-project phrasing must be gone
  if grep -qi 'republished to the project' "$page"; then
    echo "FAIL: design-lifecycle.html still has old 'republished to the project' phrasing" >&2
    return 1
  fi

  # SKILL.md cross-checks (drift guard: if the skill drops these, docs need updating)
  [ -s "$SKILL_CUX" ] || {
    echo "FAIL: create-ux SKILL.md missing" >&2; return 1
  }
  grep -qi 'design-system project' "$SKILL_CUX" || {
    echo "FAIL: create-ux SKILL.md should mention 'design-system project'" >&2; return 1
  }
  grep -qi 'token-by-value' "$SKILL_CUX" || {
    echo "FAIL: create-ux SKILL.md should mention 'token-by-value'" >&2; return 1
  }
}

# ===========================================================================
# Two-project model: create-ux page content
# ===========================================================================

@test "create-ux page describes two-project discovery and creation" {
  local page="$DOC_DIR/commands/gaia-create-ux.html"
  [ -s "$page" ] || {
    echo "FAIL: gaia-create-ux.html missing or empty" >&2; return 1
  }

  # Doc-page assertions
  grep -qi 'design-system project' "$page" || {
    echo "FAIL: gaia-create-ux.html should mention 'design-system project'" >&2; return 1
  }
  grep -qi 'product design project' "$page" || {
    echo "FAIL: gaia-create-ux.html should mention 'product design project'" >&2; return 1
  }
  grep -qi 'questionnaire' "$page" || {
    echo "FAIL: gaia-create-ux.html should still mention 'questionnaire'" >&2; return 1
  }
  grep -qiE 'brand-style|non-React' "$page" || {
    echo "FAIL: gaia-create-ux.html should mention the brand-style or non-React path" >&2; return 1
  }

  # SKILL.md cross-checks
  [ -s "$SKILL_CUX" ] || {
    echo "FAIL: create-ux SKILL.md missing" >&2; return 1
  }
  grep -qi 'design-system project' "$SKILL_CUX" || {
    echo "FAIL: create-ux SKILL.md should mention 'design-system project'" >&2; return 1
  }
  grep -qi 'product design project' "$SKILL_CUX" || {
    echo "FAIL: create-ux SKILL.md should mention 'product design project'" >&2; return 1
  }
  grep -qi 'brand-style' "$SKILL_CUX" || {
    echo "FAIL: create-ux SKILL.md should mention 'brand-style'" >&2; return 1
  }
}

# ===========================================================================
# Two-project model: edit-ux page content
# ===========================================================================

@test "edit-ux page describes scope-based republish routing" {
  local page="$DOC_DIR/commands/gaia-edit-ux.html"
  [ -s "$page" ] || {
    echo "FAIL: gaia-edit-ux.html missing or empty" >&2; return 1
  }

  # Doc-page assertions
  grep -qi 'design-system' "$page" || {
    echo "FAIL: gaia-edit-ux.html should mention the design-system project" >&2; return 1
  }
  grep -qi 'product design' "$page" || {
    echo "FAIL: gaia-edit-ux.html should mention the product design project" >&2; return 1
  }
  grep -qi 'republish' "$page" || {
    echo "FAIL: gaia-edit-ux.html should mention 'republish'" >&2; return 1
  }
  # The old single-project phrasing must be gone
  if grep -qi 'republished to the Claude Design project' "$page"; then
    echo "FAIL: gaia-edit-ux.html still has old single-project phrasing" >&2
    return 1
  fi

  # SKILL.md cross-checks
  [ -s "$SKILL_EUX" ] || {
    echo "FAIL: edit-ux SKILL.md missing" >&2; return 1
  }
  grep -qiE 'design.system pass|design_system' "$SKILL_EUX" || {
    echo "FAIL: edit-ux SKILL.md should mention the design-system pass" >&2; return 1
  }
  grep -qiE 'product.design pass|product_design' "$SKILL_EUX" || {
    echo "FAIL: edit-ux SKILL.md should mention the product-design pass" >&2; return 1
  }
}

# ===========================================================================
# Two-project model: design-review page content
# ===========================================================================

@test "design-review page describes two-project read-back and combined verdict" {
  local page="$DOC_DIR/commands/gaia-design-review.html"
  [ -s "$page" ] || {
    echo "FAIL: gaia-design-review.html missing or empty" >&2; return 1
  }

  # Extract the step-list section where the two-project read-back lives.
  # Scoped so existing troubleshooting/artifact-path mentions do not satisfy.
  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$page")"
  [ -n "$step_section" ] || {
    echo "FAIL: no step-list section in gaia-design-review.html" >&2; return 1
  }

  # Doc-page assertions — scoped to step-list
  grep -qi 'design-system project.*DesignSync\|DesignSync.*design-system' <<<"$step_section" || {
    echo "FAIL: step-list should mention design-system project through DesignSync" >&2; return 1
  }
  grep -qiE 'product design.*Artifact tool|Artifact tool.*product design|product design.*Design artifact|Design artifact.*product design' <<<"$step_section" || {
    echo "FAIL: step-list should mention product design project via Artifact tool or Design artifact" >&2; return 1
  }
  grep -qiE 'failure in either|either project' "$page" || {
    echo "FAIL: gaia-design-review.html should describe the combined verdict" >&2; return 1
  }
  grep -qiE 'reconciliation' "$page" || {
    echo "FAIL: gaia-design-review.html should mention token-change reconciliation" >&2; return 1
  }

  # SKILL.md cross-checks
  [ -s "$SKILL_DR" ] || {
    echo "FAIL: design-review SKILL.md missing" >&2; return 1
  }
  grep -qi 'DesignSync' "$SKILL_DR" || {
    echo "FAIL: design-review SKILL.md should mention 'DesignSync'" >&2; return 1
  }
  grep -qiE 'either project|either.*verdict' "$SKILL_DR" || {
    echo "FAIL: design-review SKILL.md should describe the combined verdict" >&2; return 1
  }
  grep -qi 'reconciliation' "$SKILL_DR" || {
    echo "FAIL: design-review SKILL.md should mention reconciliation" >&2; return 1
  }
}

# ===========================================================================
# Two-project model: design-lifecycle brand-style path and scope routing
# ===========================================================================

@test "design-lifecycle describes brand-style path and scope routing" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || {
    echo "FAIL: design-lifecycle.html missing or empty" >&2; return 1
  }

  # Doc-page assertions
  grep -qi 'brand-style' "$page" || {
    echo "FAIL: design-lifecycle.html should mention 'brand-style'" >&2; return 1
  }
  grep -qiE 'design-system.*first|design-system project.*first' "$page" || {
    echo "FAIL: design-lifecycle.html should describe design-system-first order" >&2; return 1
  }
  grep -qiE 'no screens available|no product design project' "$page" || {
    echo "FAIL: design-lifecycle.html should describe the null product-design behavior" >&2; return 1
  }
  grep -qiE 'composite|single.*gate|zero integration calls' "$page" || {
    echo "FAIL: design-lifecycle.html should describe the composite gate" >&2; return 1
  }

  # SKILL.md cross-checks
  [ -s "$SKILL_CUX" ] || {
    echo "FAIL: create-ux SKILL.md missing" >&2; return 1
  }
  grep -qi 'brand-style' "$SKILL_CUX" || {
    echo "FAIL: create-ux SKILL.md should mention 'brand-style'" >&2; return 1
  }
  [ -s "$SKILL_EUX" ] || {
    echo "FAIL: edit-ux SKILL.md missing" >&2; return 1
  }
  grep -qiE 'design-system.*first|design.system pass first' "$SKILL_EUX" || {
    echo "FAIL: edit-ux SKILL.md should describe design-system-first order" >&2; return 1
  }
  [ -s "$SKILL_DR" ] || {
    echo "FAIL: design-review SKILL.md missing" >&2; return 1
  }
  grep -qiE 'product_design_project.*null|null.*skip' "$SKILL_DR" || {
    echo "FAIL: design-review SKILL.md should describe null product-design skip" >&2; return 1
  }
}

# ===========================================================================
# Two-project model: add-feature page scope routing
# ===========================================================================

@test "add-feature page describes scope-based republish routing" {
  local page="$DOC_DIR/commands/gaia-add-feature.html"
  [ -s "$page" ] || {
    echo "FAIL: gaia-add-feature.html missing or empty" >&2; return 1
  }

  # The old single-project phrasing must be gone
  if grep -qi 'republished to the design project' "$page"; then
    echo "FAIL: gaia-add-feature.html still has old single-project phrasing" >&2
    return 1
  fi
  grep -qi 'design-system project' "$page" || {
    echo "FAIL: gaia-add-feature.html should mention 'design-system project'" >&2; return 1
  }
  grep -qi 'product design project' "$page" || {
    echo "FAIL: gaia-add-feature.html should mention 'product design project'" >&2; return 1
  }
  grep -qi 'republish' "$page" || {
    echo "FAIL: gaia-add-feature.html should mention 'republish'" >&2; return 1
  }

  # SKILL.md cross-checks
  [ -s "$SKILL_AF" ] || {
    echo "FAIL: add-feature SKILL.md missing" >&2; return 1
  }
  grep -qiE 'design_system|design-system' "$SKILL_AF" || {
    echo "FAIL: add-feature SKILL.md should mention the design-system project" >&2; return 1
  }
  grep -qiE 'product_design|product design' "$SKILL_AF" || {
    echo "FAIL: add-feature SKILL.md should mention the product design project" >&2; return 1
  }
}

# ===========================================================================
# Leaked-identifier gates: new pages
# ===========================================================================

@test "no internal identifier in create-ux command page" {
  [ -f "$DOC_DIR/commands/gaia-create-ux.html" ] || {
    echo "FAIL: commands/gaia-create-ux.html not found" >&2; return 1
  }
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-create-ux.html" || true)"
  hits="$(echo "$hits" | grep -vE '\[0-9\]' || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in commands/gaia-create-ux.html:" >&2
    echo "$hits" >&2
    return 1
  }
}

@test "no internal identifier in edit-ux command page" {
  [ -f "$DOC_DIR/commands/gaia-edit-ux.html" ] || {
    echo "FAIL: commands/gaia-edit-ux.html not found" >&2; return 1
  }
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-edit-ux.html" || true)"
  hits="$(echo "$hits" | grep -vE '\[0-9\]' || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in commands/gaia-edit-ux.html:" >&2
    echo "$hits" >&2
    return 1
  }
}

@test "no internal identifier in add-feature command page" {
  [ -f "$DOC_DIR/commands/gaia-add-feature.html" ] || {
    echo "FAIL: commands/gaia-add-feature.html not found" >&2; return 1
  }
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-add-feature.html" || true)"
  hits="$(echo "$hits" | grep -vE '\[0-9\]' || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in commands/gaia-add-feature.html:" >&2
    echo "$hits" >&2
    return 1
  }
}

# ===========================================================================
# Leaked-identifier sweep: count assertion
# ===========================================================================

@test "leak sweep scans at least five doc pages" {
  local count=0
  local f
  for f in \
    "$DOC_DIR/design-lifecycle.html" \
    "$DOC_DIR/commands/gaia-create-ux.html" \
    "$DOC_DIR/commands/gaia-edit-ux.html" \
    "$DOC_DIR/commands/gaia-design-review.html" \
    "$DOC_DIR/commands/gaia-add-feature.html"; do
    [ -f "$f" ] || {
      echo "FAIL: swept page not found: $f" >&2; return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 5 ] || {
    echo "FAIL: leak sweep scanned only $count pages (need >= 5)" >&2; return 1
  }
}

# ===========================================================================
# Leaked-identifier regex: whole-token proof for T-N and F-N
# ===========================================================================

@test "leak regex catches T-N and F-N as whole tokens" {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Positive cases: T-N and F-N at word boundaries
  cat > "$tmpdir/positive.html" <<'SEEDEOF'
found T-12
value F-3.
end T-99
F-1
SEEDEOF
  local pos_hits
  pos_hits="$(grep -cE "$(_leak_regex)" "$tmpdir/positive.html")"
  [ "$pos_hits" -ge 4 ] || {
    echo "FAIL: leak regex matched only $pos_hits of 4 seeded T-N/F-N tokens" >&2
    rm -rf "$tmpdir"
    return 1
  }

  # Negative cases: legitimate text that must NOT match the T/F branch.
  # Use a focused sub-regex to test only the T/F branch.
  local tf_regex='(^|[^A-Za-z0-9])(T|F)-[0-9]+([^0-9]|$)'
  cat > "$tmpdir/negative.html" <<'NEGEOF'
UTF-8 encoding
TF-100 combined
NEGEOF
  local neg_hits
  neg_hits="$(grep -cE "$tf_regex" "$tmpdir/negative.html" || true)"
  [ "$neg_hits" -eq 0 ] || {
    echo "FAIL: T/F regex false-positive on legitimate text ($neg_hits hits)" >&2
    rm -rf "$tmpdir"
    return 1
  }

  rm -rf "$tmpdir"
}

# ===========================================================================
# Two-project model: recipes page publication wording
# ===========================================================================

@test "recipes page describes two-project publication" {
  local page="$DOC_DIR/recipes.html"
  [ -s "$page" ] || {
    echo "FAIL: recipes.html missing or empty" >&2; return 1
  }

  # New wording must be present
  grep -qi 'design-system project' "$page" || {
    echo "FAIL: recipes.html should mention 'design-system project'" >&2; return 1
  }
  grep -qi 'product design project' "$page" || {
    echo "FAIL: recipes.html should mention 'product design project'" >&2; return 1
  }
  # Old wording must be gone
  if grep -qi 'publish them to Claude Design' "$page"; then
    echo "FAIL: recipes.html still has old 'publish them to Claude Design' wording" >&2
    return 1
  fi
}
