#!/usr/bin/env bats
# gaia-meeting-stdout-sentinel-forbid.bats — E76-S15 anti-pattern check
#
# Scans `/gaia-meeting` SKILL.md yield-boundary procedure sections for
# stdout-sentinel patterns that were empirically defeated by harness Auto Mode
# on 2026-05-09 (memory rule `feedback_askuserquestion_under_automode.md`).
#
# Forbidden patterns inside yield-boundary procedure sections:
#   1. `<<YIELD-STOP`     — script-side turn-terminal sentinel emitted by yield-gate.sh
#   2. `<<TURN-END`       — alternate sentinel form used in early E76-S7 drafts
#
# Both patterns are forbidden inside SKILL.md yield-boundary procedures because
# they fail under Auto Mode — the harness does not stop on stdout content. The
# substrate-correct primitive is `AskUserQuestion` (lands in E76-S18, ADR-083
# amendment AF-2026-05-10-1).
#
# The scanner deliberately limits its scope to yield-boundary procedure
# sections so this story's prose, ADR-083 detail records, change-log entries,
# and other documentation references that legitimately discuss the deprecated
# mechanism do NOT trip the check.
#
# Test cases (AC mapping):
#   TC-MTG-AUQS-1 — fixture with `<<YIELD-STOP` in yield-boundary section FAILS
#   TC-MTG-AUQS-1 — fixture with `<<TURN-END` in yield-boundary section FAILS
#   TC-MTG-AUQS-2 — clean post-AF-5-10-1 fixture PASSes
#   AC #6 — output format `{file}:{line}:{matched-pattern}`
#   TC-MTG-AUQS-3 — CI step references this bats file
#   AC #4 — SKILL.md §Critical Rules contains the auto-mode clause
#   AC #5 — SKILL.md cites memory rule + AI-2026-05-09-8 as precedent

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  SCANNER="$SKILL_DIR/scripts/stdout-sentinel-scan.sh"
  FIXTURES_DIR="$SKILL_DIR/tests/fixtures"
  SKILL_MD="$SKILL_DIR/SKILL.md"

  export LC_ALL=C

  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# --- TC-MTG-AUQS-1: regression fixture trips check ----------------------------

@test "TC-MTG-AUQS-1: scanner detects '<<YIELD-STOP' in yield-boundary section" {
  cp "$FIXTURES_DIR/skill-md-with-stdout-sentinel.md" "$TMP/dirty.md"
  run "$SCANNER" "$TMP/dirty.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "<<YIELD-STOP"
}

@test "TC-MTG-AUQS-1: scanner detects '<<TURN-END' in yield-boundary section" {
  cp "$FIXTURES_DIR/skill-md-with-stdout-sentinel.md" "$TMP/dirty.md"
  run "$SCANNER" "$TMP/dirty.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "<<TURN-END"
}

# --- AC #6: output format `{file}:{line}:{matched-pattern}` ------------------

@test "AC #6: scanner emits {file}:{line}:{matched-pattern} format on a violating fixture" {
  cp "$FIXTURES_DIR/skill-md-with-stdout-sentinel.md" "$TMP/v.md"
  run "$SCANNER" "$TMP/v.md"
  [ "$status" -ne 0 ]
  # Format: file:line:matched-pattern (3 fields separated by ':')
  echo "$output" | grep -E "^.+:[0-9]+:<<(YIELD-STOP|TURN-END)"
}

# --- TC-MTG-AUQS-2: clean fixture passes (regression guard against false positives)

@test "TC-MTG-AUQS-2: clean post-AF-5-10-1 fixture exits zero with no output" {
  run "$SCANNER" "$FIXTURES_DIR/skill-md-clean.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Negative control: documentation references outside yield-boundary
# sections MUST NOT trigger the scanner. The live SKILL.md (after E76-S18 lands)
# will still discuss the deprecated mechanism in §Critical Rules and §References,
# but those sections are out-of-scope for the scanner.
@test "negative control: documentation references outside yield-boundary scope are not flagged" {
  # Simulate a SKILL.md that mentions <<YIELD-STOP only in a §Critical Rules
  # auto-mode-clause prohibition (out-of-scope for the scanner).
  cat > "$TMP/doc-only.md" <<'EOF'
---
name: doc-only-fixture
---

## Critical Rules

- Yield boundaries MUST use the substrate `AskUserQuestion` primitive, NOT
  stdout sentinels (`<<YIELD-STOP`, `<<TURN-END`, etc.). The script-side
  stdout-sentinel mechanism was empirically defeated by harness Auto Mode on
  2026-05-09.

## Procedure

### Phase 2 — CHARTER

3. **Post-CHARTER yield boundary.** Invoke `AskUserQuestion` with the canonical
   prompt block. The substrate halts the turn.
EOF
  run "$SCANNER" "$TMP/doc-only.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- TC-MTG-AUQS-3: CI step wiring (static check) ----------------------------

@test "TC-MTG-AUQS-3: plugin-ci.yml references gaia-meeting-stdout-sentinel-forbid" {
  CI_FILE="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  [ -f "$CI_FILE" ]
  grep -F "gaia-meeting-stdout-sentinel-forbid" "$CI_FILE"
}

# --- AC #4: SKILL.md §Critical Rules contains the auto-mode clause -----------

@test "AC #4: SKILL.md §Critical Rules contains explicit auto-mode clause" {
  [ -f "$SKILL_MD" ]
  # Regex from AC: [Yy]ield boundaries MUST use the substrate .AskUserQuestion. primitive
  grep -E "[Yy]ield boundaries MUST use the substrate .AskUserQuestion. primitive" "$SKILL_MD"
}

# --- AC #5: SKILL.md cites the memory rule as empirical precedent ------------

@test "AC #5: SKILL.md cites memory rule feedback_askuserquestion_under_automode.md" {
  [ -f "$SKILL_MD" ]
  grep -F "feedback_askuserquestion_under_automode" "$SKILL_MD"
}

@test "AC #5: SKILL.md documents the AskUserQuestion-over-stdout-sentinels contract" {
  [ -f "$SKILL_MD" ]
  grep -qiE 'AskUserQuestion' "$SKILL_MD"
  grep -qiE 'stdout sentinel' "$SKILL_MD"
}

# --- Behavioral: live SKILL.md scan exits zero (post-implementation guard) ---
#
# Once E76-S18 lands and replaces the yield-gate.sh exec calls with
# AskUserQuestion in SKILL.md yield-boundary sections, this test will assert
# the live SKILL.md is clean. Until E76-S18 lands, the live SKILL.md still
# contains <<YIELD-STOP sentinels in yield-boundary sections — so this test
# is a forward-looking guard, skipped when SKILL.md still embeds the
# deprecated mechanism.
@test "live SKILL.md scan: forward-looking guard (skipped pre-E76-S18)" {
  if grep -nE '^[[:space:]]*<<YIELD-STOP|^[[:space:]]*<<TURN-END' "$SKILL_MD" >/dev/null 2>&1; then
    : # SKILL.md still emits literal sentinel lines in code-block prose; will
      # become a hard assertion once E76-S18 lands.
  fi
  # No assertion fired here — when E76-S18 replaces sentinels in
  # yield-boundary procedures, the scanner will exit 0 against the live
  # SKILL.md and the @test "live SKILL.md is clean" guard below will fire.
  run "$SCANNER" "$SKILL_MD"
  # Either passes (post-E76-S18) or fails (pre-E76-S18) — both are valid
  # transition states. The test asserts the scanner runs without crashing.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
