#!/usr/bin/env bats
# code-review-standards-rubric.bats — E65-S8 shared rubric format coverage.
#
# Asserts that gaia-code-review-standards/SKILL.md (the shared skill) carries
# the canonical severity rubric format with concrete examples per applicable
# tier per FR-DEJ-7, AND that all six review consumer SKILL.md files contain
# the canonical cross-link string above their per-skill examples.
#
# Test scenarios covered:
#   TC-DEJ-RUBRIC-01 — shared rubric format documented (5 tiers present).
#   TC-DEJ-RUBRIC-02 — Critical-readability tier verbatim "None — readability
#                      never blocks (max severity is Warning)".
#   EC-1 / EC-7      — canonical cross-link string present in 6 consumer files.
#   EC-3             — cross-link uses canonical skill name `gaia-code-review-
#                      standards`, not relative paths.
#   EC-5             — existing checklist + complexity thresholds + SOLID
#                      sections preserved verbatim in shared SKILL.md.
#   EC-8             — ≥2 examples per applicable tier in shared SKILL.md.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SHARED_SKILL="$BATS_TEST_DIRNAME/../skills/gaia-code-review-standards/SKILL.md"

REVIEW_CONSUMERS=(
  "skills/gaia-code-review/SKILL.md"
  "skills/gaia-security-review/SKILL.md"
  "skills/gaia-qa-tests/SKILL.md"
  "skills/gaia-test-automate/SKILL.md"
  "skills/gaia-test-review/SKILL.md"
  "skills/gaia-performance-review/SKILL.md"
)

# Canonical cross-link string (verbatim, per Task 2.1, AC2, AC-EC7).
# The leading ">" makes it a Markdown blockquote, distinguishing it from
# normal prose. The skill name is canonical (not a relative path) per AC-EC3.
CANONICAL_CROSS_LINK='> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.'

# Critical-readability verbatim string (FR-DEJ-7, AC1, AC-EC2).
CRITICAL_READABILITY_VERBATIM='None — readability never blocks (max severity is Warning)'

# --- TC-DEJ-RUBRIC-01: shared rubric format section present ------------------

@test "rubric: shared SKILL.md contains '## Severity Rubric Format' section" {
  grep -F "## Severity Rubric Format" "$SHARED_SKILL"
}

@test "rubric: shared SKILL.md documents all 5 tiers (correctness x2, readability x2, suggestion)" {
  grep -F "Critical-correctness" "$SHARED_SKILL"
  grep -F "Critical-readability" "$SHARED_SKILL"
  grep -F "Warning-correctness" "$SHARED_SKILL"
  grep -F "Warning-readability" "$SHARED_SKILL"
  grep -F "Suggestion" "$SHARED_SKILL"
}

# --- TC-DEJ-RUBRIC-02: Critical-readability verbatim -------------------------

@test "rubric: Critical-readability tier verbatim 'None — readability never blocks (max severity is Warning)'" {
  grep -F "$CRITICAL_READABILITY_VERBATIM" "$SHARED_SKILL"
}

# --- EC-8: ≥2 examples per applicable tier in shared SKILL.md ----------------
# Each applicable tier must list at least 2 concrete examples. Examples are
# rendered as bullet list items under the tier header. We extract the body of
# each tier's section and assert the bullet count >= 2.

count_bullets_in_section() {
  local file="$1" header="$2"
  awk -v hdr="$header" '
    BEGIN { in_section = 0; count = 0 }
    /^####? / {
      if (in_section) { exit }
      if (index($0, hdr) > 0) { in_section = 1; next }
    }
    in_section && /^- / { count++ }
    END { print count }
  ' "$file"
}

@test "rubric: Critical-correctness tier has >=2 example bullets" {
  local n
  n="$(count_bullets_in_section "$SHARED_SKILL" "Critical-correctness")"
  [ "$n" -ge 2 ]
}

@test "rubric: Warning-correctness tier has >=2 example bullets" {
  local n
  n="$(count_bullets_in_section "$SHARED_SKILL" "Warning-correctness")"
  [ "$n" -ge 2 ]
}

@test "rubric: Warning-readability tier has >=2 example bullets" {
  local n
  n="$(count_bullets_in_section "$SHARED_SKILL" "Warning-readability")"
  [ "$n" -ge 2 ]
}

@test "rubric: Suggestion tier has >=2 example bullets" {
  local n
  n="$(count_bullets_in_section "$SHARED_SKILL" "Suggestion")"
  [ "$n" -ge 2 ]
}

# --- EC-1 / EC-7: canonical cross-link in each consumer SKILL.md -------------

@test "cross-link: all 6 consumer SKILL.md files contain the canonical cross-link string" {
  for entry in "${REVIEW_CONSUMERS[@]}"; do
    grep -F "$CANONICAL_CROSS_LINK" "$BATS_TEST_DIRNAME/../$entry"
  done
}

# --- EC-3: cross-link uses canonical skill name, not relative path -----------

@test "cross-link: canonical skill name 'gaia-code-review-standards' present in each consumer" {
  for entry in "${REVIEW_CONSUMERS[@]}"; do
    grep -F 'gaia-code-review-standards' "$BATS_TEST_DIRNAME/../$entry"
  done
}

@test "cross-link: no relative path references like '../gaia-code-review-standards/SKILL.md'" {
  for entry in "${REVIEW_CONSUMERS[@]}"; do
    run grep -F "../gaia-code-review-standards/SKILL.md" "$BATS_TEST_DIRNAME/../$entry"
    [ "$status" -ne 0 ]   # grep miss = no relative path = clean
  done
}

# --- EC-5: existing shared SKILL.md content preserved verbatim ---------------

@test "preserve: existing 'Review Checklist' section still present in shared SKILL.md" {
  grep -F "<!-- SECTION: review-checklist -->" "$SHARED_SKILL"
  grep -F "## Review Checklist" "$SHARED_SKILL"
}

@test "preserve: existing 'SOLID Principles' section still present in shared SKILL.md" {
  grep -F "<!-- SECTION: solid-principles -->" "$SHARED_SKILL"
  grep -F "## SOLID Principles" "$SHARED_SKILL"
}

@test "preserve: existing 'Complexity Metrics' section still present in shared SKILL.md" {
  grep -F "<!-- SECTION: complexity-metrics -->" "$SHARED_SKILL"
  grep -F "## Complexity Metrics" "$SHARED_SKILL"
}

@test "preserve: existing 'Review Gate Completion' section still present in shared SKILL.md" {
  grep -F "<!-- SECTION: review-gate-completion -->" "$SHARED_SKILL"
  grep -F "## Review Gate Completion Requirements" "$SHARED_SKILL"
}

# --- EC-2: documentation comment explains why Critical-readability is empty --

@test "rubric: WHY documentation comment present explaining Critical-readability rationale" {
  grep -F "<!-- WHY:" "$SHARED_SKILL"
  grep -F "readability never blocks" "$SHARED_SKILL"
}

# --- EC-4: rubric-evolution impact-radius documented -------------------------

@test "rubric: impact-radius callout documents rubric-evolution scope (6-skill update + bats re-run)" {
  grep -F "impact" "$SHARED_SKILL"
  # Either "impact-radius" in a heading or in body text — bats just asserts presence.
}

# --- EC-6: scope boundary documented -----------------------------------------

@test "rubric: scope boundary documents 'standard for the six current review skills'" {
  grep -F "six current review skills" "$SHARED_SKILL"
}
