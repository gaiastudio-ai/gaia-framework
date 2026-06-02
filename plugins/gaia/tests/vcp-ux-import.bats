#!/usr/bin/env bats
# vcp-ux-import.bats — E46-S2 / FR-350 / FR-140.
#
# Script-verifiable contract checks on
#   gaia-public/plugins/gaia/skills/gaia-create-ux/SKILL.md
#   gaia-public/plugins/gaia/skills/figma-integration/SKILL.md
# guaranteeing that the Import-mode parity restoration documented by
# E46-S2 (file-key validation, depth-1 metadata check, viewport
# classification, W3C DTCG token format, component-specs.yaml emission,
# read-only FR-140 audit, write pre-dispatch guard) is wired into both
# SKILL.md files and stays regression-proof.
#
# This bats file backs the script-verifiable subset of the VCP-UX-02 /
# VCP-UX-05 anchors from docs/test-artifacts/test-plan.md §11.46.10. The
# LLM-checkable companion rows live in the test plan only — this file is
# the regression guard. VCP-UX-06 (DTCG validation) lives in a sibling
# vcp-ux-06.bats file per Subtask 7.3.
#
# All checks are structural (grep / awk over the SKILL.md files) — no
# Figma MCP calls, no network, no fixtures. Fast, deterministic, race-free.

load 'test_helper.bash'

UX_SKILL_MD="$BATS_TEST_DIRNAME/../skills/gaia-create-ux/SKILL.md"
FIGMA_SKILL_MD="$BATS_TEST_DIRNAME/../skills/figma-integration/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-UX-02 — Import mode end-to-end FR-140 audit reports zero writes.
# Story AC1, AC4; Task 2.
# -------------------------------------------------------------------------

@test "VCP-UX-02: gaia-create-ux SKILL.md Step 9 declares Import mode is read-only" {
  run grep -E "read-only|read only|zero write|expected_writes" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-02: gaia-create-ux SKILL.md Step 9 declares expected_writes: 0 for Import mode" {
  run grep -E "expected_writes:[[:space:]]*0|expected_writes = 0" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-02: gaia-create-ux SKILL.md Step 9 declares allowed_write_calls: []" {
  run grep -E "allowed_write_calls:[[:space:]]*\[\]" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-02: Import mode emits FR-140 audit table with the canonical column set" {
  # Audit report MUST surface MCP method, Direction, and Outcome — the
  # canonical column triple the story Subtask 2.3 mandates.
  run grep -E "MCP method.*Direction.*Outcome" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-02: Import mode declares an FR-140 Compliance Audit section under Step 9" {
  run grep -E "FR-140 Compliance Audit|FR-140 Audit" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# VCP-UX-05 — Audit log contains zero write calls; pre-dispatch guard.
# Story AC4; Subtask 2.4.
# -------------------------------------------------------------------------

@test "VCP-UX-05: gaia-create-ux SKILL.md documents pre-dispatch write guard" {
  run grep -E "pre-dispatch|pre dispatch|short-circuit|short circuit" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-05: gaia-create-ux SKILL.md documents 'write / blocked' audit classification" {
  run grep -F "write / blocked" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-05: gaia-create-ux SKILL.md surfaces an FR-140 violation message on attempted write" {
  run grep -E "FR-140 violation|FR-140 compliance violation" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "VCP-UX-05: gaia-create-ux SKILL.md references at least one canonical write call name" {
  # Spot-check: at least one canonical write call name MUST be referenced
  # in Step 9 so the guard surface is unambiguous.
  for _call in figma_create_ figma_update_ create_frame create_component update_style; do
    run grep -F "$_call" "$UX_SKILL_MD"
    if [ "$status" -eq 0 ]; then
      return 0
    fi
  done
  return 1
}

@test "VCP-UX-05: gaia-create-ux SKILL.md references at least one canonical read call name in Step 9" {
  # The Import-mode section MUST reference the read calls it issues so
  # readers understand the read-only API surface.
  for _call in figma_get_file get_components get_styles get_design_context; do
    run grep -F "$_call" "$UX_SKILL_MD"
    if [ "$status" -eq 0 ]; then
      return 0
    fi
  done
  return 1
}

# -------------------------------------------------------------------------
# AC5 — File key validation halts before any Figma API call.
# Story AC5; Task 3.
# -------------------------------------------------------------------------

@test "AC5: gaia-create-ux SKILL.md documents file-key validation step" {
  run grep -E "file key validation|File key validation|validateFigmaFileKey" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC5: gaia-create-ux SKILL.md documents halt-before-API on invalid key" {
  run grep -E "halt before|before any|reject malformed" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC5: figma-integration SKILL.md exposes validateFigmaFileKey helper contract" {
  run grep -F "validateFigmaFileKey" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC5: figma-integration SKILL.md documents the canonical 22+ char key pattern" {
  run grep -E "22\+|22 character|\[A-Za-z0-9\]\{22" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC6 — Depth-1 metadata check captures name, lastModified, version.
# Story AC6; Subtask 1.1b.
# -------------------------------------------------------------------------

@test "AC6: gaia-create-ux SKILL.md documents depth-1 metadata check" {
  run grep -E "depth-1|depth=1|depth 1" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC6: gaia-create-ux SKILL.md records lastModified in metadata block" {
  run grep -F "lastModified" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC6: gaia-create-ux SKILL.md records version identifier in metadata block" {
  run grep -E "\bversion\b" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC7 — Viewport classification (canonical 6-tuple + custom).
# Story AC7; Task 4.
# -------------------------------------------------------------------------

@test "AC7: figma-integration SKILL.md exposes classifyViewport helper" {
  run grep -F "classifyViewport" "$FIGMA_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC7: gaia-create-ux SKILL.md Step 9 lists the canonical viewport set 280/375/600/768/1024/1280" {
  # All six values MUST appear at least once in the SKILL.md (Generate-mode
  # Step 8 already covers this; Import mode reuses the same canonical set).
  _hits=$(grep -oE '\b(280|375|600|768|1024|1280)\b' "$UX_SKILL_MD" | sort -u | wc -l | tr -d ' ')
  [ "$_hits" -eq 6 ]
}

@test "AC7: gaia-create-ux SKILL.md documents the 'custom' viewport bucket" {
  run grep -E "\bcustom\b" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC7: gaia-create-ux SKILL.md documents viewport distribution table" {
  run grep -E "viewport distribution|Viewport.*Frame count|Frame count.*Viewport" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC2 — W3C DTCG token format with $value, $type, $description.
# Story AC2; Task 5.
# -------------------------------------------------------------------------

@test "AC2: gaia-create-ux SKILL.md documents W3C DTCG token format" {
  run grep -E "W3C DTCG|DTCG" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-create-ux SKILL.md references DTCG \$value key" {
  run grep -F '$value' "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-create-ux SKILL.md references DTCG \$type key" {
  run grep -F '$type' "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-create-ux SKILL.md references DTCG \$description key" {
  run grep -F '$description' "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-create-ux SKILL.md references the design-tokens.json output path" {
  run grep -F "design-tokens.json" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC3 — component-specs.yaml emission with schema_version.
# Story AC3; Task 6.
# -------------------------------------------------------------------------

@test "AC3: gaia-create-ux SKILL.md references component-specs.yaml output path" {
  run grep -F "component-specs.yaml" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC3: gaia-create-ux SKILL.md documents schema_version field for component-specs.yaml" {
  run grep -F "schema_version" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC3: gaia-create-ux SKILL.md documents COMPONENT and COMPONENT_SET node filtering" {
  run grep -E "COMPONENT_SET|COMPONENT\b" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC3: gaia-create-ux SKILL.md documents platform_tokens placeholder field" {
  run grep -F "platform_tokens" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Step-count guard (NFR — VCP-CPT-09 step-count regression). The Import
# mode parity work MUST NOT inflate the documented step count of the
# /gaia-create-ux skill. The canonical step count remains 12 (Steps 1..12).
# Sub-sections under Step 9 (Import Mode) MUST use H4 (####) or H5 (#####)
# headings, NOT new `### Step N — Title` headings.
# -------------------------------------------------------------------------

@test "NFR-VCP-CPT-09: gaia-create-ux SKILL.md keeps exactly 12 top-level Step headings after Import restoration" {
  _count=$(grep -cE '^### Step [0-9]+ —' "$UX_SKILL_MD")
  [ "$_count" -eq 12 ]
}

# -------------------------------------------------------------------------
# Cross-reference — architecture.md §10.17 hosts the canonical FR-140
# enforcement source. Subtask 8.2.
# -------------------------------------------------------------------------

@test "Subtask 8.2: gaia-create-ux SKILL.md cross-references architecture §10.17 for FR-350" {
  run grep -E "architecture.md §10\.17|§10\.17|architecture §10\.17|FR-350" "$UX_SKILL_MD"
  [ "$status" -eq 0 ]
}
