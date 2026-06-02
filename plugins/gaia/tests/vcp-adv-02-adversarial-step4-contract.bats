#!/usr/bin/env bats
# vcp-adv-02-adversarial-step4-contract.bats — E46-S8 / FR-356.
#
# Script-verifiable contract checks on
# gaia-public/plugins/gaia/skills/gaia-adversarial/SKILL.md guaranteeing
# that the Step 4 invocation contract documents the four auto-incorporation
# callers in a single contiguous bulleted list, plus the standalone-default
# rule, the opt-in signal rule, and a Critical Rules pointer.
#
# VCP-ADV-02 is the script-verifiable anchor for FR-356. The grep-based
# contract anchors are the regression-proof check: if any of the four
# caller tokens is accidentally dropped in a future SKILL.md edit, this
# bats file fails. VCP-ADV-01, VCP-ADV-03, VCP-ADV-04 are LLM-checkable
# and live in the test plan only; this bats file backs VCP-ADV-02 and
# adds prose-anchor sanity checks for the contract section that protect
# the AC2/AC3/AC6 contract from silent drift.

load 'test_helper.bash'

SKILL_MD="$BATS_TEST_DIRNAME/../skills/gaia-adversarial/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# -------------------------------------------------------------------------
# AC1 + AC5 — VCP-ADV-02 anchor — all four auto-incorporation callers
# documented by name in the SKILL.md contract section.
# -------------------------------------------------------------------------

@test "VCP-ADV-02: SKILL.md lists /gaia-create-arch as an auto-incorporation caller" {
  run grep -F "/gaia-create-arch" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-ADV-02: SKILL.md lists /gaia-create-prd as an auto-incorporation caller" {
  run grep -F "/gaia-create-prd" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-ADV-02: SKILL.md lists /gaia-create-epics as an auto-incorporation caller" {
  run grep -F "/gaia-create-epics" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-ADV-02: SKILL.md lists /gaia-readiness-check as an auto-incorporation caller" {
  run grep -F "/gaia-readiness-check" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-ADV-02: combined grep -E matches all four caller tokens" {
  # The exact grep incantation documented in the test-plan cell for
  # VCP-ADV-02 — reviewers can re-run this locally.
  run grep -E '(/gaia-create-arch|/gaia-create-prd|/gaia-create-epics|/gaia-readiness-check)' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # All four tokens MUST appear at least once — count distinct hits.
  _hits=$(grep -oE '/gaia-(create-arch|create-prd|create-epics|readiness-check)' "$SKILL_MD" | sort -u | wc -l | tr -d ' ')
  [ "$_hits" -eq 4 ]
}

# -------------------------------------------------------------------------
# AC1 — the four bullets MUST appear contiguously in a single list (no
# interleaving prose between them) so VCP-ADV-02's check is unambiguous.
# -------------------------------------------------------------------------

@test "VCP-ADV-02: four caller bullets are contiguous in a single list" {
  # Read the line numbers of the four caller bullets and assert the max
  # span is < 6 (allows 1 line of slack for indented sub-text per bullet,
  # but rejects an interleaving paragraph).
  _arch_line=$(grep -nE '^[[:space:]]*[-*][[:space:]]+`?/gaia-create-arch' "$SKILL_MD" | head -1 | cut -d: -f1)
  _prd_line=$(grep -nE '^[[:space:]]*[-*][[:space:]]+`?/gaia-create-prd' "$SKILL_MD" | head -1 | cut -d: -f1)
  _epics_line=$(grep -nE '^[[:space:]]*[-*][[:space:]]+`?/gaia-create-epics' "$SKILL_MD" | head -1 | cut -d: -f1)
  _rc_line=$(grep -nE '^[[:space:]]*[-*][[:space:]]+`?/gaia-readiness-check' "$SKILL_MD" | head -1 | cut -d: -f1)
  [ -n "$_arch_line" ]
  [ -n "$_prd_line" ]
  [ -n "$_epics_line" ]
  [ -n "$_rc_line" ]
  _min=$_arch_line
  _max=$_arch_line
  for _n in "$_prd_line" "$_epics_line" "$_rc_line"; do
    if [ "$_n" -lt "$_min" ]; then _min=$_n; fi
    if [ "$_n" -gt "$_max" ]; then _max=$_n; fi
  done
  _span=$(( _max - _min ))
  # Four contiguous bullets occupy at most 3 line gaps (lines N, N+1, N+2, N+3).
  # Allow up to 7 to permit a one-line rationale per bullet (Subtask 1.3).
  [ "$_span" -le 7 ]
}

# -------------------------------------------------------------------------
# AC1 — the contract section is anchored under Step 4, not Critical Rules.
# -------------------------------------------------------------------------

@test "VCP-ADV-02: SKILL.md declares the Step 4 Invocation Contract subsection" {
  # The contract heading deliberately omits the em-dash separator so the
  # cross-skill VCP-CPT-09 step-count check (which counts `### Step N —`
  # headings) stays at the canonical 4 steps. The contract section is a
  # sub-heading anchored to Step 4, not a fifth step.
  run grep -E "^### Step 4 Invocation Contract$" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC2 + AC3 — standalone-default rule explicitly stated.
# -------------------------------------------------------------------------

@test "VCP-ADV-02: SKILL.md states standalone-default rule for non-listed callers" {
  run grep -F "standalone mode" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC6 — opt-in signal rule (BOTH allowlist AND signal required).
# -------------------------------------------------------------------------

@test "VCP-ADV-02: SKILL.md documents the incorporate: true opt-in signal" {
  run grep -F "incorporate: true" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-ADV-02: SKILL.md states both conditions are required (allowlist AND signal)" {
  # Either condition alone is insufficient — phrasing per AC6.
  run grep -E "either condition alone is insufficient|both are required|both conditions" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Subtask 1.4 — Critical Rules contains a one-line pointer to the
# contract section, not a duplicate list.
# -------------------------------------------------------------------------

@test "VCP-ADV-02: Critical Rules contains a pointer bullet to the contract" {
  # The pointer bullet must appear inside the Critical Rules section AND
  # reference the Step 4 contract.
  run awk '
    /^## Critical Rules/ { in_cr=1; next }
    /^## / && in_cr { in_cr=0 }
    in_cr && /Step 4 (Invocation|invocation)? ?Contract|Step 4 — Invocation Contract|see Step 4 Invocation Contract|Invocation Contract for the allowlist/ { found=1 }
    END { exit (found?0:1) }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Regression — preserve the existing "Do NOT suggest fixes" Critical Rule
# and the existing Step 4 incorporate-on-request line verbatim.
# -------------------------------------------------------------------------

@test "VCP-ADV-02: Critical Rules preserves the Do NOT suggest fixes rule verbatim" {
  run grep -F "Do NOT suggest fixes — only identify problems" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-ADV-02: Step 4 preserves the only-when-caller-requested line" {
  run grep -F "executed when the caller explicitly requests incorporation" "$SKILL_MD"
  [ "$status" -eq 0 ]
}
