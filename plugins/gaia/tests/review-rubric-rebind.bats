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

# extract_design_consumption_section FILE
#
# Extracts the Design Consumption section (between "## Design Consumption"
# and the next "## " heading) from the base dev persona.  Returns body
# lines only (heading lines stripped).
#
# Same placement rationale as extract_phase4_block — assertions must fire
# INSIDE the section, not whole-file, because this section has the widest
# blast radius (inherited by every stack dev agent).
extract_design_consumption_section() {
  sed -n '/^## Design Consumption/,/^## /{ /^## /!p; }' "$1"
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
  grep -qi "design-record" <<<"$block" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  grep -qi "fidelity" <<<"$block" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

@test "(AC2) performance-review SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  grep -qi "design-record" <<<"$block" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  grep -qi "fidelity" <<<"$block" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

@test "(AC2) qa-tests SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  grep -qi "design-record" <<<"$block" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  grep -qi "fidelity" <<<"$block" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
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
  grep -qi "design-record" <<<"$block" || { echo "design-record missing from Step 4b in $f" >&2; return 1; }
  grep -qi "fidelity" <<<"$block" || { echo "fidelity missing from Step 4b in $f" >&2; return 1; }
}

@test "(AC2) test-automate SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  grep -qi "design-record" <<<"$block" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  grep -qi "fidelity" <<<"$block" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
}

@test "(AC2) test-review SKILL.md contains design-record reference under fidelity" {
  local f="$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  local block
  block="$(extract_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in $f" >&2; return 1; }
  grep -qi "design-record" <<<"$block" || { echo "design-record missing from Phase 4 in $f" >&2; return 1; }
  grep -qi "fidelity" <<<"$block" || { echo "fidelity missing from Phase 4 in $f" >&2; return 1; }
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
  grep -qi "design-record" <<<"$block" || \
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
    grep -qi "unavailable" <<<"$fidelity_block" || \
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
  grep -qi "unavailable" <<<"$step4b_block" || \
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
    grep -qiE "not-applicable|not applicable" <<<"$fidelity_block" || \
      { echo "not-applicable missing from Phase 4 fidelity in $f" >&2; return 1; }
  done
  # review-security uses Step 4b instead of Phase 4 -- same obligation applies
  local sec_f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$sec_f" ] || { echo "file missing: $sec_f" >&2; return 1; }
  local step4b_block
  step4b_block="$(extract_step4b_block "$sec_f")"
  [ -n "$step4b_block" ] || { echo "Step 4b block empty in $sec_f" >&2; return 1; }
  grep -qiE "not-applicable|not applicable" <<<"$step4b_block" || \
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
    grep -qiE "unreachab.*finding|finding.*unreachab" <<<"$block" || \
      { echo "unreachability not paired with finding in Phase 4 of $f" >&2; return 1; }
    grep -qiE "never.*fall back|never.*fallback" <<<"$block" || \
      { echo "never-fall-back mandate missing from Phase 4 of $f" >&2; return 1; }
  done
}

@test "(AC2) unreachability branch present in review-security Step 4b" {
  local f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_step4b_block "$f")"
  [ -n "$block" ] || { echo "Step 4b block empty in $f" >&2; return 1; }
  grep -qiE "unreachab.*finding|finding.*unreachab" <<<"$block" || \
    { echo "unreachability not paired with finding in Step 4b of $f" >&2; return 1; }
  grep -qiE "never.*fall back|never.*fallback" <<<"$block" || \
    { echo "never-fall-back mandate missing from Step 4b of $f" >&2; return 1; }
}

@test "(AC3) unreachability branch present in review-skill template" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  grep -qiE "unreachab.*finding|finding.*unreachab" <<<"$block" || \
    { echo "unreachability not paired with finding in Phase 4 of template" >&2; return 1; }
  grep -qiE "never.*fall back|never.*fallback" <<<"$block" || \
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
    grep -qi "correct behaviour, not a regression" <<<"$block" || \
      { echo "correct-behaviour note missing from Phase 4 fidelity in $f" >&2; return 1; }
  done
}

@test "(AC-EC1) Step 4b notes correct behaviour for first-time firing" {
  local f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_step4b_block "$f")"
  [ -n "$block" ] || { echo "Step 4b block empty in $f" >&2; return 1; }
  grep -qi "correct behaviour, not a regression" <<<"$block" || \
    { echo "correct-behaviour note missing from Step 4b in $f" >&2; return 1; }
}

@test "(AC-EC1) review-skill template notes correct behaviour for first-time firing" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  grep -qi "correct behaviour, not a regression" <<<"$block" || \
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
  grep -qi "unavailable" <<<"$block" || \
    { echo "unavailable missing from Phase 4 in template" >&2; return 1; }
}

@test "(AC3) review-skill-template records not-applicable on non-UI project" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  grep -qiE "not-applicable|not applicable" <<<"$block" || \
    { echo "not-applicable missing from Phase 4 in template" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# F1 closure — no positive fallback instruction coexists with the mandate
#
# The never-fall-back mandate is already asserted present in each surface.
# This test closes the inverse gap: any occurrence of "fall back" or
# "local copy" inside a fidelity block MUST co-occur with "never" on the
# same line.  Without this guard, a line like "fall back to a local copy
# for faster token resolution" passes every existing assertion.
# Mirrors the pattern in design-a11y-rebind.bats test (AC-EC4), lines 86-87.
# ---------------------------------------------------------------------------

@test "(AC2) no positive fallback instruction in Phase 4 rubric fidelity blocks" {
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
    # Occurrence-counting guard: total "fall back" occurrences must equal
    # negated "never...fall back" occurrences.  A positive instruction
    # (e.g. "fall back to a local copy for faster resolution") adds to the
    # total without adding to the negated count, even on the same line as
    # the mandate.  Line-level grep|grep-v cannot catch same-line co-
    # occurrence; occurrence counting can.
    local total_fb never_fb total_lc never_lc
    total_fb="$(printf '%s' "$block" | grep -oi 'fall back' | wc -l | tr -d ' ')"
    never_fb="$(printf '%s' "$block" | grep -oiE 'never[^.]*fall back' | wc -l | tr -d ' ')"
    [ "$total_fb" -le "$never_fb" ] || \
      { echo "positive fall-back in Phase 4 of $f ($total_fb total, $never_fb negated)" >&2; return 1; }
    total_lc="$(printf '%s' "$block" | grep -oiE 'local[^.]*copy' | wc -l | tr -d ' ')"
    never_lc="$(printf '%s' "$block" | grep -oiE '(never|not)[^.]*local[^.]*copy' | wc -l | tr -d ' ')"
    [ "$total_lc" -gt 0 ] || \
      { echo "local-copy guard vacuous (0 mentions) in Phase 4 of $f" >&2; return 1; }
    [ "$total_lc" -le "$never_lc" ] || \
      { echo "positive local-copy in Phase 4 of $f ($total_lc total, $never_lc negated)" >&2; return 1; }
  done
}

@test "(AC2) no positive fallback instruction in review-security Step 4b" {
  local f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_step4b_block "$f")"
  [ -n "$block" ] || { echo "Step 4b block empty in $f" >&2; return 1; }
  local total_fb never_fb total_lc never_lc
  total_fb="$(printf '%s' "$block" | grep -oi 'fall back' | wc -l | tr -d ' ')"
  never_fb="$(printf '%s' "$block" | grep -oiE 'never[^.]*fall back' | wc -l | tr -d ' ')"
  [ "$total_fb" -le "$never_fb" ] || \
    { echo "positive fall-back in Step 4b of $f ($total_fb total, $never_fb negated)" >&2; return 1; }
  total_lc="$(printf '%s' "$block" | grep -oiE 'local[^.]*copy' | wc -l | tr -d ' ')"
  never_lc="$(printf '%s' "$block" | grep -oiE '(never|not)[^.]*local[^.]*copy' | wc -l | tr -d ' ')"
  [ "$total_lc" -gt 0 ] || \
    { echo "local-copy guard vacuous (0 mentions) in Step 4b of $f" >&2; return 1; }
  [ "$total_lc" -le "$never_lc" ] || \
    { echo "positive local-copy in Step 4b of $f ($total_lc total, $never_lc negated)" >&2; return 1; }
}

@test "(AC3) no positive fallback instruction in review-skill template Phase 4" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  [ -n "$block" ] || { echo "Phase 4 block empty in template" >&2; return 1; }
  local total_fb never_fb total_lc never_lc
  total_fb="$(printf '%s' "$block" | grep -oi 'fall back' | wc -l | tr -d ' ')"
  never_fb="$(printf '%s' "$block" | grep -oiE 'never[^.]*fall back' | wc -l | tr -d ' ')"
  [ "$total_fb" -le "$never_fb" ] || \
    { echo "positive fall-back in Phase 4 of template ($total_fb total, $never_fb negated)" >&2; return 1; }
  total_lc="$(printf '%s' "$block" | grep -oiE 'local[^.]*copy' | wc -l | tr -d ' ')"
  never_lc="$(printf '%s' "$block" | grep -oiE '(never|not)[^.]*local[^.]*copy' | wc -l | tr -d ' ')"
  [ "$total_lc" -gt 0 ] || \
    { echo "local-copy guard vacuous (0 mentions) in template" >&2; return 1; }
  [ "$total_lc" -le "$never_lc" ] || \
    { echo "positive local-copy in Phase 4 of template ($total_lc total, $never_lc negated)" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# F2 closure — base-dev persona behavioral branches
#
# The persona's Design Consumption section carries all three branches
# (unreachability, unavailable, not-applicable) inherited by every stack
# dev agent.  These are the same branches tested in each rubric and
# template but were previously untested in the persona itself.
# Section-scoped: asserted inside the extracted Design Consumption section.
# ---------------------------------------------------------------------------

@test "(AC4) base-dev persona carries unreachability branch in Design Consumption" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  [ -n "$section" ] || \
    { echo "Design Consumption section missing or empty in $f" >&2; return 1; }
  # Unreachability paired with finding
  grep -qiE "unreachab.*finding|finding.*unreachab" <<<"$section" || \
    { echo "unreachability not paired with finding in Design Consumption of $f" >&2; return 1; }
  # Never-fall-back mandate
  grep -qiE "never.*fall back|never.*fallback" <<<"$section" || \
    { echo "never-fall-back mandate missing from Design Consumption of $f" >&2; return 1; }
}

@test "(AC4) base-dev persona carries unavailable branch in Design Consumption" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  [ -n "$section" ] || \
    { echo "Design Consumption section missing or empty in $f" >&2; return 1; }
  grep -qi "unavailable" <<<"$section" || \
    { echo "unavailable branch missing from Design Consumption of $f" >&2; return 1; }
}

@test "(AC4) base-dev persona carries not-applicable branch in Design Consumption" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  [ -n "$section" ] || \
    { echo "Design Consumption section missing or empty in $f" >&2; return 1; }
  grep -qiE "not-applicable|not applicable" <<<"$section" || \
    { echo "not-applicable branch missing from Design Consumption of $f" >&2; return 1; }
}

@test "(AC4) no positive fallback instruction in base-dev Design Consumption" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  [ -n "$section" ] || \
    { echo "Design Consumption section missing or empty in $f" >&2; return 1; }
  # Occurrence-counting guard — same rationale as the rubric inverse guards.
  local total_fb never_fb total_lc never_lc
  total_fb="$(printf '%s' "$section" | grep -oi 'fall back' | wc -l | tr -d ' ')"
  never_fb="$(printf '%s' "$section" | grep -oiE 'never[^.]*fall back' | wc -l | tr -d ' ')"
  [ "$total_fb" -le "$never_fb" ] || \
    { echo "positive fall-back in Design Consumption ($total_fb total, $never_fb negated)" >&2; return 1; }
  total_lc="$(printf '%s' "$section" | grep -oiE 'local[^.]*copy' | wc -l | tr -d ' ')"
  never_lc="$(printf '%s' "$section" | grep -oiE '(never|not)[^.]*local[^.]*copy' | wc -l | tr -d ' ')"
  [ "$total_lc" -gt 0 ] || \
    { echo "local-copy guard vacuous (0 mentions) in Design Consumption" >&2; return 1; }
  [ "$total_lc" -le "$never_lc" ] || \
    { echo "positive local-copy in Design Consumption ($total_lc total, $never_lc negated)" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Helper: extract review-perf Step 4d Design Fidelity block
# ---------------------------------------------------------------------------

# extract_reviewperf_step4d_block FILE
#
# Extracts the Step 4d Design Fidelity block (between "#### Step 4d" heading
# containing "Design Fidelity" and the next "###" or "####" heading).
# Returns the body lines only (heading lines excluded).
extract_reviewperf_step4d_block() {
  sed -n '/^#### Step 4d.*Design Fidelity/,/^###/{
    /^#### Step 4d.*Design Fidelity/d
    /^###/d
    /^####/d
    p
  }' "$1" | sed '/^####/,$d'
}

# ---------------------------------------------------------------------------
# Helper: extract a section and assert it is non-empty (fail, never skip)
# ---------------------------------------------------------------------------
require_section() {
  local section="$1" label="$2"
  [ -n "$section" ] || { echo "$label section is empty or missing" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Dual-project routing: content-type binding in base-dev persona
# ---------------------------------------------------------------------------

@test "base-dev Design Consumption binds tokens to design-system project and screens to product-design project" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  require_section "$section" "Design Consumption"
  # Token/component binding: design_system_project.reference in the same sentence
  printf '%s' "$section" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "token/component not bound to design_system_project.reference" >&2; return 1; }
  # Screen binding: product_design_project.reference in the same sentence
  printf '%s' "$section" | grep -iE 'screen[^.]*product_design_project\.reference' > /dev/null || \
    { echo "screen not bound to product_design_project.reference" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Dual-project routing: base-dev mutant with swapped references fails binding
# ---------------------------------------------------------------------------

@test "base-dev mutant with swapped project references fails content-type binding" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  require_section "$section" "Design Consumption"
  # Positive control: real section passes token binding
  printf '%s' "$section" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "positive control failed: token binding missing" >&2; return 1; }
  # True swap mutant via placeholder
  local swapped
  swapped="$(printf '%s' "$section" | sed 's/design_system_project/PLACEHOLDER_PROJ/g; s/product_design_project/design_system_project/g; s/PLACEHOLDER_PROJ/product_design_project/g')"
  # After swap: tokens should now say product_design_project — the token binding regex must fail
  run bash -c 'printf "%s" "$1" | grep -iE "(token|component)[^.]*design_system_project\.reference"' _ "$swapped"
  [ "$status" -ne 0 ] || { echo "true-swap mutant still passes token binding — test is vacuous" >&2; return 1; }
  # One-way replace mutant
  local oneway
  oneway="$(printf '%s' "$section" | sed 's/design_system_project/product_design_project/g')"
  run bash -c 'printf "%s" "$1" | grep -iE "(token|component)[^.]*design_system_project\.reference"' _ "$oneway"
  [ "$status" -ne 0 ] || { echo "one-way mutant still passes token binding — test is vacuous" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Dual-project routing: content-type binding across all 9 consumer sections
# ---------------------------------------------------------------------------

@test "all 9 consumer sections bind tokens to design-system project and screens to product-design project" {
  local checked=0
  # 1. Base dev persona
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  require_section "$section" "Design Consumption (_base-dev)"
  printf '%s' "$section" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "token binding missing in _base-dev" >&2; return 1; }
  printf '%s' "$section" | grep -iE 'screen[^.]*product_design_project\.reference' > /dev/null || \
    { echo "screen binding missing in _base-dev" >&2; return 1; }
  grep -qi 'via DesignSync' <<<"$section" || \
    { echo "DesignSync mention missing in _base-dev" >&2; return 1; }
  grep -q 'project/canvas\.json' <<<"$section" || \
    { echo "project/canvas.json mention missing in _base-dev" >&2; return 1; }
  checked=$((checked + 1))

  # 2-6. Five Phase-4 review skills
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    [ -f "$rf" ] || { echo "file missing: $rf" >&2; return 1; }
    local block
    block="$(extract_phase4_block "$rf")"
    require_section "$block" "Phase 4 ($(basename "$(dirname "$rf")"))"
    printf '%s' "$block" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
      { echo "token binding missing in $rf" >&2; return 1; }
    printf '%s' "$block" | grep -iE 'screen[^.]*product_design_project\.reference' > /dev/null || \
      { echo "screen binding missing in $rf" >&2; return 1; }
    grep -qi 'via DesignSync' <<<"$block" || \
      { echo "DesignSync mention missing in $rf" >&2; return 1; }
    grep -q 'project/canvas\.json' <<<"$block" || \
      { echo "project/canvas.json mention missing in $rf" >&2; return 1; }
    checked=$((checked + 1))
  done

  # 7. Security review (Step 4b extractor)
  local sec_f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$sec_f" ] || { echo "file missing: $sec_f" >&2; return 1; }
  local sec_block
  sec_block="$(extract_step4b_block "$sec_f")"
  require_section "$sec_block" "Step 4b (review-security)"
  printf '%s' "$sec_block" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "token binding missing in review-security Step 4b" >&2; return 1; }
  printf '%s' "$sec_block" | grep -iE 'screen[^.]*product_design_project\.reference' > /dev/null || \
    { echo "screen binding missing in review-security Step 4b" >&2; return 1; }
  grep -qi 'via DesignSync' <<<"$sec_block" || \
    { echo "DesignSync mention missing in review-security" >&2; return 1; }
  grep -q 'project/canvas\.json' <<<"$sec_block" || \
    { echo "project/canvas.json mention missing in review-security" >&2; return 1; }
  checked=$((checked + 1))

  # 8. Review-perf Step 4d
  local perf_f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$perf_f" ] || { echo "file missing: $perf_f" >&2; return 1; }
  local perf_block
  perf_block="$(extract_reviewperf_step4d_block "$perf_f")"
  require_section "$perf_block" "Step 4d (review-perf)"
  printf '%s' "$perf_block" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "token binding missing in review-perf Step 4d" >&2; return 1; }
  printf '%s' "$perf_block" | grep -iE 'screen[^.]*product_design_project\.reference' > /dev/null || \
    { echo "screen binding missing in review-perf Step 4d" >&2; return 1; }
  grep -qi 'via DesignSync' <<<"$perf_block" || \
    { echo "DesignSync mention missing in review-perf Step 4d" >&2; return 1; }
  grep -q 'project/canvas\.json' <<<"$perf_block" || \
    { echo "project/canvas.json mention missing in review-perf Step 4d" >&2; return 1; }
  checked=$((checked + 1))

  # 9. Template
  local tmpl_f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$tmpl_f" ] || { echo "file missing: $tmpl_f" >&2; return 1; }
  local tmpl_block
  tmpl_block="$(extract_template_phase4_block "$tmpl_f")"
  require_section "$tmpl_block" "Phase 4 (template)"
  printf '%s' "$tmpl_block" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "token binding missing in template" >&2; return 1; }
  printf '%s' "$tmpl_block" | grep -iE 'screen[^.]*product_design_project\.reference' > /dev/null || \
    { echo "screen binding missing in template" >&2; return 1; }
  grep -qi 'via DesignSync' <<<"$tmpl_block" || \
    { echo "DesignSync mention missing in template" >&2; return 1; }
  grep -q 'project/canvas\.json' <<<"$tmpl_block" || \
    { echo "project/canvas.json mention missing in template" >&2; return 1; }
  checked=$((checked + 1))

  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Dual-project routing: review-skill mutant with swapped reference fails
# ---------------------------------------------------------------------------

@test "review-skill mutant with swapped project references fails content-type binding" {
  local f="$REPO_ROOT/skills/gaia-code-review/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_phase4_block "$f")"
  require_section "$block" "Phase 4 (code-review)"
  # Positive control
  printf '%s' "$block" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "positive control failed: token binding missing in code-review" >&2; return 1; }
  # True swap mutant via placeholder
  local swapped
  swapped="$(printf '%s' "$block" | sed 's/design_system_project/PLACEHOLDER_PROJ/g; s/product_design_project/design_system_project/g; s/PLACEHOLDER_PROJ/product_design_project/g')"
  run bash -c 'printf "%s" "$1" | grep -iE "(token|component)[^.]*design_system_project\.reference"' _ "$swapped"
  [ "$status" -ne 0 ] || { echo "true-swap mutant still passes token binding" >&2; return 1; }
  # One-way replace mutant
  local oneway
  oneway="$(printf '%s' "$block" | sed 's/design_system_project/product_design_project/g')"
  run bash -c 'printf "%s" "$1" | grep -iE "(token|component)[^.]*design_system_project\.reference"' _ "$oneway"
  [ "$status" -ne 0 ] || { echo "one-way mutant still passes token binding" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# No positive screen-from-design-system instruction (counting-guard form)
# ---------------------------------------------------------------------------

@test "no positive screen-from-design-system instruction in any consumer section" {
  local scanned=0
  local screen_ds_pattern='screen[^.]*from the design.system project|read[^.]*screen[^.]*design.system|screen[^.]*design_system_project|screen[^.]*out of the design.system project|use[^.]*design.system[^.]*for screen|read boards from[^.]*design.system'

  # Negative control: the brand-style sentence must NOT match the pattern
  local brand_style_sentence="tokens and components come from the design-system project and screens from the product design project"
  local brand_style_hits
  brand_style_hits="$(printf '%s' "$brand_style_sentence" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  [ "$brand_style_hits" -eq 0 ] || { echo "negative control failed: brand-style sentence matches screen-from-DS pattern ($brand_style_hits hits)" >&2; return 1; }

  # Check all 9 sections
  # 1. Persona
  local f="$REPO_ROOT/agents/_base-dev.md"
  local section
  section="$(extract_design_consumption_section "$f")"
  require_section "$section" "Design Consumption (_base-dev)"
  local total_p negated_p
  total_p="$(printf '%s' "$section" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  negated_p="$(printf '%s' "$section" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
  [ "$total_p" -le "$negated_p" ] || \
    { echo "positive screen-from-DS in _base-dev ($total_p total, $negated_p negated)" >&2; return 1; }
  scanned=$((scanned + 1))

  # 2-6. Phase 4 skills
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    local block
    block="$(extract_phase4_block "$rf")"
    require_section "$block" "Phase 4 ($(basename "$(dirname "$rf")"))"
    total_p="$(printf '%s' "$block" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
    negated_p="$(printf '%s' "$block" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
    [ "$total_p" -le "$negated_p" ] || \
      { echo "positive screen-from-DS in $rf ($total_p total, $negated_p negated)" >&2; return 1; }
    scanned=$((scanned + 1))
  done

  # 7. Security review
  local sec_f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  local sec_block
  sec_block="$(extract_step4b_block "$sec_f")"
  require_section "$sec_block" "Step 4b (review-security)"
  total_p="$(printf '%s' "$sec_block" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  negated_p="$(printf '%s' "$sec_block" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
  [ "$total_p" -le "$negated_p" ] || \
    { echo "positive screen-from-DS in review-security ($total_p total, $negated_p negated)" >&2; return 1; }
  scanned=$((scanned + 1))

  # 8. Review-perf Step 4d
  local perf_f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  local perf_block
  perf_block="$(extract_reviewperf_step4d_block "$perf_f")"
  require_section "$perf_block" "Step 4d (review-perf)"
  total_p="$(printf '%s' "$perf_block" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  negated_p="$(printf '%s' "$perf_block" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
  [ "$total_p" -le "$negated_p" ] || \
    { echo "positive screen-from-DS in review-perf Step 4d ($total_p total, $negated_p negated)" >&2; return 1; }
  scanned=$((scanned + 1))

  # 9. Template
  local tmpl_f="$REPO_ROOT/knowledge/review-skill-template.md"
  local tmpl_block
  tmpl_block="$(extract_template_phase4_block "$tmpl_f")"
  require_section "$tmpl_block" "Phase 4 (template)"
  total_p="$(printf '%s' "$tmpl_block" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  negated_p="$(printf '%s' "$tmpl_block" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
  [ "$total_p" -le "$negated_p" ] || \
    { echo "positive screen-from-DS in template ($total_p total, $negated_p negated)" >&2; return 1; }
  scanned=$((scanned + 1))

  [ "$scanned" -eq 9 ] || { echo "expected 9 sections scanned, got $scanned" >&2; return 1; }

  # Mutant: insert a positive screen-from-DS instruction into one section
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-screen-ds-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  # Insert after the Phase 4 heading
  sed -i.bak '/^### Phase 4/a\
- Read screens from the design-system project for additional context.' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  local mutant_total mutant_negated
  mutant_total="$(printf '%s' "$mutant_block" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  mutant_negated="$(printf '%s' "$mutant_block" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
  [ "$mutant_total" -gt "$mutant_negated" ] || \
    { echo "mutant with positive screen-from-DS was not caught ($mutant_total total, $mutant_negated negated)" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant 2: field-literal form — "Read screen specifications from design_system_project.reference"
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-screen-field-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/^### Phase 4/a\
- Read screen specifications from `design_system_project.reference` via DesignSync.' "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  mutant_total="$(printf '%s' "$mutant_block" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  mutant_negated="$(printf '%s' "$mutant_block" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
  [ "$mutant_total" -gt "$mutant_negated" ] || \
    { echo "field-literal mutant not caught ($mutant_total total, $mutant_negated negated)" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant 3: paraphrase form — "Take screen layouts out of the design-system project."
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-screen-para-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/^### Phase 4/a\
- Take screen layouts out of the design-system project.' "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  mutant_total="$(printf '%s' "$mutant_block" | grep -oiE "$screen_ds_pattern" | wc -l | tr -d ' ')"
  mutant_negated="$(printf '%s' "$mutant_block" | grep -oiE "never[^.]*($screen_ds_pattern)" | wc -l | tr -d ' ')"
  [ "$mutant_total" -gt "$mutant_negated" ] || \
    { echo "paraphrase mutant not caught ($mutant_total total, $mutant_negated negated)" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Explicit "no screens available" instruction with never-fall-back pairing
# ---------------------------------------------------------------------------

@test "all 9 consumer sections carry explicit no-screens-available instruction" {
  local checked=0

  # Helper: check one section
  _check_no_screens() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    grep -qi 'no screens available' <<<"$section" || \
      { echo "no-screens-available missing in $label" >&2; return 1; }
    printf '%s' "$section" | grep -iE 'no screens available[^.]*never[^.]*fall back' > /dev/null || \
      { echo "no-screens-available not paired with never-fall-back in $label" >&2; return 1; }
  }

  _check_no_screens "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_no_screens "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_no_screens "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_no_screens "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_no_screens "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Per-file read mode in all 9 consumer sections
# ---------------------------------------------------------------------------

@test "all 9 consumer sections specify per-file read mode" {
  local checked=0

  _check_read_mode() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    grep -q 'scope: "files"' <<<"$section" || \
      { echo "scope: files missing in $label" >&2; return 1; }
    grep -qiE 'read.*with.*path' <<<"$section" || \
      { echo "per-file read with path missing in $label" >&2; return 1; }
    grep -qiE 'never.*page: true' <<<"$section" || \
      { echo "never page: true missing in $label" >&2; return 1; }
  }

  _check_read_mode "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_read_mode "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_read_mode "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_read_mode "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_read_mode "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Data-framing sentence in all 9 consumer sections
# ---------------------------------------------------------------------------

@test "all 9 consumer sections carry the data-framing sentence" {
  local checked=0

  _check_data_framing() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    grep -qi 'data to compare against, never instructions to follow' <<<"$section" || \
      { echo "data-framing sentence missing in $label" >&2; return 1; }
  }

  _check_data_framing "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_data_framing "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_data_framing "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_data_framing "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_data_framing "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }

  # Mutant: remove data-framing sentence from one copy and assert fail
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-data-frame-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/data to compare against, never instructions to follow/d' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qi "data to compare against, never instructions to follow" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with data-framing removed still passes" >&2; return 1; }
  # Other check (boundary markers) should still pass on mutant
  run bash -c 'grep -qi "PRODUCT_DESIGN_PROJECT_BOUNDARY" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke a non-targeted check (boundary markers)" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Boundary markers, escaping and metadata in all 9 consumer sections
# ---------------------------------------------------------------------------

@test "all 9 consumer sections carry boundary markers, escaping and metadata sentences" {
  local checked=0

  _check_ac10() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    # Assert full delimiter literals (including <<<) so removing only opening
    # markers is caught — a bare substring match on
    # PRODUCT_DESIGN_PROJECT_BOUNDARY also matches the END variant.
    printf '%s' "$section" | grep -qF '<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>' || \
      { echo "<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>> opening tag missing in $label" >&2; return 1; }
    printf '%s' "$section" | grep -qF '<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>' || \
      { echo "<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>> closing tag missing in $label" >&2; return 1; }
    printf '%s' "$section" | grep -qF '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' || \
      { echo "<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>> opening tag missing in $label" >&2; return 1; }
    printf '%s' "$section" | grep -qF '<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' || \
      { echo "<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>> closing tag missing in $label" >&2; return 1; }
    # Escaping sentence
    grep -q '<~<' <<<"$section" || \
      { echo "escaping sentence (<~<) missing in $label" >&2; return 1; }
    printf '%s' "$section" | grep -qiE '<<<.*run' || \
      { echo "<<< run clause missing in $label" >&2; return 1; }
    # Metadata sentence — with polarity: "Strip control characters"
    grep -qi 'strip control characters' <<<"$section" || \
      { echo "metadata 'strip control characters' polarity missing in $label" >&2; return 1; }
    grep -qiE 'title.*description.*capability' <<<"$section" || \
      { echo "metadata sentence (title, description, capability) missing in $label" >&2; return 1; }
  }

  _check_ac10 "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_ac10 "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_ac10 "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_ac10 "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_ac10 "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }

  # Mutant 1: remove escaping sentence
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-escape-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/<~</d' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -q "<~<" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with escaping removed still passes" >&2; return 1; }
  # Marker tags should still pass
  run bash -c 'grep -q "PRODUCT_DESIGN_PROJECT_BOUNDARY" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke marker tag check" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant 2: remove marker tags
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-markers-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/PRODUCT_DESIGN_PROJECT_BOUNDARY/d; /DESIGN_SYSTEM_PROJECT_BOUNDARY/d' "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -q "PRODUCT_DESIGN_PROJECT_BOUNDARY" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with markers removed still passes" >&2; return 1; }
  # Escaping should still pass
  run bash -c 'grep -q "<~<" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke escaping check" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant 3: remove metadata sentence
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-metadata-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/title.*description.*capability/Id' "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qiE "title.*description.*capability" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with metadata removed still passes" >&2; return 1; }
  # Markers should still pass
  run bash -c 'grep -q "PRODUCT_DESIGN_PROJECT_BOUNDARY" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke marker tag check" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Verdict provenance, single-source confidence and credential sentences
# ---------------------------------------------------------------------------

@test "all 9 consumer sections carry verdict provenance, single-source and credential sentences" {
  local checked=0

  _check_ac11() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    # Verdict provenance — with polarity: "No verdict … taken from inside"
    grep -qiE 'No verdict.*taken from inside' <<<"$section" || \
      { echo "verdict-provenance negation ('No verdict … taken from inside') missing in $label" >&2; return 1; }
    # Single-source confidence — with polarity: "not … independently corroborated"
    grep -qi 'not treated as independently corroborated' <<<"$section" || \
      { echo "single-source 'not treated as independently corroborated' missing in $label" >&2; return 1; }
    # Credential-shaped content — with polarity: "never acted on"
    grep -qi 'never acted on' <<<"$section" || \
      { echo "credential 'never acted on' polarity missing in $label" >&2; return 1; }
    # Credential enumeration: "access tokens" present
    grep -qi 'access tokens' <<<"$section" || \
      { echo "credential enumeration 'access tokens' missing in $label" >&2; return 1; }
  }

  _check_ac11 "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_ac11 "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_ac11 "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_ac11 "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_ac11 "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }

  # Mutant 1: remove verdict-provenance sentence
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-verdict-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak "/originate.*consumer/Id" "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qiE "verdict.*originate.*consumer.s own analysis" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with verdict-provenance removed still passes" >&2; return 1; }
  run bash -c 'grep -qiE "trust boundary" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke trust-boundary check" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant 2: remove single-source sentence
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-trust-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak "/trust boundary/Id" "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qiE "trust boundary" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with trust-boundary removed still passes" >&2; return 1; }
  run bash -c 'grep -qiE "credential-shaped" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke credential check" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant 3: remove credential sentence
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-cred-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak "/credential-shaped/Id" "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qiE "credential-shaped" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with credential sentence removed still passes" >&2; return 1; }
  run bash -c 'grep -qiE "verdict.*originate.*consumer.s own analysis" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke verdict-provenance check" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Review-perf Step 4d: section present, correctly structured, mutant fails
# ---------------------------------------------------------------------------

@test "review-perf has Step 4d Design Fidelity with correct structure and performance scope" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }

  # Positive control: Step 4d section exists and has routing
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  require_section "$block" "Step 4d (review-perf)"
  printf '%s' "$block" | grep -iE '(token|component)[^.]*design_system_project\.reference' > /dev/null || \
    { echo "token binding missing in Step 4d" >&2; return 1; }
  printf '%s' "$block" | grep -iE 'screen[^.]*product_design_project\.reference' > /dev/null || \
    { echo "screen binding missing in Step 4d" >&2; return 1; }

  # Relettered heading exists
  grep -q '^#### Step 4e -- Generate Findings' "$f" || \
    { echo "Step 4e -- Generate Findings heading missing" >&2; return 1; }

  # Intro updated
  grep -qi '4a through 4e' "$f" || \
    { echo "'4a through 4e' intro missing" >&2; return 1; }

  # Performance scope keywords
  grep -qi 'token size' <<<"$block" || \
    { echo "performance scope: 'token size' missing" >&2; return 1; }
  grep -qi 'component render budget' <<<"$block" || \
    { echo "performance scope: 'component render budget' missing" >&2; return 1; }
  grep -qi 'screen render budget' <<<"$block" || \
    { echo "performance scope: 'screen render budget' missing" >&2; return 1; }

  # Section-removed mutant
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-perf-rm-XXXXXX")"
  cp "$f" "$mutant_f"
  # Delete from Step 4d Design Fidelity heading to next #### or ### heading
  sed -i.bak '/^#### Step 4d.*Design Fidelity/,/^###/{/^#### Step 4d.*Design Fidelity/d; /^###/!d; /^####/!d;}' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_reviewperf_step4d_block "$mutant_f")"
  [ -z "$mutant_block" ] || { echo "section-removed mutant still has Step 4d content" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Brand-style neutrality sentence in all 9 consumer sections
# ---------------------------------------------------------------------------

@test "all 9 consumer sections state routing is unaffected by sync_mode" {
  local checked=0

  _check_brand_style() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    grep -qi 'sync_mode' <<<"$section" || \
      { echo "sync_mode mention missing in $label" >&2; return 1; }
    grep -qi 'unaffected by.*sync_mode' <<<"$section" || \
      { echo "routing-unaffected-by-sync_mode statement missing in $label" >&2; return 1; }
  }

  _check_brand_style "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_brand_style "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_brand_style "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_brand_style "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_brand_style "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }

  # Mutant: remove the sync_mode sentence
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-brand-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/sync_mode/Id' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qi "sync_mode" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with sync_mode removed still passes" >&2; return 1; }
  # Other checks should still pass
  run bash -c 'grep -qi "design-record" <<<"$1"' _ "$mutant_block"
  [ "$status" -eq 0 ] || { echo "mutant broke design-record check" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Companion: review-perf Step 4d carries unreachability branch
# ---------------------------------------------------------------------------

@test "review-perf Step 4d carries unreachability branch" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  require_section "$block" "Step 4d (review-perf)"
  grep -qiE "unreachab.*finding|finding.*unreachab" <<<"$block" || \
    { echo "unreachability not paired with finding in review-perf Step 4d" >&2; return 1; }
  grep -qiE "never.*fall back|never.*fallback" <<<"$block" || \
    { echo "never-fall-back mandate missing from review-perf Step 4d" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Companion: review-perf Step 4d reports unavailable on UI project
# ---------------------------------------------------------------------------

@test "review-perf Step 4d reports unavailable on UI project without reference" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  require_section "$block" "Step 4d (review-perf)"
  grep -qi "unavailable" <<<"$block" || \
    { echo "unavailable missing from review-perf Step 4d" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Companion: review-perf Step 4d records not-applicable on non-UI project
# ---------------------------------------------------------------------------

@test "review-perf Step 4d records not-applicable on non-UI project" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  require_section "$block" "Step 4d (review-perf)"
  grep -qiE "not-applicable|not applicable" <<<"$block" || \
    { echo "not-applicable missing from review-perf Step 4d" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Companion: review-perf Step 4d notes correct behaviour for first-time firing
# ---------------------------------------------------------------------------

@test "review-perf Step 4d notes correct behaviour for first-time firing" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  require_section "$block" "Step 4d (review-perf)"
  grep -qi "correct behaviour, not a regression" <<<"$block" || \
    { echo "correct-behaviour note missing from review-perf Step 4d" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Companion: review-perf Step 4d has no positive fallback instruction
# ---------------------------------------------------------------------------

@test "review-perf Step 4d has no positive fallback instruction" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  require_section "$block" "Step 4d (review-perf)"
  local total_fb never_fb total_lc never_lc
  total_fb="$(printf '%s' "$block" | grep -oi 'fall back' | wc -l | tr -d ' ')"
  never_fb="$(printf '%s' "$block" | grep -oiE 'never[^.]*fall back' | wc -l | tr -d ' ')"
  [ "$total_fb" -le "$never_fb" ] || \
    { echo "positive fall-back in review-perf Step 4d ($total_fb total, $never_fb negated)" >&2; return 1; }
  total_lc="$(printf '%s' "$block" | grep -oiE 'local[^.]*copy' | wc -l | tr -d ' ')"
  never_lc="$(printf '%s' "$block" | grep -oiE '(never|not)[^.]*local[^.]*copy' | wc -l | tr -d ' ')"
  [ "$total_lc" -gt 0 ] || \
    { echo "local-copy guard vacuous (0 mentions) in review-perf Step 4d" >&2; return 1; }
  [ "$total_lc" -le "$never_lc" ] || \
    { echo "positive local-copy in review-perf Step 4d ($total_lc total, $never_lc negated)" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Companion: review-perf Step 4d carries design-record reference
# ---------------------------------------------------------------------------

@test "review-perf Step 4d carries design-record and fidelity references" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  require_section "$block" "Step 4d (review-perf)"
  grep -qi "design-record" <<<"$block" || \
    { echo "design-record missing from review-perf Step 4d" >&2; return 1; }
  grep -qi "fidelity" <<<"$block" || \
    { echo "fidelity missing from review-perf Step 4d" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Local-copy guard is non-vacuous (at least one mention across all sections)
# ---------------------------------------------------------------------------

@test "local-copy counting guard is non-vacuous across all 9 consumer sections" {
  local total_lc_sum=0

  _count_lc() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    local lc
    lc="$(printf '%s' "$section" | grep -oiE 'local[^.]*copy' | wc -l | tr -d ' ')"
    total_lc_sum=$((total_lc_sum + lc))
  }

  _count_lc "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _count_lc "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
  done
  _count_lc "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  _count_lc "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  _count_lc "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  [ "$total_lc_sum" -gt 0 ] || \
    { echo "local-copy counting guard is vacuous: zero local-copy mentions across all 9 sections" >&2; return 1; }

  # Insertion mutant: a positive local-copy instruction in a non-persona
  # section must break the per-section guard.
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-localcopy-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/^### Phase 4/a\
- Read tokens from a local design-system copy when DesignSync is slow.' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  local m_total m_negated
  m_total="$(printf '%s' "$mutant_block" | grep -oiE 'local[^.]*copy' | wc -l | tr -d ' ')"
  m_negated="$(printf '%s' "$mutant_block" | grep -oiE '(never|not)[^.]*local[^.]*copy' | wc -l | tr -d ' ')"
  [ "$m_total" -gt "$m_negated" ] || \
    { echo "insertion mutant not caught by per-section guard ($m_total total, $m_negated negated)" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Review-perf Step 6 report includes design-fidelity results
# ---------------------------------------------------------------------------

@test "review-perf Step 6 report list includes design-fidelity results" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  # Extract Step 6 section
  local step6
  step6="$(sed -n '/^### Step 6/,/^### Step 7/{ /^### Step [67]/d; p; }' "$f")"
  [ -n "$step6" ] || { echo "Step 6 section empty in $f" >&2; return 1; }
  grep -qi 'design-fidelity' <<<"$step6" || \
    { echo "design-fidelity missing from Step 6 report list" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Review-perf Step 4d findings feed Step 4e
# ---------------------------------------------------------------------------

@test "review-perf Step 4d findings feed Step 4e with severity tiers" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  # The linkage sentence lives between Step 4d heading and Step 4e heading.
  # Scope the grep to that region, not the whole file.
  local region
  region="$(sed -n '/^#### Step 4d/,/^#### Step 4e/p' "$f")"
  [ -n "$region" ] || { echo "Step 4d–4e region empty" >&2; return 1; }
  grep -qi 'Step 4d findings feed Step 4e' <<<"$region" || \
    { echo "Step 4d → Step 4e linkage sentence missing from 4d–4e region" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Board token-copies sentence: present in all 9, deletion mutant caught
# ---------------------------------------------------------------------------

@test "all 9 consumer sections carry the board token-copies sentence" {
  local checked=0

  _check_token_copies() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    grep -qi 'token copies embedded in each board' <<<"$section" || \
      { echo "board token-copies sentence missing in $label" >&2; return 1; }
    # Polarity: "are not a token source"
    grep -qi 'are not a token source' <<<"$section" || \
      { echo "token-copies 'are not a token source' polarity missing in $label" >&2; return 1; }
  }

  _check_token_copies "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_token_copies "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_token_copies "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_token_copies "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_token_copies "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }

  # Deletion mutant
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-tokencopy-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/token copies embedded in each board/d' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qi "token copies embedded in each board" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with token-copies removed still passes" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Tools-unavailable sentence: present in all 9, deletion mutant caught
# ---------------------------------------------------------------------------

@test "all 9 consumer sections carry the tools-unavailable sentence" {
  local checked=0

  _check_tools_unavail() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    grep -qiE 'design tools.*not available.*unreachability' <<<"$section" || \
      grep -qiE 'DesignSync.*Artifact.*not available' <<<"$section" || \
      { echo "tools-unavailable sentence missing in $label" >&2; return 1; }
  }

  _check_tools_unavail "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_tools_unavail "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_tools_unavail "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_tools_unavail "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_tools_unavail "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }

  # Deletion mutant
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-toolsunavail-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak '/design tools.*not available/Id' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qiE "design tools.*not available|DesignSync.*Artifact.*not available" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with tools-unavailable removed still passes" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Unreachability failure-mode sentence: DesignSync failure listed
# ---------------------------------------------------------------------------

@test "all 9 consumer sections list DesignSync failure in unreachability clause" {
  local checked=0

  _check_ds_failure() {
    local section="$1" label="$2"
    require_section "$section" "$label"
    grep -qi 'DesignSync or design-system project failure' <<<"$section" || \
      { echo "DesignSync failure mode missing from unreachability clause in $label" >&2; return 1; }
  }

  _check_ds_failure "$(extract_design_consumption_section "$REPO_ROOT/agents/_base-dev.md")" "_base-dev"
  checked=$((checked + 1))
  local phase4_rubrics=(
    "$REPO_ROOT/skills/gaia-code-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-performance-review/SKILL.md"
    "$REPO_ROOT/skills/gaia-qa-tests/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-automate/SKILL.md"
    "$REPO_ROOT/skills/gaia-test-review/SKILL.md"
  )
  for rf in "${phase4_rubrics[@]}"; do
    _check_ds_failure "$(extract_phase4_block "$rf")" "$(basename "$(dirname "$rf")")"
    checked=$((checked + 1))
  done
  _check_ds_failure "$(extract_step4b_block "$REPO_ROOT/skills/gaia-review-security/SKILL.md")" "review-security"
  checked=$((checked + 1))
  _check_ds_failure "$(extract_reviewperf_step4d_block "$REPO_ROOT/skills/gaia-review-perf/SKILL.md")" "review-perf Step 4d"
  checked=$((checked + 1))
  _check_ds_failure "$(extract_template_phase4_block "$REPO_ROOT/knowledge/review-skill-template.md")" "template"
  checked=$((checked + 1))
  [ "$checked" -eq 9 ] || { echo "expected 9 sections checked, got $checked" >&2; return 1; }

  # Deletion mutant
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-dsfailure-XXXXXX")"
  cp "$REPO_ROOT/skills/gaia-code-review/SKILL.md" "$mutant_f"
  sed -i.bak 's/DesignSync or design-system project failure, //' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qi "DesignSync or design-system project failure" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "mutant with DesignSync failure removed still passes" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Polarity checks: dropped "never"/"not"/"strip" caught
# ---------------------------------------------------------------------------

@test "polarity mutants: dropped never/not/strip caught in persona and code-review" {
  # Polarity assertions now live in _check_ac11, _check_ac10, _check_token_copies
  # and run across all 9 sections.  This test verifies the mutant-killing power
  # in two representative surfaces: persona (Design Consumption) and code-review
  # (Phase 4).

  # --- Persona mutants ---
  local persona="$REPO_ROOT/agents/_base-dev.md"

  # Mutant: drop "never" from credential sentence in persona
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-pol-persona-XXXXXX")"
  cp "$persona" "$mutant_f"
  sed -i.bak 's/is never acted on/is acted on/' "$mutant_f"
  local mutant_section
  mutant_section="$(extract_design_consumption_section "$mutant_f")"
  run bash -c 'grep -qi "never acted on" <<<"$1"' _ "$mutant_section"
  [ "$status" -ne 0 ] || { echo "persona: dropped-never mutant passes credential polarity" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant: drop "not" from single-source in persona
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-pol-persona2-XXXXXX")"
  cp "$persona" "$mutant_f"
  sed -i.bak 's/is not treated as independently corroborated/is treated as independently corroborated/' "$mutant_f"
  mutant_section="$(extract_design_consumption_section "$mutant_f")"
  run bash -c 'grep -qi "not treated as independently corroborated" <<<"$1"' _ "$mutant_section"
  [ "$status" -ne 0 ] || { echo "persona: dropped-not mutant passes single-source polarity" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant: drop "No" from verdict-provenance in persona
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-pol-persona3-XXXXXX")"
  cp "$persona" "$mutant_f"
  sed -i.bak 's/No verdict/Verdict/' "$mutant_f"
  mutant_section="$(extract_design_consumption_section "$mutant_f")"
  run bash -c 'grep -qiE "No verdict.*taken from inside" <<<"$1"' _ "$mutant_section"
  [ "$status" -ne 0 ] || { echo "persona: dropped-No mutant passes verdict-provenance polarity" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant: drop "are not" from token-copies in persona
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-pol-persona4-XXXXXX")"
  cp "$persona" "$mutant_f"
  sed -i.bak 's/are not a token source/are a token source/' "$mutant_f"
  mutant_section="$(extract_design_consumption_section "$mutant_f")"
  run bash -c 'grep -qi "are not a token source" <<<"$1"' _ "$mutant_section"
  [ "$status" -ne 0 ] || { echo "persona: dropped-not mutant passes token-copies polarity" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # --- Code-review mutants ---
  local f="$REPO_ROOT/skills/gaia-code-review/SKILL.md"

  # Mutant: drop "never" from credential sentence
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-pol-cr-XXXXXX")"
  cp "$f" "$mutant_f"
  sed -i.bak 's/is never acted on/is acted on/' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qi "never acted on" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "code-review: dropped-never mutant passes credential polarity" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant: drop "Strip" from metadata sentence
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-pol-cr2-XXXXXX")"
  cp "$f" "$mutant_f"
  sed -i.bak '/[Ss]trip control characters/d' "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qi "strip control characters" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "code-review: dropped-strip mutant passes metadata polarity" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"

  # Mutant: drop "are not" from token-copies in code-review
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-pol-cr3-XXXXXX")"
  cp "$f" "$mutant_f"
  sed -i.bak 's/are not a token source/are a token source/' "$mutant_f"
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -qi "are not a token source" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "code-review: dropped-not mutant passes token-copies polarity" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Read-mode mutant: swapping scope: "files" to scope: "pages" is caught
# ---------------------------------------------------------------------------

@test "read-mode mutant: scope files swapped to scope pages is caught" {
  local f="$REPO_ROOT/skills/gaia-code-review/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }

  # Positive control: real file has scope: "files"
  local block
  block="$(extract_phase4_block "$f")"
  require_section "$block" "Phase 4 (code-review)"
  grep -q 'scope: "files"' <<<"$block" || \
    { echo "positive control failed: scope: files missing" >&2; return 1; }

  # Mutant: swap scope: "files" to scope: "pages"
  local mutant_f
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-readmode-XXXXXX")"
  cp "$f" "$mutant_f"
  sed -i.bak 's/scope: "files"/scope: "pages"/g' "$mutant_f"
  local mutant_block
  mutant_block="$(extract_phase4_block "$mutant_f")"
  run bash -c 'grep -q "scope: \"files\"" <<<"$1"' _ "$mutant_block"
  [ "$status" -ne 0 ] || { echo "read-mode mutant still has scope: files — swap failed" >&2; return 1; }
  rm -f "$mutant_f" "$mutant_f.bak"
}

# ---------------------------------------------------------------------------
# Persona routing is not gated on design_state value
#
# The Design Consumption entry condition must fire whenever a design-record
# reference exists, regardless of the record's approval state.  A draft,
# in-review, or stale design record must still receive routing instructions.
# The separate stale-state bullet handles the staleness warning.
# ---------------------------------------------------------------------------

@test "base-dev persona routing is not gated on a design_state value" {
  local f="$REPO_ROOT/agents/_base-dev.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local section
  section="$(extract_design_consumption_section "$f")"
  require_section "$section" "Design Consumption"

  # The routing entry sentence must mention design-record.yaml but must NOT
  # condition on a specific design_state value (e.g. "approved", "draft").
  # Match the parenthetical that names the file path and assert it does not
  # also contain "design_state".
  #
  # Strategy: extract the line that names "design-record.yaml" and assert
  # it does not contain "design_state".  This is tighter than a whole-section
  # grep because design_state can legitimately appear in the stale-state
  # bullet further down.
  local routing_line
  routing_line="$(printf '%s\n' "$section" | grep 'design-record\.yaml')"
  [ -n "$routing_line" ] || \
    { echo "no line mentioning design-record.yaml in Design Consumption" >&2; return 1; }
  run bash -c 'printf "%s" "$1" | grep -ci "design_state"' _ "$routing_line"
  [ "$output" = "0" ] || \
    { echo "routing line is gated on design_state ($output hits): $routing_line" >&2; return 1; }

  # Mutant: re-add the condition and assert the test catches it
  local mutant_f mutant_tmp
  mutant_f="$(mktemp "$BATS_TMPDIR/mutant-dstate-XXXXXX")"
  mutant_tmp="$(mktemp "$BATS_TMPDIR/mutant-dstate-tmp-XXXXXX")"
  cp "$f" "$mutant_f"
  sed 's/\.yaml`)/\.yaml` with `design_state: approved`)/' "$mutant_f" > "$mutant_tmp" && mv "$mutant_tmp" "$mutant_f"
  local mutant_section
  mutant_section="$(extract_design_consumption_section "$mutant_f")"
  local mutant_routing_line
  mutant_routing_line="$(printf '%s\n' "$mutant_section" | grep 'design-record\.yaml')"
  run bash -c 'printf "%s" "$1" | grep -ci "design_state"' _ "$mutant_routing_line"
  [ "$output" != "0" ] || \
    { echo "mutant with design_state re-added was not caught" >&2; return 1; }
  rm -f "$mutant_f"
}

# ---------------------------------------------------------------------------
# Severity tier for design-fidelity findings
#
# Each design-fidelity section must define a severity tier: a default level
# and an escalated level for contradictions.  The five Phase-4 rubrics and
# the shared template use Warning/Critical; the security review (Step 4b)
# and review-perf (Step 4d) use their own medium/critical scale.
# ---------------------------------------------------------------------------

# Shared check helper — called by both the real tests and the swap mutant.
# Usage: _check_severity_tier <block> <label> [default_phrase] [contradict_phrase]
_check_severity_tier() {
  local block="$1" label="$2"
  local default_phrase="${3:-Warning by default}"
  local contradict_phrase="${4:-contradict}"
  [ -n "$block" ] || { echo "$label section is empty or missing" >&2; return 1; }
  grep -qi "$default_phrase" <<<"$block" || \
    { echo "default severity tier missing from $label (expected: $default_phrase)" >&2; return 1; }
  grep -qiE "[Cc]ritical when.*${contradict_phrase}" <<<"$block" || \
    { echo "contradiction tier missing from $label" >&2; return 1; }
  # Top-level placement: the severity line must start with "- " (a top-level
  # bullet), not "  - " (a sub-bullet).  This catches the drift where the
  # severity tier is nested under the design-record branch instead of
  # governing all fidelity findings including the "no reference" case.
  grep -qiE "^- [^ ].*${default_phrase}" <<<"$block" || \
    { echo "severity tier not a top-level bullet in $label" >&2; return 1; }
}

@test "Phase 4 fidelity sections define severity tiers for design-fidelity findings" {
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
    _check_severity_tier "$block" "Phase 4 ($(basename "$(dirname "$f")"))"
  done
}

@test "review-security Step 4b defines severity tiers for design-fidelity findings" {
  local f="$REPO_ROOT/skills/gaia-review-security/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_step4b_block "$f")"
  _check_severity_tier "$block" "Step 4b (review-security)" "medium by default" "contradict"
}

@test "review-perf Step 4d defines severity tiers for design-fidelity findings" {
  local f="$REPO_ROOT/skills/gaia-review-perf/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_reviewperf_step4d_block "$f")"
  _check_severity_tier "$block" "Step 4d (review-perf)" "medium by default" "contradict"
}

@test "review-skill template defines severity tiers for design-fidelity findings" {
  local f="$REPO_ROOT/knowledge/review-skill-template.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_template_phase4_block "$f")"
  _check_severity_tier "$block" "Phase 4 (template)" "Warning by default" "contradict"
}

@test "severity tier swap mutant turns check red" {
  # Positive control: the real shared helper passes on the real section
  local f="$REPO_ROOT/skills/gaia-code-review/SKILL.md"
  [ -f "$f" ] || { echo "file missing: $f" >&2; return 1; }
  local block
  block="$(extract_phase4_block "$f")"
  run _check_severity_tier "$block" "positive-control"
  [ "$status" -eq 0 ] || { echo "positive control failed: $output" >&2; return 1; }

  # Swap mutant: "Warning by default" -> "Critical by default",
  #              "Critical when" -> "Warning when"
  local mutant
  mutant="$(printf '%s' "$block" | sed 's/Warning by default/Critical by default/g; s/Critical when/Warning when/g')"
  # The SAME shared helper must fail against the mutant
  run _check_severity_tier "$mutant" "mutant"
  [ "$status" -ne 0 ] || { echo "swap mutant still passes severity tier check — test is vacuous" >&2; return 1; }
}
