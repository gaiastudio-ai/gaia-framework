---
name: gaia-trace
description: Generate requirements-to-tests traceability matrix with deterministic gate verification. Use when "create traceability matrix" or /gaia-trace.
context: fork
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-trace/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh test-architect all

## Mission

You are generating a **traceability matrix** that maps every PRD requirement (FR-xxx, NFR-xxx) to its implementing story and covering test case(s). The matrix is written to `docs/test-artifacts/traceability-matrix.md`. After generation, you invoke `validate-gate.sh traceability_exists` to verify the gate deterministically.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/traceability` workflow (E28-S85, Cluster 11). The step ordering, matrix format, and output path are preserved verbatim from the legacy `instructions.xml` -- do not restructure, re-prompt, or reorder.

## Critical Rules

- Matrix rows MUST be PRD requirements (FR-001...FR-N, NFR-001...NFR-N), NOT story acceptance criteria. Stories are an intermediate mapping between requirements and tests, not the primary dimension.
- Map every requirement to at least one test.
- Identify requirements without test coverage as gaps.
- Output ALL artifacts to `docs/test-artifacts/`.
- The output path is `docs/test-artifacts/traceability-matrix.md` -- this matches the legacy workflow output path exactly.
- The legacy `val_validate_output: true` flag is preserved -- the output traceability matrix should be validated when Val integration is active.
- If validate-gate.sh not found at `${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh` (missing validate-gate script), halt with a clear error identifying the missing script path and exit with non-zero status. Do not attempt to run the gate check without the script.
- If prd.md is missing at `docs/planning-artifacts/prd.md`: HALT -- "PRD not found at docs/planning-artifacts/prd.md. Run /gaia-create-prd first. The traceability matrix requires PRD requirements as its primary dimension."
- If the FR/NFR set is empty (no requirements found in prd.md): exit gracefully with a warning message "No FR/NFR requirements found in prd.md -- generating empty matrix file." Generate an empty matrix file with headers only (no crash, no partial output).
- If test-plan.md has malformed table syntax or broken table headers: log a parse warning "Malformed table syntax detected in test-plan.md -- skipping unparseable rows", skip unparseable rows, and generate the matrix from valid rows only.

## Steps

### Step 1 -- Load Requirements

- Read `docs/planning-artifacts/prd.md` -- extract ALL functional requirements (FR-001 through FR-N) and non-functional requirements (NFR-001 through NFR-N) as the primary requirement inventory. These are the matrix rows.
- GATE: If prd.md does not exist or cannot be loaded: HALT -- "PRD not found at docs/planning-artifacts/prd.md. Run /gaia-create-prd first. The traceability matrix requires PRD requirements as its primary dimension."
- Read `docs/planning-artifacts/epics-and-stories.md` -- for each story, identify which FR/NFR it implements. Build a mapping: FR/NFR -> Story(s) -> Story ACs.
- Read `docs/test-artifacts/test-plan.md` if it exists -- extract planned test IDs and their categories (Unit, Integration, E2E, Manual, Performance, Security, Accessibility).

> `!scripts/write-checkpoint.sh gaia-trace 1 trace_matrix_path="docs/test-artifacts/traceability-matrix.md" coverage_metrics=pending stage=requirements-loaded`

### Step 2 -- Load Test Inventory

- Scan existing test descriptions from test-plan.md.
- For each test, record: test ID, test type (Unit/Integration/E2E/Manual/Performance/Security/Accessibility), implementation status (planned/implemented), requirement mapping, and file path if implemented.
- If test-plan.md has broken table syntax or missing headers, log a parse warning and skip unparseable rows. Continue with valid rows only.

> `!scripts/write-checkpoint.sh gaia-trace 2 trace_matrix_path="docs/test-artifacts/traceability-matrix.md" coverage_metrics=pending stage=test-inventory-loaded`

### Step 3 -- Build Matrix

- Build the **Functional Requirements** matrix section:
  - Rows: FR-001 through FR-N (from PRD)
  - Columns: FR ID | Description | Story(s) | Unit | Integration | E2E | Manual | Coverage %
  - For each FR, map to its implementing story(s) via the FR->Story mapping from Step 1, then map stories to their planned/implemented tests.

- Build the **Non-Functional Requirements** matrix section:
  - Rows: NFR-001 through NFR-N (from PRD)
  - Columns: NFR ID | Description | Category | Target | Test(s) | Status
  - Categories: Performance, Security, Accessibility, Scalability, Reliability, etc.
  - Map each NFR to its non-functional test(s) -- these may not have story intermediaries.

- Build the **Story -> Test** detail section as a supplementary view:
  - For each story with ACs, list the specific test IDs covering each AC.
  - This section supports the primary FR/NFR matrix but is NOT the primary dimension.

> `!scripts/write-checkpoint.sh gaia-trace 3 trace_matrix_path="docs/test-artifacts/traceability-matrix.md" coverage_metrics=pending stage=matrix-built`

### Step 4 -- Gap Analysis

- Identify FR/NFR requirements with no mapped story -- flag as "No implementing story" gap.
- Identify FR/NFR requirements with stories but no mapped tests -- flag as "No test coverage" gap.
- Identify tests with no requirement mapping -- flag as "Orphan test" warning.
- For each story tagged Risk: HIGH -- check if `docs/test-artifacts/atdd-{story_key}.md` exists. If missing, flag as "HIGH-RISK STORY WITHOUT ATDD -- run /gaia-atdd before /gaia-dev-story" gap. This is a blocking gap.
- Prioritize gaps by risk level (High-risk FR/NFRs without coverage are blocking).
- Calculate implementation rate: count implemented tests vs total planned tests. Record as: Total planned: N, Implemented: M (percentage%).

<!-- E77-S16: plugin-aware chain begin (FR-421) -->
- **Plugin-aware chain (FR-421, AC5).** When `project_kind == claude-code-plugin` (resolved from `config/project-config.yaml` or `detect-signals.sh` output), additionally run `${CLAUDE_PLUGIN_ROOT}/scripts/plugin-trace-chain.sh --project-root <PROJECT_ROOT> --require-plugin` and append a "Plugin Chain" section to the traceability matrix. The chain entries map `manifest.yaml` / `.claude-plugin/plugin.json` -> `plugins/*/SKILL.md` -> bang-line `!scripts/*.sh` references -> `tests/*.bats` files. Surface each `gaps[]` entry as a matrix row:
  - `gap_kind: missing_skill_md`   -> "Manifest lists skill but SKILL.md is absent" (BLOCKING).
  - `gap_kind: missing_script`     -> "SKILL.md references a script that does not exist on disk" (BLOCKING).
  - `gap_kind: no_bats_coverage`   -> "Script exists but has no bats coverage" (WARNING).
  - `gap_kind: orphan_skill_md`    -> "SKILL.md present on disk but absent from manifest skills[]" (advisory).

  When `project_kind` is anything other than `claude-code-plugin` (or unset), SKIP this section entirely — non-plugin traceability behaviour is unchanged (AC5 invariant). The `--require-plugin` flag also makes `plugin-trace-chain.sh` short-circuit on projects that fail the FR-420 3-signal threshold, so even an erroneous invocation on a non-plugin project produces an empty chain.
<!-- E77-S16: plugin-aware chain end -->


> `!scripts/write-checkpoint.sh gaia-trace 4 trace_matrix_path="docs/test-artifacts/traceability-matrix.md" coverage_metrics="$COVERAGE_METRICS" stage=gap-analysis-complete`

### Step 5 -- Generate Matrix

- Compile the traceability matrix with:
  1. FR Requirements -> Test mapping table
  2. NFR Requirements -> Test mapping table
  3. Story AC -> Test detail (supplementary)
  4. Gap analysis summary
  5. Coverage statistics
  6. Implementation-readiness gate decision: if all High-risk FR/NFRs have at least one planned test AND implementation rate > 50%, declare PASS. If any High-risk FR/NFR has zero test coverage, declare BLOCKED. Otherwise declare CONDITIONAL.
- Write the compiled matrix to `docs/test-artifacts/traceability-matrix.md`.

> `!scripts/write-checkpoint.sh gaia-trace 5 trace_matrix_path="docs/test-artifacts/traceability-matrix.md" coverage_metrics="$COVERAGE_METRICS" stage=matrix-generated --paths docs/test-artifacts/traceability-matrix.md`

### Step 6 -- Gate Verification

- Invoke `validate-gate.sh traceability_exists` to verify the traceability matrix was written successfully.
- If validate-gate.sh returns exit code 0: gate PASSED -- report success.
- If validate-gate.sh returns non-zero exit code: gate FAILED -- report the actionable error message listing each uncovered requirement by ID with its title. The error output from validate-gate.sh contains the expected file path and failure reason.
- If all requirements have zero test coverage (100% uncovered): validate-gate.sh returns non-zero and the error message lists all requirements as uncovered.

> `!scripts/write-checkpoint.sh gaia-trace 6 trace_matrix_path="docs/test-artifacts/traceability-matrix.md" coverage_metrics="$COVERAGE_METRICS" gate_status="$GATE_STATUS" stage=gate-verified`

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-trace/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-ci-setup` — scaffold the CI pipeline once traceability is green.
- **Alternative:** `/gaia-readiness-check` — confirm implementation readiness when CI is already in place.
