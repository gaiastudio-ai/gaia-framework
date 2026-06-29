#!/usr/bin/env bats
# e28-s283-brownfield-fidelity-summary.bats — the end-of-run "what did I
# actually get?" fidelity summary in the brownfield primary output.
#
# The brownfield fidelity signals (tier reached, which scanners ran, which were
# skipped + why, the upgrade command) already exist but are dispersed across
# three artifacts with no unified summary; the Phase 3 diagnostic table is
# rendered to the conversation only and persisted nowhere. This pins that the
# gaia-brownfield SKILL.md primary-output spec prescribes a consolidated Scan
# Fidelity Summary section sourcing all four signals.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$PLUGIN/skills/gaia-brownfield/SKILL.md"
}

teardown() { common_teardown; }

@test "primary-output spec prescribes a Scan Fidelity Summary section (AC1)" {
  grep -qF '### Scan Fidelity Summary' "$SKILL"
  grep -qiF 'what did i actually get' "$SKILL"
}

@test "fidelity summary reports the tier reached, sourced from consolidated-gaps frontmatter (AC2)" {
  # The section names the tier signal + its source (scan_fidelity frontmatter).
  run awk '/### Scan Fidelity Summary/{f=1} f&&/scan_fidelity/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL"
  [[ "$output" == *"found"* ]]
  awk '/### Scan Fidelity Summary/{f=1} f&&/[Tt]ier reached/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL" | grep -q found
}

@test "fidelity summary reports which scanners ran + flags first-persistence of the diagnostic table (AC3)" {
  awk '/### Scan Fidelity Summary/{f=1} f&&/Scanners that ran/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL" | grep -q found
  # The persistence note: the diagnostic table is conversation-only, this is the first persistence point.
  awk '/### Scan Fidelity Summary/{f=1} f&&/FIRST persistence point/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL" | grep -q found
}

@test "fidelity summary reports skipped/unavailable scanners with why (AC4)" {
  awk '/### Scan Fidelity Summary/{f=1} f&&/skipped \/ unavailable/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL" | grep -q found
}

@test "fidelity summary names the upgrade/remediation command (AC4)" {
  awk '/### Scan Fidelity Summary/{f=1} f&&/gaia-doctor --install/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL" | grep -q found
  awk '/### Scan Fidelity Summary/{f=1} f&&/[Hh]ow to upgrade/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL" | grep -q found
}

@test "existing primary-output summary bullets are preserved — additive (AC5)" {
  # The section must not have replaced the pre-existing summary bullets.
  grep -qF 'Project discovery findings' "$SKILL"
  grep -qF 'Consolidated gap summary (counts by severity / category)' "$SKILL"
  grep -qF 'NFR baseline summary' "$SKILL"
  grep -qF 'Next-step recommendations' "$SKILL"
  # And the section is explicitly additive.
  awk '/### Scan Fidelity Summary/{f=1} f&&/purely additive/{print "found"} /## Output — Secondary Artifacts/{f=0}' "$SKILL" | grep -q found
}
