#!/usr/bin/env bats
# AF-2026-05-30-5: Test11 D-04 + D-05 doc-page closures.
#
# Audit after AF-30-4 landed surfaced two HTML doc pages that didn't carry
# the new SKILL-level content. The SKILL.md files were updated correctly;
# this AF brings the public HTML doc site into sync.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../documentation" && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# D-04: gaia-readiness-check.html documents the frontmatter contract
# ===========================================================================

@test "D-04: readiness-check.html lists the required frontmatter fields" {
  for f in checks_passed critical_blockers contradictions_found; do
    run grep -F "$f" "$DOC_ROOT/commands/gaia-readiness-check.html"
    [ "$status" -eq 0 ] || { echo "missing field: $f" >&2; return 1; }
  done
}

@test "D-04: readiness-check.html documents the Output Verification section" {
  run grep -F 'Output Verification' \
        "$DOC_ROOT/commands/gaia-readiness-check.html"
  [ "$status" -eq 0 ]
}

@test "D-04: readiness-check.html documents the frontmatter contract" {
  # Assert the documented contract, not an internal anchor identifier (scrubbed
  # from published docs).
  run grep -F 'Readiness-report frontmatter contract' \
        "$DOC_ROOT/commands/gaia-readiness-check.html"
  [ "$status" -eq 0 ]
  grep -qF 'checks_passed' "$DOC_ROOT/commands/gaia-readiness-check.html"
}

# ===========================================================================
# D-05: gaia-create-story.html documents the --file vs positional CLI shape
# ===========================================================================

@test "D-05: create-story.html documents the canonical --file form" {
  # Use -e -- so grep doesn't interpret --file as its own flag.
  run grep -F -e '--file' \
        "$DOC_ROOT/commands/gaia-create-story.html"
  [ "$status" -eq 0 ]
}

@test "D-05: create-story.html documents the positional deprecation NOTICE" {
  run grep -F 'positional path is deprecated' \
        "$DOC_ROOT/commands/gaia-create-story.html"
  [ "$status" -eq 0 ]
}

@test "D-05: create-story.html lists all three validators" {
  for v in validate-frontmatter validate-ac-format validate-canonical-filename; do
    run grep -F "$v" \
          "$DOC_ROOT/commands/gaia-create-story.html"
    [ "$status" -eq 0 ] || { echo "missing validator: $v" >&2; return 1; }
  done
}

@test "D-05: create-story.html sidebar TOC includes the new section" {
  run grep -F '#story-validators' \
        "$DOC_ROOT/commands/gaia-create-story.html"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Design gate and stale propagation on affected command pages
# ===========================================================================

@test "dev-story.html documents the design approval prerequisite" {
  local page="$DOC_ROOT/commands/gaia-dev-story.html"
  [ -f "$page" ] || { echo "page not found: $page" >&2; return 1; }

  # The phrase must be inside a prerequisites section <ul>
  grep -qF 'Design approval required.' "$page" \
    || { echo "missing: Design approval required." >&2; return 1; }
  grep -qF '/gaia-design-review' "$page" \
    || { echo "missing: /gaia-design-review" >&2; return 1; }
  # Verify entities are intact (not corrupted to bare < or >)
  grep -qF '&lt;text&gt;' "$page" \
    || { echo "missing or corrupted entity: &lt;text&gt;" >&2; return 1; }
}

@test "add-feature.html documents the design impact assessment step" {
  local page="$DOC_ROOT/commands/gaia-add-feature.html"
  [ -f "$page" ] || { echo "page not found: $page" >&2; return 1; }

  grep -qF 'Design impact assessment' "$page" \
    || { echo "missing: Design impact assessment step" >&2; return 1; }
  # The step must be inside the step-list <ol>
  grep -q 'step-title.*Design impact assessment' "$page" \
    || { echo "Design impact assessment not inside step-list" >&2; return 1; }
}

@test "edit-ux.html documents the design stale transition step" {
  local page="$DOC_ROOT/commands/gaia-edit-ux.html"
  [ -f "$page" ] || { echo "page not found: $page" >&2; return 1; }

  grep -qF 'Design stale transition' "$page" \
    || { echo "missing: Design stale transition step" >&2; return 1; }
  # The step must be inside the step-list
  grep -q 'step-title.*Design stale transition' "$page" \
    || { echo "Design stale transition not inside step-list" >&2; return 1; }
}
