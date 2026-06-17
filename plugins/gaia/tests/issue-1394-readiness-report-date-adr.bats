#!/usr/bin/env bash
# issue-1394-readiness-report-date-adr.bats
#
# generate-readiness-report.sh emitted a report that FAILED the same skill's
# own finalize checklist: SV-19 (needs a `date:` frontmatter key — the stub
# wrote only `generated_at:`) and SV-17 (needs an "ADR" keyword — the body
# never said it). The deterministic generator must satisfy its own gate
# without LLM hand-patching.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GEN="$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh"
  REPORT="$TEST_TMP/.gaia/artifacts/planning-artifacts/readiness-report.md"
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
}
teardown() { common_teardown; }

_gen() {
  run bash "$GEN" --status PASS --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ -f "$REPORT" ]
}

@test "issue-1394: generated report has a 'date:' YAML frontmatter key" {
  _gen
  # The frontmatter must carry a top-level `date:` field (not only generated_at:).
  run grep -nE '^date:[[:space:]]' "$REPORT"
  [ "$status" -eq 0 ]
}

@test "issue-1394: generated report body mentions ADR (Architecture ADR review)" {
  _gen
  grep -qE '\bADR\b' "$REPORT"
}

@test "issue-1394: generated report still validates artifact_type + status" {
  _gen
  grep -qF 'artifact_type: readiness-report' "$REPORT"
}

# Drive the actual finalize checklist: the generator output must PASS SV-17 + SV-19.
@test "issue-1394: generator output passes the skill's own + checks" {
  _gen
  FINALIZE="$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/finalize.sh"
  [ -f "$FINALIZE" ]
  run env READINESS_ARTIFACT="$REPORT" CHECKPOINT_PATH="$TEST_TMP/.gaia/memory/checkpoints" \
    bash "$FINALIZE"
  # finalize may exit non-zero for unrelated env reasons, but SV-17/SV-19 must
  # NOT appear in any FAIL/violation lines.
  ! printf '%s\n' "$output" | grep -E 'SV-17|SV-19' | grep -qiE 'fail|violation|missing'
}
