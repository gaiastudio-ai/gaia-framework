---
name: gaia-trace
description: Generate requirements-to-tests traceability matrix with deterministic gate verification. Use when "create traceability matrix" or /gaia-trace.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-trace/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh test-architect all

## Mission

You are generating a **traceability matrix** that maps every PRD requirement (FR-xxx, NFR-xxx) to its implementing story and covering test case(s). The matrix is written via the strategy-fallback rule (ADR-072 / AF-2026-05-08-5): if an existing matrix is found under `.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md` (E53 reorganization placement), write to that location to preserve placement; otherwise write to flat `.gaia/artifacts/test-artifacts/traceability-matrix.md`. After generation, you invoke `validate-gate.sh traceability_exists` to verify the gate deterministically (the gate already accepts both placements + the sharded `traceability-matrix/index.md` form per ADR-070).

**Path resolution (AF-2026-05-21-15).** All path references in this SKILL.md use the canonical post-ADR-111 location under `.gaia/artifacts/test-artifacts/` and `.gaia/artifacts/planning-artifacts/`. The ADR-072 strategy-fallback rule and the ADR-069/FR-396..402 sharded-fallback rule are preserved under path-root substitution — both branches of each fallback are rooted at canonical. Pre-ADR-111 projects continue to work via `validate-gate.sh`'s built-in canonical-first resolution (the gate accepts both layouts).

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/traceability` workflow (E28-S85, Cluster 11). The step ordering, matrix format, and output path are preserved verbatim from the legacy `instructions.xml` -- do not restructure, re-prompt, or reorder.

## Critical Rules

- Matrix rows MUST be PRD requirements (FR-001...FR-N, NFR-001...NFR-N), NOT story acceptance criteria. Stories are an intermediate mapping between requirements and tests, not the primary dimension.
- Map every requirement to at least one test.
- Identify requirements without test coverage as gaps.
- Output ALL artifacts to `.gaia/artifacts/test-artifacts/` (or `.gaia/artifacts/test-artifacts/strategy/` under the E53 reorganization placement — see ADR-072).
- Resolve the output path via the strategy-fallback rule (ADR-072 / AF-2026-05-08-5): if `.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md` already exists, write to that path to preserve placement; otherwise default to flat `.gaia/artifacts/test-artifacts/traceability-matrix.md`. The legacy flat path remains the default for greenfield projects; existing strategy/ placements are honored to avoid duplicate-matrix shadowing.
- The legacy `val_validate_output: true` flag is preserved -- the output traceability matrix should be validated when Val integration is active.
- If validate-gate.sh not found at `${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh` (missing validate-gate script), halt with a clear error identifying the missing script path and exit with non-zero status. Do not attempt to run the gate check without the script.
- Resolve the PRD via the sharded-fallback rule: first try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); if it does not exist, fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout per ADR-069 / FR-396..402). If NEITHER path exists: HALT -- "PRD not found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md. Run /gaia-create-prd first. The traceability matrix requires PRD requirements as its primary dimension."
- If the FR/NFR set is empty (no requirements found in prd.md): exit gracefully with a warning message "No FR/NFR requirements found in prd.md -- generating empty matrix file." Generate an empty matrix file with headers only (no crash, no partial output).
- Resolve the test-plan path via the strategy-fallback rule (ADR-072 / AF-2026-05-08-5): first try `.gaia/artifacts/test-artifacts/test-plan.md` (flat layout); if missing, fall back to `.gaia/artifacts/test-artifacts/strategy/test-plan.md` (E53 reorganization placement); the sharded `test-plan/index.md` form per ADR-070 is also accepted by `validate-gate.sh test_plan_exists`. Reads of test-plan throughout the skill resolve via this rule.
- If test-plan.md has malformed table syntax or broken table headers: log a parse warning "Malformed table syntax detected in test-plan.md -- skipping unparseable rows", skip unparseable rows, and generate the matrix from valid rows only.

## Steps

### Step 1 -- Load Requirements

- Resolve the PRD path via the sharded-fallback rule (see Critical Rules above): prefer `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); if missing, use `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout per ADR-069 / FR-396..402). Read the resolved file (and, for the sharded layout, also walk shard sections under `.gaia/artifacts/planning-artifacts/prd/04-functional-requirements/` and `.gaia/artifacts/planning-artifacts/prd/05-non-functional-requirements.md`) -- extract ALL functional requirements (FR-001 through FR-N) and non-functional requirements (NFR-001 through NFR-N) as the primary requirement inventory. These are the matrix rows.
- GATE: If neither flat `.gaia/artifacts/planning-artifacts/prd.md` nor sharded `.gaia/artifacts/planning-artifacts/prd/prd.md` exists or can be loaded: HALT -- "PRD not found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md. Run /gaia-create-prd first. The traceability matrix requires PRD requirements as its primary dimension."
- Read `.gaia/artifacts/planning-artifacts/epics-and-stories.md` -- for each story, identify which FR/NFR it implements. Build a mapping: FR/NFR -> Story(s) -> Story ACs.
- Resolve the test-plan path via the strategy-fallback rule (Critical Rules above): try `.gaia/artifacts/test-artifacts/test-plan.md` (flat layout); fall back to `.gaia/artifacts/test-artifacts/strategy/test-plan.md` (strategy/ placement). Read the resolved file if it exists — extract planned test IDs and their categories (Unit, Integration, E2E, Manual, Performance, Security, Accessibility).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-trace 1 trace_matrix_path=".gaia/artifacts/test-artifacts/traceability-matrix.md" coverage_metrics=pending stage=requirements-loaded`

### Step 2 -- Load Test Inventory

- Scan existing test descriptions from test-plan.md.
- For each test, record: test ID, test type (Unit/Integration/E2E/Manual/Performance/Security/Accessibility), implementation status (planned/implemented), requirement mapping, and file path if implemented.
- If test-plan.md has broken table syntax or missing headers, log a parse warning and skip unparseable rows. Continue with valid rows only.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-trace 2 trace_matrix_path=".gaia/artifacts/test-artifacts/traceability-matrix.md" coverage_metrics=pending stage=test-inventory-loaded`

### Step 3 -- Build Matrix

- Build the **Functional Requirements** matrix section:
  - Rows: FR-001 through FR-N (from PRD)
  - Columns: FR ID | Description | surface_type | Story(s) | Unit | Integration | E2E | Manual | Coverage %
  - For each FR, map to its implementing story(s) via the FR->Story mapping from Step 1, then map stories to their planned/implemented tests.
  - **`Coverage %` formula (AF-2026-05-24-14 / Test02 F-38):** the percentage published in the `Coverage %` column MUST be computed as `(implemented_tiers_for_this_req / required_tiers_per_risk_band) × 100`, rounded to the nearest integer. `implemented_tiers_for_this_req` counts non-empty cells across the four tier columns (Unit / Integration / E2E / Manual) for this row. `required_tiers_per_risk_band` is read from the story's frontmatter `risk_level:` mapping: `low → 1` (Unit only), `medium → 2` (Unit + Integration), `high → 3` (Unit + Integration + E2E), `critical → 4` (all four tiers including Manual). The matrix MUST include a `> **Coverage formula:**` callout in the header so auditors can reproduce the numbers without grepping this SKILL.md. Empty matrix (no rows) → no Coverage formula callout needed.
  - **`surface_type` column (E95-S1, NFR-073):** taxonomy values are `none | command | warning | output | config | ui` (frozen at NFR-073 authoring). The value is read from each linked story's frontmatter `surface_type:` field. When a story has no `surface_type` field, write `none` (forward-only adoption per NFR-073 §Backfill — existing stories are tolerated). FR rows with `surface_type != none` AND zero integration coverage trigger a BLOCKED finding at Step 6c (E95-S1 wire-verification gate).

- Build the **Non-Functional Requirements** matrix section:
  - Rows: NFR-001 through NFR-N (from PRD)
  - Columns: NFR ID | Description | surface_type | Category | Target | Test(s) | Status
  - Categories: Performance, Security, Accessibility, Scalability, Reliability, etc.
  - Map each NFR to its non-functional test(s) -- these may not have story intermediaries.
  - **`surface_type` column** mirrors the FR table semantics (see above) — same NFR-073 taxonomy, same wire-verification gate at Step 6c.

- Build the **Story -> Test** detail section as a supplementary view:
  - For each story with ACs, list the specific test IDs covering each AC.
  - This section supports the primary FR/NFR matrix but is NOT the primary dimension.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-trace 3 trace_matrix_path=".gaia/artifacts/test-artifacts/traceability-matrix.md" coverage_metrics=pending stage=matrix-built`

### Step 4 -- Gap Analysis

- Identify FR/NFR requirements with no mapped story -- flag as "No implementing story" gap.
- Identify FR/NFR requirements with stories but no mapped tests -- flag as "No test coverage" gap.
- Identify tests with no requirement mapping -- flag as "Orphan test" warning.
- For each story tagged Risk: HIGH -- check if `.gaia/artifacts/test-artifacts/atdd-{story_key}.md` exists. If missing, flag as "HIGH-RISK STORY WITHOUT ATDD -- run /gaia-atdd before /gaia-dev-story" gap. This is a blocking gap.
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


> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-trace 4 trace_matrix_path=".gaia/artifacts/test-artifacts/traceability-matrix.md" coverage_metrics="$COVERAGE_METRICS" stage=gap-analysis-complete`

### Step 5 -- Generate Matrix

- Compile the traceability matrix with:
  1. FR Requirements -> Test mapping table
  2. NFR Requirements -> Test mapping table
  3. Story AC -> Test detail (supplementary)
  4. Gap analysis summary
  5. Coverage statistics
  6. Implementation-readiness gate decision: if all High-risk FR/NFRs have at least one planned test AND implementation rate > 50%, declare PASS. If any High-risk FR/NFR has zero test coverage, declare BLOCKED. Otherwise declare CONDITIONAL.
- Resolve the output path via the strategy-fallback rule (Critical Rules above): if `.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md` already exists, write the compiled matrix to that path; otherwise write to flat `.gaia/artifacts/test-artifacts/traceability-matrix.md`.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-trace 5 trace_matrix_path=".gaia/artifacts/test-artifacts/traceability-matrix.md" coverage_metrics="$COVERAGE_METRICS" stage=matrix-generated --paths .gaia/artifacts/test-artifacts/traceability-matrix.md`

### Step 6 -- Gate Verification

- Invoke `validate-gate.sh traceability_exists` to verify the traceability matrix was written successfully.
- If validate-gate.sh returns exit code 0: gate PASSED -- report success.
- If validate-gate.sh returns non-zero exit code: gate FAILED -- report the actionable error message listing each uncovered requirement by ID with its title. The error output from validate-gate.sh contains the expected file path and failure reason.
- If all requirements have zero test coverage (100% uncovered): validate-gate.sh returns non-zero and the error message lists all requirements as uncovered.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-trace 6 trace_matrix_path=".gaia/artifacts/test-artifacts/traceability-matrix.md" coverage_metrics="$COVERAGE_METRICS" gate_status="$GATE_STATUS" stage=gate-verified`

### Step 6b — Dispatch-verb integration-coverage enforcement (E88-S6, FR-DPD-6)

For every story walked, run `scripts/lib/trace-dispatch-verb-enforcement.sh --story-file <story> --matrix-file <traceability-matrix>`. The helper sources `dispatch-verb-match.sh` (E88-S1), walks ACs, and enforces that every dispatch-verb AC in a `risk: medium|high` story has >=1 `test_class: integration` row in the matrix referencing it. HALTs with the canonical message on a coverage gap.

```bash
!scripts/lib/trace-dispatch-verb-enforcement.sh \
  --story-file "$STORY_FILE" \
  --matrix-file "$TRACE_MATRIX_PATH"
```

**Scope note (E88-S6 scope-split):** the original E88-S6 AC1 mandated a matrix-wide `test_class` column migration touching all 2185 rows. That migration is deferred to a follow-up. This enforcement step is the in-scope behaviour — it fires on `risk: medium|high` + dispatch-verb-bearing ACs only. Stories without `test_class: integration` rows in the matrix HALT until either (a) a matching row is added, OR (b) the story risk is downgraded to `low`.

### Step 6c — Wire-verification enforcement (E95-S1, NFR-073)

For every story walked, run `scripts/lib/wire-verification-emit.sh --story-file <story> --matrix-file <traceability-matrix>`. The helper walks the matrix for FR/NFR rows where `surface_type != none` AND zero linked rows have integration coverage. On a gap: emits a single HALT line listing ALL violating FR/NFR ids, invokes `review-gate.sh update --story <key> --gate "Test Review" --verdict FAILED` (pathway-i per ADR-054 dominance — zero `review-gate.sh` source changes), and exits 1.

```bash
!scripts/lib/wire-verification-emit.sh \
  --story-file "$STORY_FILE" \
  --matrix-file "$TRACE_MATRIX_PATH"
```

**Pathway-i rationale (ADR-054 invariance preserved):** `/gaia-trace` writes a FAILED verdict into the canonical Test Review row of the story's Review Gate table. ADR-054's existing dominance rule (any FAILED → composite BLOCKED) automatically refuses the `review → done` transition. No new severity vocabulary added to `review-gate.sh`; UNVERIFIED/PASSED/FAILED stays at three values. ADR-077's seven-phase review pipeline (APPROVE/REQUEST_CHANGES/BLOCKED at a different layer) is also unchanged.

**Forward-only adoption (NFR-073 §Backfill):** Stories without a `surface_type:` frontmatter field are treated as `surface_type: none` and produce no findings. The backfill of existing FRs/NFRs is deferred to a separate story per Sable's R2 recommendation in /gaia-meeting 2026-05-15. Re-runs against a clean matrix exit 0 without re-invoking `review-gate.sh update` (the gate does NOT auto-flip FAILED → PASSED — the operator must re-run `/gaia-run-all-reviews` to restore Test Review to PASSED).

## Changelog

- **2026-05-14 — E88-S6 — Dispatch-verb integration-coverage enforcement (FR-DPD-6, ADR-107, AI-2026-05-13-8, AI-2026-05-13-10).** Added Step 6b that invokes `scripts/lib/trace-dispatch-verb-enforcement.sh` for every story walked. The helper sources `lib/dispatch-verb-match.sh` (E88-S1) and HALTs with the canonical stderr message `HALT: dispatch-verb AC <story_key>:<ac_id> (risk: <risk>) requires >=1 integration row in traceability-matrix.md — add a TC-* row with test_class: integration, OR downgrade risk to low.` when a `risk: medium|high` story's dispatch-verb AC lacks an integration row. Closes AI-2026-05-13-8 (no test-class typing) at the `/gaia-trace` enforcement layer. **Scope-split note:** the original E88-S6 AC1 (matrix-wide `test_class` column migration on all 2185 rows) is filed as a Finding for a follow-up dedicated migration story — the enforcement step here works against the matrix in its current schema by checking `test_class: integration` substring presence on rows that already declare the field.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-trace/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-ci-setup` — scaffold the CI pipeline once traceability is green.
- **Alternative:** `/gaia-readiness-check` — confirm implementation readiness when CI is already in place.
