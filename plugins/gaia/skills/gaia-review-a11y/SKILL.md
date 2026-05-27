---
name: gaia-review-a11y
description: Pre-merge accessibility gate — reviews code and UI for WCAG 2.1 compliance (semantic HTML, ARIA, keyboard navigation, color contrast, screen reader support). Conditional gate that fires only when compliance.ui_present is true; skipped neutrally otherwise. Produces a verdict via verdict-resolver.sh per ADR-077 seven-phase structure. Use when "review accessibility" or /gaia-review-a11y.
argument-hint: "[target — file, directory, or component name]"
command: /gaia-review-a11y
phase: implementation
verdict_producing: true
conditional: true
trigger: compliance.ui_present
context: fork
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
orchestration_class: reviewer
---

## ADR-077 Mission (E69-S2)

You are the **pre-merge a11y gate** for UI-bearing projects. The gate is conditional — `/gaia-review-all` includes this gate only when `compliance.ui_present: true` is resolved from the project's `project-config.yaml` (FR-RSV2-44). When `compliance.ui_present` is `false` or absent, the composite-verdict aggregator is invoked with `--skip-a11y "compliance.ui_present: false"` and this skill is not executed.

This skill is the **implementation-phase** sibling of the three-phase a11y skill family (FR-RSV2-25):

- `/gaia-validate-design-a11y` — planning (agent: Christy)
- `/gaia-review-a11y` — pre-merge gate (this skill, conditional, agent: Christy)
- `/gaia-test-a11y` — post-deploy smoke (agent: Sable)

All three skills load the same rubric layer (`rubrics/base/a11y.json`) via the layered rubric loader (E68-S2 / ADR-079). This skill is verdict-producing and follows the seven-phase structure mandated by ADR-077.

### Phase 1 — Setup

- Resolve `compliance.ui_present` via `resolve-config.sh`. If the value is not `true`, exit early with `SKIPPED — compliance.ui_present is not true` (the orchestrator at `/gaia-review-all` performs this check via `--skip-a11y`; this guard is defense-in-depth).
- Load the layered rubric via `${CLAUDE_PLUGIN_ROOT}/scripts/rubric-loader.sh --skill a11y`. On non-zero exit (missing `rubrics/base/a11y.json`, schema validation failure), HALT with the loader's stderr — do NOT silently fall back to empty rules (AC-EC3).

### Phase 2 — Discovery

- Resolve the review target from `$ARGUMENTS` or default to the diff under review.
- Read the target file(s) — if a directory is given, recursively read all source files under it.

### Phase 3A — Analysis (pre-merge implementation-time WCAG checks)

- **Semantic HTML (WCAG 1.3.1, 4.1.2):** verify interactive elements use the proper semantic HTML element (`<button>`, `<a>`, `<nav>`, `<main>`, `<article>`, etc.) rather than `<div>` + `onclick`. Verify form inputs are associated with labels.
- **ARIA usage (WAI-ARIA Authoring Practices):** verify ARIA roles, states, and labels are present and consistent — `aria-label`, `aria-labelledby`, `aria-describedby`, `role`, `aria-expanded`, `aria-controls`, `aria-live`. Flag conflicting roles (e.g., `<button role=link>`).
- **Keyboard handlers (WCAG 2.1.1, 2.1.2, 2.4.7):** verify every interactive component is reachable and operable via Tab/Shift+Tab/Enter/Space and arrow keys where applicable. Verify focus-visible styles, focus traps in modals, and Escape-to-dismiss.
- **Color contrast in CSS / tokens (WCAG 1.4.3, 1.4.11):** body text ≥ 4.5:1, large text ≥ 3:1, UI components ≥ 3:1. Inspect token definitions and CSS variables.
- **Screen reader support (WCAG 1.1.1, 2.4.1):** verify `alt` text on meaningful images, skip-links on pages with repeated nav blocks, `aria-live` regions for asynchronous updates.
- For every finding, cite the specific WCAG 2.1 criterion with conformance level (A/AA/AAA) and the matching rubric rule ID from the loaded rubric.

### Phase 3B — Cross-checks

- Cross-reference the diff against the project's component library and shared a11y patterns (if any).
- Verify changes do not regress existing a11y guarantees (no new `outline: none` without alternative focus style, no new color-only meaning, no new modals without focus traps).

### Phase 4 — Findings

- Aggregate findings into the canonical schema (severity is rubric-driven):

  | Severity | Category | File | Finding | WCAG Criterion | Remediation |

### Phase 5 — Verdict

- Resolve the composite verdict via the deterministic resolver:

  ```bash
  !${CLAUDE_PLUGIN_ROOT}/scripts/review-common/verdict-resolver.sh --findings <findings.json>
  ```

- The resolver emits `APPROVE | REQUEST_CHANGES | BLOCKED`. The skill MUST NOT recompute the verdict by hand (ADR-077, ADR-042).

### Phase 6 — Report

- Write the report to `.gaia/artifacts/test-artifacts/accessibility-review-{date}.md` (preserved verbatim from the legacy task path for downstream consumers — traceability, deploy checklist, run-all-reviews aggregation). If a same-day file exists, append a numeric suffix (`-2`, `-3`).

### Phase 7 — Exit

- Emit the verdict on stdout for the caller (`/gaia-review-all` composite aggregator or direct user invocation).
- Exit 0 on success regardless of verdict; exit non-zero only on infrastructure failure (rubric load failed, target unresolvable).

## Agent Wiring

Per the E69-S2 wiring-table delta (added to ADR-077 wiring table), this skill resolves to **Christy (UX Designer)** via:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh --skill gaia-review-a11y
# {"agent_id":"christy","sidecar_path":".gaia/memory/christy-sidecar.md"}
```

Pre-merge a11y review is a UX-design concern, consistent with `gaia-validate-design-a11y -> Christy`. Sable owns post-deploy a11y _testing_, not pre-merge a11y _review_.

## Conditional-trigger contract

- The orchestrator `/gaia-review-all` reads `compliance.ui_present` via `resolve-config.sh` and:
  - includes this gate (calls the verdict-resolver path) when `compliance.ui_present: true`;
  - invokes the composite aggregator with `--skip-a11y "compliance.ui_present: false"` (or `--skip-a11y "compliance section absent"` per AC-EC2) when the value is false / absent.
- A skipped gate contributes neutrally to the composite verdict per ADR-082; it does NOT fail the composite (FR-RSV2-44).

---

## Legacy Task Body (preserved for backward compatibility)

The original task body (pre-ADR-077) is preserved below verbatim so existing consumers and runbooks still work. New invocations follow the seven-phase structure above; both paths converge on the same `rubrics/base/a11y.json` rubric and emit the same verdict via `verdict-resolver.sh`.

## Mission

You are performing a **WCAG 2.1 accessibility review** on the target the user supplies (a file, directory, or named component). You evaluate the target across four categories — semantic HTML + ARIA, keyboard + focus, visual + screen reader — and produce a markdown findings report where every finding cites the specific WCAG 2.1 success criterion ID, its conformance level, a severity rating, and concrete remediation guidance.

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/review-accessibility.xml` task (47 lines). Per **ADR-041** (Native Execution Model) and **ADR-042** (Scripts-over-LLM for Deterministic Operations), the legacy task-runner engine is retired and this skill runs natively under the Claude Code primitives model. Deterministic report-header generation is delegated to the shared foundation script `template-header.sh` (E28-S16) rather than re-prosed per skill.

## Critical Rules

- **Check ARIA attributes and roles.** Every interactive component must declare a role, label, and state appropriate to its behavior.
- **Verify keyboard navigation support.** Every interactive element must be reachable and operable by keyboard alone — no pointer-only affordances.
- **Evaluate color contrast and screen reader support.** Text must meet WCAG 1.4.3 ratios (4.5:1 body / 3:1 large) and be announced correctly by screen readers.
- Every finding MUST cite a specific WCAG 2.1 success criterion (e.g., `1.1.1 Non-text Content`, `2.1.1 Keyboard`, `1.4.3 Contrast (Minimum)`) and its conformance level (A/AA/AAA). Findings without a criterion reference are not acceptable.
- The review is READ-ONLY on the target — do NOT refactor the target code. Findings go in the report artifact.

## Inputs

- `$ARGUMENTS`: optional target (file, directory, or component name). If omitted, ask the user inline: "Which code or component should I review for accessibility?"

## Steps

### Step 1 — Scope

- If `$ARGUMENTS` is non-empty, use it as the target. Otherwise ask the user inline for the code or component to review (preserves the legacy Step 1 "Ask user for code/component to review" behavior — AC-EC4).
- Read the target file(s). If a directory is given, recursively read all source files under it.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-a11y 1 a11y_scope="$A11Y_SCOPE" report_path="$REPORT_PATH" wcag_level="$WCAG_LEVEL" stage=scope-resolved`

### Step 2 — Semantic HTML and ARIA

- Check that interactive elements use the proper semantic HTML element (`<button>`, `<a>`, `<nav>`, `<main>`, `<article>`, etc.) rather than `<div>` + `onclick`.
- Verify ARIA attributes, roles, states, and labels — `aria-label`, `aria-labelledby`, `aria-describedby`, `role`, `aria-expanded`, `aria-controls`, `aria-live`, etc.
- Check for `alt` text on images (WCAG 1.1.1) and labels on form inputs (WCAG 1.3.1, 3.3.2, 4.1.2).
- For every finding, cite the specific WCAG 2.1 criterion — e.g., `1.1.1 Non-text Content (A)`, `1.3.1 Info and Relationships (A)`, `4.1.2 Name, Role, Value (A)` — and note its conformance level.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-a11y 2 a11y_scope="$A11Y_SCOPE" report_path="$REPORT_PATH" wcag_level="$WCAG_LEVEL" stage=semantic-aria-reviewed`

### Step 3 — Keyboard and Focus

- Verify every interactive component is keyboard-reachable and operable with `Tab`, `Shift+Tab`, `Enter`, `Space`, and arrow keys where applicable.
- Check focus management — focus visible at all times (WCAG 2.4.7), focus trapped inside modals, focus returned on close.
- Check tab order follows logical reading order (WCAG 2.4.3).
- Verify skip-navigation links are present on pages with repeated blocks (WCAG 2.4.1).
- For every finding, cite the specific WCAG 2.1 criterion — e.g., `2.1.1 Keyboard (A)`, `2.4.3 Focus Order (A)`, `2.4.1 Bypass Blocks (A)`, `2.4.7 Focus Visible (AA)` — and note its conformance level.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-a11y 3 a11y_scope="$A11Y_SCOPE" report_path="$REPORT_PATH" wcag_level="$WCAG_LEVEL" stage=keyboard-focus-reviewed`

### Step 4 — Visual and Screen Reader

- Measure color contrast ratios: body text ≥ 4.5:1, large text (≥ 18pt or 14pt bold) ≥ 3:1 — WCAG 1.4.3.
- Check screen reader compatibility: announced labels match visible labels, reading order is logical, dynamic content uses `aria-live` appropriately.
- Verify text scaling: content must remain usable when scaled up to 200% (WCAG 1.4.4) and 400% (WCAG 1.4.10 Reflow).
- Confirm no information is conveyed by color alone — WCAG 1.4.1 and 1.3.3.
- For every finding, cite the specific WCAG 2.1 criterion — e.g., `1.4.3 Contrast (Minimum) (AA)`, `1.4.4 Resize Text (AA)`, `1.3.3 Sensory Characteristics (A)`, `1.4.1 Use of Color (A)` — and note its conformance level.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-a11y 4 a11y_scope="$A11Y_SCOPE" report_path="$REPORT_PATH" wcag_level="$WCAG_LEVEL" stage=visual-sr-reviewed`

### Step 5 — Generate Report

Invoke the shared foundation script to emit the deterministic artifact header (ADR-042):

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/template-header.sh --template accessibility-review --workflow gaia-review-a11y
```

If `template-header.sh` is missing or non-executable (AC-EC7), degrade gracefully to an inline prose header (`# Accessibility Review — {date}`), log a warning, and still write a valid report.

Write the report to the following path (preserved verbatim from the legacy task for downstream consumers — traceability, deploy checklist, run-all-reviews aggregation — AC4):

```
{test_artifacts}/accessibility-review-{date}.md
```

If the file already exists for the same day (AC-EC3), write to a suffix-incremented filename (`accessibility-review-{date}-2.md`, `-3.md`, ...) to match the legacy task's safe behavior and avoid clobbering a prior same-day run.

**Output override (Test05 F-017).** The default path above is preserved for downstream aggregation. To redirect the report (e.g. into a per-story `reviews/` dir, or a CI-scoped location), pass `--output <path>` in `$ARGUMENTS` or set `GAIA_A11Y_REPORT_PATH`; an explicit override wins over the default and skips the same-day suffix logic (the caller owns collision handling). Document the resolution precedence: `--output` arg > `GAIA_A11Y_REPORT_PATH` env > the default `{test_artifacts}/accessibility-review-{date}.md`.

The report is organised by category (semantic HTML, ARIA, keyboard, focus, visual, screen reader). Every finding row uses this exact schema:

| WCAG Criterion ID | Criterion Name | Conformance Level (A/AA/AAA) | Severity (Critical/High/Medium/Low) | Finding Description | Remediation Guidance |

If the target directory is empty or the target resolves to no files (AC-EC6), exit with `No review target resolved` and do NOT write an empty report file — mirrors the legacy task's behavior on empty fixtures.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-a11y 5 a11y_scope="$A11Y_SCOPE" report_path="$REPORT_PATH" wcag_level="$WCAG_LEVEL" stage=report-generated --paths "$REPORT_PATH"`

## References

- Source: `_gaia/core/tasks/review-accessibility.xml` (legacy 47-line task body — ported per ADR-041 + ADR-042).
- ADR-041: Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042: Scripts-over-LLM for Deterministic Operations.
- ADR-048: Engine Deletion as Program-Closing Action — legacy task coexists with this skill until program close.
- FR-323: Skill Conversion — slash-command identity preserved.
- NFR-053: Full v1.127.2-rc.1 Feature Parity.

## Next Step

After an accessibility review run, the legacy next-step hint pointed to `/gaia-create-arch` (Phase 3 onboarding). Preserved here so downstream onboarding does not regress.
