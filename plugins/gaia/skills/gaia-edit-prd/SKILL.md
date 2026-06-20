---
name: gaia-edit-prd
description: Edit an existing Product Requirements Document with cascade-aware downstream artifact detection, delegating PRD-authoring reasoning to the pm subagent (Derek) — planning skill. Use when the user wants to modify sections of an existing PRD while preserving consistency with architecture, epics, stories, and test plans.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-prd/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh pm all

## Mission

This skill orchestrates edits to an existing Product Requirements Document (PRD). PRD authoring and reasoning is delegated to the **pm** subagent (Derek), who evaluates change impact, validates consistency, and produces the updated artifact. The skill loads the current PRD, coordinates the multi-step edit flow, detects cascade impacts on downstream artifacts, and writes the output to the canonical path `.gaia/artifacts/planning-artifacts/prd.md`.

**Path resolution.** All PRD path references in this SKILL.md use the canonical location `.gaia/artifacts/planning-artifacts/prd.md` (flat) and `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded, per the sharded-fallback rule). The shard directory and adversarial-review artifact location use `.gaia/artifacts/planning-artifacts/` as well. Legacy projects continue to work via a positive-evidence-legacy fallback at the script layer (`scripts/setup.sh` three-tier idiom: `PRD_PATH` env-var override → legacy `docs/planning-artifacts/prd.md` only when that file exists AND `.gaia/artifacts/planning-artifacts/` does NOT → canonical default). When writing the PRD via the Write tool, target the canonical path; the legacy fallback is read-side only.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/2-planning/edit-prd` workflow. The step ordering, cascade-aware semantics, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A PRD MUST already exist before starting. Resolve via the sharded-fallback rule: first try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); if missing, fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout). If NEITHER exists, fail fast with "No PRD found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md — run /gaia-create-prd first."
- Preserve existing content not being changed — edits are surgical, not wholesale rewrites.
- Add a version note documenting what changed and why after every edit session.
- Update "Review Findings Incorporated" section after adversarial review (if triggered).
- PRD edit reasoning is delegated to the `pm` subagent (Derek) via native Claude Code subagent invocation — do NOT inline Derek's persona into this skill body. If the pm subagent is not available, fail with "pm subagent not available" error.
- Cascade impact assessment on downstream artifacts (architecture.md, epics-and-stories.md, test-plan.md) is MANDATORY after every edit — this is the key semantic preserved from the legacy workflow.

## Val Dispatch Contract

> Any Val invocation triggered by this skill (directly or via `/gaia-val-validate` delegation as part of cascade follow-ups) is dispatched with `model: claude-opus-4-7` and `effort: high` per the Val opus pin contract. Validation rigor is the framework-wide contract; the harness MUST NOT downgrade Val to a cheaper default model. **Non-opus mismatch guard:** if a test fixture or downstream override forces a non-opus model into the dispatch context, this skill MUST emit the canonical WARNING `Val dispatch on non-opus model — forcing opus` and force `model: claude-opus-4-7` before invoking Val. Silent degradation is forbidden.
>
> [Val opus-pin contract — see plugins/gaia/agents/validator.md §Val Operations]

## Steps

### Step 1 — Load PRD

- Resolve the PRD path via the sharded-fallback rule (Critical Rules above). Read the resolved PRD (flat `.gaia/artifacts/planning-artifacts/prd.md` OR sharded `.gaia/artifacts/planning-artifacts/prd/prd.md`).
- If neither path resolves, fail fast: "No PRD found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md — run /gaia-create-prd first."
- Display the current structure summary to the user: list all section headers, requirement count (FR-### and NFR-### IDs), and last version note date.

### Step 2 — Identify Changes

Delegate to the **pm** subagent (Derek) via `agents/pm` to evaluate the requested changes.

Ask the user:

1. What sections need to change?
2. Why are these changes needed?
3. Is this linked to a change request? If so, provide the CR ID.

Confirm scope of changes before proceeding. The pm subagent evaluates whether the requested changes are consistent with the existing PRD structure and flags any potential conflicts.

### Step 3 — Apply Edits

Delegate to the **pm** subagent (Derek) via `agents/pm` to apply the edits:

- Make requested changes while preserving unchanged content.
- Validate consistency with remaining sections — ensure cross-references between requirements, user journeys, and data requirements remain valid.
- Add version note at top of the PRD: date, changes made, reason, CR ID (if applicable).

### Step 4 — Save Updated PRD

Write the updated PRD to `.gaia/artifacts/planning-artifacts/prd.md` with the version note prepended.

### Step 5 — Adversarial Review

- Read `${CLAUDE_PLUGIN_ROOT}/knowledge/adversarial-triggers.yaml` to evaluate trigger rules. (This policy table ships inside the plugin under the `knowledge/` convention; the legacy v1 location `_gaia/_config/adversarial-triggers.yaml` is retired and no longer used.) Determine the current `change_type`: if invoked with a change_type context (e.g., from add-feature triage), use that value. If no context is available, infer from the change scope: minor edits map to "low-risk-enhancement", significant feature additions map to "feature".
- Look up the trigger rule for `change_type` + artifact "prd". If adversarial is false for this combination: skip adversarial review — mark "Review Findings Incorporated" as "Adversarial review not triggered — change type: {change_type} per adversarial-triggers.yaml". Proceed to Step 7.
- If adversarial is true: dispatch the **`adversarial-reviewer`** subagent (Sage) via the Agent tool to critique `.gaia/artifacts/planning-artifacts/prd.md`. **Before dispatching, run `mkdir -p .gaia/artifacts/planning-artifacts/adversarial/`** so the nested directory exists on first run. The dispatch prompt MUST specify (a) the artifact path to review and (b) the report output path `.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-{YYYY-MM-DD}.md` (adversarial joins the dated-snapshot pattern; use today's UTC date). Sage's persona at `plugins/gaia/agents/adversarial-reviewer.md` defines the review structure and severity vocabulary (CRITICAL/WARNING/INFO).
- When the subagent returns: verify `adversarial-review-prd-*.md` exists in `.gaia/artifacts/planning-artifacts/adversarial/` (legacy ungrouped `.gaia/artifacts/planning-artifacts/adversarial-review-prd-*.md` is accepted as a read-only fallback on older projects). Per the Mandatory Verdict Surfacing rule, display the returned envelope status + summary + findings list to the user before proceeding to Step 6.

### Step 6 — Incorporate Review Findings

- Read `.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-*.md` (legacy ungrouped `.gaia/artifacts/planning-artifacts/adversarial-review-prd-*.md` accepted as a read-only fallback) — extract critical and high severity findings.
- For each critical/high finding: add or refine requirement in the PRD.
- Update the "## Review Findings Incorporated" section — append new entries with amendment date.
- Write the updated PRD to `.gaia/artifacts/planning-artifacts/prd.md`.

### Step 7 — Architecture Cascade Check

This is the cascade-aware behavior preserved from the legacy edit-prd workflow — the key semantic that distinguishes editing from creation.

- Read `.gaia/artifacts/planning-artifacts/architecture.md` section headers.
- Compare PRD changes against architecture scope.
- Classify cascade impact:
  - **NONE:** Requirements-only changes — architecture unaffected.
  - **MINOR:** Architecture needs a section update — recommend `/gaia-edit-arch`.
  - **SIGNIFICANT:** New component/API/data model — recommend `/gaia-edit-arch` with adversarial review, then `/gaia-add-stories`.
- Report cascade assessment to user with recommended next command(s).

### Step 8 — Re-shard touched documents

Editing the PRD monolith MUST be followed by a re-shard so the per-section shards under `.gaia/artifacts/planning-artifacts/prd/` stay aligned with the monolith. This step honours the monolith-vs-shard sync contract — it is not optional unless the user passes `--monolith-only` for an explicit atomic same-PR edit (see below).

- If `$ARGUMENTS` contains `--monolith-only`: skip this step entirely. The user takes responsibility for re-running `/gaia-shard-doc` (or merging shards back to the monolith) before commit. Record `reshard: skipped (--monolith-only)` in the cascade summary.
- Otherwise, invoke `/gaia-shard-doc .gaia/artifacts/planning-artifacts/prd.md` (or the canonical monolith path resolved at runtime). The skill writes to `.gaia/artifacts/planning-artifacts/prd/` — `_preamble.md`, `01-*.md`, `02-*.md`, etc.
- After the re-shard returns, run `${CLAUDE_PLUGIN_ROOT}/scripts/check-monolith-shard-sync.sh` against the project root. The check is advisory (always exits 0). If it emits any `WARNING` lines naming `prd.md`, surface those WARNINGs to the user — they indicate the re-shard did not converge and the user must investigate before commit.
- Record `reshard: invoked (gaia-shard-doc)` in the cascade summary so the audit trail captures the invocation.

This step runs in YOLO mode automatically — re-sharding is deterministic and needs no user prompt. It is purely additive: skills that did not previously include this step continue to function for backwards compatibility.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-prd/scripts/finalize.sh

## Next Steps

- If cascade NONE: no further action required.
- If cascade MINOR: `/gaia-edit-arch` — Update architecture to match PRD changes.
- If cascade SIGNIFICANT: `/gaia-edit-arch` — Update architecture, then `/gaia-add-stories` to create new stories for added scope.

## Mode B Readiness

This skill is Mode B-ready. Under the team-orchestration mode, the authoring work that the prose above describes as inline subagent dispatch is instead routed through the shared planning bridge library at `${CLAUDE_PLUGIN_ROOT}/scripts/lib/planning-mode-b-bridge.sh`, which itself layers on the shared dispatch library `${CLAUDE_PLUGIN_ROOT}/scripts/lib/dispatch-teammate.sh`.

- **Spawn seam.** The pm subagent (Derek) authors the PRD edits. The orchestration calls `planning_spawn_subagent gaia:pm "gaia-edit-prd"` to obtain a persistent teammate handle. The clean-room gate in the shared library refuses any reviewer persona before a teammate is created.
- **Relay seam.** Each authoring turn is relayed verbatim to the team lead via `planning_relay_turn <handle> <payload>`, so the produced artifact structure is identical to the Mode A subagent-dispatch path — only the dispatch seam differs, never the authored output.
- **Shutdown seam.** At skill exit the orchestration calls `planning_shutdown`, which delegates to `shutdown_all` so no teammate pane is left orphaned.
- **Honest fallback.** Live Mode B is not exercisable in every Claude Code context. When the substrate is absent the bridge degrades to the existing Mode A foreground dispatch and emits a single `MODE_B_FALLBACK` token to stderr; the Mode A behaviour documented above remains the source of truth.
