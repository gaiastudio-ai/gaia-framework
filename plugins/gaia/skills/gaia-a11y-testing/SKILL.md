---
name: gaia-test-a11y
description: Post-deploy accessibility smoke variant — runs axe-core / pa11y / Lighthouse adapters against a deployed URL and produces a verdict. Sibling of /gaia-validate-design-a11y (planning) and /gaia-review-a11y (pre-merge gate); all three share rubrics/base/a11y.json. Use when "accessibility testing" or /gaia-test-a11y (formerly /gaia-a11y-testing).
argument-hint: "[story-key | deployed-url]"
command: /gaia-test-a11y
phase: deployment
verdict_producing: true
context: main
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
deprecated_aliases: [gaia-a11y-testing]
deprecated_since: sprint-37
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## ADR-077 Mission (E69-S2 — post-deploy smoke variant)

You are the **post-deploy a11y smoke** for the three-phase a11y skill family (FR-RSV2-25):

- `/gaia-validate-design-a11y` — planning (agent: Christy)
- `/gaia-review-a11y` — pre-merge gate, conditional on `compliance.ui_present: true` (agent: Christy)
- `/gaia-test-a11y` — post-deploy smoke (this skill, agent: Sable)

All three skills load the same rubric layer (`rubrics/base/a11y.json`) via the layered rubric loader (E68-S2 / ADR-079). This skill is verdict-producing and follows the seven-phase structure mandated by ADR-077.

### Phase 1 — Setup

- Resolve the deployed URL or story key from `$ARGUMENTS`.
- Load the layered rubric via `${CLAUDE_PLUGIN_ROOT}/scripts/rubric-loader.sh --skill a11y`. On non-zero exit (missing `rubrics/base/a11y.json`, schema validation failure), HALT with the loader's stderr — do NOT silently fall back to empty rules (AC-EC3).

### Phase 2 — Discovery

- Resolve the deployed environment URL (typically from `ci_cd.promotion_chain` or the user-supplied argument).
- Identify pages/routes to smoke-test from the architecture or story context.

### Phase 3A — Analysis (post-deploy adapter invocations)

> **TODO: E73-S4** — adapter internals (axe-core / pa11y / Lighthouse) are E73-S4 scope. This story (E69-S2) wires the SKILL.md, rubric-sharing, and conditional-trigger surface; the call sites below remain `TODO: E73-S4` placeholders.

- **TODO: E73-S4** axe-core adapter — invoke via headless browser, collect findings, normalize to the rubric category schema (semantic-html, aria-usage, keyboard-navigation, color-contrast, screen-reader-support).
- **TODO: E73-S4** pa11y adapter — invoke against the deployed URL list, collect findings, normalize.
- **TODO: E73-S4** Lighthouse adapter — invoke the Lighthouse a11y audit, collect findings, normalize.
- For every finding, cite the specific WCAG 2.1 criterion with conformance level (A/AA/AAA) and the matching rubric rule ID from the loaded rubric.

### Phase 3B — Cross-checks

- Cross-check post-deploy findings against the pre-merge `/gaia-review-a11y` report (if available in the same sprint) — identify regressions introduced between merge and deploy.

### Phase 4 — Findings

- Aggregate findings into the canonical schema (severity is rubric-driven):

  | # | Severity | Component / Page | Finding | WCAG Criterion | Remediation |

### Phase 5 — Verdict

- Resolve the composite verdict via the deterministic resolver:

  ```bash
  !${CLAUDE_PLUGIN_ROOT}/scripts/review-common/verdict-resolver.sh --findings <findings.json>
  ```

- The resolver emits `APPROVE | REQUEST_CHANGES | BLOCKED`. The skill MUST NOT recompute the verdict by hand (ADR-077, ADR-042).

### Phase 6 — Report

- Write the report to `docs/test-artifacts/accessibility-report-{date}.md` (preserved verbatim from the legacy task path for downstream consumers — deploy checklist aggregation).

### Phase 7 — Exit

- Emit the verdict on stdout for the caller (`/gaia-deploy-checklist` post-deploy aggregator or direct user invocation).
- Exit 0 on success regardless of verdict; exit non-zero only on infrastructure failure (rubric load failed, deployed URL unresolvable).

## Agent Wiring

Per ADR-077 wiring table, this skill resolves to **Sable (Test Architect)** via:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh --skill gaia-test-a11y
# {"agent_id":"sable","sidecar_path":"_memory/sable-sidecar.md"}
```

Sable owns post-deploy testing across all phases (e2e, perf, dast, a11y).

---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-a11y-testing/scripts/setup.sh

## Mission (legacy test-plan workflow — preserved for backward compatibility)

The legacy test-plan workflow (E28-S88) is preserved verbatim below so existing consumers continue to work. New invocations follow the seven-phase ADR-077 structure above; both paths converge on the same `rubrics/base/a11y.json` rubric and emit the same verdict via `verdict-resolver.sh`.

## Mission

You are creating a WCAG 2.1 accessibility test plan for the specified story or project context. The plan covers automated checks (axe-core, pa11y), manual test procedures (keyboard navigation, screen reader testing), ARIA audits, and remediation priorities. The output is written to `docs/test-artifacts/accessibility-report-{date}.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/accessibility-testing` workflow (E28-S88, Cluster 12, ADR-041). The step ordering, prompts, and output path are preserved from the legacy instructions.xml.

**Main context semantics (ADR-041):** This skill runs under `context: main` with full tool access. It reads project state (architecture, test plan, story) and produces an output document.

## Critical Rules

- A story key or project context MUST be available. If no story key is provided as an argument and no project context can be loaded, prompt: "Provide a story key or confirm project-level assessment."
- WCAG level MUST be explicitly declared by the user; no silent default. In YOLO mode the skill auto-selects AA and logs the auto-selection (per ADR-067 — auto-confirm sensible default), but in interactive mode the user MUST be prompted for A, AA, or AAA before proceeding (per ADR-066 inline-ask contract).
- Automated checks MUST cover EVERY identified page and component — no partial coverage. Cross-reference Step 1 targets against Step 2 test scenarios before proceeding to Step 3.
- Every finding row MUST include a specific WCAG success criterion reference in the form `X.Y.Z Criterion Name` (e.g., `1.4.3 Contrast Minimum`).
- Every Critical-severity finding MUST include at least one specific remediation recommendation. Reports with unremediated Critical findings MUST NOT be written.
- Output MUST be written to `docs/test-artifacts/accessibility-report-{date}.md` where `{date}` is today's date in YYYY-MM-DD format.
- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Scope

- Identify which pages and components to test from the story context or architecture.
- **Declare target WCAG level (mandatory user prompt — no silent default).** Prompt the user inline: `Select WCAG level: A, AA, or AAA`. Wait for the user's response before proceeding. The selected level propagates to Step 2 rule set configuration (`wcag2a` for A, `wcag2aa` for AA, `wcag2aaa` for AAA — Level AAA inherits A and AA criteria). YOLO mode handling: when YOLO mode is active, auto-select `AA` (the sensible default) without prompting and emit the log line `YOLO: auto-selected WCAG 2.1 Level AA` so the auto-selection is auditable in the report.
- Document user personas including users with disabilities (screen reader users, keyboard-only users, low vision users, cognitive disabilities).
- If architecture.md is available at `docs/planning-artifacts/architecture.md`, extract frontend components and routes.
- If story file is available, extract UI components from acceptance criteria and subtasks.

### Step 2 -- Automated Checks

- Load knowledge fragment: `knowledge/axe-core-patterns.md`
- Design axe-core or pa11y integration for each target page and component.
- **Automated test scenarios MUST cover every page and component identified in Step 1 — no partial coverage.** Build a coverage checklist that cross-references each Step 1 target (pages and components) against the test scenarios defined here. If any Step 1 target is not covered by at least one test scenario, expand the scenario set before proceeding.
- Configure rule sets matching the declared WCAG level from Step 1: `wcag2a` (Level A), `wcag2aa` (Level AA — inherits A), or `wcag2aaa` (Level AAA — inherits A and AA). Use the level captured by the Step 1 prompt; do not re-prompt or fall back to a default here.
- Include CI integration configuration for automated accessibility regression testing.

### Step 3 -- Manual Test Plan

- Define keyboard navigation testing procedure for all interactive elements.
- Define screen reader testing procedure (VoiceOver for macOS/iOS, NVDA for Windows).
- Define color contrast verification steps (4.5:1 for normal text, 3:1 for large text per WCAG 1.4.3).
- Document focus order expectations for each page.
- Load knowledge fragment: `knowledge/wcag-checks.md` for the manual testing checklist.

### Step 4 -- ARIA Audit

- Review ARIA roles and labels for correctness across all components.
- Verify focus management on modal dialogs, dropdowns, and dynamic content.
- Check live regions (aria-live) for dynamic content updates.
- Validate landmark regions (nav, main, aside, footer).
- Check for ARIA overuse -- semantic HTML should be preferred over ARIA attributes.

### Step 5 -- Remediation Priorities

- Categorize findings by impact level:
  - **Critical** -- blocks access entirely (no keyboard nav, missing alt text on functional images)
  - **High** -- significantly degrades experience (poor focus indicators, missing form labels)
  - **Medium** -- inconvenient but workaround exists (suboptimal heading hierarchy)
  - **Low** -- enhancement opportunity (decorative improvements)
- **Hard rule: every finding classified as Critical MUST include at least one specific remediation recommendation.** Findings tables that contain a Critical row with an empty or missing remediation cell MUST NOT be written to the report — fill the remediation before continuing to Step 6.
- **Hard rule: every finding row MUST include a specific WCAG success criterion reference in the format `X.Y.Z Criterion Name`** (e.g., `1.4.3 Contrast Minimum`, `2.1.1 Keyboard`, `4.1.2 Name, Role, Value`). Use the canonical WCAG 2.1 short title for the criterion.
- Findings table schema (use this column order):

  | # | Severity | Component / Page | Finding | WCAG Criterion | Remediation |

  The `WCAG Criterion` column is mandatory for every row; the `Remediation` column is mandatory for every Critical row and recommended for High rows.

### Step 6 -- Generate Report

- Generate accessibility report with:
  - Executive summary with the **explicitly declared WCAG level target** (A, AA, or AAA, as captured in Step 1) and overall compliance rating
  - Automated check results and configuration, plus the Step 2 coverage checklist confirming every Step 1 target is covered
  - Manual test procedures with pass/fail expectations
  - ARIA audit findings
  - Remediation priorities with impact categorization, rendered using the Step 5 schema (`# | Severity | Component / Page | Finding | WCAG Criterion | Remediation`)
  - **Per-finding WCAG success criterion reference** in the format `X.Y.Z Criterion Name` (e.g., `1.4.3 Contrast Minimum`) — the `WCAG Criterion` column is populated for every row.
- **Pre-write validation gate (hard rule):** before writing the report, scan the findings table and verify (a) every row has a non-empty `WCAG Criterion` cell formatted as `X.Y.Z Criterion Name`, and (b) every row whose `Severity` is `Critical` has a non-empty `Remediation` cell. If either check fails, do NOT write the report — return to Step 5 and fill the missing data.
- Write output to `docs/test-artifacts/accessibility-report-{date}.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/test-artifacts/accessibility-report-${DATE}.md`

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-a11y-testing/scripts/finalize.sh
