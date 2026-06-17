#!/usr/bin/env bats
# e44-s2-val-auto-fix-loop-pattern.bats
#
# Script-verifiable coverage for the Val Auto-Fix Loop Pattern (E44-S2 /
# FR-344 / NFR-VCP-2 / ADR-058). Asserts the gaia-val-validate SKILL.md
# encodes the canonical 3-iteration pattern that consumer skills (E44-S3..S6)
# embed verbatim.
#
# Covers (story acceptance criteria):
#   AC1 — happy path documented (iter 1 critical -> iter 2 clean)
#   AC2 — iteration-3 user prompt with exactly 3 options and verbatim text
#   AC3 — post-escape continue semantics (no implicit cap)
#   AC4 — per-iteration log record shape distinguishable by iteration number
#   AC5 — token budget targets (per-iteration <=2x, total <=6x baseline)
#   AC6 — YOLO hard-gate invariant cross-referenced to ADR-057 FR-YOLO-2(e)
#   AC-EC4 — thrash detection rule documented
#   AC-EC6 — accept-as-is creates ## Open Questions section if missing
#   AC-EC7 — YOLO bypass attempt logs hard-gate violation
#   AC-EC10 — INFO-only findings exit without applying fix
#
# Companion to e44-s1-val-validate-upstream-contract.bats which verifies
# the upstream invocation contract this pattern consumes.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-val-validate" && pwd)/SKILL.md"
  export SKILL
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — Section anchor present
# ---------------------------------------------------------------------------

@test "SKILL.md exists and is readable" {
  [ -f "$SKILL" ]
  [ -r "$SKILL" ]
}

@test "SKILL.md contains '## Auto-Fix Loop Pattern' anchor" {
  grep -q '^## Auto-Fix Loop Pattern' "$SKILL"
}

@test "SKILL.md documents the canonical auto-fix-loop pattern section" {
  # Assert the contract (the canonical auto-fix-loop spec), not an internal
  # story key (scrubbed from published source).
  grep -qE '^## Auto-Fix Loop Pattern' "$SKILL"
  grep -qiE '3-iteration' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC1/AC4 — State machine documented with iteration numbering
# ---------------------------------------------------------------------------

@test "SKILL.md documents the canonical state machine" {
  grep -q -E 'State [Mm]achine' "$SKILL"
}

@test "SKILL.md states iteration counter starts at 1" {
  grep -q -E 'iteration *= *1' "$SKILL"
}

@test "SKILL.md states 3-iteration hard cap" {
  grep -q -E '3-iteration|iteration *<= *3|iteration *> *3' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC2 — Iteration-3 prompt verbatim with exactly 3 options
# ---------------------------------------------------------------------------

@test "SKILL.md contains canonical iteration-3 prompt text" {
  grep -q 'Iteration 3 of Val auto-fix did not converge' "$SKILL"
}

@test "prompt offers Continue option (key c)" {
  grep -q -F '[c] Continue' "$SKILL"
}

@test "prompt offers Accept-as-is option (key a)" {
  grep -q -F '[a] Accept as-is' "$SKILL"
}

@test "prompt offers Abort option (key x)" {
  grep -q -F '[x] Abort' "$SKILL"
}

@test "SKILL.md documents accepted input synonyms (continue/accept/abort)" {
  grep -q -E 'continue' "$SKILL"
  grep -q -E 'accept' "$SKILL"
  grep -q -E 'abort' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC3 — Post-escape semantics (no implicit cap after user "continue")
# ---------------------------------------------------------------------------

@test "SKILL.md documents post-escape continue semantics" {
  grep -q -E -i 'post-?escape' "$SKILL"
}

@test "SKILL.md states no implicit cap after first escape" {
  grep -q -E -i 'no implicit cap' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC4 — Iteration log record shape
# ---------------------------------------------------------------------------

@test "SKILL.md documents per-iteration log record shape" {
  grep -q -E 'iteration number' "$SKILL"
  grep -q -E 'timestamp' "$SKILL"
  grep -q -E 'findings' "$SKILL"
  grep -q -E 'fix.diff' "$SKILL"
}

@test "SKILL.md routes iteration logs to checkpoint custom.val_loop_iterations" {
  grep -q 'val_loop_iterations' "$SKILL"
}

@test "SKILL.md documents checkpoint custom namespace for iteration log storage" {
  grep -q -E "checkpoint.*custom.*namespace|custom.*namespace.*checkpoint|custom:.*namespace" "$SKILL"
}

# ---------------------------------------------------------------------------
# AC5 — Token budget targets documented
# ---------------------------------------------------------------------------

@test "SKILL.md states per-iteration <= 2x single-pass baseline" {
  grep -q -E '(2x|<= *2x|<=2x)' "$SKILL"
}

@test "SKILL.md states 3-iteration total <= 6x baseline" {
  grep -q -E '(6x|<= *6x|<=6x)' "$SKILL"
}

@test "SKILL.md documents token-budget envelope section" {
  grep -q -E '## Token Budget|token-budget envelope|token budget' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC6 / AC-EC7 — YOLO hard-gate invariant
# ---------------------------------------------------------------------------

@test "SKILL.md documents YOLO hard-gate invariant" {
  grep -q -E -i 'YOLO' "$SKILL"
  grep -q -E -i 'hard.?gate' "$SKILL"
}

@test "SKILL.md states YOLO hard-gate is invariant and prompt must not be auto-answered" {
  grep -q -E 'invariant under YOLO|YOLO.*invariant' "$SKILL"
  grep -q -E 'MUST NOT.*auto-answer|auto-answered.*YOLO|yolo_hard_gate_violation' "$SKILL"
}

@test "SKILL.md documents bypass-attempt logging" {
  grep -q -E -i 'bypass' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC-EC4 — Thrash detection
# ---------------------------------------------------------------------------

@test "SKILL.md documents thrash detection rule" {
  grep -q -E -i 'thrash' "$SKILL"
}

@test "SKILL.md states thrash still advances iteration counter" {
  # Thrashes are logged but DO NOT short-circuit the 3-cap.
  grep -q -E 'short.circuit|advance.*counter|still increments|increments the iteration' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC-EC6 — Accept-as-is creates ## Open Questions section
# ---------------------------------------------------------------------------

@test "SKILL.md documents Open Questions section creation on accept-as-is" {
  grep -q '## Open Questions' "$SKILL"
}

@test "SKILL.md documents accept-as-is record template" {
  grep -q -E 'Unresolved after 3 Val iterations' "$SKILL"
}

# ---------------------------------------------------------------------------
# AC-EC10 — INFO-only findings exit without fix
# ---------------------------------------------------------------------------

@test "SKILL.md states INFO does not trigger auto-fix" {
  grep -q -E -i 'INFO.*(informational|does not trigger|not.*trigger)' "$SKILL"
}

# ---------------------------------------------------------------------------
# Severity contract — only CRITICAL and WARNING drive the loop
# ---------------------------------------------------------------------------

@test "SKILL.md states CRITICAL and WARNING drive the loop" {
  grep -q -E 'CRITICAL.*WARNING|CRITICAL or WARNING' "$SKILL"
}

# ---------------------------------------------------------------------------
# Consumer-skill snippet — copy-pasteable fragment for E44-S3..S6
# ---------------------------------------------------------------------------

@test "Snippet: SKILL.md contains a copy-pasteable consumer-skill snippet section" {
  grep -q -E -i 'Consumer.?[Ss]kill [Ss]nippet|Copy-Pasteable' "$SKILL"
}

# ---------------------------------------------------------------------------
# Cross-references — story dependencies and traces
# ---------------------------------------------------------------------------

@test "Trace: SKILL.md is the single source of truth for the Val auto-fix loop pattern" {
  grep -q -E 'single source of truth' "$SKILL"
}

@test "Trace: SKILL.md documents the auto-fix-loop re-invocation contract" {
  # Assert the contract the loop spec depends on (severity-driven blocking +
  # idempotent re-invocation), not an internal identifier.
  grep -qiE 'CRITICAL and WARNING block the upstream loop|severity.*drive the 3-iteration loop' "$SKILL"
}
