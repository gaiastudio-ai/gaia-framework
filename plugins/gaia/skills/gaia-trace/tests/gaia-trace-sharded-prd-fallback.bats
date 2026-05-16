#!/usr/bin/env bats
# gaia-trace-sharded-prd-fallback.bats — AF-2026-05-16-2 regression guard
#
# Asserts that the gaia-trace SKILL.md describes the sharded-PRD fallback
# rule, so the skill body resolves PRD location as: flat
# docs/planning-artifacts/prd.md → sharded docs/planning-artifacts/prd/prd.md
# → HALT only if NEITHER exists.
#
# Bug: pre-patch, the skill HALTed unconditionally on missing flat prd.md,
# making /gaia-trace non-functional on projects using the sharded PRD
# layout (ADR-069 / FR-396..402). Fix patches Critical Rules + Step 1
# Load Requirements to perform a flat-then-shard probe.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_MD="$REPO_ROOT/plugins/gaia/skills/gaia-trace/SKILL.md"
  export LC_ALL=C
}

@test "SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "Critical Rules describe the sharded-fallback resolution order" {
  run grep -c 'docs/planning-artifacts/prd/prd.md' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "HALT message names BOTH flat and sharded paths" {
  run grep -E 'HALT.*prd.md.*prd/prd.md|prd.md or .*prd/prd.md' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "Step 1 Load Requirements references sharded-fallback rule" {
  awk '/^### Step 1 -- Load Requirements/{flag=1;next} /^### Step 2/{flag=0} flag' "$SKILL_MD" > /tmp/gaia-trace-step1.txt
  run grep -E 'sharded-fallback|prd/prd.md' /tmp/gaia-trace-step1.txt
  [ "$status" -eq 0 ]
}

@test "no surviving unconditional HALT on flat-only prd.md" {
  # The pre-patch sentinel: a HALT line that mentions only docs/planning-artifacts/prd.md
  # without also mentioning the sharded path on the same line.
  run grep -nE 'HALT.*"PRD not found at docs/planning-artifacts/prd.md\."' "$SKILL_MD"
  [ "$status" -ne 0 ]
}
