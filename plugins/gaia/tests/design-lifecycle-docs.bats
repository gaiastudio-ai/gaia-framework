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
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Leaked-identifier regex — same families as the repo-wide gates.
# ---------------------------------------------------------------------------
_leak_regex() {
  printf '%s' 'E[0-9]+-S[0-9]+|FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|(AF|AI)-[0-9]{4}-[0-9]{2}|TC-[A-Z]|T-[0-9]+ |F-[0-9]+ '
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
    if ! echo "$current_hrefs" | grep -qxF "$href"; then
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
  printf '%s' "$pub_section" | grep -qiE 'design-last-published|persisted manifest|persist' || {
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
  printf '%s' "$delta_li" | grep -qi 'screen' || {
    echo "FAIL: delta sync step should mention screen changes: $delta_li" >&2; return 1
  }
  printf '%s' "$delta_li" | grep -qiE 'report|manual' || {
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
  printf '%s' "$block" | grep -qiF 'sha256' || {
    echo "FAIL: Publication step should mention sha256 hash computation" >&2; return 1
  }
  printf '%s' "$block" | grep -qF 'get_file' || {
    echo "FAIL: Publication step should mention get_file for hash computation" >&2; return 1
  }
}
