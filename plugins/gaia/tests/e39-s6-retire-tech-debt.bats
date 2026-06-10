#!/usr/bin/env bats
# e39-s6-retire-tech-debt.bats — TC-STCL-7 (CRITICAL post-retirement
# dead-reference scan) + TC-STCL-8 (gaia-help.csv row swap) + retirement
# structural assertions for /gaia-tech-debt-review.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ROOT="$(cd "$PLUGIN/../.." && pwd)"   # repo root (contains plugins/)
  SKILL="$PLUGIN/skills/gaia-tech-debt-review/SKILL.md"
  HELP="$PLUGIN/knowledge/gaia-help.csv"
  MANIFEST="$PLUGIN/knowledge/workflow-manifest.csv"
  LIFECYCLE="$PLUGIN/knowledge/lifecycle-sequence.yaml"
  DEADREF="$PLUGIN/scripts/dead-reference-scan.sh"
}

# TC-STCL-7 (CRITICAL) — the dead-reference scan passes clean after retirement.
@test "TC-STCL-7: dead-reference-scan.sh is CLEAN after tech-debt-review retirement" {
  run bash "$DEADREF" --project-root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEAN"* ]]
}

# Retirement: the SKILL.md is a thin deprecation redirect with the canonical
# frontmatter (deprecated_since + replaced_by: gaia-triage-findings).
@test "TC-STCL-7b: tech-debt-review SKILL.md is a deprecation redirect" {
  grep -qE '^deprecated_since:' "$SKILL"
  grep -qE 'replaced_by:.*gaia-triage-findings' "$SKILL"
  grep -qiF "DEPRECATED" "$SKILL"
}

# Retirement: the standalone scripts are gone (capability lives in triage).
@test "TC-STCL-7c: tech-debt-review standalone scripts are removed" {
  [ ! -f "$PLUGIN/skills/gaia-tech-debt-review/scripts/scan-findings.sh" ]
  [ ! -f "$PLUGIN/skills/gaia-tech-debt-review/scripts/td-id-assign.sh" ]
  [ ! -d "$PLUGIN/skills/gaia-tech-debt-review/scripts" ]
}

# TC-STCL-8 — gaia-help.csv: the tech-debt-review row is gone and a
# triage-findings row is present.
@test "TC-STCL-8: gaia-help.csv has triage-findings, not tech-debt-review" {
  run grep -c '"gaia-tech-debt-review"' "$HELP"
  [ "$output" -eq 0 ]
  grep -qE '"triage-findings"' "$HELP"
}

# workflow-manifest.csv: tech-debt-review row removed, triage-findings kept.
@test "TC-STCL-8b: workflow-manifest.csv drops the tech-debt-review row" {
  run grep -c '^"tech-debt-review"' "$MANIFEST"
  [ "$output" -eq 0 ]
  grep -qE '^"triage-findings"' "$MANIFEST"
}

# lifecycle-sequence.yaml: tech-debt-review node removed, triage-findings kept.
@test "TC-STCL-8c: lifecycle-sequence.yaml drops the tech-debt-review node" {
  run grep -c '^  tech-debt-review:' "$LIFECYCLE"
  [ "$output" -eq 0 ]
  grep -qE '^  triage-findings:' "$LIFECYCLE"
}
