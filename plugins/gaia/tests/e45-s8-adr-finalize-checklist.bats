#!/usr/bin/env bats
# e45-s8-adr-finalize-checklist.bats
#
# E45-S8 — Canonical finalize-checklist.sh ADR (decision artifact only).
#
# This story is a decision artifact only — no production code ships.
# The bats suite enforces document-presence and structural completeness
# of ADR-068 against a fixture copy shipped under
# tests/fixtures/e45-s8-adr-068/. The canonical (living) ADR resides in
# the user's project tree at
# docs/planning-artifacts/adr-068-finalize-checklist-canonical.md
# (which is outside this marketplace repo per gaia-public/docs/INDEX.md;
# project planning artifacts are not vendored here). When the project-tree
# ADR is available — i.e., when this test is run from inside a checked-out
# GAIA-Framework workspace alongside the gaia-public repo — the
# corresponding @tests also assert against the live file.
#
# E45-S8 Acceptance Criteria covered:
#
#   AC1: ADR file exists and is numbered ADR-068 (next free slot after
#        ADR-067 in the architecture.md registry).
#   AC2: ADR documents Status, Context, Decision, Consequences, Alternatives.
#   AC3: Decision section pins: argument grammar, exit codes, JSON output
#        schema, --strict mode, integration with quality_gates.post_complete.
#   AC4: References E45-S6 (CI bats scaling) sequencing dependency.
#   AC5: Linked from architecture.md ADR registry table (covered by
#        the workspace-only @test below) and from global.yaml's
#        adr_registry pointer (covered by the workspace-only @test below).
#
# Internal helpers use leading-underscore prefix per NFR-052 allowlist
# convention (textual coverage gate exemption — see e45-s6-bats-budget-watch
# precedent at lines 11-22 of that file).

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

# Fixture (CI-stable, shipped in-tree) — primary test target.
ADR_FIXTURE="$BATS_TEST_DIRNAME/fixtures/e45-s8-adr-068/adr-068-finalize-checklist-canonical.md"

# Workspace-only paths — present when the test is run inside a GAIA-Framework
# workspace alongside the gaia-public repo. Resolved by walking up from
# tests/ -> plugins/gaia/ -> plugins/ -> gaia-public/ -> GAIA-Framework/.
WORKSPACE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
WORKSPACE_ADR="$WORKSPACE_ROOT/docs/planning-artifacts/adr-068-finalize-checklist-canonical.md"
WORKSPACE_ARCH="$WORKSPACE_ROOT/docs/planning-artifacts/architecture.md"
WORKSPACE_GLOBAL_YAML="$WORKSPACE_ROOT/_gaia/_config/global.yaml"

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

_grep_decision_pin() {
  # Usage: _grep_decision_pin <file> <pin-keyword-regex>
  # Returns 0 if the keyword appears anywhere in the file. The Decision
  # section is the load-bearing block; pin keywords are unique enough that
  # a stray match elsewhere in the same ADR is acceptable signal.
  local file="$1"
  local pattern="$2"
  grep -qiE "$pattern" "$file"
}

_count_adr_table_row() {
  # Usage: _count_adr_table_row <file> <adr-id>
  # Counts table rows registering the given ADR-ID (rows of the form
  # "| ADR-XXX | ... |").
  local file="$1"
  local adr_id="$2"
  grep -cE "^\| ${adr_id} \|" "$file"
}

_have_workspace_artifact() {
  # Returns 0 (true) if the workspace-only ADR file is present.
  #
  # NOTE: this helper guards ONLY on the workspace ADR. AC5 @tests that
  # assert against architecture.md or global.yaml MUST NOT use this guard
  # alone — they must additionally verify presence of the artifact they
  # actually assert against (see _have_workspace_arch and
  # _have_workspace_global_yaml below). The original single-guard design
  # produced a false-positive failure for the global.yaml @test when the
  # ADR was present but global.yaml was not (E28-S219).
  [ -f "$WORKSPACE_ADR" ]
}

_have_workspace_arch() {
  # Returns 0 (true) if the workspace architecture.md file is present.
  [ -f "$WORKSPACE_ARCH" ]
}

_have_workspace_global_yaml() {
  # Returns 0 (true) if the workspace global.yaml file is present.
  [ -f "$WORKSPACE_GLOBAL_YAML" ]
}

# ---------------------------------------------------------------------------
# AC1 — File presence and ADR numbering (fixture-based, CI-stable).
# ---------------------------------------------------------------------------

@test "AC1: ADR fixture exists at the canonical path" {
  [ -f "$ADR_FIXTURE" ]
}

@test "AC1: ADR fixture is non-empty" {
  [ -s "$ADR_FIXTURE" ]
}

@test "AC1: ADR fixture declares ADR-068 in title or frontmatter" {
  run grep -E "ADR-068" "$ADR_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "AC1: ADR fixture frontmatter pins adr_id to ADR-068" {
  run grep -E "^adr_id: ['\"]ADR-068['\"]" "$ADR_FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — Required ADR sections (Status, Context, Decision, Consequences,
# Alternatives). Asserted against the in-tree fixture.
# ---------------------------------------------------------------------------

@test "AC2: ADR contains Status section" {
  _grep_section "$ADR_FIXTURE" "Status"
}

@test "AC2: ADR contains Context section" {
  _grep_section "$ADR_FIXTURE" "Context"
}

@test "AC2: ADR contains Decision section" {
  _grep_section "$ADR_FIXTURE" "Decision"
}

@test "AC2: ADR contains Consequences section" {
  _grep_section "$ADR_FIXTURE" "Consequences"
}

@test "AC2: ADR contains Alternatives section" {
  _grep_section "$ADR_FIXTURE" "Alternatives"
}

# ---------------------------------------------------------------------------
# AC3 — Decision section pins. Asserted against the in-tree fixture.
# ---------------------------------------------------------------------------

@test "AC3: Decision pins argument grammar" {
  _grep_decision_pin "$ADR_FIXTURE" "argument grammar|argument-grammar|## Argument"
}

@test "AC3: Decision pins exit codes" {
  _grep_decision_pin "$ADR_FIXTURE" "exit code"
}

@test "AC3: Decision pins JSON output schema" {
  _grep_decision_pin "$ADR_FIXTURE" "JSON.{0,30}schema|output schema|json output"
}

@test "AC3: Decision pins --strict mode" {
  _grep_decision_pin "$ADR_FIXTURE" "[-]{2}strict"
}

@test "AC3: Decision pins quality_gates.post_complete integration" {
  _grep_decision_pin "$ADR_FIXTURE" "quality_gates\.post_complete|quality_gates_post_complete"
}

# ---------------------------------------------------------------------------
# AC4 — References E45-S6 sequencing dependency.
# ---------------------------------------------------------------------------

@test "AC4: ADR references E45-S6 (CI bats scaling sequencing dependency)" {
  run grep -E "E45-S6|ADR-062" "$ADR_FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — Workspace-only @tests. Skip cleanly when the gaia-public repo is
# not running inside a full GAIA-Framework workspace (e.g., on CI for the
# marketplace publish, where only the plugin tree is checked out).
# ---------------------------------------------------------------------------

@test "AC5: workspace ADR matches in-tree fixture (when workspace present)" {
  if ! _have_workspace_artifact; then
    skip "workspace ADR not present (running outside GAIA-Framework workspace) — fixture-only assertion"
  fi
  # Body content of the canonical ADR must match the fixture byte-for-byte.
  run diff -q "$WORKSPACE_ADR" "$ADR_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "AC5: ADR-068 is registered in architecture.md ADR table (workspace)" {
  if ! _have_workspace_arch; then
    skip "workspace architecture.md not present (running outside GAIA-Framework workspace)"
  fi
  local rows
  rows=$(_count_adr_table_row "$WORKSPACE_ARCH" "ADR-068")
  [ "$rows" -ge 1 ]
}

@test "AC5: global.yaml contains an ADR registry reference (workspace)" {
  if ! _have_workspace_global_yaml; then
    skip "workspace global.yaml not present (running outside GAIA-Framework workspace)"
  fi
  run grep -iE "adr_registry|ADR registry|adr-068" "$WORKSPACE_GLOBAL_YAML"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Internal-helper smoke tests (NFR-052 leading-underscore exemption).
# ---------------------------------------------------------------------------

@test "_grep_section returns 0 on a present heading" {
  local tmp="$TEST_TMP/h.md"
  printf '## Decision\n\nbody\n' > "$tmp"
  _grep_section "$tmp" "Decision"
}

@test "_grep_section returns non-zero on an absent heading" {
  local tmp="$TEST_TMP/h.md"
  printf '## Context\n\nbody\n' > "$tmp"
  run _grep_section "$tmp" "Decision"
  [ "$status" -ne 0 ]
}

@test "_grep_decision_pin matches case-insensitively" {
  local tmp="$TEST_TMP/d.md"
  printf 'The --STRICT mode is enabled.\n' > "$tmp"
  _grep_decision_pin "$tmp" "[-]{2}strict"
}

@test "_count_adr_table_row counts only table rows, not prose mentions" {
  local tmp="$TEST_TMP/a.md"
  printf '| ADR-068 | foo | bar |\nADR-068 mentioned in prose.\n| ADR-068 | baz | qux |\n' > "$tmp"
  local n
  n=$(_count_adr_table_row "$tmp" "ADR-068")
  [ "$n" -eq 2 ]
}

@test "_have_workspace_artifact returns deterministically based on file presence" {
  if [ -f "$WORKSPACE_ADR" ]; then
    _have_workspace_artifact
  else
    run _have_workspace_artifact
    [ "$status" -ne 0 ]
  fi
}
