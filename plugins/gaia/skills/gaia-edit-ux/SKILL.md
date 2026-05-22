---
name: gaia-edit-ux
description: Edit an existing UX design document with cascade-aware downstream artifact detection, delegating UX-authoring reasoning to the ux-designer subagent (Christy) — Cluster 5 planning skill. Use when the user wants to modify sections of an existing UX design while preserving consistency with architecture, epics, stories, and test plans.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
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

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-ux/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh ux-designer decision-log

## Mission

This skill orchestrates edits to an existing UX Design document. UX design authoring and reasoning is delegated to the **ux-designer** subagent (Christy), who evaluates change impact, validates consistency, and produces the updated artifact. The skill loads the current UX design, coordinates the multi-step edit flow, detects cascade impacts on downstream artifacts, and writes the output to the canonical post-ADR-111 path `.gaia/artifacts/planning-artifacts/ux-design.md`.

**Path resolution (AF-2026-05-21-14).** All UX path references in this SKILL.md use the canonical post-ADR-111 location `.gaia/artifacts/planning-artifacts/ux-design.md`. Pre-ADR-111 projects continue to work via a positive-evidence-legacy fallback at the script layer (`scripts/setup.sh` three-tier idiom: `UX_DESIGN_PATH` env-var override → legacy `docs/planning-artifacts/ux-design.md` only when that file exists AND `.gaia/artifacts/planning-artifacts/` does NOT → canonical default). When writing the UX design via the Write tool, target the canonical path; the pre-ADR-111 fallback is read-side only.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/2-planning/edit-ux-design` workflow (brief Cluster 5, story P5-S4 / E28-S43). The step ordering, cascade-aware semantics, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A UX design MUST already exist at `.gaia/artifacts/planning-artifacts/ux-design.md` before starting. If missing, fail fast with "No UX design found at .gaia/artifacts/planning-artifacts/ux-design.md — run /gaia-create-ux first."
- Preserve existing content not being changed — edits are surgical, not wholesale rewrites.
- Add a version note documenting what changed and why after every edit session.
- Update "Review Findings Incorporated" section after adversarial review (if triggered).
- UX design edit reasoning is delegated to the `ux-designer` subagent (Christy) via native Claude Code subagent invocation — do NOT inline Christy's persona into this skill body. If the ux-designer subagent (E28-S21) is not available, fail with "ux-designer subagent not available — install E28-S21" error.
- Cascade impact assessment on downstream artifacts (architecture.md, epics-and-stories.md, test-plan.md) is MANDATORY after every edit — this is the key semantic preserved from the legacy workflow.

## Val Dispatch Contract

> Any Val invocation triggered by this skill (directly or via `/gaia-val-validate` delegation as part of cascade follow-ups) is dispatched with `model: claude-opus-4-7` and `effort: high` per ADR-074 contract C2 (Val opus pin). Validation rigor is the framework-wide contract; the harness MUST NOT downgrade Val to a cheaper default model. **Non-opus mismatch guard (AC3):** if a test fixture or downstream override forces a non-opus model into the dispatch context, this skill MUST emit the canonical WARNING `Val dispatch on non-opus model — forcing opus per ADR-074 contract C2` and force `model: claude-opus-4-7` before invoking Val. Silent degradation is forbidden.
>
> [Val opus-pin contract — see plugins/gaia/agents/validator.md §Val Operations]

## Steps

### Step 1 — Load Existing UX Design

- Read the current UX design at `.gaia/artifacts/planning-artifacts/ux-design.md`.
- If the file does not exist, fail fast: "No UX design found at .gaia/artifacts/planning-artifacts/ux-design.md — run /gaia-create-ux first."
- Identify existing sections: personas, information architecture, wireframes, interaction patterns, accessibility.
- Identify existing Version History entries — note last version for auto-increment.
- Display current structure summary to user: section headers, persona count, wireframe count, current version.

### Step 2 — Identify Changes

Delegate to the **ux-designer** subagent (Christy) via `agents/ux-designer` to evaluate the requested changes.

Ask the user:

1. What sections need to change?
2. Why are these changes needed?
3. Is this linked to a change request? If so, provide the CR ID.

Classify change scope: MINOR (section update, text change) / SIGNIFICANT (new persona, new flow, navigation restructure) / BREAKING (complete redesign of major section).

Confirm scope of changes before proceeding. The ux-designer subagent evaluates whether the requested changes are consistent with the existing UX design structure and flags any potential conflicts.

### Step 3 — Apply Edits

Delegate to the **ux-designer** subagent (Christy) via `agents/ux-designer` to apply the edits:

- For each affected section: present current content, propose edits, wait for user confirmation or modification.
- Preserve all unchanged sections exactly as-is — no reordering, no reformatting, no content loss.
- Validate consistency between edited sections and remaining unchanged sections.
- If edits affect FR-to-Screen Mapping: verify traceability remains accurate.

### Step 4 — Add Version Note

- Append a new row to the Version History table:
  `| {date} | {change summary} | {driver} | {CR ID or reference} |`
- If no Version History section exists, create one:
  ```
  ## Version History
  | Date | Change | Reason | CR/Reference |
  |------|--------|--------|-------------|
  | {date} | {change summary} | {driver} | {CR ID or reference} |
  ```

### Step 5 — Save Updated UX Design

- Generate a diff summary showing exactly what changed.
- Write updated UX design to `.gaia/artifacts/planning-artifacts/ux-design.md` with all edits applied, unchanged sections preserved, and version note added.

### Step 6 — Adversarial Review

- Read `${CLAUDE_PLUGIN_ROOT}/knowledge/adversarial-triggers.yaml` to evaluate trigger rules. (This policy table ships inside the plugin under ADR-041's `knowledge/` convention; the legacy v1 location `_gaia/_config/adversarial-triggers.yaml` is retired and no longer used.) Determine the current `change_type`: if invoked with a change_type context (e.g., from add-feature triage), use that value. If no context is available, infer from the change scope: minor edits map to "low-risk-enhancement", significant feature additions map to "feature".
- Look up the trigger rule for `change_type` + artifact "ux-design". If adversarial is false for this combination: skip adversarial review — mark "Review Findings Incorporated" as "Adversarial review not triggered — change type: {change_type} per adversarial-triggers.yaml". Proceed to Step 8.
- If adversarial is true: dispatch the **`adversarial-reviewer`** subagent (Sage) via the Agent tool to critique `.gaia/artifacts/planning-artifacts/ux-design.md`. The dispatch prompt MUST specify (a) the artifact path to review and (b) the report output path `.gaia/artifacts/planning-artifacts/adversarial-review-ux-design-{YYYY-MM-DD}.md` (use today's UTC date). Sage's persona at `plugins/gaia/agents/adversarial-reviewer.md` defines the review structure and UX-specific lenses (accessibility, empty/loading/error states, adversarial users, localization).
- When the subagent returns: verify `adversarial-review-ux-design-*.md` exists in `.gaia/artifacts/planning-artifacts/`. Per ADR-063, display the returned ADR-037 envelope (status + summary + findings) to the user.

### Step 7 — Incorporate Review Findings

- Read `.gaia/artifacts/planning-artifacts/adversarial-review-ux-design-*.md` — extract critical and high severity findings.
- For each critical/high finding: incorporate into UX design document.
- Update the "## Review Findings Incorporated" section — append new entries with amendment date.
- Write the updated UX design to `.gaia/artifacts/planning-artifacts/ux-design.md`.

### Step 8 — Cascade Impact Check

This is the cascade-aware behavior preserved from the legacy edit-ux-design workflow — the key semantic that distinguishes editing from creation.

- Read `.gaia/artifacts/planning-artifacts/architecture.md` section headers.
- Compare UX design changes against architecture scope and downstream artifacts (epics-and-stories.md, test-plan.md).
- Classify cascade impact:
  - **NONE:** UX-only changes — architecture and stories unaffected.
  - **MINOR:** Architecture needs a section update — recommend `/gaia-edit-arch`.
  - **SIGNIFICANT:** New components or interaction patterns affecting architecture — recommend `/gaia-edit-arch` with adversarial review, then `/gaia-add-stories`.
- Report cascade assessment to user with recommended next command(s).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-ux/scripts/finalize.sh

## Next Steps

- If cascade NONE: no further action required.
- If cascade MINOR: `/gaia-edit-arch` — Update architecture to match UX design changes.
- If cascade SIGNIFICANT: `/gaia-edit-arch` — Update architecture, then `/gaia-add-stories` to create new stories for added scope.
