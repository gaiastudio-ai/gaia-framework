#!/usr/bin/env bats
# e102-s1-adr-119-artifact-subdirectory-grouping.bats
#
# Story: E102-S1 — ADR-119 artifact subdirectory grouping convention +
#   three-tier idiom contract.
# Origin: AF-2026-05-24-2.
# Traces to: FR-531, ADR-119, TC-ASG-1.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  # Project-root-evidence fixture; skip outside the project-root workspace.
  if [ ! -d "$REPO_ROOT/.gaia/artifacts/planning-artifacts/architecture" ]; then
    skip "project-root .gaia/ not present — skipping story-evidence fixture"
  fi
  ARCH_DIR="$REPO_ROOT/.gaia/artifacts/planning-artifacts/architecture"
  ADR_FILE=""
  if [ -d "$ARCH_DIR" ]; then
    for candidate in "$ARCH_DIR"/*-adr-119-artifact-subdirectory-grouping.md; do
      if [ -f "$candidate" ]; then
        ADR_FILE="$candidate"
        break
      fi
    done
  fi
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-ASG-1a — ADR shard exists
# ---------------------------------------------------------------------------

@test "shard exists under planning-artifacts/architecture/" {
  [ -n "$ADR_FILE" ]
  [ -f "$ADR_FILE" ]
}

# ---------------------------------------------------------------------------
# TC-ASG-1b — All 4 canonical nested paths present verbatim
# ---------------------------------------------------------------------------

@test "ADR names all four canonical nested paths verbatim" {
  [ -n "$ADR_FILE" ]
  grep -qF ".gaia/artifacts/planning-artifacts/adversarial/adversarial-review-" "$ADR_FILE"
  grep -qF ".gaia/artifacts/implementation-artifacts/sprint-plan/" "$ADR_FILE"
  grep -qF ".gaia/artifacts/implementation-artifacts/sprint-review/sprint-review-" "$ADR_FILE"
  grep -qF ".gaia/artifacts/implementation-artifacts/retrospective/retrospective-" "$ADR_FILE"
}

# ---------------------------------------------------------------------------
# TC-ASG-1c — Three-Tier Idiom section present with 3 numbered tiers
# ---------------------------------------------------------------------------

@test "ADR Three-Tier Idiom section has three numbered tiers" {
  [ -n "$ADR_FILE" ]
  grep -qE "^## Three-Tier" "$ADR_FILE"
  tier_count="$(awk '
    /^## Three-Tier/ {capture=1; next}
    capture && /^## / {capture=0}
    capture && /^[[:space:]]*[1-3]\./ {print}
  ' "$ADR_FILE" | wc -l | tr -d " ")"
  [ "$tier_count" -ge 3 ]
}

# ---------------------------------------------------------------------------
# TC-ASG-1d — /gaia-sprint-close retro backward-compat requirement
# ---------------------------------------------------------------------------

@test "ADR names /gaia-sprint-close retro backward-compat requirement" {
  [ -n "$ADR_FILE" ]
  grep -qF "/gaia-sprint-close" "$ADR_FILE"
  grep -qiE "retro|retrospective" "$ADR_FILE"
  grep -qE "BOTH|both legacy" "$ADR_FILE"
}

# ---------------------------------------------------------------------------
# TC-ASG-1e — Out of Scope names all four broader families
# ---------------------------------------------------------------------------

@test "ADR Out of Scope names code-review/qa-tests/test-review/performance-review" {
  [ -n "$ADR_FILE" ]
  grep -qF "code-review" "$ADR_FILE"
  grep -qF "qa-tests" "$ADR_FILE"
  grep -qF "test-review" "$ADR_FILE"
  grep -qF "performance-review" "$ADR_FILE"
}

# ---------------------------------------------------------------------------
# TC-ASG-1f — Related section cross-references ADR-111, ADR-070, AF-2026-05-24-2
# ---------------------------------------------------------------------------

@test "ADR Related section cross-references" {
  [ -n "$ADR_FILE" ]
  grep -q "ADR-111" "$ADR_FILE"
  grep -q "ADR-070" "$ADR_FILE"
  grep -q "AF-2026-05-24-2" "$ADR_FILE"
}
