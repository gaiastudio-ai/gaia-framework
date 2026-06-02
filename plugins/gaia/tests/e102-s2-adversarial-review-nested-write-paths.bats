#!/usr/bin/env bats
# e102-s2-adversarial-review-nested-write-paths.bats
#
# Story: E102-S2 — gaia-create-prd Step 13 + gaia-create-arch Step 12 write
#   adversarial reviews to planning-artifacts/adversarial/ nested subdir.
# Origin: AF-2026-05-24-2.
# Traces to: FR-532, ADR-119, TC-ASG-2.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PRD_SKILL="$PLUGIN/skills/gaia-create-prd/SKILL.md"
  ARCH_SKILL="$PLUGIN/skills/gaia-create-arch/SKILL.md"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-ASG-2a — gaia-create-prd Step 13 references nested path
# ---------------------------------------------------------------------------

@test "TC-ASG-2a: gaia-create-prd/SKILL.md Step 13 writes to nested adversarial dir" {
  [ -f "$PRD_SKILL" ]
  grep -qF "planning-artifacts/adversarial/adversarial-review-prd-" "$PRD_SKILL"
}

# ---------------------------------------------------------------------------
# TC-ASG-2b — gaia-create-arch Step 12 references nested path
# ---------------------------------------------------------------------------

@test "TC-ASG-2b: gaia-create-arch/SKILL.md Step 12 writes to nested adversarial dir" {
  [ -f "$ARCH_SKILL" ]
  grep -qF "planning-artifacts/adversarial/adversarial-review-architecture-" "$ARCH_SKILL"
}

# ---------------------------------------------------------------------------
# TC-ASG-2c — neither file retains a flat adversarial write reference
# ---------------------------------------------------------------------------

@test "TC-ASG-2c: neither SKILL.md retains flat adversarial-review-(prd|architecture)- write path" {
  [ -f "$PRD_SKILL" ]
  [ -f "$ARCH_SKILL" ]
  # Flat path: "planning-artifacts/adversarial-review-(prd|architecture)-" — i.e. NOT followed by "adversarial/"
  ! grep -qE "planning-artifacts/adversarial-review-(prd|architecture)-" "$PRD_SKILL"
  ! grep -qE "planning-artifacts/adversarial-review-(prd|architecture)-" "$ARCH_SKILL"
}

# ---------------------------------------------------------------------------
# TC-ASG-2d — both Step prose blocks mention mkdir -p (or equivalent) guidance
# ---------------------------------------------------------------------------

@test "TC-ASG-2d: both SKILL.md prose blocks include mkdir -p guidance for nested dir" {
  [ -f "$PRD_SKILL" ]
  [ -f "$ARCH_SKILL" ]
  grep -qF "mkdir -p" "$PRD_SKILL"
  grep -qF "mkdir -p" "$ARCH_SKILL"
}
