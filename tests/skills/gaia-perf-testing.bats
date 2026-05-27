#!/usr/bin/env bats
# gaia-perf-testing.bats — performance-testing skill structural tests (E28-S88)
#
# Validates:
#   AC4: SKILL.md exists with valid YAML frontmatter and performance testing content
#   AC5: setup.sh/finalize.sh follow shared pattern
#   AC6: Bats-core structural verification
#
# Usage:
#   bats tests/skills/gaia-perf-testing.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  SKILL_DIR="$SKILLS_DIR/gaia-perf-testing"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
}

# ---------- AC4: SKILL.md exists with valid frontmatter ----------

@test "AC4: SKILL.md exists at gaia-perf-testing skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "AC4: SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "AC4: SKILL.md frontmatter contains name: gaia-perf-testing" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^name: gaia-perf-testing"
}

@test "AC4: SKILL.md frontmatter contains description field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^description:"
}

@test "AC4: SKILL.md body contains load testing section" {
  grep -qi "load.*test\|k6\|virtual.*user\|ramp.*up" "$SKILL_FILE"
}

@test "AC4: SKILL.md body contains Core Web Vitals section" {
  grep -qi "core.*web.*vital\|LCP\|INP\|CLS\|lighthouse" "$SKILL_FILE"
}

@test "AC4: SKILL.md body contains performance budget section" {
  grep -qi "performance.*budget\|response.*time.*target\|P50\|P95\|P99" "$SKILL_FILE"
}

@test "AC4: SKILL.md body contains CI gates section" {
  grep -qi "ci.*gate\|ci.*pipeline\|ci.*integration\|lighthouse.*score.*threshold" "$SKILL_FILE"
}

@test "AC4: SKILL.md body contains backend profiling section" {
  grep -qi "backend.*profil\|slow.*quer\|memory.*leak\|connection.*pool" "$SKILL_FILE"
}

@test "AC4: SKILL.md references performance test plan output" {
  grep -q "performance-test-plan\|test-artifacts" "$SKILL_FILE"
}

# ---------- AC5: Shared setup.sh/finalize.sh pattern ----------

@test "AC5: setup.sh exists and is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "AC5: finalize.sh exists and is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}

@test "AC5: setup.sh calls resolve-config.sh" {
  grep -q "resolve-config.sh" "$SETUP_SCRIPT"
}

@test "AC5: setup.sh calls validate-gate.sh" {
  grep -q "validate-gate.sh" "$SETUP_SCRIPT"
}

@test "AC5: setup.sh loads checkpoint" {
  grep -q "checkpoint" "$SETUP_SCRIPT"
}

@test "AC5: finalize.sh writes checkpoint" {
  grep -q "checkpoint" "$FINALIZE_SCRIPT"
}

@test "AC5: finalize.sh emits lifecycle event" {
  grep -q "lifecycle-event" "$FINALIZE_SCRIPT"
}

@test "AC5: SKILL.md invokes setup.sh at entry" {
  grep -q '!.*setup\.sh' "$SKILL_FILE"
}

@test "AC5: SKILL.md invokes finalize.sh at exit" {
  grep -q '!.*finalize\.sh' "$SKILL_FILE"
}

# ---------- AC6: Output format verification ----------

@test "AC6: SKILL.md references output to docs/test-artifacts/" {
  grep -q "planning-artifacts/performance-test-plan\|test-artifacts/\|docs/test-artifacts" "$SKILL_FILE"  # E105-S3 / ADR-127 Pillar 3: performance-test-plan grouped under planning-artifacts/ (legacy test-artifacts/ read-only)
}

# ---------- Knowledge bundling (NFR-048) ----------

@test "NFR-048: knowledge directory contains k6-patterns.md" {
  [ -f "$SKILL_DIR/knowledge/k6-patterns.md" ]
}

@test "NFR-048: knowledge directory contains lighthouse-ci.md" {
  [ -f "$SKILL_DIR/knowledge/lighthouse-ci.md" ]
}
