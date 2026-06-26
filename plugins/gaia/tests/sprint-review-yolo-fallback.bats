#!/usr/bin/env bats
# sprint-review-yolo-fallback.bats — prose-coverage tests for the
# --yolo-defaults works-as-expected fallback contract in
# /gaia-sprint-review SKILL.md.
#
# Verifies:
#   - The fallback is documented and internally consistent (no
#     "future enhancement" contradiction).
#   - Canonical spelling is works-as-expected (no singular typo).
#   - Step 3a (substrate halt) + Step 8 (UNVERIFIED) remain
#     interactive even under the fallback.
#   - The fallback references the canonical yolo-mode helper or the
#     explicit --yolo-defaults flag.

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL_MD="$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fallback documentation (AC1)
# ---------------------------------------------------------------------------

@test "SKILL.md documents the --yolo-defaults works-as-expected Step 4a fallback (AC1)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  grep -qE '\-\-yolo-defaults[[:space:]]+works-as-expected' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# Internal consistency — no "future enhancement" contradiction (AC2)
# ---------------------------------------------------------------------------

@test "SKILL.md does NOT contain the future-enhancement contradiction language (AC2)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  # The contradiction: "A future enhancement may add a --yolo-defaults ..."
  # After reconciliation this language must be gone.
  if grep -qiE 'future enhancement.*yolo|may add.*yolo-defaults' "$SKILL_MD"; then
    echo "Found contradictory 'future enhancement may add' language — should be reconciled"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Step 3a + Step 8 remain interactive under fallback (AC3)
# ---------------------------------------------------------------------------

@test "SKILL.md states Step 3a substrate halt remains interactive under fallback (AC3)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  # Must document that Step 3a is NOT bypassable
  grep -qE 'Step 3a.*remain.*interactive|Step 3a.*substrate.*halt.*cannot.*bypass|substrate.*halt.*cannot.*bypass' "$SKILL_MD"
}

@test "SKILL.md states Step 8 UNVERIFIED remains interactive under fallback (AC3)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  # Must document that Step 8 stays interactive or that --yolo-defaults
  # refuses the UNVERIFIED bypass
  grep -qE 'Step 8.*remain.*interactive|Step 8.*stays interactive|yolo-defaults.*REFUSES.*UNVERIFIED|yolo-defaults.*UNVERIFIED.*FAILED' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# Canonical spelling — works-as-expected, no singular typo (AC4)
# ---------------------------------------------------------------------------

@test "SKILL.md uses canonical spelling works-as-expected (AC4)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  grep -qF 'works-as-expected' "$SKILL_MD"
}

@test "SKILL.md does NOT contain the singular typo work-as-expected as a flag value (AC4)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  # The typo: --yolo-defaults work-as-expected (missing trailing 's')
  # We scan for the exact pattern of the flag value without the 's'.
  # Allow 'work-as-expected' only when preceded by 'works' (which includes 's')
  # — effectively, the bare 'work-as-expected' without 'works' prefix must be absent.
  if grep -E '\bwork-as-expected\b' "$SKILL_MD" | grep -vE '\bworks-as-expected\b' | grep -q .; then
    echo "Found singular typo 'work-as-expected' (should be 'works-as-expected')"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Fallback references canonical helper or explicit flag (AC5)
# ---------------------------------------------------------------------------

@test "SKILL.md references the canonical yolo-mode helper or explicit --yolo-defaults flag (AC5)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  # Must reference either the canonical helper path or the explicit flag
  grep -qE 'yolo-mode\.sh|--yolo-defaults' "$SKILL_MD"
}
