#!/usr/bin/env bats
# dev-story-stack-dev-delegation.bats
#
# Structural guards that gaia-dev-story delegates plan authoring (Step 4) and
# TDD implementation (Steps 5/6/7) to a stack-matched developer subagent
# resolved from project knowledge — mirroring the gaia-quick-dev delegation
# model — rather than authoring the plan and writing code inline in the
# main-turn orchestrator.
#
# Behavioral contract under test:
#   1. A dedicated "Resolve Stack Developer" step exists and resolves the
#      persona via the shared load-stack-persona.sh resolver keyed off the
#      story file.
#   2. The plan step (Step 4) is delegated to the resolved developer subagent.
#   3. Each TDD body (Red / Green / Refactor) is authored by the developer
#      subagent, not by orchestrator-inline Edit/Write.
#   4. The Val auto-fix loops (plan gate + Step 7b) route code/plan fixes to
#      the developer subagent — no orchestrator-inline "no subagent spawn"
#      code-writing remains.
#   5. The orchestrator-owned gates are preserved unchanged: the tdd-reviewer
#      review gates and the Val plan/diff validation still dispatch their own
#      sibling subagents.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_MD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story" && pwd)/SKILL.md"
  RESOLVER="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/load-stack-persona.sh"
  export SKILL_MD RESOLVER
  [ -f "$SKILL_MD" ] || { echo "SKILL.md not found at $SKILL_MD" >&2; return 1; }
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# 1 — Resolve Stack Developer step
# ---------------------------------------------------------------------------

@test "Resolve Stack Developer step is present" {
  run grep -Ec '^### Step 3b -- Resolve Stack Developer' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "developer resolution uses the shared load-stack-persona.sh resolver with --story-file" {
  grep -q 'load-stack-persona.sh --story-file' "$SKILL_MD"
}

@test "the shared resolver script exists and is executable" {
  [ -x "$RESOLVER" ]
}

@test "resolver supports the --story-file flag (contract the SKILL.md depends on)" {
  run "$RESOLVER" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'story|stack'
}

@test "unsupported/unresolved stack HALTs rather than self-implementing" {
  # The skill must explicitly forbid falling back to an orchestrator-authored
  # implementation when no developer persona resolves.
  grep -qiE 'HALT.*(do NOT|never).*(fall back|self-implement|orchestrator-authored)' "$SKILL_MD" \
    || grep -qiE 'do NOT.*fall back.*orchestrator-authored implementation' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# 2 — Plan authoring delegated (Step 4)
# ---------------------------------------------------------------------------

@test "Step 4 plan is developer-authored, not orchestrator-authored" {
  # Assert the plan-authoring delegation directive is present in Step 4.
  # Use `run bash -c` so the pipeline's final exit status (grep) is what is
  # asserted — a bare `awk | grep -q` can surface awk's SIGPIPE status under
  # some bats/awk combinations (the exit-code pipe-masking class).
  run bash -c "awk '/^### Step 4 -- Plan Implementation/{f=1} /^### Step 5 -- TDD Red/{f=0} f' \"$SKILL_MD\" | grep -EiC0 'developer subagent.*author|authored by the resolved .*-dev developer|dispatch the .*-dev developer subagent .*to author'"
  [ "$status" -eq 0 ]
}

@test "Step 4 explicitly says the orchestrator does NOT author the plan inline" {
  run bash -c "awk '/^### Step 4 -- Plan Implementation/{f=1} /^### Step 5 -- TDD Red/{f=0} f' \"$SKILL_MD\" | grep -EiC0 'orchestrator does NOT author|NOT by the main-turn orchestrator'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3 — TDD bodies authored by the developer
# ---------------------------------------------------------------------------

@test "Step 5 (Red) tests are written by the developer subagent" {
  run bash -c "awk '/^### Step 5 -- TDD Red/{f=1} /^### Step 5a/{f=0} f' \"$SKILL_MD\" | grep -EiC0 'written by the resolved .*-dev developer subagent|developer writes failing test'"
  [ "$status" -eq 0 ]
}

@test "Step 6 (Green) implementation is written by the developer subagent" {
  run bash -c "awk '/^### Step 6 -- TDD Green/{f=1} /^### Step 6a/{f=0} f' \"$SKILL_MD\" | grep -EiC0 'written by the resolved .*-dev developer subagent|developer implements the minimum code'"
  [ "$status" -eq 0 ]
}

@test "Step 7 (Refactor) is performed by the developer subagent" {
  run bash -c "awk '/^### Step 7 -- TDD Refactor/{f=1} /^### Step 7a/{f=0} f' \"$SKILL_MD\" | grep -EiC0 'performed by the resolved .*-dev developer subagent|developer improves code quality'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4 — Auto-fix loops route to the developer (no inline code-writing remains)
# ---------------------------------------------------------------------------

@test "no auto-fix loop still claims inline Edit/Write code-writing with no subagent spawn" {
  # The legacy phrase that authored code inline in the orchestrator must be
  # gone from the auto-fix loop bodies.
  run grep -nE 'apply_fixes\(critical \+ warning\) +# inline Edit/Write — no subagent spawn' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "Step 7b auto-fix re-dispatches the developer subagent for code fixes" {
  run bash -c "awk '/^### Step 7b/{f=1} /^### Step 8/{f=0} f' \"$SKILL_MD\" | grep -EiC0 'dispatch_developer|re-dispatching the .*-dev developer subagent'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5 — Orchestrator-owned gates preserved (regression guard)
# ---------------------------------------------------------------------------

@test "tdd-reviewer review gates are preserved (reviewer subagent still dispatched)" {
  run grep -c 'tdd-reviewer' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]   # one per TDD phase gate (red/green/refactor) at minimum
}

@test "Val plan-validation gate is preserved (main-turn Agent dispatch)" {
  grep -q 'gaia-val-validate' "$SKILL_MD"
  grep -q 'assert_agent_envelope' "$SKILL_MD"
}

@test "developer dispatch is single-level (no nested subagent spawn inside loops)" {
  grep -qiE 'single-level|one level of subagent nesting|ONE level of subagent nesting' "$SKILL_MD"
}
