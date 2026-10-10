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
  printf '%s' 'FR-[0-9]+|NFR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z][A-Z0-9]*-|SR-[0-9]+|(AF|AI)-[0-9]{4}|T-DPS-[0-9]+|GitHub #[0-9]+|(^|[^A-Za-z0-9])(T|F)-[0-9]+([^0-9]|$)'
}

# ---------------------------------------------------------------------------
# _step_item STEP_LIST TITLE — extract one <li> from a step list by its
# step-title span text.  Uses fixed-string matching only.
# ---------------------------------------------------------------------------
_step_item() {
  local step_list="$1" title="$2"
  printf '%s' "$step_list" \
    | sed 's/<li>/\n<li>/g' \
    | grep -F "$title" \
    | head -1
}

# Pinned sidebar links
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
# Lifecycle page exists
# ===========================================================================

@test "design lifecycle page exists and is non-empty" {
  [ -s "$DOC_DIR/design-lifecycle.html" ] || {
    echo "FAIL: documentation/design-lifecycle.html missing or empty" >&2
    return 1
  }
}

# ===========================================================================
# Seven lifecycle stages
# ===========================================================================

@test "page covers discovery stage" {
  grep -qi 'discovery' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'discovery'" >&2; return 1
  }
}

@test "page covers questionnaire stage" {
  grep -qi 'questionnaire' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'questionnaire'" >&2; return 1
  }
}

@test "page covers publication stage" {
  grep -qi 'publi' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'publication'" >&2; return 1
  }
}

@test "page covers review stage" {
  grep -qi 'review' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'review'" >&2; return 1
  }
}

@test "page covers approval stage" {
  grep -qiE 'approv(al|ed)' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'approval'" >&2; return 1
  }
}

@test "page covers gate and override stage" {
  grep -qi 'gate' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'gate'" >&2; return 1
  }
  grep -qiE 'override|force-design' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'override'" >&2; return 1
  }
}

@test "page covers stale-on-change stage" {
  grep -qi 'stale' "$DOC_DIR/design-lifecycle.html" || {
    echo "FAIL: does not mention 'stale'" >&2; return 1
  }
}

# ===========================================================================
# Leaked-identifier gates
# ===========================================================================

@test "no internal identifier in design-lifecycle page" {
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/design-lifecycle.html" || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in design-lifecycle.html:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no internal identifier in lifecycle-diagram changes" {
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/lifecycle-diagram.html" || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in lifecycle-diagram.html:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no internal identifier in design-review command page" {
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-design-review.html" || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in design-review:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no internal identifier in create-ux command page" {
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-create-ux.html" || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in create-ux:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no internal identifier in edit-ux command page" {
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-edit-ux.html" || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in edit-ux:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no internal identifier in add-feature command page" {
  local hits
  hits="$(grep -nE "$(_leak_regex)" "$DOC_DIR/commands/gaia-add-feature.html" || true)"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in add-feature:" >&2
    echo "$hits" >&2; return 1
  }
}

# ===========================================================================
# Lifecycle diagram structural tests
# ===========================================================================

@test "lifecycle-diagram shows gate between UX and solutioning" {
  local a11y_line gate_line phase3_line
  a11y_line="$(grep -n 'validate-design-a11y' "$DOC_DIR/lifecycle-diagram.html" | head -1 | cut -d: -f1 || true)"
  gate_line="$(grep -nE 'design-review|design-approval' "$DOC_DIR/lifecycle-diagram.html" | head -1 | cut -d: -f1 || true)"
  phase3_line="$(grep -n 'ld-phase--3' "$DOC_DIR/lifecycle-diagram.html" | head -1 | cut -d: -f1 || true)"
  [ -n "$gate_line" ] || { echo "FAIL: no gate node" >&2; return 1; }
  [ -n "$a11y_line" ] || { echo "FAIL: no a11y node" >&2; return 1; }
  [ -n "$phase3_line" ] || { echo "FAIL: no phase 3" >&2; return 1; }
  [ "$gate_line" -gt "$a11y_line" ] || { echo "FAIL: gate before a11y" >&2; return 1; }
  [ "$gate_line" -lt "$phase3_line" ] || { echo "FAIL: gate after phase 3" >&2; return 1; }
}

@test "lifecycle-diagram gate node uses ld-node--gate class" {
  local gate_section gate_inline
  gate_section="$(grep -A2 'design-review' "$DOC_DIR/lifecycle-diagram.html" | grep 'ld-node--gate' || true)"
  [ -z "$gate_section" ] && gate_section="$(grep -A2 'design-approval' "$DOC_DIR/lifecycle-diagram.html" | grep 'ld-node--gate' || true)"
  gate_inline="$(grep 'design-review.*ld-node--gate' "$DOC_DIR/lifecycle-diagram.html" || true)"
  [ -z "$gate_inline" ] && gate_inline="$(grep 'ld-node--gate.*design-review' "$DOC_DIR/lifecycle-diagram.html" || true)"
  [ -n "$gate_section" ] || [ -n "$gate_inline" ] || {
    echo "FAIL: gate does not use ld-node--gate" >&2; return 1
  }
}

@test "lifecycle-diagram does not reorder existing nodes" {
  local current_cmds
  current_cmds="$(grep -oE '/gaia-[a-z0-9-]+' "$DOC_DIR/lifecycle-diagram.html" | awk '!seen[$0]++')"
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
      [ "$ccmd" = "$cmd" ] && { found=true; break; }
      idx=$((idx + 1))
    done <<< "$current_cmds"
    $found || { echo "FAIL: '$cmd' missing" >&2; return 1; }
    [ "$idx" -gt "$prev_idx" ] || { echo "FAIL: '$cmd' out of order" >&2; return 1; }
    prev_idx=$idx
  done <<< "$baseline_cmds"
}

@test "design-review command page links to design-lifecycle page" {
  grep -q 'design-lifecycle\.html' "$DOC_DIR/commands/gaia-design-review.html" || {
    echo "FAIL: no link to design-lifecycle.html" >&2; return 1
  }
}

@test "index.html sidebar contains design-lifecycle.html link" {
  grep -q 'href="design-lifecycle\.html"' "$DOC_DIR/index.html" || {
    echo "FAIL: no sidebar link" >&2; return 1
  }
}

@test "index.html sidebar preserves pre-existing entries" {
  local current_hrefs
  current_hrefs="$(grep -oE 'href="[^"]*\.html"' "$DOC_DIR/index.html" | sed 's/href="//;s/"//' | sort -u)"
  local missing=0
  for href in "${SIDEBAR_BASELINE[@]}"; do
    grep -qxF "$href" <<<"$current_hrefs" || { echo "MISSING: $href" >&2; missing=$((missing + 1)); }
  done
  [ "$missing" -eq 0 ] || { echo "FAIL: $missing missing" >&2; return 1; }
}

# =========================================================================
# Stale-on-change wording
# =========================================================================

@test "design-lifecycle.html does not claim the diagnostic names the triggering change" {
  local page="$DOC_DIR/design-lifecycle.html"
  if grep -qi 'names the change' "$page"; then
    echo "FAIL: still claims diagnostic names the change" >&2; return 1
  fi
  grep -qi 're-approved.*review round\|same halt.*non-approved' "$page" || {
    echo "FAIL: should carry the replacement wording" >&2; return 1
  }
}

# =========================================================================
# Override notice and sprint scope
# =========================================================================

@test "(AC1) gaia-dev-story.html documents the override notice" {
  local page="$DOC_DIR/commands/gaia-dev-story.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }
  grep -qi 'override' "$page" || { echo "FAIL: no override" >&2; return 1; }
  grep -qiE 'notice|design.state' "$page" || { echo "FAIL: no notice" >&2; return 1; }
}

@test "(AC2) design-lifecycle.html documents the sprint scope in overrides" {
  local page="$DOC_DIR/design-lifecycle.html"
  grep -qiE 'sprint.scope|sprint_id' "$page" || {
    echo "FAIL: no sprint scope" >&2; return 1
  }
}

@test "(AC1) design-lifecycle.html documents the override notice" {
  local page="$DOC_DIR/design-lifecycle.html"
  grep -qiE 'notice|surfaced' "$page" || {
    echo "FAIL: no override notice" >&2; return 1
  }
}

# =========================================================================
# Fail-closed approval gate
# =========================================================================

@test "(AC3) gaia-design-review.html troubleshooting names both roster locations and /gaia-create-stakeholder" {
  local page="$DOC_DIR/commands/gaia-design-review.html"
  grep -qF '.gaia/custom/stakeholders' "$page" || {
    echo "FAIL: no .gaia/custom/stakeholders" >&2; return 1
  }
  local root_roster_count
  root_roster_count="$(grep -oE '([^ <>"]*custom/stakeholders)' "$page" | grep -vcF '.gaia/' || true)"
  [ "$root_roster_count" -gt 0 ] || {
    echo "FAIL: no root custom/stakeholders" >&2; return 1
  }
  grep -qF '/gaia-create-stakeholder' "$page" || {
    echo "FAIL: no /gaia-create-stakeholder" >&2; return 1
  }
}

@test "(AC1) design-lifecycle.html approval section names the roster requirement" {
  local page="$DOC_DIR/design-lifecycle.html"
  grep -qi 'roster' "$page" || { echo "FAIL: no roster" >&2; return 1; }
  grep -qF '/gaia-create-stakeholder' "$page" || { echo "FAIL: no remediation" >&2; return 1; }
}

# =========================================================================
# Publication manifest persistence
# =========================================================================

@test "(AC2) create-ux doc page describes manifest persistence after publication" {
  local page="$DOC_DIR/commands/gaia-create-ux.html"
  grep -qi 'manifest' "$page" || { echo "FAIL: no manifest" >&2; return 1; }
  grep -qiE 'persist|persisted' "$page" || { echo "FAIL: no persistence" >&2; return 1; }
}

@test "(AC2) design-lifecycle.html publication section describes persisted manifest" {
  local page="$DOC_DIR/design-lifecycle.html"
  local pub_section
  pub_section="$(sed -n '/<section id="publication">/,/<\/section>/p' "$page")"
  [ -n "$pub_section" ] || { echo "FAIL: no publication section" >&2; return 1; }
  grep -qiE 'design-last-published|persisted manifest|persist' <<<"$pub_section" || {
    echo "FAIL: no persisted manifest" >&2; return 1
  }
}

# =========================================================================
# Delta sync screen reporting
# =========================================================================

@test "(AC4) design-review doc page describes screen reporting in delta sync" {
  local doc_page="$DOC_DIR/commands/gaia-design-review.html"
  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$doc_page")"
  local delta_li
  delta_li="$(_step_item "$step_section" "Delta sync")"
  [ -n "$delta_li" ] || { echo "FAIL: no delta sync step" >&2; return 1; }
  grep -qi 'screen' <<<"$delta_li" || { echo "FAIL: no screen in delta sync" >&2; return 1; }
  grep -qiE 'report|manual' <<<"$delta_li" || { echo "FAIL: no report in delta sync" >&2; return 1; }
}

@test "(AC1) create-ux Step 10 documents remote-listing hash computation from get_file" {
  local skill_md="$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  [ -s "$skill_md" ] || { echo "FAIL: SKILL.md missing" >&2; return 1; }
  local block
  block="$(awk '/^### Step.*Publication/{found=1} found{print} found && /^### Step/ && !/Publication/{exit}' "$skill_md")"
  [ -n "$block" ] || { echo "FAIL: no Publication step" >&2; return 1; }
  grep -qiF 'sha256' <<<"$block" || { echo "FAIL: no sha256" >&2; return 1; }
  grep -qF 'get_file' <<<"$block" || { echo "FAIL: no get_file" >&2; return 1; }
}

# ===========================================================================
# Two-project model: design-lifecycle direction-sensitive assertions
# ===========================================================================

@test "design-lifecycle describes both projects and token-by-value model" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }

  # Discovery: DesignSync paired with design-system, Artifact with product design
  local disc
  disc="$(sed -n '/<section id="discovery">/,/<\/section>/p' "$page")"
  grep -qiE 'DesignSync.*design-system|design-system.*DesignSync' <<<"$disc" || {
    echo "FAIL: discovery should pair DesignSync with design-system" >&2; return 1
  }
  grep -qiE 'product design.*Design artifact|Design artifact.*product design' <<<"$disc" || {
    echo "FAIL: discovery should pair Design artifact with product design" >&2; return 1
  }

  # Publication: token-by-value, designSystems empty expected, artifact-installed
  # Join lines so multi-line phrases match.
  local pub
  pub="$(sed -n '/<section id="publication">/,/<\/section>/p' "$page" | tr '\n' ' ')"
  grep -qiE 'token-by-value' <<<"$pub" || {
    echo "FAIL: publication should describe token-by-value" >&2; return 1
  }
  grep -qi 'artifact-installed' <<<"$pub" || {
    echo "FAIL: publication should mention artifact-installed" >&2; return 1
  }
  grep -qiE 'designSystems.*empty.*expected|empty.*designSystems.*expected' <<<"$pub" || {
    echo "FAIL: publication should say designSystems list is empty as expected" >&2; return 1
  }
  grep -qiE 'after.*first.*screen.*publish.*verif|after.*screen.*publish.*canvas' <<<"$pub" || {
    echo "FAIL: should say canvas verified after first screens published" >&2; return 1
  }

  # Questionnaire feeds only design-system
  local quest
  quest="$(sed -n '/<section id="questionnaire">/,/<\/section>/p' "$page")"
  grep -qiF 'only the design-system project' <<<"$quest" || {
    echo "FAIL: questionnaire should feed only design-system" >&2; return 1
  }

  # Old phrasing gone
  if grep -qi 'republished to the project' "$page"; then
    echo "FAIL: old single-project phrasing" >&2; return 1
  fi

  # SKILL.md cross-checks
  grep -qi 'design-system project' "$SKILL_CUX" || { echo "FAIL: SKILL.md drift" >&2; return 1; }
  grep -qi 'token-by-value' "$SKILL_CUX" || { echo "FAIL: SKILL.md drift" >&2; return 1; }
}

# ===========================================================================
# Two-project model: create-ux direction-sensitive assertions
# ===========================================================================

@test "create-ux page describes two-project discovery and creation" {
  local page="$DOC_DIR/commands/gaia-create-ux.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }

  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$page")"

  # Project creation step: DS via DesignSync, PD via Artifact
  local creation
  creation="$(_step_item "$step_section" "Project creation")"
  [ -n "$creation" ] || { echo "FAIL: no Project creation step" >&2; return 1; }
  grep -qiF 'design-system project' <<<"$creation" || {
    echo "FAIL: creation should mention design-system project" >&2; return 1
  }
  grep -qiF 'product design project' <<<"$creation" || {
    echo "FAIL: creation should mention product design project" >&2; return 1
  }
  grep -qiE 'design-system.*DesignSync|DesignSync.*design-system' <<<"$creation" || {
    echo "FAIL: creation should pair DesignSync with design-system" >&2; return 1
  }
  grep -qiE 'product design.*Artifact|Artifact.*product design' <<<"$creation" || {
    echo "FAIL: creation should pair Artifact with product design" >&2; return 1
  }

  # Questionnaire feeds only design-system
  local quest
  quest="$(_step_item "$step_section" "Stakeholder questionnaire")"
  grep -qiF 'only the design-system project' <<<"$quest" || {
    echo "FAIL: questionnaire should feed only design-system" >&2; return 1
  }

  # Screen publication: screens to PD, components to DS
  local pub
  pub="$(_step_item "$step_section" "Screen specification publication")"
  grep -qiE 'screen.*product design|product design.*screen' <<<"$pub" || {
    echo "FAIL: screens should go to product design" >&2; return 1
  }
  grep -qiE 'component.*design-system|design-system.*component' <<<"$pub" || {
    echo "FAIL: components should go to design-system" >&2; return 1
  }

  # Creates or binds
  grep -qiE 'creates or binds|create or bind' "$page" || {
    echo "FAIL: should say creates or binds" >&2; return 1
  }
  grep -qiE 'brand-style|non-React' "$page" || {
    echo "FAIL: should mention brand-style" >&2; return 1
  }

  # SKILL.md cross-checks
  grep -qi 'design-system project' "$SKILL_CUX" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qi 'product design project' "$SKILL_CUX" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qi 'brand-style' "$SKILL_CUX" || { echo "FAIL: SKILL drift" >&2; return 1; }
}

# ===========================================================================
# Two-project model: edit-ux direction-sensitive assertions
# ===========================================================================

@test "edit-ux page describes scope-based republish routing" {
  local page="$DOC_DIR/commands/gaia-edit-ux.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }

  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$page")"
  local republish
  republish="$(_step_item "$step_section" "Republish changed specifications")"
  [ -n "$republish" ] || { echo "FAIL: no Republish step" >&2; return 1; }

  if grep -qi 'republished to the Claude Design project' "$page"; then
    echo "FAIL: old single-project phrasing" >&2; return 1
  fi

  # Direction: token/component -> design-system
  grep -qiE 'token.*component.*design-system' <<<"$republish" || {
    echo "FAIL: should route token/component to design-system" >&2; return 1
  }
  # Direction: screen/flow -> product design
  grep -qiE 'screen.*flow.*product design' <<<"$republish" || {
    echo "FAIL: should route screen/flow to product design" >&2; return 1
  }
  # Token change also refreshes screens
  grep -qiE 'token.*also.*screen|token.*refresh.*screen|screen.*carries.*token' <<<"$republish" || {
    echo "FAIL: should say token change also refreshes screens" >&2; return 1
  }
  # DS first
  grep -qiE 'design-system.*first' <<<"$republish" || {
    echo "FAIL: should say design-system first" >&2; return 1
  }

  # SKILL.md cross-checks
  grep -qiE 'design.system pass|design_system' "$SKILL_EUX" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qiE 'product.design pass|product_design' "$SKILL_EUX" || { echo "FAIL: SKILL drift" >&2; return 1; }
}

# ===========================================================================
# Two-project model: design-review direction-sensitive assertions
# ===========================================================================

@test "design-review page describes two-project read-back and combined verdict" {
  local page="$DOC_DIR/commands/gaia-design-review.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }

  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$page")"

  # Read-back: DS through DesignSync, PD through Artifact
  local readback
  readback="$(_step_item "$step_section" "Read-back")"
  [ -n "$readback" ] || { echo "FAIL: no Read-back step" >&2; return 1; }
  grep -qiE 'design-system.*DesignSync|DesignSync.*design-system' <<<"$readback" || {
    echo "FAIL: read-back should pair DesignSync with design-system" >&2; return 1
  }
  grep -qiE 'product design.*Artifact|Artifact.*product design' <<<"$readback" || {
    echo "FAIL: read-back should pair Artifact with product design" >&2; return 1
  }

  # Combined verdict in Findings step
  local findings
  findings="$(_step_item "$step_section" "Findings")"
  grep -qiE 'failure in either|either project' <<<"$findings" || {
    echo "FAIL: findings should describe combined verdict" >&2; return 1
  }

  # Delta sync: screens from product design, components from design-system
  local delta
  delta="$(_step_item "$step_section" "Delta sync")"
  grep -qiE 'screen.*product design|product design.*screen' <<<"$delta" || {
    echo "FAIL: delta sync should read screens from product design" >&2; return 1
  }
  grep -qiE 'component.*design-system|design-system.*component' <<<"$delta" || {
    echo "FAIL: delta sync should read components from design-system" >&2; return 1
  }
  grep -qi 'reconciliation' <<<"$delta" || {
    echo "FAIL: delta sync should mention reconciliation" >&2; return 1
  }

  # No old single-project in step list
  local stakeholder_step
  stakeholder_step="$(_step_item "$step_section" "Stakeholder delivery")"
  if grep -qF 'Re-reads the project' <<<"$stakeholder_step"; then
    echo "FAIL: stakeholder step has old single-project wording" >&2; return 1
  fi

  # SKILL.md cross-checks
  grep -qi 'DesignSync' "$SKILL_DR" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qiE 'either project|either.*verdict' "$SKILL_DR" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qi 'reconciliation' "$SKILL_DR" || { echo "FAIL: SKILL drift" >&2; return 1; }
}

# ===========================================================================
# Two-project model: lifecycle brand-style, routing, gate, consumer
# ===========================================================================

@test "design-lifecycle describes brand-style path and scope routing" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }

  grep -qi 'brand-style' "$page" || { echo "FAIL: no brand-style" >&2; return 1; }
  grep -qiE 'design-system.*first' "$page" || { echo "FAIL: no DS-first" >&2; return 1; }
  grep -qiE 'no screens available|no product design project' "$page" || {
    echo "FAIL: no null-PD behavior" >&2; return 1
  }

  # Gate: convergence, review coverage, zero integration calls
  local gate
  gate="$(sed -n '/<section id="gate-and-override">/,/<\/section>/p' "$page" | tr '\n' ' ')"
  grep -qiE 'zero integration calls|no integration calls' <<<"$gate" || {
    echo "FAIL: gate should say zero integration calls" >&2; return 1
  }
  grep -qiE 'convergence|stakeholder.*converg' <<<"$gate" || {
    echo "FAIL: gate should mention convergence" >&2; return 1
  }
  grep -qiE 'review coverage|coverage.*both' <<<"$gate" || {
    echo "FAIL: gate should mention review coverage" >&2; return 1
  }

  # Token change also refreshes screens
  local stale
  stale="$(sed -n '/<section id="stale-on-change">/,/<\/section>/p' "$page" | tr '\n' ' ')"
  grep -qiE 'token.*also.*screen|token.*refresh.*screen|screen.*carries.*token' <<<"$stale" || {
    echo "FAIL: stale section should say token change refreshes screens" >&2; return 1
  }

  # SKILL.md cross-checks
  grep -qi 'brand-style' "$SKILL_CUX" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qiE 'design-system.*first|design.system pass first' "$SKILL_EUX" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qiE 'product_design_project.*null|null.*skip' "$SKILL_DR" || { echo "FAIL: SKILL drift" >&2; return 1; }
}

# ===========================================================================
# Two-project model: add-feature direction-sensitive assertions
# ===========================================================================

@test "add-feature page describes scope-based republish routing" {
  local page="$DOC_DIR/commands/gaia-add-feature.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }

  if grep -qi 'republished to the design project' "$page"; then
    echo "FAIL: old single-project phrasing" >&2; return 1
  fi

  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$page")"
  local impact
  impact="$(_step_item "$step_section" "Design impact assessment")"
  [ -n "$impact" ] || { echo "FAIL: no Design impact step" >&2; return 1; }

  grep -qiE 'token.*component.*design-system' <<<"$impact" || {
    echo "FAIL: should route token/component to design-system" >&2; return 1
  }
  grep -qiE 'screen.*flow.*product design' <<<"$impact" || {
    echo "FAIL: should route screen/flow to product design" >&2; return 1
  }
  grep -qi 'republish' "$page" || { echo "FAIL: no republish" >&2; return 1; }

  # SKILL.md cross-checks
  grep -qiE 'design_system|design-system' "$SKILL_AF" || { echo "FAIL: SKILL drift" >&2; return 1; }
  grep -qiE 'product_design|product design' "$SKILL_AF" || { echo "FAIL: SKILL drift" >&2; return 1; }
}

# ===========================================================================
# Leaked-identifier sweep: scanning count
# ===========================================================================

@test "leak sweep scans at least five doc pages" {
  local count=0 f hits
  for f in \
    "$DOC_DIR/design-lifecycle.html" \
    "$DOC_DIR/commands/gaia-create-ux.html" \
    "$DOC_DIR/commands/gaia-edit-ux.html" \
    "$DOC_DIR/commands/gaia-design-review.html" \
    "$DOC_DIR/commands/gaia-add-feature.html"; do
    [ -f "$f" ] || { echo "FAIL: not found: $f" >&2; return 1; }
    hits="$(grep -nE "$(_leak_regex)" "$f" || true)"
    [ -z "$hits" ] || {
      echo "FAIL: leaked identifier(s) in $f:" >&2
      echo "$hits" >&2; return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 5 ] || { echo "FAIL: only $count pages" >&2; return 1; }
}

# ===========================================================================
# Leaked-identifier regex proof
# ===========================================================================

@test "leak regex catches T-N and F-N as whole tokens" {
  cat > "$BATS_TEST_TMPDIR/positive.html" <<'SEEDEOF'
found T-12
value F-3.
end T-99
F-1
SEEDEOF
  local pos_hits
  pos_hits="$(grep -cE "$(_leak_regex)" "$BATS_TEST_TMPDIR/positive.html")"
  [ "$pos_hits" -ge 4 ] || {
    echo "FAIL: matched only $pos_hits of 4" >&2; return 1
  }

  # Negative: derive the T/F sub-regex from _leak_regex
  local full_regex tf_regex
  full_regex="$(_leak_regex)"
  tf_regex="${full_regex##*GitHub #\[0-9\]+\|}"
  cat > "$BATS_TEST_TMPDIR/negative.html" <<'NEGEOF'
UTF-8 encoding
TF-100 combined
NEGEOF
  local neg_hits
  neg_hits="$(grep -cE "$tf_regex" "$BATS_TEST_TMPDIR/negative.html" || true)"
  [ "$neg_hits" -eq 0 ] || {
    echo "FAIL: false-positive ($neg_hits hits)" >&2; return 1
  }

  # TC family: TC-AB1 must be caught
  cat > "$BATS_TEST_TMPDIR/tc-test.html" <<'TCEOF'
test case TC-AB1-verify
TCEOF
  local tc_hits
  tc_hits="$(grep -cE "$(_leak_regex)" "$BATS_TEST_TMPDIR/tc-test.html" || true)"
  [ "$tc_hits" -ge 1 ] || {
    echo "FAIL: should catch TC-AB1 ($tc_hits)" >&2; return 1
  }
}

# ===========================================================================
# Recipes page
# ===========================================================================

@test "recipes page describes two-project publication" {
  local page="$DOC_DIR/recipes.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }
  grep -qi 'design-system project' "$page" || { echo "FAIL: no design-system project" >&2; return 1; }
  grep -qi 'product design project' "$page" || { echo "FAIL: no product design project" >&2; return 1; }
  if grep -qi 'publish them to Claude Design' "$page"; then
    echo "FAIL: old wording" >&2; return 1
  fi
}

# ===========================================================================
# Roster symlink refusal
# ===========================================================================

@test "design-lifecycle approval section describes roster symlink refusal" {
  local page="$DOC_DIR/design-lifecycle.html"
  local approval
  approval="$(sed -n '/<section id="approval">/,/<\/section>/p' "$page" | tr '\n' ' ')"
  [ -n "$approval" ] || { echo "FAIL: no approval section" >&2; return 1; }
  grep -qiE 'symlink.*refuse|refuse.*symlink' <<<"$approval" || {
    echo "FAIL: should mention symlink refusal" >&2; return 1
  }
  grep -qiE 'tab.*newline|newline.*tab' <<<"$approval" || {
    echo "FAIL: should mention tab/newline refusal" >&2; return 1
  }
}

# ===========================================================================
# Create-ux prerequisites and troubleshooting
# ===========================================================================

@test "create-ux lists the Artifact tool prerequisite and troubleshooting" {
  local page="$DOC_DIR/commands/gaia-create-ux.html"
  [ -s "$page" ] || { echo "FAIL: missing" >&2; return 1; }

  local prereq
  prereq="$(sed -n '/<section id="prerequisites">/,/<\/section>/p' "$page")"
  grep -qiE 'Artifact tool|Design artifact' <<<"$prereq" || {
    echo "FAIL: prerequisites should mention the Artifact tool" >&2; return 1
  }

  local trouble
  trouble="$(sed -n '/<section id="troubleshooting">/,/<\/section>/p' "$page")"
  grep -qiE 'Artifact.*unavailable|Artifact.*not available|Design artifact.*unavailable' <<<"$trouble" || {
    echo "FAIL: troubleshooting should cover Artifact unavailable" >&2; return 1
  }
}

@test "edit-ux troubleshooting covers product design project not set up" {
  local page="$DOC_DIR/commands/gaia-edit-ux.html"
  local trouble
  trouble="$(sed -n '/<section id="troubleshooting">/,/<\/section>/p' "$page")"
  grep -qiE 'product design project.*not set up|not set up.*product design' <<<"$trouble" || {
    echo "FAIL: should cover product design project not set up" >&2; return 1
  }
}

# ===========================================================================
# Design-review no single-project wording
# ===========================================================================

@test "design-review page has no single-project wording in step list or inputs" {
  local page="$DOC_DIR/commands/gaia-design-review.html"
  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$page")"
  if grep -qF 'Re-reads the project' <<<"$step_section"; then
    echo "FAIL: step list still says 'Re-reads the project'" >&2; return 1
  fi
  local inputs
  inputs="$(sed -n '/<section id="inputs">/,/<\/section>/p' "$page")"
  if grep -qF '>Design project<' <<<"$inputs"; then
    echo "FAIL: inputs still lists 'Design project'" >&2; return 1
  fi
}
