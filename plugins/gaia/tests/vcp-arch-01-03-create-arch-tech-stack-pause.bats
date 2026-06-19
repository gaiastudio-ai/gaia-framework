#!/usr/bin/env bats
# vcp-arch-01-03-create-arch-tech-stack-pause.bats — E46-S6 / FR-354.
#
# Script-verifiable contract checks on
# gaia-public/plugins/gaia/skills/gaia-create-arch/SKILL.md guaranteeing
# that the two load-bearing parity behaviors restored by E46-S6 are
# present in the SKILL.md prose:
#
#   1. Tech-Stack Confirmation Pause inserted as Step 3.5 between the
#      existing Step 3 and Step 4. (AC1, AC2, AC4)
#   2. ADR sidecar write to _memory/architect-sidecar/architecture-decisions.md
#      wired into the finalize step. (AC3, AC5)
#
# These checks are deliberately prose-anchor based: VCP-ARCH-01 and
# VCP-ARCH-02 are LLM-checkable end-to-end, and VCP-ARCH-03 is an
# Integration test that requires a live Claude Code session. What CI
# CAN witness is the SKILL.md contract itself — and a regression that
# silently drops the pause or the sidecar wiring MUST fail at least
# one of these anchors.
#
# Companion fixture project lives at
# tests/fixtures/create-arch-tech-stack-pause/ for the LLM-checkable
# and Integration runs.

load 'test_helper.bash'

SKILL_MD="$BATS_TEST_DIRNAME/../skills/gaia-create-arch/SKILL.md"
FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/create-arch-tech-stack-pause"

setup() { common_setup; }
teardown() { common_teardown; }

# -------------------------------------------------------------------------
# AC1 — Tech-Stack Confirmation Pause inserted as Step 3.5.
# Step numbers 4..N MUST remain stable (Dev Notes invariant).
# -------------------------------------------------------------------------

@test "SKILL.md declares Step 3.5 — Tech-Stack Confirmation Pause" {
  run grep -E "^### Step 3\.5 — Tech-Stack Confirmation Pause" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md preserves stable Step 4 numbering (no renumber)" {
  run grep -E "^### Step 4 — System Architecture" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "Step 3.5 emits the [a]ccept / [m]odify / [r]eject prompt verbatim" {
  run grep -F "[a]ccept / [m]odify / [r]eject" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "Step 3.5 documents the YOLO auto-accept audit-log concession" {
  run grep -F "YOLO auto-accepted tech stack" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC2 — confirmed_tech_stack contract — Steps 4+ read the confirmed stack
# variable, NOT the original Theo response object.
# -------------------------------------------------------------------------

@test "SKILL.md introduces the confirmed_tech_stack runtime variable" {
  run grep -F "confirmed_tech_stack" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md documents the [r]eject branch (re-invoke or abort)" {
  run grep -F "aborted at tech-stack confirmation" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC3 + AC5 — ADR sidecar write wired into the finalize step with
# append-only semantics and non-blocking failure policy.
# -------------------------------------------------------------------------

@test "SKILL.md wires the sidecar path .gaia/memory/architect-sidecar/architecture-decisions.md" {
  # AF-2026-05-22-4 canonicalized the sidecar path. Accept canonical or legacy.
  grep -qE '(_memory|\.gaia/memory)/architect-sidecar/architecture-decisions\.md' "$SKILL_MD"
}

@test "SKILL.md documents append-only sidecar contract" {
  run grep -Ei "append-only" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md documents non-blocking sidecar write failure policy" {
  run grep -F "ADR sidecar write failed" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md mandates write-order — architecture.md before sidecar" {
  # The sidecar action must be described as running AFTER the
  # architecture document write succeeds (Subtask 3.1).
  run grep -Ei "AFTER the architecture" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Fixture presence — drives VCP-ARCH-01/02 (LLM-checkable) and
# VCP-ARCH-03 (Integration) in a local Claude Code session.
# -------------------------------------------------------------------------

@test "fixture: create-arch-tech-stack-pause/README.md documents fixture contents" {
  [ -f "$FIXTURE_DIR/README.md" ]
}

@test "fixture: create-arch-tech-stack-pause/prd.md is the minimal Step-3-reachable PRD" {
  [ -f "$FIXTURE_DIR/prd.md" ]
  run grep -F "Review Findings Incorporated" "$FIXTURE_DIR/prd.md"
  [ "$status" -eq 0 ]
}
