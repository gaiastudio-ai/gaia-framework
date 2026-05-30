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

@test "AF-30-5 D-04: readiness-check.html lists the required frontmatter fields" {
  for f in checks_passed critical_blockers contradictions_found; do
    run grep -F "$f" "$DOC_ROOT/commands/gaia-readiness-check.html"
    [ "$status" -eq 0 ] || { echo "missing field: $f" >&2; return 1; }
  done
}

@test "AF-30-5 D-04: readiness-check.html documents the Output Verification section" {
  run grep -F 'Output Verification' \
        "$DOC_ROOT/commands/gaia-readiness-check.html"
  [ "$status" -eq 0 ]
}

@test "AF-30-5 D-04: readiness-check.html cites the AF-30-4 / Test11 D-04 anchor" {
  run grep -F 'AF-2026-05-30-4 / Test11 D-04' \
        "$DOC_ROOT/commands/gaia-readiness-check.html"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-05: gaia-create-story.html documents the --file vs positional CLI shape
# ===========================================================================

@test "AF-30-5 D-05: create-story.html documents the canonical --file form" {
  # Use -e -- so grep doesn't interpret --file as its own flag.
  run grep -F -e '--file' \
        "$DOC_ROOT/commands/gaia-create-story.html"
  [ "$status" -eq 0 ]
}

@test "AF-30-5 D-05: create-story.html documents the positional deprecation NOTICE" {
  run grep -F 'positional path is deprecated' \
        "$DOC_ROOT/commands/gaia-create-story.html"
  [ "$status" -eq 0 ]
}

@test "AF-30-5 D-05: create-story.html lists all three validators" {
  for v in validate-frontmatter validate-ac-format validate-canonical-filename; do
    run grep -F "$v" \
          "$DOC_ROOT/commands/gaia-create-story.html"
    [ "$status" -eq 0 ] || { echo "missing validator: $v" >&2; return 1; }
  done
}

@test "AF-30-5 D-05: create-story.html sidebar TOC includes the new section" {
  run grep -F '#story-validators' \
        "$DOC_ROOT/commands/gaia-create-story.html"
  [ "$status" -eq 0 ]
}
