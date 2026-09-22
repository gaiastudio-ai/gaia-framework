#!/usr/bin/env bats
# review-rubric-rebind.bats -- rebind-completeness assertions for review
# rubrics, review-skill template, and base dev persona.
#
# Validates that the six review rubrics carry the design-record reference
# formulation and zero word-bounded hits for the retired provider literal,
# that the review-skill template carries the design-record formulation,
# and that the base dev persona directs to the project reference.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Split-fragment provider literal -- never contiguous in this file
  PROVIDER="$(printf '%s%s' 'fig' 'ma')"
  # Retired integration skill name -- also split
  RETIRED_SKILL="$(printf '%s%s%s' 'fig' 'ma-' 'integration')"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# extract_phase4_block FILE
#
# Extracts the Phase 4 block (between "### Phase 4" and "### Phase 5")
# from a rubric SKILL.md.  Returns the body lines only (heading lines
# stripped).
#
# WARNING: This block extraction is load-bearing for placement-sensitive
# assertions.  The test asserts that "design-record" and "fidelity" appear
# INSIDE the Phase 4 section, not merely anywhere in the file.  Do NOT
# "simplify" this into a whole-file grep -- that silently re-opens the hole
# where the fidelity bullet could drift into References or Notes and still
# pass.
extract_phase4_block() {
  sed -n '/^### Phase 4/,/^### Phase 5/{ /^### Phase [45]/d; p; }' "$1"
}

# extract_step4b_block FILE
#
# Extracts the Step 4b block (between "### Step 4b" and the next "### "
# heading) from the review-security SKILL.md.  Same placement rationale
# as extract_phase4_block above.
extract_step4b_block() {
  sed -n '/^### Step 4b/,/^### /{ /^### Step 4b/d; /^### /d; p; }' "$1"
}

# extract_template_phase4_block FILE
#
# Extracts the Phase 4 block from the review-skill template.  Same
# placement rationale as extract_phase4_block above.
extract_template_phase4_block() {
  sed -n '/^### Phase 4/,/^### Phase 5/{ /^### Phase [45]/d; p; }' "$1"
}

# ---------------------------------------------------------------------------
# AC1 — zero word-bounded provider hits per rubric
# ---------------------------------------------------------------------------

@test "(AC1) code-review SKILL.md has zero word-bounded provider hits" {
  local f="$REPO_ROOT/skills/gaia-code-review/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in $f" >&2; return 1; }
}

@test "(AC1) performance-review SKILL.md has zero word-bounded provider hits" {
  local f="$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in $f" >&2; return 1; }
}

@test "(AC1) qa-tests SKILL.md has zero word-bounded provider hits" {
  local f="$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in $f" >&2; return 1; }
}

@test "(AC1) security-review deprecated SKILL.md has zero word-bounded provider hits" {
  local f="$REPO_ROOT/skills/gaia-security-review/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in $f" >&2; return 1; }
}

@test "(AC1) test-automate SKILL.md has zero word-bounded provider hits" {
  local f="$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in $f" >&2; return 1; }
}

@test "(AC1) test-review SKILL.md has zero word-bounded provider hits" {
  local f="$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in $f" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2 — each rubric contains design-record reference under fidelity
#
# These are placement-sensitive: the block extraction ensures the
# design-record text lives INSIDE the Phase 4 / Step 4b section, not
# merely somewhere in the file.  See the helper comments above.
# ---------------------------------------------------------------------------

@test "(AC2) code-review SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-code-review/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "design-record" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "fidelity" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

@test "(AC2) performance-review SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "design-record" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "fidelity" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

@test "(AC2) qa-tests SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "design-record" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "fidelity" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

@test "(AC2) review-security canonical SKILL.md contains design-record reference in Step 4b" {
  local f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  # WARNING: Block extraction is load-bearing here.  The test asserts that
  # design-record and fidelity appear INSIDE the Step 4b section.  A bullet
  # dropped into References or Notes would fail this test.  Do NOT simplify
  # this into a whole-file grep.
  local block
  block="$(extract_step4b_block "$f")"
  [ -n "$block" ] || { echo "Step 4b block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "design-record" || { echo "design-record missing from Step 4b in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "fidelity" || { echo "fidelity missing from Step 4b in $f" >&2; return 1; }
}

@test "(AC2) test-automate SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "design-record" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "fidelity" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

@test "(AC2) test-review SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "design-record" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "fidelity" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC3 — review-skill template
# ---------------------------------------------------------------------------

@test "(AC3) review-skill-template contains design-record reference formulation" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  # Block-extracted: design-record must live inside the Phase 4 section, not
  # merely anywhere in the file.  Mirrors the AC2 rubric pattern.
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  printf '%s' "$block" | grep -qi "design-record" || \
    { echo "design-record missing from Phase 4 in template" >&2; return 1; }
}

@test "(AC3) review-skill-template has zero word-bounded provider hits" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in template" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC4 — base dev persona
# ---------------------------------------------------------------------------

@test "(AC4) base-dev persona directs to project reference for design truth" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  # Must contain either "design-record" or "project reference"
  grep -qiE "design-record|project reference" "$f" || \
    { echo "neither design-record nor project reference found in base-dev" >&2; return 1; }
}

@test "(AC4) base-dev persona has no provider token/cache/spec-extraction guidance" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  # Zero word-bounded provider hits
  run grep -ciw "$PROVIDER" "$f"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output in base-dev" >&2; return 1; }
  # Extract the design consumption section and verify no cache guidance.
  # The section MUST exist -- an empty extraction means the heading was
  # renamed and the guard silently no-ops, hiding any cache/spec-extraction
  # text that may have been added under the new heading.
  local design_section
  design_section="$(sed -n '/^## Design Consumption/,/^## /{ /^## /!p; }' "$f")"
  [ -n "$design_section" ] || \
    { echo "Design Consumption section missing or empty in $f -- heading renamed?" >&2; return 1; }
  run bash -c 'printf "%s" "$1" | grep -ci "cache"' _ "$design_section"
  [ "$output" = "0" ] || { echo "cache guidance found in Design Consumption section" >&2; return 1; }
  run bash -c 'printf "%s" "$1" | grep -ciE "spec-extraction|extract.*spec"' _ "$design_section"
  [ "$output" = "0" ] || { echo "spec-extraction guidance found in Design Consumption section" >&2; return 1; }
}

@test "(AC4) base-dev persona JIT list does not include retired integration skill" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  # The retired skill name must not appear anywhere in the file
  run grep -c "$RETIRED_SKILL" "$f"
  [ "$output" = "0" ] || { echo "retired skill name still present in base-dev ($output hits)" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC-EC2 — rebound fidelity bullet reports unavailable on UI project
# ---------------------------------------------------------------------------

@test "(AC-EC2) rebound fidelity bullet reports unavailable rather than skipping on UI project" {
  # Each of the five non-deprecated rubrics must mention "unavailable" in the
  # fidelity block AND must NOT say "skip silently" in that block.
  local rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for f in "${rubrics[@]}"; do
    local fidelity_block
    # WARNING: Block extraction is load-bearing.  See extract_phase4_block.
    fidelity_block="$(extract_phase4_block "$f")"
    [ -n "$fidelity_block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
    # Must explicitly say "unavailable" (not just "finding" which is vacuously true)
    printf '%s' "$fidelity_block" | grep -qi "unavailable" || \
      { echo "unavailable missing from Phase 4 fidelity in $f" >&2; return 1; }
    # Must NOT say "skip silently" -- the old wording
    run bash -c 'printf "%s" "$1" | grep -ci "skip silently"' _ "$fidelity_block"
    [ "$output" = "0" ] || { echo "skip silently still present in $f" >&2; return 1; }
  done
  # review-security uses Step 4b instead of Phase 4 -- same obligation applies
  local sec_f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$sec_f" ] || { echo "file missing: $sec_f" >&2; return 1; }
  local step4b_block
  step4b_block="$(extract_step4b_block "$sec_f")"
  [ -n "$step4b_block" ] || { echo "Step 4b block empty in $sec_f" >&2; return 1; }
  printf '%s' "$step4b_block" | grep -qi "unavailable" || \
    { echo "unavailable missing from Step 4b fidelity in $sec_f" >&2; return 1; }
  run bash -c 'printf "%s" "$1" | grep -ci "skip silently"' _ "$step4b_block"
  [ "$output" = "0" ] || { echo "skip silently still present in Step 4b of $sec_f" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC-EC3 — rebound fidelity bullet records not-applicable on non-UI project
# ---------------------------------------------------------------------------

@test "(AC-EC3) rebound fidelity bullet records not-applicable on non-UI project" {
  local rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for f in "${rubrics[@]}"; do
    local fidelity_block
    # WARNING: Block extraction is load-bearing.  See extract_phase4_block.
    fidelity_block="$(extract_phase4_block "$f")"
    [ -n "$fidelity_block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
    printf '%s' "$fidelity_block" | grep -qiE "not-applicable|not applicable" || \
      { echo "not-applicable missing from Phase 4 fidelity in $f" >&2; return 1; }
  done
  # review-security uses Step 4b instead of Phase 4 -- same obligation applies
  local sec_f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$sec_f" ] || { echo "file missing: $sec_f" >&2; return 1; }
  local step4b_block
  step4b_block="$(extract_step4b_block "$sec_f")"
  [ -n "$step4b_block" ] || { echo "Step 4b block empty in $sec_f" >&2; return 1; }
  printf '%s' "$step4b_block" | grep -qiE "not-applicable|not applicable" || \
    { echo "not-applicable missing from Step 4b fidelity in $sec_f" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2/AC3 extended — unreachability branch present in all seven surfaces
#
# The unreachability rule ("surface unreachability as a finding, never fall
# back to a local copy") is a security control added to every surface.
# Placement-sensitive: asserted inside the extracted block, not whole-file.
# ---------------------------------------------------------------------------

@test "(AC2) unreachability branch present in all five Phase 4 rubrics" {
  local rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for f in "${rubrics[@]}"; do
    local block
    block="$(extract_phase4_block "$f")"
    [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
    printf '%s' "$block" | grep -qiE "unreachab.*finding|finding.*unreachab" || \
      { echo "unreachability not paired with finding in Phase 4 of $f" >&2; return 1; }
    printf '%s' "$block" | grep -qiE "never.*fall back|never.*fallback" || \
      { echo "never-fall-back mandate missing from Phase 4 of $f" >&2; return 1; }
  done
}

@test "(AC2) unreachability branch present in review-security Step 4b" {
  local f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_step4b_block "$f")"
  [ -n "$block" ] || { echo "Step 4b block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qiE "unreachab.*finding|finding.*unreachab" || \
    { echo "unreachability not paired with finding in Step 4b of $f" >&2; return 1; }
  printf '%s' "$block" | grep -qiE "never.*fall back|never.*fallback" || \
    { echo "never-fall-back mandate missing from Step 4b of $f" >&2; return 1; }
}

@test "(AC3) unreachability branch present in review-skill template" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  printf '%s' "$block" | grep -qiE "unreachab.*finding|finding.*unreachab" || \
    { echo "unreachability not paired with finding in Phase 4 of template" >&2; return 1; }
  printf '%s' "$block" | grep -qiE "never.*fall back|never.*fallback" || \
    { echo "never-fall-back mandate missing from Phase 4 of template" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC-EC1 — each fidelity block calls out that a newly-firing check is
# correct behaviour, not a regression (placement-sensitive)
# ---------------------------------------------------------------------------

@test "(AC-EC1) Phase 4 fidelity blocks note correct behaviour for first-time firing" {
  local rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for f in "${rubrics[@]}"; do
    local block
    # WARNING: Block extraction is load-bearing.  See extract_phase4_block.
    block="$(extract_phase4_block "$f")"
    [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
    printf '%s' "$block" | grep -qi "correct behaviour, not a regression" || \
      { echo "correct-behaviour note missing from Phase 4 fidelity in $f" >&2; return 1; }
  done
}

@test "(AC-EC1) Step 4b notes correct behaviour for first-time firing" {
  local f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_step4b_block "$f")"
  [ -n "$block" ] || { echo "Step 4b block empty in $f" >&2; return 1; }
  printf '%s' "$block" | grep -qi "correct behaviour, not a regression" || \
    { echo "correct-behaviour note missing from Step 4b in $f" >&2; return 1; }
}

@test "(AC-EC1) review-skill template notes correct behaviour for first-time firing" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  printf '%s' "$block" | grep -qi "correct behaviour, not a regression" || \
    { echo "correct-behaviour note missing from Phase 4 in template" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC3 extended — template carries unavailable and not-applicable branches
# (mirrors the AC-EC2/AC-EC3 rubric assertions to gate template drift)
# ---------------------------------------------------------------------------

@test "(AC3) review-skill-template reports unavailable on UI project without reference" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  printf '%s' "$block" | grep -qi "unavailable" || \
    { echo "unavailable missing from Phase 4 in template" >&2; return 1; }
}

@test "(AC3) review-skill-template records not-applicable on non-UI project" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  printf '%s' "$block" | grep -qiE "not-applicable|not applicable" || \
    { echo "not-applicable missing from Phase 4 in template" >&2; return 1; }
}
