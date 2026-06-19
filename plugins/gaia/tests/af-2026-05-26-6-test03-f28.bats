#!/usr/bin/env bats
# AF-2026-05-26-6: F-28 — reconcile the review-report path/name reference
# authorities (review-summary-gen.sh CANONICAL_REPORT_RELPATHS + the
# gaia-run-all-reviews SKILL.md table) to the FR-402 type-prefix-FIRST
# convention the six per-review skills actually write to. The per-review
# SKILL.md write paths were already correct and MUST NOT change here.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SUMMARY="$PLUGIN_ROOT/scripts/review-summary-gen.sh"
  RUNALL="$PLUGIN_ROOT/skills/gaia-run-all-reviews/SKILL.md"
}

teardown() { common_teardown; }

# --- review-summary-gen.sh CANONICAL_REPORT_RELPATHS is type-first ---

@test "CANONICAL_REPORT_RELPATHS uses type-first names" {
  for tok in code-review qa-tests security-review test-automate-review test-review performance-review; do
    run grep -F "/${tok}-{key}.md" "$SUMMARY"
    [ "$status" -eq 0 ] || { echo "missing type-first relpath for $tok"; false; }
  done
}

@test "CANONICAL_REPORT_RELPATHS no longer uses the reversed {key}-type form" {
  run grep -E '\{key\}-(code-review|qa-tests|security-review|test-automation|test-review|performance-review)\.md' "$SUMMARY"
  [ "$status" -ne 0 ]
}

@test "all six canonical relpaths resolve under implementation-artifacts" {
  # No {test_artifacts} placeholder remains in the report relpaths array.
  run bash -c "awk '/CANONICAL_REPORT_RELPATHS=\\(/{f=1} f&&/^\\)/{f=0} f' '$SUMMARY' | grep -c test_artifacts"
  [ "$output" = "0" ]
}

# --- gaia-run-all-reviews SKILL.md table is type-first ---

@test "run-all-reviews table uses type-first impl-artifacts paths" {
  for tok in code-review qa-tests security-review test-automate-review test-review performance-review; do
    run grep -F "implementation-artifacts/${tok}-{key}.md" "$RUNALL"
    [ "$status" -eq 0 ] || { echo "table missing type-first path for $tok"; false; }
  done
}

@test "run-all-reviews table no longer routes test-aligned reviews to test-artifacts/" {
  run grep -E 'test-artifacts/\{key\}-(qa-tests|test-automation|test-review)\.md' "$RUNALL"
  [ "$status" -ne 0 ]
}

# End-to-end proof that the corrected type-first paths are found by
# review-summary-gen's proof-of-execution check (no MISSING) is covered by
# TC-OTP-2 in tests/review-summary-gen-canonical-relpaths.bats, whose
# seed_gaia_canonical helper now seeds the type-first form. Not duplicated here.
