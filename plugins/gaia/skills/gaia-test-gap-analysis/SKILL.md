---
name: gaia-test-gap-analysis
description: Scan test suite against requirements to identify coverage gaps. Use when "test gap analysis" or /gaia-test-gap-analysis.
argument-hint: "[--mode coverage|verification]"
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-gap-analysis/scripts/setup.sh

## Mission

You are performing a test gap analysis to identify untested or under-tested areas in the project. You scan the test plan and story files to find acceptance criteria that lack corresponding test cases, calculate per-module and aggregate coverage percentages, and produce a gap analysis report following the FR-223 schema.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/test-gap-analysis` workflow (Cluster 11, story E28-S84, ADR-042). It follows the canonical skill pattern established by E28-S66 (code-review).

**Fork context semantics (ADR-041, ADR-045):** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files -- the tool allowlist enforces NFR-048 (no-write isolation). Do NOT attempt to call Write or Edit. The gap analysis report is printed to conversation output for the caller to persist.

**Dual-mode operation:** This skill supports two modes:
- `coverage` (default) -- scans acceptance criteria against test plan to identify gaps
- `verification` -- cross-references generated test cases against execution results (JUnit XML, LCOV, E17 evidence JSON)

## Critical Rules

- A mode argument is optional. If omitted, default to `coverage` mode.
- If `--mode` is provided, it MUST be one of `coverage` or `verification`. Fail fast with "usage: /gaia-test-gap-analysis [--mode coverage|verification]" on invalid mode.
- This skill is READ-ONLY. Do NOT attempt to call Write or Edit tools -- the fork context allowlist enforces this.
- NFR-040 constraint: the analysis MUST complete within 60 seconds. Log execution time in the report footer.
- Output MUST follow the FR-223 schema: Executive Summary, Per-Module Coverage table, Per-Story Detail, Gap Table.
- When no gaps are detected, output MUST state "No coverage gaps detected" with gap count of 0 and coverage rate of 100%.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).
- When gaps are found, emit the completion nudge: "Run `/gaia-fill-test-gaps` to remediate these gaps now." (E19-S28 AC1/FR-315). Display-only, never auto-invokes.

## Steps

### Step 1 -- Determine Mode

- Check the argument for `--mode coverage` or `--mode verification`.
- If no mode specified, default to `coverage` mode.
- If mode is `coverage`, proceed to Step 2 (coverage mode steps).
- If mode is `verification`, proceed to Step 7 (verification mode steps).

### Step 2 -- Scan Test Plan (Coverage Mode)

- Resolve the test-plan via the strategy-fallback rule (ADR-072 / AF-2026-05-08-5): try `.gaia/artifacts/test-artifacts/test-plan.md` (flat); fall back to `.gaia/artifacts/test-artifacts/strategy/test-plan.md` (strategy/ placement). Read the resolved file.
- Extract all test case IDs and their linked story keys from the test plan.
- Build a map of `test_case_id -> [story_keys]` for cross-referencing.
- If `test-plan.md` is missing, log warning: "test-plan.md not found -- partial coverage analysis only" and continue with empty test case map (AC-EC1).

### Step 3 -- Scan Story Files (Coverage Mode)

- Scan all story files in `.gaia/artifacts/implementation-artifacts/` matching pattern `*-*.md`.
- For each story file, extract all acceptance criteria (AC items) from the "Acceptance Criteria" section.
- Build a map of `story_key -> [AC items]` with their identifiers (AC1, AC2, etc.).
- Track untested acceptance criteria -- ACs that have no matching test case in the test plan map.

### Step 4 -- Cross-Reference and Identify Gaps (Coverage Mode)

- For each story's acceptance criteria, check if a corresponding test case exists in the test plan.
- Flag each AC as `covered` (has test case) or `uncovered-ac` (no test case found).
- Calculate coverage rate per story: `covered_ACs / total_ACs`.
- Calculate overall coverage percentage across all stories using the shared helper `scripts/lib/coverage-calc.js` when available (E19-S25). If the helper is unavailable, compute inline with banker's rounding to one decimal place.

### Step 4a -- Inline AC Linkage Validation (Coverage Mode, E48-S5, ADR-063)

This skill MUST cross-reference each story AC against the test-plan.md test case map built in Step 2 inline -- the linkage check is performed by the skill itself and the verdict is surfaced directly to the user, not solely delegated to a downstream helper. ADR-063 (subagent dispatch contract -- mandatory verdict surfacing) governs this rule: validation results must be visible, not swallowed by helper internals.

For each AC, build a row in an "AC Linkage" table with: `story_key`, `ac_id`, `linkage_status` (`covered` or `unmapped`), `test_case_id` (when covered).

The skill output MUST include an `## AC Linkage` section directly, in addition to the FR-223 Gap Table. The section lists every story-AC pair scanned, with covered ACs showing the matched `test_case_id` and unmapped ACs flagged with their story key + AC identifier.

**Unmapped AC flagging format** (mandatory): every AC without a matching test case is flagged inline as `{story_key} {AC_id}: unmapped` -- for example, `E48-S5 AC3: unmapped`. The format uses the pinned story-key format `E{n}-S{n}` and the pinned AC identifier format `AC{n}` documented in the Pinned Schemas section below.

This linkage validation is performed inline by the skill (the skill itself reads the test-plan map and the story ACs and surfaces the table). It is NOT delegated solely to a shared helper -- the skill remains the visible owner of the verdict so users see the result without reading helper logs.

### Step 4b -- Frontend Dimensions Analysis (Coverage Mode, Conditional)

- Detect project type via `scripts/lib/project-type-detection.js` if available. If `result.type` is `frontend`, `fullstack`, or `mobile`, set `is_frontend=true`. Otherwise skip this step entirely.
- If `is_frontend == true`: for each of the six architectural dimensions (Unit Tests, E2E Tests, Cross-browser, Accessibility, Visual Regression, Responsive/Viewport), scan the project and compute gap_count, coverage_score 0-100%, and top 3 uncovered items per ADR-030 section 10.22.3 and FR-224.
- If `is_frontend == false`: skip. Do NOT emit a "## Frontend Dimensions" section.

### Step 4c -- Per-Module Coverage Calculation (Coverage Mode)

- Group all scanned story files by epic key (from `epic:` frontmatter field).
- For each epic group, count `total_acs`, `tested_acs`, and `gap_count`.
- Calculate per-epic and aggregate coverage percentages using `scripts/lib/coverage-calc.js` as the single source of truth (E19-S25). If unavailable, compute inline.
- Sort per-module table by `coverage_pct` ascending (lowest first); break ties by epic key lexicographic ascending.
- Exclude epics with zero story files from the per-module table.

### Step 5 -- Generate Coverage Output (FR-223 Schema)

- Generate the gap analysis report with the following FR-223 schema sections:
  - **Executive Summary** -- total stories analyzed, ACs scanned, gaps found, overall coverage percentage
  - **Per-Module Coverage** -- table with columns: module, total_acs, tested_acs, coverage_pct, gap_count
  - **Per-Story Detail** -- each story with its ACs and coverage status
  - **AC Linkage** (E48-S5) -- inline table with `story_key`, `ac_id`, `linkage_status` (covered or unmapped), `test_case_id` (when covered). Unmapped ACs MUST be listed with the format `{story_key} {AC_id}: unmapped` (e.g., `E48-S5 AC3: unmapped`). The skill itself surfaces this section directly per ADR-063.
  - **Gap Table** -- listing each uncovered AC with story_key, gap_type, severity, description
- If zero gaps detected: "No coverage gaps detected" in summary with gap count 0 and coverage 100%.
- Print the report to the conversation.

### Step 6 -- Performance Validation (Coverage Mode)

- Verify skill completed within the NFR-040 constraint of under 60 seconds.
- Log total execution time in the report footer.
- If gaps were found, emit completion nudge: "Run `/gaia-fill-test-gaps` to remediate these gaps now."

### Step 7 -- Scan Generated Test Cases (Verification Mode)

- Scan `.gaia/artifacts/test-artifacts/` for all generated test case files matching `{story_key}-*.md` and ATDD files `atdd-{story_key}*.md`.
- Build a map of generated test cases per story: `story_key -> [test_case_id, test_file, test_name]`.
- Count total generated test cases per story (`generated` count) and in aggregate (`total_generated`).

### Step 8 -- Detect and Parse Execution Results (Verification Mode)

- Scan for test execution result files in the following formats:
  1. JUnit XML -- parse test name, status from XML testcase elements
  2. LCOV coverage files -- parse source file coverage data
  3. E17 evidence JSON -- parse test IDs and execution status per E17-S10 schema
- If no execution result files found: log warning "No test execution results found -- falling back to coverage mode output" and proceed to Step 5 instead.
- Build a unified executed tests map: `test_id -> {status, source_format, last_run}`.

### Step 9 -- Cross-Reference Generated vs Executed (Verification Mode)

- For each story, cross-reference generated test cases against the executed tests map.
- Classify each test case as: EXECUTED (found in results) or UNEXECUTED (not found).
- Calculate per-story `exec_ratio = (executed / generated) * 100`, rounded to one decimal place.
- Division-by-zero: when `generated == 0`, set `exec_ratio = 0.0%` with note `(0/0 -- no generated tests)`.
- Flag stories with `executed == 0` and `generated > 0` as HIGH priority gaps.

### Step 10 -- Generate Verification Output (FR-226 Schema)

- Generate verification mode report with:
  - **Executive Summary** with aggregate `Generated vs Executed: {total_executed}/{total_generated} ({aggregate_exec_ratio}%)`
  - **Per-Story Detail** with `generated`, `executed`, and `exec_ratio` fields
  - **Unverified Tests Table** listing test files with UNVERIFIED status
  - HIGH priority flags for stories with zero executed tests
- Print the report to the conversation.

### Step 11 -- Performance Validation (Verification Mode)

- Verify skill completed within the NFR-040 constraint of under 60 seconds.
- Log total execution time in the report footer.
- If gaps were found, emit completion nudge: "Run `/gaia-fill-test-gaps` to remediate these gaps now."

## Pinned Schemas (E48-S5)

The skill reads `.gaia/artifacts/test-artifacts/test-plan.md` and story frontmatter as plain markdown -- there is no runtime schema validator. The schemas below are pinned in this SKILL.md so the LLM knows what column names, story-key format, and frontmatter fields to expect. Deviations are handled with the documented fallbacks; they do not abort the run.

### test-plan.md test-case table schema

The test-plan.md test case map built in Step 2 prefers the following CANONICAL column layout:

`| # | Test Case ID | Story Key | AC | Scenario | Type | Severity |`

- **Test Case ID** -- unique test identifier (e.g., `TC-001`, `TC-GR37-10`).
- **Story Key** -- traceability key in the pinned format `E{n}-S{n}` (e.g., `E48-S5`).
- **AC** -- AC identifier in the pinned format `AC{n}` (e.g., `AC1`, `AC2`, `AC3`). Multiple ACs may be comma-separated (`AC1, AC3`).
- **Scenario** -- test scenario description.
- **Type** / **Severity** -- optional metadata columns; tolerated if absent.

#### Section-scoped heterogeneous tables (AF-2026-05-17-1)

On real projects the test-plan is frequently structured as section-scoped tables with no single universal schema. As of 2026-05-17, a representative GAIA-Framework test-plan contains **64 distinct table-header shapes across 435 tables**, with the top three covering ~63% (276/435) of all tables:

| Rank | Header shape | Count |
|---|---|---|
| 1 | `\| ID \| Scenario \| Type \| Severity \| Story \|` | 111 |
| 2 | `\| ID \| Scenario \| Expected \| Type \| Validates \| Status \|` | 84 |
| 3 | `\| ID \| Scenario \| Expected \| Type \|` | 81 |

None of these match the canonical schema above. They omit "Story Key" and "AC" columns; story-key references and FR/NFR linkages live in section headings, `Validates`, `Story`, or scenario-prose.

#### Three coverage signals (decreasing accuracy)

1. **STRONG** -- canonical-schema table is present (`| TC-ID | Story-Key | AC | ... |`). The documented per-AC matching in Step 4 works. This is the only signal that proves per-AC test coverage.
2. **MEDIUM** -- section-scoped tables present with TC-ID + requirement linkage (e.g. `| TC-VSP-1 | Scenario | Expected | Type | FR-VSP-1 | Status |`). The skill can build a TC → FR/NFR map by detecting per-section column position; story-key + AC linkage is not available, so coverage degrades to "requirement is referenced by at least one TC".
3. **WEAK / DEGRADED-MODE** -- neither canonical nor section-scoped tables are detected. Last-resort coverage signal is a document-wide regex sweep for FR-NNN/NFR-NNN identifier mentions. This counts "requirement is mentioned somewhere" but does NOT prove a test case exists. Reports MUST display a `[DEGRADED-MODE: regex-sweep coverage signal]` banner in the Executive Summary.

#### DEGRADED-MODE banner contract

When the skill falls back to the WEAK signal, the Executive Summary section MUST begin with a line: `> ⚠ DEGRADED-MODE: test-plan.md uses heterogeneous section-scoped tables; canonical Story-Key/AC schema not detected. Coverage figures below reflect document-wide FR/NFR regex sweep, NOT per-AC test linkage.` This banner replaces the silent tolerant-match warning that previously made the degraded state invisible to the user.

#### Out of scope for this AF

Redesign of the matching logic to detect per-section column positions (MEDIUM signal computation, schema-detection state machine, multi-shape parser) is deferred to a follow-on AF or epic. AF-2026-05-17-1 is documentation-only -- it updates the schema description in this section, adds the three-signal taxonomy, and mandates the DEGRADED-MODE banner. Adding new matching code is explicitly NOT in scope.

If the table uses non-standard column names (e.g., `Test ID` instead of `Test Case ID`), the skill logs a warning `test-plan.md schema mismatch: expected '{column}', found '{actual}' -- attempting tolerant match` and proceeds with case-insensitive substring matching. If matching cannot recover the columns, the impacted rows are treated as unmapped and surfaced in the AC Linkage section, AND the DEGRADED-MODE banner is emitted in the Executive Summary per the contract above.

### Story-key and AC-id formats

- **Story key format**: `E{n}-S{n}` where `{n}` is a positive integer (e.g., `E48-S5`, `E1-S12`). Cross-referencing in Step 4 uses exact-match on this format.
- **AC identifier format**: `AC{n}` (e.g., `AC1`, `AC2`). The identifier appears in story acceptance-criteria lines and in the test-plan AC column.

### Story frontmatter -- required `epic:` field

Step 4c (Per-Module Coverage Calculation) groups stories by epic. The grouping requires a `epic:` field in the YAML frontmatter of every story file:

```yaml
---
key: "E48-S5"
epic: "E48"      # required for per-epic grouping (format: E{n})
status: ready-for-dev
---
```

- **Format**: `E{n}` (e.g., `E48`, `E1`, `E20`).
- **Required**: yes -- per-module table grouping in Step 4c depends on this field.
- **Fallback for missing `epic:` field**: skip story with warning. Step 4c emits `WARN: story {story_key} missing epic: frontmatter -- skipping per-epic grouping for this story` and excludes the story from the per-module table. The story still contributes to overall coverage and to the gap table; only the per-epic row is omitted.

This pinning prevents silent failures when stories lack the `epic:` frontmatter field and makes the fallback behavior explicit.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-gap-analysis/scripts/finalize.sh
