#!/usr/bin/env bats
# design-a11y-rebind.bats -- design-a11y validator rebind assertions.
#
# Validates that the design-a11y validator carries the design-record
# reference formulation, zero retired-provider hits, all five WCAG
# finding classes, and fail-closed unreachability handling.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_FILE="$REPO_ROOT/skills/gaia-validate-design-a11y/SKILL.md"
  # Split-fragment provider literal -- never contiguous in this file
  PROVIDER="$(printf '%s%s' 'fig' 'ma')"
}

# ---------------------------------------------------------------------------
# AC5 — zero word-bounded provider hits
# ---------------------------------------------------------------------------

@test "(AC5) design-a11y validator has zero word-bounded provider hits" {
  [ -f "$SKILL_FILE" ] || { echo "file missing: $SKILL_FILE" >&2; return 1; }
  run grep -ciw "$PROVIDER" "$SKILL_FILE"
  [ "$output" = "0" ] || { echo "expected 0 provider hits, got $output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC5 — references design-record for target resolution
# ---------------------------------------------------------------------------

@test "(AC5) design-a11y validator references design-record for target resolution" {
  [ -f "$SKILL_FILE" ] || { echo "file missing: $SKILL_FILE" >&2; return 1; }
  grep -qi "design-record" "$SKILL_FILE" || \
    { echo "design-record reference missing from a11y validator" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC5 — retains all five WCAG finding classes (forward regression guard)
# ---------------------------------------------------------------------------

@test "(AC5) design-a11y validator retains all five WCAG finding classes" {
  [ -f "$SKILL_FILE" ] || { echo "file missing: $SKILL_FILE" >&2; return 1; }
  # Color contrast
  grep -q "1\.4\.3" "$SKILL_FILE" || { echo "WCAG 1.4.3 (color contrast) missing" >&2; return 1; }
  # Semantic structure
  grep -q "1\.3\.1" "$SKILL_FILE" || { echo "WCAG 1.3.1 (semantic structure) missing" >&2; return 1; }
  # Keyboard navigation design
  grep -q "2\.1\.1" "$SKILL_FILE" || { echo "WCAG 2.1.1 (keyboard nav) missing" >&2; return 1; }
  # ARIA landmark planning
  grep -q "4\.1\.2" "$SKILL_FILE" || { echo "WCAG 4.1.2 (ARIA landmarks) missing" >&2; return 1; }
  # Color-alone meaning
  grep -q "1\.4\.1" "$SKILL_FILE" || { echo "WCAG 1.4.1 (color-alone meaning) missing" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC5 — surfaces unreachability as finding not fallback
# ---------------------------------------------------------------------------

@test "(AC5) design-a11y validator surfaces unreachability as finding not fallback" {
  [ -f "$SKILL_FILE" ] || { echo "file missing: $SKILL_FILE" >&2; return 1; }
  # Must explicitly mention "unreachability" and pair it with "finding"
  # in the same line (not just "finding" anywhere, which is vacuously true).
  grep -qiE "unreachab.*finding|finding.*unreachab" "$SKILL_FILE" || \
    { echo "unreachability not paired with finding" >&2; return 1; }
  # Must explicitly say "never fall back" (the mandate)
  grep -qiE "never.*fall back|never.*fallback" "$SKILL_FILE" || \
    { echo "never-fall-back mandate missing" >&2; return 1; }
  # Must NOT offer "degrade gracefully" for the design-record path
  # (old text says "degrade gracefully to text-only")
  run bash -c 'grep -i "design-record" "$1" | grep -ci "degrade gracefully"' _ "$SKILL_FILE"
  [ "$output" = "0" ] || { echo "degrade gracefully still paired with design-record" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC-EC4 — unreachability surfaced as finding or halt, no local fallback
# ---------------------------------------------------------------------------

@test "(AC-EC4) design-a11y validator surfaces unreachability as finding or halt" {
  [ -f "$SKILL_FILE" ] || { echo "file missing: $SKILL_FILE" >&2; return 1; }
  # Must explicitly pair unreachability with finding/halt (co-occurrence)
  grep -qiE "unreachab.*finding|unreachab.*halt|finding.*unreachab" "$SKILL_FILE" || \
    { echo "unreachability not paired with finding or halt" >&2; return 1; }
  # Must state the no-local-fallback mandate
  grep -qiE "never.*fall back.*local copy|never.*fallback.*local copy" "$SKILL_FILE" || \
    { echo "never-fall-back-to-local-copy mandate missing" >&2; return 1; }
  # Every mention of "local copy" must be in a negative context (preceded by "never")
  # i.e., no line says "fall back to a local copy" without "never" before it
  run bash -c 'grep -i "local copy" "$1" | grep -cvi "never"' _ "$SKILL_FILE"
  [ "$output" = "0" ] || { echo "local copy mentioned without never ($output hits)" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC-EC6 — test asserts finding CLASSES not byte-identical output
#           (by design: the AC5 test above asserts WCAG criterion IDs,
#            not exact finding text lines)
# ---------------------------------------------------------------------------
# This is proven by construction: the AC5 test above greps for WCAG
# criterion IDs (1.4.3, 1.3.1, 2.1.1, 4.1.2, 1.4.1) not full lines.
# No additional test needed -- the design IS the assertion.
