---
name: gaia-review-perf
description: Review code for performance issues. Use when "review performance" or /gaia-review-perf.
argument-hint: "[story-key]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: reviewer
---

> **Premium upgrade available.** The `gaia-enterprise` marketplace ships a `performance-review-advanced` SKILL.md (E28-S124) that layers real profiling-tool integration (py-spy, `node --prof`, jfr, pprof) and hot-path summaries on top of this OSS heuristic skill, gated behind the `perf-advanced` feature flag. Install via `/plugin marketplace add gaiastudio-ai/gaia-enterprise` and `/plugin install gaia-enterprise`. Without the enterprise plugin, this OSS skill serves unaffected.

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-review-perf/scripts/setup.sh

## Mission

You are performing a performance review for a story. The story is resolved by `{story_key}` via the canonical glob `{story_key}-*.md` in `docs/implementation-artifacts/`. You analyze each changed file for performance bottlenecks -- N+1 queries, memory leaks, algorithmic complexity, bundle size, caching gaps -- and produce a machine-readable verdict (PASSED or FAILED) written to the story's Review Gate "Performance Review" row via `review-gate.sh`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/anytime/performance-review` workflow (brief Cluster 9, story E28-S71, ADR-042). It follows the canonical reviewer skill pattern established by E28-S66 (code-review).

**Fork context semantics (ADR-041, ADR-045):** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files -- the tool allowlist enforces NFR-048 (no-write isolation). Do NOT attempt to call Write or Edit.

**Subagent dispatch:** Performance bottleneck analysis and optimization recommendations are dispatched to the Juno performance subagent (E28-S21). The fork context invokes Juno for deep performance assessment; Juno's verdict is returned across the fork boundary.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-review-perf [story-key]".
- The story file MUST exist at `docs/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug. If zero matches, fail with "story file not found for key {story_key}".
- The story MUST be in `review` status. If not, fail with "story must be in review status before performance review".
- This skill is READ-ONLY. Do NOT attempt to call Write or Edit tools -- the fork context allowlist enforces this.
- Performance analysis MUST be dispatched to the Juno performance subagent -- do NOT perform inline analysis in the fork context.
- The verdict uses PASSED or FAILED (canonical Review Gate vocabulary, per CLAUDE.md).
- Verdict logic: NO critical or high severity findings = PASSED; ANY critical or high severity finding = FAILED.
- Auto-pass: if zero performance-relevant files are changed (only markdown, config, test files, static assets, CSS-only, copy/translations, lock files), verdict is PASSED with note "No performance-relevant code changes -- auto-passed".
- Call `review-gate.sh` to update the Review Gate row -- do NOT manually edit the story file.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Resolve Story File

- If no story key was provided as an argument, fail with: "usage: /gaia-review-perf [story-key]"
- Resolve the story file path using the canonical glob: `docs/implementation-artifacts/{story_key}-*.md`
- If zero matches: fail with "story file not found for key {story_key} -- searched docs/implementation-artifacts/{story_key}-*.md"
- If multiple matches: fail with "multiple story files matched key {story_key} -- resolve ambiguity"
- Read the resolved story file.

### Step 2 -- Status Gate

- Parse the story file YAML frontmatter and extract the `status` field.
- If status is not `review`, fail with: "story {story_key} is in '{status}' status -- must be in 'review' status for performance review"
- Extract the list of files changed from the story file's "File List" section under "Dev Agent Record".

### Step 3 -- Auto-Pass Classification

- Classify each changed file as performance-relevant or not:
  - **Performance-relevant:** files containing DB queries, API endpoints, data processing, rendering logic, loops/algorithms, middleware, caching, network calls, core application code (.ts, .js, .py, .java, .go, .dart, .swift, .kt)
  - **Not relevant:** markdown (.md), config/yaml/json, test files, static assets, CSS-only, copy/translations, .gitignore, lock files
- If zero performance-relevant files exist: verdict is PASSED with note "No performance-relevant code changes -- auto-passed". Skip to Step 8.

### Step 4 -- Dispatch Performance Analysis to Juno

Invoke the Juno performance subagent to perform deep performance analysis on all performance-relevant changed files. Pass the story key, file list, and architecture context (if available at `docs/planning-artifacts/architecture.md`) to Juno. Juno performs Steps 4a through 4d below and returns findings across the fork boundary.

#### Step 4a -- N+1 and Database Analysis

- Analyze for N+1 queries and inefficient database access patterns
- Check for missing indexes on queried columns
- Identify unbounded queries (missing LIMIT, pagination)
- Report in percentiles (P50, P95, P99), not averages where applicable

#### Step 4b -- Memory and Bundle Analysis

- Identify memory leaks, large payloads, unoptimized loops
- Check frontend: bundle size impact, render blocking, unnecessary re-renders
- Review image optimization and lazy loading

#### Step 4c -- Caching and Complexity Review

- Review caching strategy: what is cached, what should be, cache invalidation
- Check for blocking operations and synchronous bottlenecks
- Analyze algorithm complexity -- flag O(n^2) or worse in hot paths

#### Step 4d -- Generate Findings

- Categorize all issues found by severity:
  - **Critical:** Must be fixed before merge (N+1 queries in hot paths, memory leaks, O(n^2)+ in hot paths, unbounded queries)
  - **High:** Should be fixed (missing caching, blocking operations, large bundle impact)
  - **Medium:** Recommended improvements (suboptimal algorithm, missing lazy loading)
  - **Low:** Minor suggestions (naming, minor optimization opportunities)

### Step 5 -- Verdict

- If NO critical or high severity performance issues: verdict is **PASSED**
- If ANY critical or high severity issue found: verdict is **FAILED** -- list blocking findings
- The verdict MUST appear as a machine-readable keyword in the report output.

### Step 6 -- Write Performance Review Report

- Generate the performance review report and print it to the conversation. The report must contain:
  - Story key and title
  - Auto-pass classification result (if applicable)
  - Summary of files reviewed
  - N+1 and database analysis results
  - Memory and bundle analysis results
  - Caching and complexity review results
  - Findings organized by severity (Critical, High, Medium, Low)
  - Machine-readable verdict line: `**Verdict: PASSED**` or `**Verdict: FAILED**`
- Save the report to `docs/implementation-artifacts/{story_key}-performance-review.md`.

### Step 7 -- Update Review Gate

- Map the verdict to the canonical Review Gate vocabulary:
  - PASSED stays PASSED
  - FAILED stays FAILED
- Invoke the shared `review-gate.sh` script to update the story's Review Gate table:
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update --story "{story_key}" --gate "Performance Review" --verdict "{PASSED|FAILED}"
  ```
- Confirm the update succeeded (exit code 0).
- Report the final status to the user.
- Note: sprint-status.yaml may now be out of sync. Run `/gaia-sprint-status` to reconcile.

### Step 8 -- Composite Review Gate Check

- After the individual gate update completes successfully, invoke the composite review-gate-check to show the overall story review status:
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check --story "{story_key}"
  ```
- Capture stdout and include the Review Gate table and summary line (`Review Gate: COMPLETE|PENDING|BLOCKED`) in the command's output.
- This check is informational only -- do not halt on non-zero exit codes. Exit codes 0/1/2 correspond to COMPLETE/BLOCKED/PENDING per ADR-054. Log the result and continue regardless of exit code.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-review-perf/scripts/finalize.sh
