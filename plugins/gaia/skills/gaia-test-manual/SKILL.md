---
name: gaia-test-manual
description: Agent-driven manual verification — exercises a target as a real user would and produces a run record with observed-vs-expected evidence. Disambiguated from /gaia-test-run (automated machine suite).
argument-hint: "<target>"
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-manual/scripts/setup.sh

## Mission

Dispatch the manual-tester agent (Reese) to exercise a target — a skill, script, workflow step, or user-facing feature — as a human operator would. The agent runs commands, observes output, compares expected vs. actual behavior, and produces a structured run-record with per-step evidence. The parent skill persists the evidence artifacts (run-record.md and exit-code.log) and enforces the proof-of-execution gate.

## Disambiguation

This skill (`/gaia-test-manual`) and `/gaia-test-run` serve different purposes:

- **`/gaia-test-manual`** — Agent-as-user manual verification. Reese exercises the target the way a human tester would: running commands interactively, observing output, checking visual or behavioral expectations that automated suites cannot cover. Produces a run-record (steps table with observed-vs-expected) and an exit-code log. Best for exploratory testing, smoke testing, UX verification, and validating behaviors that resist automation.

- **`/gaia-test-run`** — Automated machine test suite execution. Runs the project's existing automated tests (unit, integration, e2e) via the configured test runner (jest, pytest, bats, etc.) and reports structured pass/fail results. Best for regression testing, CI gates, and coverage measurement.

Use `/gaia-test-manual` when you need a human-style walkthrough with evidence. Use `/gaia-test-run` when you need to execute the automated test suite.

## Critical Rules

- A target argument MUST be provided. If missing, fail fast with "usage: /gaia-test-manual <target>".
- The manual-tester agent runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify source files. Evidence persistence is parent-mediated.
- Proof-of-execution gate: if the agent verdict is `PASSED` but either `run-record.md` or `exit-code.log` is missing or empty, the verdict MUST be downgraded to `UNVERIFIED`. This gate is enforced by `write-evidence.sh --verify`.
- Evidence files land under the canonical evidence directory resolved by `resolve-artifact-path.sh manual_test --slug <target-slug>`.
- Sprint-status.yaml is NEVER written by this skill.

## Supported Surfaces

The manual-test skill supports four verification surfaces, each keyed to a project-config signal. Each surface carries a verification **class** — `functional` or `visual` — so a consumer can tell whether a run included any *functional* verification (a smoke command actually executed, exit code = verdict) versus only a *visual* check (appearance / pixel-diff):

| Surface   | Class      | Config Signal                          | When Absent         |
|-----------|------------|----------------------------------------|---------------------|
| api       | functional | `platforms` contains `server` AND a functional smoke command (`sprint_review.manual_test.api_command`) | SKIPPED (dormant)   |
| browser   | visual     | `platforms` contains `web`             | SKIPPED (dormant) — runs pixel-diff when baselines exist |
| mobile    | visual     | `platforms` contains `ios` or `android`| SKIPPED (dormant)   |
| desktop   | visual     | `sprint_review.desktop_commands` has entries | SKIPPED (dormant) |

**Functional vs visual — why it matters.** The `api` surface is the only **functional** path: it runs the configured smoke command and the command's exit code is the verdict. The `browser` / `mobile` / `desktop` surfaces are **visual** — they verify appearance, not behavior. A run that exercised only visual surfaces is NOT functionally verified. Each surface's emitted JSON carries a `"class"` field, and the per-stack review reducer detects when a user-facing surface ran visual-only (no functional surface exercised): it sets `no_functional_surface` and **downgrades the Track B composite to `UNVERIFIED`** (fail-closed) so a visual-only run cannot silently auto-approve into a green PASSED — an operator must acknowledge it via the review bypass path. To get real functional coverage on a web-first project, configure `sprint_review.manual_test.api_command` with a smoke command (it does not require a `server` platform — any project can declare a functional smoke); that clears the `no_functional_surface` downgrade.

A surface that is not configured is always SKIPPED (exit code 2) — never UNVERIFIED, never FAILED. SKIPPED means dormant: the surface is simply not relevant to this project. UNVERIFIED means the surface was exercised but evidence was insufficient.

**Tracked (un-auto-approved) env-limited skip — enforced, not just logged.** When a configured functional smoke (`sprint_review.manual_test.api_command`) runs but cannot produce a clean pass/fail because its environment or tooling is unavailable, it reports `UNVERIFIED`. The per-stack review reducer records that surface on the result's `env_limited_surfaces` list AND **downgrades the Track B composite verdict to `UNVERIFIED`** (fail-closed) — which routes the sprint-review composite through the operator-acknowledgement bypass path (a PM explanation + a second Val pass), exactly like any other UNVERIFIED verdict. So an "env not available → functional check unverified" can NEVER silently auto-approve into a green PASSED; an operator must explicitly acknowledge it. A smoke that runs and *fails* is a hard `FAILED` (Track B fails); only the could-not-verify case becomes the tracked UNVERIFIED skip. A genuinely-dormant surface (no functional smoke configured at all, and no user-facing visual surface) stays a benign PASSED-equivalent SKIPPED.

**Hermetic / staging smoke path.** To run the functional surface without standing up every stack locally, point `sprint_review.manual_test.api_command` at a hermetic or staging endpoint (e.g. a health/smoke check against a deployed staging service, or a self-contained command that needs no local environment). This gives a real functional check even on a machine that cannot run the full per-stack environment, and is the recommended way to clear an `env_limited` tracked skip.

The default surface when none is specified is `api`, for backward compatibility with backend-only projects.

## Relationship to Existing Testing Skills

`/gaia-test-manual` is complementary to, not a replacement for, the existing automated and specialized testing skills:

- **`/gaia-test-e2e`** — Automated end-to-end test execution via Playwright or Cypress. Manual testing covers behaviors that resist browser automation (visual polish, subjective UX, edge-case flows that the e2e suite does not yet cover).

- **`/gaia-test-mobile-e2e`** — Automated mobile end-to-end tests via Detox or Appium. Manual testing on the mobile surface provides human-walkthrough coverage for gestures, haptics, and platform-specific behaviors that mobile e2e frameworks handle poorly.

- **`/gaia-test-a11y`** — Automated accessibility testing via axe-core, pa11y, or Lighthouse. Manual testing surfaces accessibility issues that require human judgment (focus order intuitiveness, screen-reader narrative coherence, color-contrast edge cases in complex gradients).

- **`/gaia-review-mobile`** — Code review with a mobile-specific lens. Manual testing verifies runtime behavior; the mobile review inspects code-level patterns (memory leaks, deep-link handling, offline resilience).

- **`/gaia-test-device-matrix`** — Automated cross-device test matrix execution. Manual testing complements the matrix by covering devices or OS versions that the matrix does not include, or by exercising behaviors that differ across physical hardware in ways emulators miss.

- **`/gaia-config-device-target`** — Configuration editor for the device-target matrix. Not a testing skill itself, but its output (the `device_targets` section) feeds both `/gaia-test-device-matrix` and the manual-test mobile surface's scope decisions.

## Visual Regression (Browser Surface)

When the browser surface runs, `dispatch-surface.sh` captures per-breakpoint screenshots and compares them against per-story design baselines via `pixel-diff.sh`. The baseline directory for each story is resolved through the paths helper (`resolve-artifact-path.sh --kind design_baselines --slug <story-slug>`).

**Thresholds and masking.** The `visual_diff` section in `project-config.yaml` controls comparison behavior. `threshold_percent` (default 0.1) sets the maximum percentage of pixels that may differ before a comparison records FAILED. At-threshold passes; only strictly above fails. `mask_regions` declares rectangular regions (x, y, w, h, label) excluded from comparison before diffing -- use for dynamic content like timestamps, ads, or live data feeds.

**Baseline lifecycle.** When no baseline exists for a story, the visual check records UNVERIFIED (non-blocking). This matches the advisory-gate precedent: a missing baseline never blocks the story-to-done transition. When a baseline exists and the diff exceeds the threshold, the check records FAILED. To update a baseline after an intentional design change, run `approve-baseline.sh --story <slug> --breakpoint <width>`. The approval script requires an interactive terminal and explicit confirmation per breakpoint -- baselines are never auto-accepted. Old baselines are archived under a `previous/` subdirectory and each approval is logged to `baseline-approvals.log`.

**Tool availability.** The pixel-diff comparison requires ImageMagick (`compare`) or `pixelmatch` on PATH. When neither is available, the visual check records UNVERIFIED with a diagnostic naming the missing tool, matching the non-blocking degradation contract.

## Steps

### Step 1 — Resolve target and evidence path

Resolve the target argument to a concrete testable entity (script path, skill name, feature description). Derive a slug from the target for the evidence directory path. Use `resolve-artifact-path.sh manual_test --slug <slug>` to determine the canonical evidence location.

### Step 1b — Resolve surface profile

Determine which surface to exercise. If the caller provides a `MANUAL_TEST_SURFACE` environment variable, use it; otherwise default to `api`. Run `surface-adapter.sh --surface <surface>` to check whether the surface is configured in the project. If the adapter returns SKIPPED (exit 2), skip directly to Step 5 with a SKIPPED verdict — do not dispatch the agent. If the adapter returns an error (exit 1), fail fast.

### Step 2 — Dispatch the manual-tester agent

Dispatch the `manual-tester` agent (Reese) via the Agent tool with `context: fork`. Pass the target description and any relevant context (acceptance criteria, usage examples, expected behaviors). The agent runs commands, observes output, and returns a structured run-record payload.

### Step 3 — Persist evidence artifacts

Receive the agent's run-record payload. Invoke `write-evidence.sh <evidence-dir> <verdict>` with the run-record content piped via stdin. The script writes `run-record.md` and `exit-code.log` to the evidence directory.

### Step 4 — Enforce proof-of-execution gate

Invoke `write-evidence.sh <evidence-dir> <verdict> --verify` to validate that both evidence files exist and are non-empty. If the verdict is `PASSED` but evidence is missing or empty, the script downgrades to `UNVERIFIED` and exits non-zero.

### Step 5 — Surface verdict and findings

Report the final verdict to the user. Surface any `WARNING` or `CRITICAL` findings from the run-record. Suppress `INFO` findings from the user-visible transcript (they remain in the evidence files).

### Step 5b — Record verdict on review-gate ledger

The finalize script records the manual-test verdict on the review-gate extended ledger (the same tier used by test-automate-plan and story-validation). It also appends a row to the persistent verdicts TSV (`.gaia/state/manual-test-verdicts.tsv`) for flakiness tracking. Set `MANUAL_TEST_VERDICT`, `MANUAL_TEST_STORY_KEY`, and optionally `MANUAL_TEST_RUN_ID` before finalize runs. Stories with `manual_verification: true` in frontmatter will see an advisory WARNING on `review -> done` transition if the latest manual-test verdict is FAILED.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-manual/scripts/finalize.sh
