#!/usr/bin/env bats
# completion-notes-deferral-scan.bats — E88-S4 Val pattern + triage extension.
#
# Covers TC-DPD-15..18.
#
# Helper under test:
#   gaia-public/plugins/gaia/scripts/lib/completion-notes-deferral-scan.sh
#
# Invocation contract:
#   completion-notes-deferral-scan.sh --story-file <path>
#     - exit 0 always (the helper emits, doesn't HALT — the caller decides
#       whether unmatched phrases are CRITICAL findings)
#     - stdout: one record per matched deferral phrase, format:
#         phrase=<phrase>\tpaired=<true|false>\tfinding_id=<id-or-empty>
#       Pair-check: substring-match against `## Findings` table rows OR
#       explicit `Finding ID: <X>` token on the matching Completion-Notes line.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  HELPER="$LIB_DIR/completion-notes-deferral-scan.sh"
  FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures/completion-notes-deferral"
  export LIB_DIR HELPER FIXTURES_DIR
}

teardown() {
  common_teardown
}

# ---------------- TC-DPD-15: unmatched deferral -> finding ----------------
@test "unmatched deferral phrase in Completion Notes -> emit paired=false" {
  local fixture="$FIXTURES_DIR/unmatched.md"
  [ -f "$fixture" ]
  run "$HELPER" --story-file "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"phrase=follow-up integration story"* ]]
  [[ "$output" == *"paired=false"* ]]
}

# ---------------- TC-DPD-16: matched deferral -> no emission ----------------
@test "matched deferral phrase (Findings row pair) -> paired=true" {
  local fixture="$FIXTURES_DIR/matched.md"
  [ -f "$fixture" ]
  run "$HELPER" --story-file "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"phrase=follow-up integration story"* ]]
  [[ "$output" == *"paired=true"* ]]
  [[ "$output" == *"finding_id=1"* ]]
}

# ---------------- TC-DPD-17: triage source-column extension ----------------
@test "helper output is consumable as triage-row source=completion-notes-deferral-scan" {
  local fixture="$FIXTURES_DIR/unmatched.md"
  run "$HELPER" --story-file "$fixture"
  [ "$status" -eq 0 ]
  # Triage caller consumes the helper output and pipes it through a source-tag.
  # The contract: each emitted record contains a matchable phrase + paired flag
  # that the triage caller maps to `source: completion-notes-deferral-scan`.
  # This bats only verifies the helper-side payload is non-empty + structured.
  [[ "$output" == *"phrase="* ]]
  [[ "$output" == *"paired="* ]]
}

# ---------------- TC-DPD-18 (SSOT static audit) ----------------
@test "SKILL.md files reference matcher library, not inline taxonomy" {
  local PLUGIN_DIR
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # gaia-validation-patterns SKILL.md must reference the matcher library OR
  # the new helper script that wraps it.
  local vp="$PLUGIN_DIR/skills/gaia-validation-patterns/SKILL.md"
  [ -f "$vp" ]
  grep -qE 'deferral-phrase-match\.sh|completion-notes-deferral-scan\.sh' "$vp"

  # gaia-triage-findings SKILL.md must reference the matcher or the helper.
  local tf="$PLUGIN_DIR/skills/gaia-triage-findings/SKILL.md"
  [ -f "$tf" ]
  grep -qE 'deferral-phrase-match\.sh|completion-notes-deferral-scan\.sh' "$tf"

  # Neither SKILL.md may reproduce the full deferral taxonomy list. Same
  # >=3-distinct-entries drift signal as E88-S1's SSOT audit.
  for skill in "$vp" "$tf"; do
    local distinct
    # grep returns exit 1 when there are no matches, which fires set -e
    # under bats. The `|| true` and explicit fallback keep the count
    # robust at zero when the SKILL.md has no taxonomy references.
    distinct="$(grep -wFf "$PLUGIN_DIR/knowledge/taxonomy/deferral-phrases.txt" "$skill" 2>/dev/null \
      | grep -oE 'deferred|follow-up integration story|stub seam|harness wiring lands|not-yet-wired|production wiring' 2>/dev/null \
      | sort -u | wc -l | tr -d ' ' || true)"
    distinct="${distinct:-0}"
    if [ "$distinct" -ge 3 ]; then
      printf 'TC-DPD-18: %s reproduces taxonomy entries (>=3 distinct): %s\n' \
        "$skill" "$distinct" >&2
      return 1
    fi
  done
}
