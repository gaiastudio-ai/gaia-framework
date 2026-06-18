#!/usr/bin/env bats
# gaia-deploy-post.bats — post-deploy verification skill structural tests
#
# Validates:
#   - SKILL.md exists with health check validation, endpoint reachability, error rate thresholds
#   - setup.sh/finalize.sh follow shared deployment skill pattern
#   - Health check logic uses inline !scripts/*.sh calls
#   - Output format includes structured pass/fail report
#   - Unreachable endpoint handling
#   - setup.sh missing or not executable detection
#   - Error rate threshold boundary behavior documented
#   - No orphaned engine-specific XML tags
#
# Usage:
#   bats tests/skills/gaia-deploy-post.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  SKILL_DIR="$SKILLS_DIR/gaia-deploy-post"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
}

# ---------- SKILL.md exists with valid frontmatter and health check content ----------

@test "SKILL.md exists at gaia-deploy-post skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "SKILL.md frontmatter contains name: gaia-deploy-post" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^name: gaia-deploy-post"
}

@test "SKILL.md frontmatter contains description field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^description:"
}

@test "SKILL.md frontmatter contains allowed-tools field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^allowed-tools:"
}

@test "SKILL.md covers health endpoint verification" {
  grep -qi "health.*endpoint\|endpoint.*health\|health.*check" "$SKILL_FILE"
}

@test "SKILL.md covers error rate validation" {
  grep -qi "error.*rate\|error_rate" "$SKILL_FILE"
}

@test "SKILL.md covers latency metrics" {
  grep -qi "latency\|p50\|p95\|p99" "$SKILL_FILE"
}

@test "SKILL.md covers service connectivity checks" {
  grep -qi "connectivity\|database\|cache\|queue\|external.*api" "$SKILL_FILE"
}

@test "SKILL.md covers smoke tests" {
  grep -qi "smoke.*test" "$SKILL_FILE"
}

@test "SKILL.md covers metric validation" {
  grep -qi "metric.*valid\|valid.*metric\|slo" "$SKILL_FILE"
}

@test "SKILL.md covers canary analysis" {
  grep -qi "canary" "$SKILL_FILE"
}

@test "SKILL.md generates a structured pass/fail report" {
  grep -qi "pass.*fail\|report\|deployment.*status" "$SKILL_FILE"
}

# ---------- Shared setup.sh/finalize.sh pattern ----------

@test "setup.sh exists and is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "finalize.sh exists and is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}

@test "setup.sh calls resolve-config.sh" {
  grep -q "resolve-config.sh" "$SETUP_SCRIPT"
}

@test "setup.sh references validate-gate or checkpoint" {
  grep -q "validate-gate\|checkpoint" "$SETUP_SCRIPT"
}

@test "setup.sh loads checkpoint" {
  grep -q "checkpoint" "$SETUP_SCRIPT"
}

@test "finalize.sh writes checkpoint" {
  grep -q "checkpoint" "$FINALIZE_SCRIPT"
}

@test "finalize.sh emits lifecycle event" {
  grep -q "lifecycle-event" "$FINALIZE_SCRIPT"
}

@test "SKILL.md invokes setup.sh at entry" {
  grep -q '!.*setup\.sh' "$SKILL_FILE"
}

@test "SKILL.md invokes finalize.sh at exit" {
  grep -q '!.*finalize\.sh' "$SKILL_FILE"
}

# ---------- Health check logic uses inline script calls ----------

@test "SKILL.md references inline script calls for deterministic operations" {
  grep -qi 'scripts/\|!.*\.sh' "$SKILL_FILE"
}

@test "SKILL.md references deterministic script delegation" {
  grep -qi "deterministic" "$SKILL_FILE"
}

# ---------- Output format includes structured report ----------

@test "SKILL.md produces post-deployment report artifact" {
  grep -qi "post-deploy\|report\|artifact" "$SKILL_FILE"
}

@test "SKILL.md includes health check results in output" {
  grep -qi "health.*check.*result\|result.*health" "$SKILL_FILE"
}

# ---------- Unreachable endpoint handling ----------

@test "SKILL.md handles unreachable endpoints" {
  grep -qi "unreachable\|timeout\|connection.*fail\|dns.*fail\|endpoint.*fail" "$SKILL_FILE"
}

@test "SKILL.md provides remediation guidance for failures" {
  grep -qi "remediation\|guidance\|suggest\|action" "$SKILL_FILE"
}

# ---------- setup.sh missing or not executable ----------

@test "SKILL.md or setup.sh checks script existence" {
  grep -qi "not found\|not executable\|missing.*script\|script.*missing" "$SKILL_FILE" || \
  grep -qi "not found\|not executable" "$SETUP_SCRIPT"
}

# ---------- Error rate threshold boundary behavior ----------

@test "SKILL.md documents threshold boundary behavior" {
  grep -qi "threshold\|boundary\|<=\|>=\|exact" "$SKILL_FILE"
}

# ---------- No orphaned engine-specific XML tags ----------

@test "SKILL.md contains no orphaned action tags" {
  ! grep -q '<action>' "$SKILL_FILE"
}

@test "SKILL.md contains no orphaned template-output tags" {
  ! grep -q '<template-output>' "$SKILL_FILE"
}

@test "SKILL.md contains no orphaned invoke-workflow tags" {
  ! grep -q '<invoke-workflow>' "$SKILL_FILE"
}

@test "SKILL.md contains no orphaned step tags" {
  ! grep -q '<step ' "$SKILL_FILE"
}

@test "SKILL.md contains no orphaned check tags" {
  ! grep -q '<check ' "$SKILL_FILE"
}

@test "SKILL.md contains no orphaned mandate tags" {
  ! grep -q '<mandate>' "$SKILL_FILE"
}

@test "SKILL.md contains no orphaned critical tags" {
  ! grep -q '<critical>' "$SKILL_FILE"
}

# ---------- No shared mutable state ----------

@test "setup.sh uses safe shell defaults" {
  grep -q "set -euo pipefail" "$SETUP_SCRIPT"
}

@test "finalize.sh uses safe shell defaults" {
  grep -q "set -euo pipefail" "$FINALIZE_SCRIPT"
}
