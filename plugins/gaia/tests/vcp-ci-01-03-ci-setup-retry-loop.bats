#!/usr/bin/env bats
# vcp-ci-01-03-ci-setup-retry-loop.bats — E46-S7 LLM-checkable structural
# guards for the /gaia-ci-setup schema validation retry loop (FR-355).
#
# Covers VCP-CI-01 (valid-first-pass), VCP-CI-02 (single retry), and
# VCP-CI-03 (multi-retry) per docs/test-artifacts/test-plan.md §11.46.15.
#
# These tests are LLM-checkable in the test-plan classification because the
# loop body itself is interpreted by Claude Code at runtime against the
# SKILL.md prose. The bats here verifies the structural contract that the
# SKILL.md actually contains the loop machinery, the violation output
# format, and the documented entry / exit / abort paths — i.e. the
# preconditions a Claude Code session needs before the LLM-side run can
# pass. If any of these structural guards regress, the runtime LLM check
# would also regress, so a CI-side bats sentinel is the cheapest gate.
#
# Story: E46-S7 — `/gaia-ci-setup` schema validation retry loop.
# Trace : FR-355 → E46-S7 → VCP-CI-01..VCP-CI-03.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-ci-setup"
SKILL_MD="$SKILL_DIR/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CI-01 — Valid first-pass: SKILL.md documents that on a passing
# validation the retry loop exits immediately with no violations output.
# -------------------------------------------------------------------------

@test "VCP-CI-01: SKILL.md declares the retry-loop subsection (anchor present)" {
  run grep -E '^### Schema Validation Retry Loop' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-CI-01: SKILL.md documents the valid-first-pass exit (no violations on pass)" {
  # The skill must explicitly state that on successful validation the loop
  # exits immediately and no violations output is emitted — otherwise a
  # downstream LLM run cannot tell whether silence means pass or skip.
  run bash -c "grep -Eiq '(first[- ]?(attempt|pass)|on[[:space:]]+pass).*exit' '$SKILL_MD' \
            && grep -Eiq 'no[[:space:]]+violations' '$SKILL_MD'"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# VCP-CI-02 — Single retry: violations output format is a {field, expected,
# actual} triplet AND the user prompt for re-validation is documented.
# -------------------------------------------------------------------------

@test "VCP-CI-02: SKILL.md documents the violation triplet {field, expected, actual}" {
  # The triplet is the canonical machine-parseable record per Tech Notes
  # §Violation format contract. All three field names MUST appear.
  run bash -c "grep -Eiq 'field' '$SKILL_MD' \
            && grep -Eiq 'expected' '$SKILL_MD' \
            && grep -Eiq 'actual' '$SKILL_MD'"
  [ "$status" -eq 0 ]
}

@test "VCP-CI-02: SKILL.md declares a 'Violation Output Format' subsection" {
  # Subtask 2.2 — the format MUST be documented under its own subsection so
  # future edits don't silently regress it.
  run grep -E '^####?[[:space:]]+Violation[[:space:]]+Output[[:space:]]+Format' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-CI-02: SKILL.md documents the [c] re-validate prompt" {
  # Subtask 3.2 — on failure the user must be prompted [c] to re-validate.
  run grep -E '\[c\]' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-CI-02: SKILL.md documents the [x] abort prompt" {
  # Subtask 3.4 — abort path must be explicit and distinct from pass.
  run grep -E '\[x\]' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# VCP-CI-03 — Multi-retry: the loop has NO hard iteration cap. The user
# controls convergence. Abort is the only forced exit other than pass.
# -------------------------------------------------------------------------

@test "VCP-CI-03: SKILL.md states the loop has no hard retry cap" {
  # AC3 explicitly forbids an arbitrary retry limit. Look for the
  # documented "no hard cap" / "no retry limit" / "user controls
  # convergence" phrasing.
  run bash -c "grep -Eiq 'no[[:space:]]+hard[[:space:]]+cap|no[[:space:]]+(retry|iteration)[[:space:]]+(limit|cap)|user[- ]controll?ed[[:space:]]+convergence|user[[:space:]]+controls[[:space:]]+convergence' '$SKILL_MD'"
  [ "$status" -eq 0 ]
}

@test "VCP-CI-03: SKILL.md documents the Schema Validation Retry Loop subsection" {
  # Assert the documented retry-loop subsection + its no-hard-cap semantics,
  # not an internal test-plan section pointer (scrubbed from published source).
  grep -qE '^### Schema Validation Retry Loop' "$SKILL_MD"
  grep -qiE 'No hard retry cap|no hard cap on iterations' "$SKILL_MD"
}

@test "VCP-CI-03: SKILL.md cross-references VCP-CI-01..VCP-CI-03" {
  # Subtask 4.3 — must document all three test-case behavioral paths:
  # valid-first-pass (VCP-CI-01), single-retry (VCP-CI-02), multi-retry (VCP-CI-03).
  run bash -c "grep -Eiq 'valid-first-pass|VCP-CI-01' '$SKILL_MD' \
            && grep -Eiq 'single-retry|VCP-CI-02' '$SKILL_MD' \
            && grep -Eiq 'multi-retry|VCP-CI-03' '$SKILL_MD'"
  [ "$status" -eq 0 ]
}

@test "VCP-CI-03: SKILL.md documents the loop body (entry, body, exit, abort)" {
  # Subtask 4.1 — all four loop semantics must be documented.
  run bash -c "grep -Eiq 'entry' '$SKILL_MD' \
            && grep -Eiq 'exit' '$SKILL_MD' \
            && grep -Eiq 'abort' '$SKILL_MD'"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Scope guard — the loop wraps validate-gate.sh; it does NOT duplicate
# validate-gate.sh logic inline (Tech Notes §Scope boundary, DoD §Code
# Quality & CI).
# -------------------------------------------------------------------------

@test "Scope: SKILL.md retry loop references validate-gate.sh as the wrapped primitive" {
  run grep -E 'validate-gate\.sh' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Loop placement — the retry loop lives inside the SKILL.md validation
# step, NOT in finalize.sh (Tech Notes §Loop placement).
# -------------------------------------------------------------------------

@test "Placement: retry-loop subsection appears before the ## Finalize section" {
  run awk '
    /^### Schema Validation Retry Loop/ { retry = NR }
    /^## Finalize/                      { finalize = NR }
    END {
      if (retry > 0 && finalize > 0 && retry < finalize) { print "ok" }
      else { print "bad" }
    }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
