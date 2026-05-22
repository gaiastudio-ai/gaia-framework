---
name: gaia-validate-design-a11y
description: Planning-phase accessibility validation against design artifacts (Figma, wireframes, UX docs). Verifies WCAG 2.1 design-time concerns — color contrast, semantic structure, keyboard navigation design, ARIA landmark planning — before implementation begins. Produces a verdict via verdict-resolver.sh per ADR-077 seven-phase structure. Use when "design accessibility review" or /gaia-validate-design-a11y.
argument-hint: "[design-target — Figma URL, design doc path, or component name]"
command: /gaia-validate-design-a11y
phase: planning
verdict_producing: true
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: reviewer
---

## Mission

You are performing a **planning-phase accessibility validation** on the supplied design target (Figma frame, wireframe, design doc, or named component). The review evaluates design-time WCAG 2.1 concerns — color contrast, semantic structure, keyboard navigation design, ARIA landmark planning — and produces a verdict (`APPROVE | REQUEST_CHANGES | BLOCKED`) via the deterministic resolver.

This is the **planning** sibling of the three-phase a11y skill family (FR-RSV2-25):

- `/gaia-validate-design-a11y` — planning (this skill, agent: Christy)
- `/gaia-review-a11y` — pre-merge gate (conditional on `compliance.ui_present: true`, agent: Christy)
- `/gaia-test-a11y` — post-deploy smoke (agent: Sable)

All three skills load the same rubric layer (`rubrics/base/a11y.json`) via the layered rubric loader (E68-S2 / ADR-079). This skill is verdict-producing and follows the seven-phase structure mandated by ADR-077.

## Critical Rules

- The skill is verdict-producing — every run MUST emit a single verdict via `verdict-resolver.sh` (`APPROVE | REQUEST_CHANGES | BLOCKED`).
- Findings MUST cite a specific WCAG 2.1 success criterion (e.g., `1.4.3 Contrast (Minimum)`, `2.1.1 Keyboard`) with conformance level (A/AA/AAA).
- The rubric is loaded via `rubric-loader.sh --skill a11y` — the skill MUST NOT carry hardcoded severity rules. If the rubric load fails (missing `rubrics/base/a11y.json`), the skill exits with a clear error referencing the missing file (AC-EC3).
- This is a **planning-phase** review — the target is a design artifact, not implementation code. Do NOT inspect runtime code; that is the pre-merge gate (`/gaia-review-a11y`) and post-deploy smoke (`/gaia-test-a11y`) scope.

## Inputs

- `$ARGUMENTS`: optional design target (Figma URL, design doc path, or component name). If omitted, ask the user inline: "Which design artifact should I validate for accessibility?"

## Steps (ADR-077 seven-phase structure)

### Phase 1 — Setup

<!-- Guard added by AF-2026-05-17-9 -->
- Resolve `compliance.ui_present` via `resolve-config.sh`. If the value is not `true`, exit early with `SKIPPED — compliance.ui_present is not true` (the orchestrator at `/gaia-review-all` performs this check via `--skip-a11y`; this guard is defense-in-depth). Mirrors `/gaia-review-a11y` L29 for three-phase a11y family gating consistency (FR-RSV2-44, E69-S2).
- Resolve the design target from `$ARGUMENTS` or prompt the user inline.
- Load the layered rubric:

  ```bash
  !${CLAUDE_PLUGIN_ROOT}/scripts/rubric-loader.sh --skill a11y
  ```

  If the loader exits non-zero (missing base rubric, schema validation failure), HALT with the loader's stderr — do NOT silently fall back to empty rules.

### Phase 2 — Discovery

- Read the design artifact (Figma export, design doc, or component spec).
- If the target is a Figma URL, retrieve the design context via the Figma MCP server when available; degrade gracefully to text-only when unavailable.
- Identify all interactive components, color palettes, text sizes, and navigation flows in the design.

### Phase 3A — Analysis (design-time WCAG checks)

- **Color contrast (WCAG 1.4.3, 1.4.11):** verify body-text contrast ≥ 4.5:1, large-text ≥ 3:1, UI-component contrast ≥ 3:1 against adjacent colors. Inspect every theme variant (light/dark, hover/focus states).
- **Semantic structure (WCAG 1.3.1, 2.4.6):** verify heading hierarchy is continuous (no level skips), landmark regions are planned (nav, main, aside, footer), and headings communicate page structure rather than visual size.
- **Keyboard navigation design (WCAG 2.1.1, 2.4.3, 2.4.7):** verify every interactive component has a planned keyboard activation contract, tab order follows logical reading order, and focus-visible styles are designed (not just `outline: none`).
- **ARIA landmark planning (WCAG 1.3.1, 4.1.2):** verify ARIA landmarks are planned for each major region; avoid ARIA where a native element fits.
- **Color-alone meaning (WCAG 1.4.1):** verify status / error / success information is paired with a redundant cue (icon, label, shape) — not color alone.
- For every finding, cite the specific WCAG 2.1 criterion with conformance level (A/AA/AAA) and the matching rubric rule ID from the loaded rubric.

### Phase 3B — Cross-checks

- Cross-reference the design's planned components against the project's component library (if any) to flag duplication or divergence from established a11y patterns.
- Verify the design accounts for assistive-tech personas (screen reader, keyboard-only, low vision, cognitive disabilities).

### Phase 4 — Findings

- Aggregate findings into the canonical schema:

  | Severity | Category | Finding | WCAG Criterion | Remediation |

- Severity is derived from the rubric (`rubrics/base/a11y.json`); the skill does NOT hand-pick severities outside the rubric.

### Phase 5 — Verdict

- Resolve the composite verdict via the deterministic resolver:

  ```bash
  !${CLAUDE_PLUGIN_ROOT}/scripts/review-common/verdict-resolver.sh --findings <findings.json>
  ```

- The resolver emits `APPROVE | REQUEST_CHANGES | BLOCKED`. The skill MUST NOT recompute the verdict by hand — the resolver is the single source of truth (ADR-077, ADR-042).

### Phase 6 — Report

- Write the report to `.gaia/artifacts/test-artifacts/design-a11y-review-{date}.md`.
- The report includes the verdict, the findings table, the rubric source (path of merged rubric), and the design target reference.

### Phase 7 — Exit

- Emit the verdict on stdout for the caller (typically `/gaia-validate-design` orchestrator or direct user invocation).
- Exit 0 on success regardless of verdict (verdict semantics are carried in the output, not the exit code).
- Exit non-zero only on infrastructure failure (rubric load failed, target unresolvable).

## Agent Wiring

Per ADR-077 wiring table, this skill resolves to **Christy (UX Designer)** via:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh --skill gaia-validate-design-a11y
# {"agent_id":"christy","sidecar_path":"_memory/christy-sidecar.md"}
```

Design-time a11y is a UX-design concern; Christy owns the design fidelity review.

## References

- ADR-077 — Verdict-producing skill seven-phase structure + agent-overlay wiring table.
- ADR-079 — Layered rubric loading (base + regimes + domain + project).
- FR-RSV2-25 — "The three phases share rubrics but have distinct triggers and verdicts."
- E68-S3 — Six base rubrics shipped under `rubrics/base/` (including `a11y.json`).
- E69-S1 — Slash-command rename map (canonical `/gaia-validate-design-a11y`).
- E66-S1 — `agent-overlay.sh` wiring resolver.
- E66-S3 — Composite verdict aggregator (ADR-082) consumes this skill's verdict in the `/gaia-validate-design` composite (planning phase).

## Next Step

After a passing planning-phase a11y verdict, proceed to architecture review (`/gaia-review-arch`) and implementation. The pre-merge gate `/gaia-review-a11y` will fire automatically when `compliance.ui_present: true` and `/gaia-review-all` runs.
