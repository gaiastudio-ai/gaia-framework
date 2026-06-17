#!/usr/bin/env bats
# e39-s5-merge-structure.bats — TC-STCL-5/6 structural assertions for the
# tech-debt-phase merge into /gaia-triage-findings.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$PLUGIN/skills/gaia-triage-findings/SKILL.md"
  SCRIPTS="$PLUGIN/skills/gaia-triage-findings/scripts"
}

# TC-STCL-5 — the merged SKILL.md documents the tech-debt dashboard phase with
# the ledger / scoring / aging / detection / trend capabilities.
@test "Step 5b documents the tech-debt dashboard phase" {
  run grep -E '^### Step 5b --- Tech-Debt Phase' "$SKILL"
  [ "$status" -eq 0 ]
  for token in "tech-debt-dashboard.md" "TD-{N}" "STALE TARGET" "UNASSIGNED" "RESOLVED" "trend"; do
    grep -qF "$token" "$SKILL"
  done
}

# TC-STCL-5b — the td-id-assign helper is co-located in this skill's scripts
# (copied from the retired skill) and the phase references it.
@test "td-id-assign.sh is present in triage scripts and referenced" {
  [ -f "$SCRIPTS/td-id-assign.sh" ]
  grep -qF "td-id-assign.sh" "$SKILL"
}

# TC-STCL-4d (AC4) — the merged phase reuses the S4 extractor; NO second
# scanner. extract-findings.sh is referenced by Step 5b; scan-findings.sh
# (the retired skill's directory-walker) is NOT introduced into this skill.
@test "tech-debt phase reuses extract-findings.sh, no second scanner" {
  grep -qF "extract-findings.sh" "$SKILL"
  [ ! -f "$SCRIPTS/scan-findings.sh" ]   # the directory-walk scanner is NOT copied in
}

# TC-STCL-6 (AC3) — action items route through the canonical writer, and the
# legacy planning-artifacts inline append is explicitly prohibited (not
# prescribed) in the tech-debt phase.
@test "tech-debt phase routes action items through canonical writer" {
  grep -qF "action-items-write.sh" "$SKILL"
  grep -qF ".gaia/state/action-items.yaml" "$SKILL"
  # The legacy path is named only inside an explicit prohibition ("Do NOT ...").
  run grep -nE "Do NOT inline-append to .planning-artifacts/action-items" "$SKILL"
  [ "$status" -eq 0 ]
}
