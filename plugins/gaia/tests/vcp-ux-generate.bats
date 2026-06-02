#!/usr/bin/env bats
# vcp-ux-generate.bats — E46-S1 / FR-350 / FR-140.
#
# Script-verifiable contract checks on
#   gaia-public/plugins/gaia/skills/gaia-create-ux/SKILL.md
#   gaia-public/plugins/gaia/skills/figma-integration/SKILL.md
# guaranteeing that the Generate-mode parity restoration documented by
# E46-S1 (6 viewports, 6 state variants, 429 backoff schedule, prototype
# flows, asset export catalogs, FR-140 compliance audit) is wired into
# both SKILL.md files and stays regression-proof.
#
# This bats file backs the script-verifiable subset of the VCP-UX-01 /
# VCP-UX-03 / VCP-UX-04 / VCP-UX-07 / VCP-UX-08 anchors from
# docs/test-artifacts/test-plan.md §11.46.10. The LLM-checkable companion
# rows live in the test plan only — this file is the regression guard.
#
# All checks are structural (grep / awk over the SKILL.md files) — no
# Figma MCP calls, no network, no fixtures. Fast, deterministic, race-free.

load 'test_helper.bash'

UX_SKILL_MD="$BATS_TEST_DIRNAME/../skills/gaia-create-ux/SKILL.md"
FIGMA_SKILL_MD="$BATS_TEST_DIRNAME/../skills/figma-integration/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-UX-03 — All 6 canonical viewports listed in Generate-mode section.
# Story AC2; Subtask 1.1.
# -------------------------------------------------------------------------

@test "VCP-UX-03: gaia-create-ux SKILL.md lists 280px viewport" {
  run grep -F "280px" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-03: gaia-create-ux SKILL.md lists 375px viewport" {
  run grep -F "375px" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-03: gaia-create-ux SKILL.md lists 600px viewport" {
  run grep -F "600px" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-03: gaia-create-ux SKILL.md lists 768px viewport" {
  run grep -F "768px" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-03: gaia-create-ux SKILL.md lists 1024px viewport" {
  run grep -F "1024px" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-03: gaia-create-ux SKILL.md lists 1280px viewport" {
  run grep -F "1280px" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-03: viewport list canonicalized as a 6-tuple" {
  # All six values must appear at least once. Distinct count = 6.
  _hits=$(grep -oE '\b(280|375|600|768|1024|1280)px' "$UX_SKILL_MD" | sort -u | wc -l | tr -d ' ')
  [ "$_hits" -eq 6 ]
}

# -------------------------------------------------------------------------
# VCP-UX-08 — All 6 canonical component state variants documented.
# Story AC3; Subtask 1.2.
# -------------------------------------------------------------------------

@test "VCP-UX-08: gaia-create-ux SKILL.md documents default state variant" {
  run grep -E "\b(default)\b" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-08: gaia-create-ux SKILL.md documents hover state variant" {
  run grep -F "hover" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-08: gaia-create-ux SKILL.md documents active state variant" {
  run grep -F "active" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-08: gaia-create-ux SKILL.md documents disabled state variant" {
  run grep -F "disabled" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-08: gaia-create-ux SKILL.md documents error state variant" {
  run grep -F "error" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-08: gaia-create-ux SKILL.md documents loading state variant" {
  run grep -F "loading" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-08: state variant list canonicalized as a 6-tuple" {
  # The canonical list MUST appear contiguously (e.g.,
  # `default, hover, active, disabled, error, loading`) so the variant
  # enumeration is unambiguous.
  run grep -E "default.*hover.*active.*disabled.*error.*loading" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# VCP-UX-04 — 429 rate-limit handling: exponential backoff schedule
# 1s, 2s, 4s, 8s, 16s — capped at 30s, max 5 retries.
# Story AC4; Subtask 2.1, 2.2, 2.3.
# -------------------------------------------------------------------------

@test "VCP-UX-04: figma-integration SKILL.md documents the backoff schedule (1s/2s/4s/8s/16s)" {
  run grep -E "1s.*2s.*4s.*8s.*16s" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-04: figma-integration SKILL.md documents the 30s backoff cap" {
  run grep -F "30s" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-04: figma-integration SKILL.md documents the 5-retry maximum" {
  run grep -E "max 5 retries|5 retries|retries: 5" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-04: figma-integration SKILL.md documents the 429 trigger" {
  run grep -F "429" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-04: figma-integration SKILL.md documents rate_limit_exhausted error surface" {
  run grep -F "rate_limit_exhausted" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# VCP-UX-01 — FR-140 compliance audit step in Generate mode.
# Story AC1; Subtask 3.1, 3.2, 3.3, 3.4.
# -------------------------------------------------------------------------

@test "VCP-UX-01: gaia-create-ux SKILL.md declares an FR-140 Compliance Audit section" {
  run grep -E "FR-140 Compliance Audit|FR-140 Audit" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-01: gaia-create-ux SKILL.md references the audit.json artifact" {
  run grep -F "audit.json" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-01: gaia-create-ux SKILL.md references fr_140_compliance status field" {
  run grep -F "fr_140_compliance" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-01: gaia-create-ux SKILL.md enumerates the three audit outcomes" {
  # pass | fail | incomplete — all three must appear in the SKILL.md so
  # the audit logic surface is unambiguous.
  run grep -E "pass.*fail.*incomplete|pass \\| fail \\| incomplete" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-01: figma-integration SKILL.md hosts the read/write classification table" {
  # The classification table is shared by E46-S2 (Import mode), so it
  # MUST live in figma-integration/SKILL.md (Subtask 3.2 / 6.1) — not in
  # the Generate-mode-specific create-ux SKILL.md.
  run grep -E "read/write|Read/Write|read or write" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-01: figma-integration SKILL.md classification table references the canonical MCP read calls" {
  # Spot-check: at least three canonical read calls appear in the table.
  for _call in get_file get_components get_styles; do
    run grep -F "$_call" "$FIGMA_SKILL_MD"
    [ "$status" -eq 0 ]
  done
}

@test "VCP-UX-01: figma-integration SKILL.md classification table references the canonical MCP write calls" {
  # Spot-check: at least three canonical write calls appear in the table.
  for _call in create_frame create_component export_asset; do
    run grep -F "$_call" "$FIGMA_SKILL_MD"
    [ "$status" -eq 0 ]
  done
}

@test "VCP-UX-01: figma-integration SKILL.md declares fr_140_scope column" {
  # Per Subtask 6.1 — the table must surface the FR-140 scope per call so
  # the audit can reason about generate_only vs always_allowed.
  run grep -F "fr_140_scope" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# VCP-UX-07 — Asset export platform catalogs (iOS .xcassets + Android
# drawable-* density buckets) at 1x/2x/3x.
# Story AC5; Subtask 1.4, 4.1, 4.2, 4.3.
# -------------------------------------------------------------------------

@test "VCP-UX-07: gaia-create-ux SKILL.md documents iOS .xcassets layout" {
  run grep -F ".xcassets" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents iOS imageset structure" {
  run grep -F ".imageset" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents iOS Contents.json" {
  run grep -F "Contents.json" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents Android drawable-mdpi bucket" {
  run grep -F "drawable-mdpi" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents Android drawable-hdpi bucket" {
  run grep -F "drawable-hdpi" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents Android drawable-xhdpi bucket" {
  run grep -F "drawable-xhdpi" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents Android drawable-xxhdpi bucket" {
  run grep -F "drawable-xxhdpi" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents Android drawable-xxxhdpi bucket" {
  run grep -F "drawable-xxxhdpi" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-07: gaia-create-ux SKILL.md documents the 1x/2x/3x asset density set" {
  # The trio (1x, 2x, 3x) MUST appear together in the SKILL.md so the
  # asset export contract is unambiguous.
  run grep -E "1x.*2x.*3x|1x/2x/3x" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC6 — Prototype flow connections between screens.
# Story AC6; Subtask 1.3.
# -------------------------------------------------------------------------

@test "AC6: gaia-create-ux SKILL.md documents prototype_flows section" {
  run grep -F "prototype_flows" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC6: gaia-create-ux SKILL.md documents flow edges between screens" {
  run grep -E "flow edge|prototype flow|flow connection" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Step-count guard (NFR — VCP-CPT-09 step-count regression). The Generate
# mode parity work MUST NOT inflate the documented step count of the
# /gaia-create-ux skill. The canonical step count remains 12 (Steps 1..12).
# Sub-sections under Step 8 (Generate Mode) MUST use H4 (####) or H5
# (#####) headings, NOT new `### Step N — Title` headings.
# -------------------------------------------------------------------------

@test "NFR-VCP-CPT-09: gaia-create-ux SKILL.md keeps exactly 12 top-level Step headings" {
  _count=$(grep -cE '^### Step [0-9]+ —' "$UX_SKILL_MD")
  [ "$_count" -eq 12 ]
}

# -------------------------------------------------------------------------
# Cross-reference — architecture.md §10.17 hosts the canonical FR-140
# enforcement source. Subtask 6.2.
# -------------------------------------------------------------------------

@test "Subtask 6.2: figma-integration SKILL.md cross-references architecture.md §10.17" {
  run grep -E "architecture.md §10\.17|§10\.17|architecture §10\.17" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}
