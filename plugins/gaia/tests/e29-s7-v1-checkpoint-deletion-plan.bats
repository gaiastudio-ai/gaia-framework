#!/usr/bin/env bats
# e29-s7-v1-checkpoint-deletion-plan.bats
#
# E29-S7 — V1 checkpoint deletion plan + sunset window (decision artifact only).
#
# This story is a planning artifact only — no production code ships.
# The bats suite enforces document-presence and structural completeness
# of the deletion plan against a fixture copy shipped under
# tests/fixtures/e29-s7-deletion-plan/. The canonical (living) plan resides
# in the user's project tree at
# docs/planning-artifacts/v1-checkpoint-deletion-plan.md
# (which is outside this marketplace repo per gaia-public/docs/INDEX.md;
# project planning artifacts are not vendored here). When the project-tree
# plan is available — i.e., when this test is run from inside a checked-out
# GAIA-Framework workspace alongside the gaia-public repo — the
# corresponding @tests also assert against the live file.
#
# E29-S7 Acceptance Criteria covered:
#
#   AC1: Plan file exists at docs/planning-artifacts/v1-checkpoint-deletion-plan.md.
#   AC2: Inventory section enumerates V1-shaped checkpoints (schema markers /
#        directory shape) currently on disk.
#   AC3: Recommended sunset window is dated relative to the V1 sunset
#        (ADR-049, 2026-04-20) with a clear cutoff.
#   AC4: Plan distinguishes archive-then-delete vs straight-delete cases
#        with a one-sentence rationale each.
#   AC5: Plan calls out coordination with /gaia-resume (must not crash on
#        a missing legacy checkpoint).
#
# Internal helpers use leading-underscore prefix per NFR-052 allowlist
# convention (textual coverage gate exemption — see e45-s6-bats-budget-watch
# precedent at lines 11-22 of that file).

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

# Fixture (CI-stable, shipped in-tree) — primary test target.
PLAN_FIXTURE="$BATS_TEST_DIRNAME/fixtures/e29-s7-deletion-plan/v1-checkpoint-deletion-plan.md"

# Workspace-only paths — present when the test is run inside a GAIA-Framework
# workspace alongside the gaia-public repo. Resolved by walking up from
# tests/ -> plugins/gaia/ -> plugins/ -> gaia-public/ -> GAIA-Framework/.
WORKSPACE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
WORKSPACE_PLAN="$WORKSPACE_ROOT/docs/planning-artifacts/v1-checkpoint-deletion-plan.md"

# ---------------------------------------------------------------------------
# Internal helpers — leading-underscore prefix per NFR-052 allowlist.
# ---------------------------------------------------------------------------

_grep_section() {
  # Usage: _grep_section <file> <section-header-regex>
  # Returns 0 if a level-2 ATX heading matching the regex is found.
  local file="$1"
  local pattern="$2"
  grep -qE "^## ${pattern}" "$file"
}

_grep_keyword() {
  # Usage: _grep_keyword <file> <keyword-regex>
  # Returns 0 if the keyword appears anywhere in the file.
  local file="$1"
  local pattern="$2"
  grep -qiE "$pattern" "$file"
}

_have_workspace_artifact() {
  # Returns 0 (true) if the workspace-only plan file is present.
  [ -f "$WORKSPACE_PLAN" ]
}

# ---------------------------------------------------------------------------
# AC1 — File presence (fixture-based, CI-stable).
# ---------------------------------------------------------------------------

@test "AC1: deletion plan fixture exists at the canonical path" {
  [ -f "$PLAN_FIXTURE" ]
}

@test "AC1: deletion plan fixture is non-empty" {
  [ -s "$PLAN_FIXTURE" ]
}

@test "AC1: deletion plan frontmatter pins type to deletion-plan" {
  run grep -E "^type: ['\"]deletion-plan['\"]" "$PLAN_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "AC1: deletion plan frontmatter references ADR-049" {
  run grep -E "ADR-049" "$PLAN_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "AC1: deletion plan frontmatter back-references story E29-S7" {
  run grep -E "E29-S7" "$PLAN_FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — Inventory section enumerates V1-shaped checkpoints.
# ---------------------------------------------------------------------------

@test "AC2: plan contains an Inventory section" {
  _grep_section "$PLAN_FIXTURE" "Inventory"
}

@test "AC2: inventory enumerates flat YAML checkpoints" {
  _grep_keyword "$PLAN_FIXTURE" "yaml"
}

@test "AC2: inventory enumerates flat MD checkpoints" {
  _grep_keyword "$PLAN_FIXTURE" "\.md"
}

@test "AC2: inventory enumerates legacy JSON checkpoints" {
  _grep_keyword "$PLAN_FIXTURE" "json"
}

@test "AC2: inventory enumerates the completed/ archive subtree" {
  _grep_keyword "$PLAN_FIXTURE" "completed/"
}

@test "AC2: inventory describes V1 schema markers" {
  _grep_keyword "$PLAN_FIXTURE" "schema marker|workflow:|files_touched"
}

# ---------------------------------------------------------------------------
# AC3 — Recommended sunset window dated relative to V1 sunset (ADR-049).
# ---------------------------------------------------------------------------

@test "AC3: plan declares a Recommended Sunset Window section" {
  _grep_section "$PLAN_FIXTURE" "Recommended Sunset Window"
}

@test "AC3: sunset window references ADR-049 sunset date 2026-04-20" {
  _grep_keyword "$PLAN_FIXTURE" "2026-04-20"
}

@test "AC3: sunset window declares a hard cutoff date" {
  _grep_keyword "$PLAN_FIXTURE" "cutoff"
}

@test "AC3: sunset window includes a soak phase" {
  _grep_keyword "$PLAN_FIXTURE" "soak"
}

# ---------------------------------------------------------------------------
# AC4 — Archive-vs-delete policy with one-sentence rationale per case.
# ---------------------------------------------------------------------------

@test "AC4: plan contains an Archive-vs-Delete Policy section" {
  _grep_section "$PLAN_FIXTURE" "Archive-vs-Delete Policy"
}

@test "AC4: policy enumerates the archive-then-delete case" {
  _grep_keyword "$PLAN_FIXTURE" "archive-then-delete|Archive-then-delete"
}

@test "AC4: policy enumerates the straight-delete case" {
  _grep_keyword "$PLAN_FIXTURE" "straight-delete|Straight-delete"
}

@test "AC4: policy includes a rationale column or paragraph" {
  _grep_keyword "$PLAN_FIXTURE" "rationale"
}

# ---------------------------------------------------------------------------
# AC5 — Coordination with /gaia-resume.
# ---------------------------------------------------------------------------

@test "AC5: plan contains a Coordination section for /gaia-resume" {
  _grep_section "$PLAN_FIXTURE" "Coordination with"
  _grep_keyword "$PLAN_FIXTURE" "/gaia-resume"
}

@test "AC5: coordination section calls out the no-crash invariant" {
  _grep_keyword "$PLAN_FIXTURE" "no-crash|No-crash|crash"
}

@test "AC5: coordination section references no-active-workflows path" {
  _grep_keyword "$PLAN_FIXTURE" "No active workflows to resume|no-active-workflows"
}

@test "AC5: coordination section excludes V2 per-skill subdirectories from sweep" {
  _grep_keyword "$PLAN_FIXTURE" "per-skill|V2|ADR-059"
}

# ---------------------------------------------------------------------------
# Workspace-only @tests — assert canonical plan matches the in-tree fixture
# when running inside a GAIA-Framework workspace.
# ---------------------------------------------------------------------------

@test "workspace plan matches in-tree fixture (when workspace present)" {
  if ! _have_workspace_artifact; then
    skip "workspace plan not present (running outside GAIA-Framework workspace) — fixture-only assertion"
  fi
  run diff -q "$WORKSPACE_PLAN" "$PLAN_FIXTURE"
  [ "$status" -eq 0 ]
}
