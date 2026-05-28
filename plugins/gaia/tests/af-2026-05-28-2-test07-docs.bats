#!/usr/bin/env bats
# AF-2026-05-28-2: Test07 documentation gaps + HTML path-sweep guard.
#
# - Moved the project-root documentation/ tree into gaia-public/documentation/
#   and added .github/workflows/pages.yml so push-to-main builds + deploys it
#   via GitHub Pages (real ship-path for the user-facing doc site).
# - 91 HTML files / 355 path-literal swaps from legacy docs/<X>-artifacts/ to
#   canonical .gaia/artifacts/<X>-artifacts/ + sprint-status.yaml to .gaia/state/.
# - D-1: gaia-init.html Outputs enumerates EVERY written file (incl. .gitignore
#   seed + .gaia/config + .gaia/config/test-environment.yaml.example).
# - D-2: 5 discovery research pages publish their canonical H2 schemas.
# - D-3: gaia-test-strategy.html + gaia-trace.html distinguish test-strategy.md
#   (strategy doc) vs test-plan.md (per-FR catalogue).
# - D-4: gaia-config-ci.html documents the YOLO / non-interactive entry.
# - D-7: gaia-retro.html flags Step 7 (Val sidecar write) as REQUIRED before
#   finalize under GAIA_FINALIZE_SENTINEL_REQUIRED=1.
# - D-8: first-30-minutes.html extended to cover the full lifecycle through
#   sprint-close + plan-next-sprint (Steps 11-18).
# - D-6 (bonus): new troubleshooting.html with HALT remediations, env-var
#   reference, canonical path cheat-sheet, statusline + bridge issues.
#
# This suite is the class-preventer: the doc-site sweep guard ensures the legacy
# docs/*-artifacts/ literal never reappears in any HTML file.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # The HTML doc site lives under gaia-public/documentation/ (post-AF-2026-05-28-2
  # move). CI checks out only gaia-public, so all assertions MUST anchor to a
  # path INSIDE gaia-public — never the non-git project-root documentation/.
  # See memory rule: feedback_no_project_root_artifact_assert_in_gaia_public_bats.
  GAIA_PUBLIC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCS_DIR="$GAIA_PUBLIC_ROOT/documentation"
  REPO_ROOT="$GAIA_PUBLIC_ROOT"
}

teardown() { common_teardown; }

# ===========================================================================
# Move + Pages publish workflow
# ===========================================================================

@test "AF-28-2: documentation/ is now tracked in gaia-public" {
  [ -d "$DOCS_DIR" ]
  [ -f "$DOCS_DIR/index.html" ]
  [ -f "$DOCS_DIR/glossary.html" ]
  [ -f "$DOCS_DIR/lifecycle-diagram.html" ]
  [ -f "$DOCS_DIR/troubleshooting.html" ]
  [ -d "$DOCS_DIR/commands" ]
  [ -d "$DOCS_DIR/categories" ]
  [ -d "$DOCS_DIR/tutorials" ]
}

@test "AF-28-2: .nojekyll marker present so jekyll doesn't choke on underscored dirs" {
  [ -f "$DOCS_DIR/.nojekyll" ]
}

@test "AF-28-2: GitHub Pages publish workflow exists" {
  [ -f "$REPO_ROOT/.github/workflows/pages.yml" ]
  grep -qF 'actions/deploy-pages' "$REPO_ROOT/.github/workflows/pages.yml"
  grep -qF "path: documentation" "$REPO_ROOT/.github/workflows/pages.yml"
}

# ===========================================================================
# Sweep-discipline guard — NO legacy docs/<X>-artifacts/ literals in HTML
# ===========================================================================

@test "AF-28-2 sweep: NO HTML file references legacy docs/<X>-artifacts/ paths (except the canonical cheat-sheet)" {
  # Class-prevention guard. If a new doc page (or an edit) regrows a legacy
  # docs/planning-artifacts/, docs/implementation-artifacts/, docs/test-artifacts/,
  # or docs/creative-artifacts/ literal, this test fails CI before the next
  # manual test surfaces it. The canonical homes are .gaia/artifacts/<X>-artifacts/.
  #
  # ALLOWLIST: troubleshooting.html is exempt because its "Canonical path
  # cheat-sheet" intentionally documents the legacy→canonical mapping. That's
  # the page that EXPLAINS the drift, so it MUST contain the legacy strings.
  local hits
  hits=$(grep -rlE 'docs/(planning|implementation|test|creative)-artifacts' \
    "$DOCS_DIR" 2>/dev/null | grep -v '/troubleshooting\.html$' || true)
  [ -z "$hits" ] || {
    echo "STALE PATH FOUND in documentation/:" >&2
    echo "$hits" >&2
    false
  }
}

@test "AF-28-2 sweep: NO HTML file references the legacy sprint-status.yaml impl-artifacts location" {
  # sprint-status.yaml moved to the state tier per ADR-111. The HTML site must
  # use .gaia/state/sprint-status.yaml, never .gaia/artifacts/implementation-artifacts/sprint-status.yaml.
  # troubleshooting.html cheat-sheet may legitimately mention both as
  # "legacy → canonical" — exempt it from the guard.
  local hits
  hits=$(grep -rlF '.gaia/artifacts/implementation-artifacts/sprint-status.yaml' \
    "$DOCS_DIR" 2>/dev/null | grep -v '/troubleshooting\.html$' || true)
  [ -z "$hits" ] || {
    echo "STALE sprint-status.yaml path in documentation/:" >&2
    echo "$hits" >&2
    false
  }
}

# ===========================================================================
# D-1 — gaia-init.html Outputs enumerates every written file
# ===========================================================================

@test "AF-28-2 D-1: gaia-init.html Outputs lists .gaia/config/project-config.yaml + .gitignore + test-environment.yaml.example" {
  local f="$DOCS_DIR/commands/gaia-init.html"
  [ -f "$f" ]
  grep -qF '.gaia/config/project-config.yaml' "$f"
  grep -qF '.gaia/config/test-environment.yaml.example' "$f"
  grep -qF '.gitignore' "$f"
  grep -qF '.github/workflows' "$f"
  grep -qF 'Carve-out' "$f"  # explicit doc of files-outside-.gaia/
}

# ===========================================================================
# D-2 — 5 discovery research pages publish their canonical H2 schemas
# ===========================================================================

@test "AF-28-2 D-2: gaia-brainstorm.html publishes the Output schema H2 list" {
  local f="$DOCS_DIR/commands/gaia-brainstorm.html"
  grep -qF 'id="output-schema"' "$f"
  grep -qF '## Vision Summary' "$f"
  grep -qF '## Target Users' "$f"
  grep -qF '## Pain Points' "$f"
}

@test "AF-28-2 D-2: gaia-product-brief.html publishes the Output schema H2 list" {
  local f="$DOCS_DIR/commands/gaia-product-brief.html"
  grep -qF 'id="output-schema"' "$f"
  grep -qF '## Vision Statement' "$f"
  grep -qF '## Problem Statement' "$f"
  grep -qF '## Success Metrics' "$f"
}

@test "AF-28-2 D-2: gaia-market-research.html publishes the Output schema H2 list" {
  local f="$DOCS_DIR/commands/gaia-market-research.html"
  grep -qF 'id="output-schema"' "$f"
  grep -qF '## Executive Summary' "$f"
  grep -qF '## Market Sizing' "$f"
  grep -qF '## Competitive Analysis' "$f"
}

@test "AF-28-2 D-2: gaia-domain-research.html publishes the Output schema H2 list" {
  local f="$DOCS_DIR/commands/gaia-domain-research.html"
  grep -qF 'id="output-schema"' "$f"
  grep -qF '## Domain Overview' "$f"
  grep -qF '## Terminology Glossary' "$f"
}

@test "AF-28-2 D-2: gaia-tech-research.html publishes the Output schema H2 list" {
  local f="$DOCS_DIR/commands/gaia-tech-research.html"
  grep -qF 'id="output-schema"' "$f"
  grep -qF '## Technology Overview' "$f"
  grep -qF '## Evaluation Matrix' "$f"
}

# ===========================================================================
# D-3 — test-strategy.md vs test-plan.md disambiguation
# ===========================================================================

@test "AF-28-2 D-3: gaia-test-strategy.html distinguishes test-strategy.md vs test-plan.md" {
  local f="$DOCS_DIR/commands/gaia-test-strategy.html"
  grep -qF 'Two artifacts, two names' "$f"
  grep -qF 'test-strategy.md' "$f"
  grep -qF 'test-plan.md' "$f"
  # the canonical home (post-ADR-127 §7.2) is planning-artifacts/
  grep -qF '.gaia/artifacts/planning-artifacts/test-strategy.md' "$f"
}

@test "AF-28-2 D-3: gaia-trace.html cites the canonical planning-artifacts test-plan location + cross-ref to test-strategy" {
  local f="$DOCS_DIR/commands/gaia-trace.html"
  grep -qF '.gaia/artifacts/planning-artifacts/test-plan.md' "$f"
  grep -qF '.gaia/artifacts/planning-artifacts/traceability-matrix.md' "$f"
  grep -qF 'test-strategy' "$f"  # the cross-ref callout
}

# ===========================================================================
# D-4 — gaia-config-ci YOLO / non-interactive entry
# ===========================================================================

@test "AF-28-2 D-4: gaia-config-ci.html documents the YOLO / non-interactive entry" {
  local f="$DOCS_DIR/commands/gaia-config-ci.html"
  grep -qF 'Non-interactive / YOLO entry' "$f"
  grep -qF 'GAIA_YOLO_FLAG=1' "$f"
  grep -qF 'GAIA_NONINTERACTIVE=1' "$f"
  grep -qF -- '--preset' "$f"
}

# ===========================================================================
# D-7 — gaia-retro Step 7 required-before-finalize badge
# ===========================================================================

@test "AF-28-2 D-7: gaia-retro.html marks Step 7 (Val sidecar write) as REQUIRED before finalize" {
  local f="$DOCS_DIR/commands/gaia-retro.html"
  grep -qF 'step-7-val-sidecar-write' "$f"
  grep -qF 'REQUIRED before finalize' "$f"
  grep -qF 'GAIA_FINALIZE_SENTINEL_REQUIRED' "$f"
}

# ===========================================================================
# D-8 — first-30-minutes tutorial covers Steps 11-18 (full E2E)
# ===========================================================================

@test "AF-28-2 D-8: first-30-minutes.html extends past Step 10 through sprint close + next-sprint planning" {
  local f="$DOCS_DIR/tutorials/first-30-minutes.html"
  grep -qF 'id="step-11"' "$f"
  grep -qF 'id="step-15"' "$f"
  grep -qF 'id="step-17"' "$f"
  grep -qF 'id="step-18"' "$f"
  grep -qF 'gaia-sprint-review' "$f"
  grep -qF 'gaia-sprint-close' "$f"
  grep -qF 'Full Lifecycle End-to-End' "$f"
}

# ===========================================================================
# D-6 (bonus) — troubleshooting.html present + linked from index
# ===========================================================================

@test "AF-28-2 D-6: troubleshooting.html exists with the documented HALT cases" {
  local f="$DOCS_DIR/troubleshooting.html"
  [ -f "$f" ]
  grep -qF 'compliance.ui_present=true' "$f"
  grep -qF 'no non-empty test-plan artifact found' "$f"
  grep -qF 'sprint-status.yaml is missing' "$f"
  grep -qF 'GAIA_STRICT_LIFECYCLE' "$f"
  grep -qF 'Canonical path cheat-sheet' "$f"
}

@test "AF-28-2 D-6: troubleshooting.html is linked from the home page sidebar" {
  local f="$DOCS_DIR/index.html"
  grep -qF 'troubleshooting.html' "$f"
}
