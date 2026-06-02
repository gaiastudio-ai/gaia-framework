#!/usr/bin/env bats
# e44-s8-val-observability-logging.bats
#
# Script-verifiable coverage for the Val Auto-Review Observability + Logging
# story (E44-S8 / FR-344 / ADR-058 / ADR-059 / VCP-FIX-07). Asserts that the
# gaia-val-validate SKILL.md documents the per-iteration log record shape,
# cross-references the canonical ADRs, and that the VCP-FIX-07 thrash test
# carries the fields required by the story acceptance criteria.
#
# Covers (story acceptance criteria):
#   AC1 — each of 3 iterations is distinguishable by a unique iteration number
#   AC2 — log is structured (parsable without regex scraping); checkpoint custom
#         namespace per ADR-059
#   AC3 — iteration record carries iteration, timestamp, findings list,
#         fix_diff, revalidation_outcome
#   AC4 — checkpoint custom.val_loop_iterations carries the log across resume
#   AC5 — VCP-FIX-07 exercises a 3-iteration thrash and inspects per-iteration
#         findings + fix_diff
#
# Tasks covered:
#   Task 1 — record shape documented in SKILL.md
#   Task 2 — log writes wired into auto-fix loop pattern (consumer snippet)
#   Task 3 — VCP-FIX-07 test file shape
#   Task 4 — Iteration Log Format subsection with cross-references
#   Task 5 — test-plan §11.46.4 VCP-FIX-07 row marked Written

load 'test_helper.bash'

setup() {
  common_setup
  SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-val-validate" && pwd)/SKILL.md"
  VCP_FIX_07="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-val-validate/tests" && pwd)/vcp-fix-07-thrash.md"
  # test-plan.md lives at the project-root level (docs/test-artifacts/) — NOT
  # in this repo (gaia-public/). The published artifact is generated outside
  # the gaia-public tree per the GAIA project-root convention. Resolve
  # tolerantly: try the candidate path; if absent, leave TEST_PLAN unset and
  # the §11.46.4 row tests will skip.
  local _candidate="$BATS_TEST_DIRNAME/../../../../docs/test-artifacts/test-plan.md"
  if [ -f "$_candidate" ]; then
    TEST_PLAN="$(cd "$BATS_TEST_DIRNAME/../../../../docs/test-artifacts" && pwd)/test-plan.md"
  else
    TEST_PLAN=""
  fi
  export SKILL VCP_FIX_07 TEST_PLAN
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Task 1 / AC3 — Iteration record shape documented
# ---------------------------------------------------------------------------

@test "Task1: SKILL.md exists and is readable" {
  [ -f "$SKILL" ]
  [ -r "$SKILL" ]
}

@test "Task1/AC3: SKILL.md documents iteration_number field in the record shape" {
  grep -q '`iteration_number`' "$SKILL"
}

@test "Task1/AC3: SKILL.md documents timestamp field in the record shape" {
  grep -q '`timestamp`' "$SKILL"
}

@test "Task1/AC3: SKILL.md documents findings field in the record shape" {
  grep -q '`findings`' "$SKILL"
}

@test "Task1/AC3: SKILL.md documents fix_diff_summary field in the record shape" {
  grep -q '`fix_diff_summary`' "$SKILL"
}

@test "Task1/AC3: SKILL.md documents revalidation_outcome field in the record shape" {
  grep -q '`revalidation_outcome`' "$SKILL"
}

@test "Task1/AC3: SKILL.md documents revalidation_outcome enum values" {
  grep -q -E 'clean|info_only|findings_present|val_invocation_failed' "$SKILL"
}

# ---------------------------------------------------------------------------
# Task 4 — Iteration Log Format subsection + cross-references (AC2, AC4)
# ---------------------------------------------------------------------------

@test "Task4: SKILL.md contains '### Iteration Log Format' subsection" {
  grep -q '^### Iteration Log Format' "$SKILL"
}

@test "Task4/AC2: SKILL.md cites ADR-059 checkpoint custom: namespace" {
  grep -q -E 'ADR-059' "$SKILL"
  grep -q -E 'custom\.val_loop_iterations|custom\.`val_loop_iterations`|`custom\.val_loop_iterations`' "$SKILL"
}

@test "Task4: SKILL.md cites ADR-058 for the loop contract" {
  grep -q 'ADR-058' "$SKILL"
}

@test "Task4: SKILL.md contains a JSON example illustrating the log record" {
  # Look for a JSON code fence anywhere under the Iteration Log Format
  # subsection (and require the example to mention iteration_number).
  awk '/^### Iteration Log Format/{flag=1; next}
       /^### /{if(flag)exit} flag' "$SKILL" \
    | grep -q -E '"iteration_number"'
}

@test "Task4/AC4: SKILL.md notes /gaia-resume reads val_loop_iterations" {
  grep -q -E '/gaia-resume' "$SKILL"
  grep -q 'val_loop_iterations' "$SKILL"
}

# ---------------------------------------------------------------------------
# Task 2 / AC1 / AC4 — Log writes wired into the loop (consumer snippet)
# ---------------------------------------------------------------------------

@test "Task2/AC1: consumer snippet appends iteration log record" {
  grep -q -E 'Append an iteration log record|append.*iteration.*log.*record' "$SKILL"
}

@test "Task2/AC4: consumer snippet writes to checkpoint custom.val_loop_iterations" {
  grep -q 'custom.val_loop_iterations' "$SKILL"
}

@test "Task2.3/AC1: SKILL.md documents post_escape flag for iterations 4+" {
  grep -q 'post_escape' "$SKILL"
}

# ---------------------------------------------------------------------------
# Task 3 / AC1 / AC5 — VCP-FIX-07 LLM-checkable test exists with thrash shape
# ---------------------------------------------------------------------------

@test "Task3: VCP-FIX-07 test file exists" {
  [ -f "$VCP_FIX_07" ]
}

@test "Task3/AC5: VCP-FIX-07 documents a 3-iteration thrash scenario" {
  grep -q -E '3[- ]iteration|Iteration 1.*Iteration 2.*Iteration 3' "$VCP_FIX_07"
  grep -q 'Iteration 1' "$VCP_FIX_07"
  grep -q 'Iteration 2' "$VCP_FIX_07"
  grep -q 'Iteration 3' "$VCP_FIX_07"
}

@test "Task3/AC1: VCP-FIX-07 asserts unique iteration_number per record" {
  grep -q -E 'iteration_number = 1, 2, 3|distinguishable by .*iteration' "$VCP_FIX_07"
}

@test "Task3/AC3: VCP-FIX-07 asserts findings list present per iteration" {
  grep -q '`findings`' "$VCP_FIX_07"
}

@test "Task3/AC3: VCP-FIX-07 asserts fix_diff captured per iteration" {
  grep -q -E 'fix_diff|fix_diff_summary' "$VCP_FIX_07"
}

@test "Task3/AC2: VCP-FIX-07 references checkpoint custom namespace or val_loop_iterations" {
  grep -q -E 'val_loop_iterations|custom\.' "$VCP_FIX_07"
}

# ---------------------------------------------------------------------------
# Task 5.2 — test-plan.md §11.46.4 VCP-FIX-07 row marked Written
# ---------------------------------------------------------------------------

@test "Task5.2: test-plan.md exists at project-root (skip if not in this repo tree)" {
  if [ -z "$TEST_PLAN" ] || [ ! -f "$TEST_PLAN" ]; then
    skip "test-plan.md is at project-root (docs/test-artifacts/), outside gaia-public/"
  fi
  [ -f "$TEST_PLAN" ]
}

@test "Task5.2: test-plan.md VCP-FIX-07 row is marked Written (not Planned)" {
  if [ -z "$TEST_PLAN" ] || [ ! -f "$TEST_PLAN" ]; then
    skip "test-plan.md is at project-root (docs/test-artifacts/), outside gaia-public/"
  fi
  # Find the VCP-FIX-07 row and ensure it ends with "Written" (or " | Written |"),
  # not "Planned / Not Yet Written".
  local row
  row="$(grep '^| VCP-FIX-07' "$TEST_PLAN")"
  [ -n "$row" ]
  echo "$row" | grep -qv 'Planned / Not Yet Written'
  echo "$row" | grep -q 'Written'
}
