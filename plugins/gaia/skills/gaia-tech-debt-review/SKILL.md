---
name: gaia-tech-debt-review
description: "DEPRECATED — This skill has been retired. The tech-debt review capability is now a phase of /gaia-triage-findings (it runs automatically after triage and emits the same rolling tech-debt-dashboard.md). Preserved as a thin one-sprint deprecation redirect."
argument-hint: "[story-key?]"
allowed-tools: [Read, Bash, Skill]
deprecated_aliases: [gaia-tech-debt-review]
deprecated_since: sprint-56
replaced_by: [gaia-triage-findings]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Deprecation Notice

> **This skill is retired.** Technical-debt review is no longer a separate command — it is a phase inside `/gaia-triage-findings`.
>
> The two skills always did one job in sequence: triage routes each finding into a story (writing a `[TRIAGED -> {key}]` marker), and tech-debt review then read those markers to score and age the debt. Having two commands where the second only continued the first's work was a lifecycle gap — operators following the sprint-close breadcrumbs never reached this standalone command, and a marker-glyph mismatch between the two silently broke the handoff.
>
> The full capability — TD-{N} stable-ID ledger, DESIGN/CODE/TEST/INFRASTRUCTURE classification, Impact+Risk−Effort scoring, sprint aging, STALE TARGET / UNASSIGNED / RESOLVED detection, duplicate merge, and the rolling `tech-debt-dashboard.md` with trend comparison — now runs as **Step 5b (Tech-Debt Phase)** of `/gaia-triage-findings`, immediately after triage. The dashboard output path is unchanged (`.gaia/artifacts/implementation-artifacts/tech-debt-dashboard.md`), so `/gaia-retro`'s tech-debt reflection reads it exactly as before.

## Mission

This skill is a thin deprecation redirect. It exists only to surface the retirement notice and point callers at the canonical replacement:

- To review technical debt → run **`/gaia-triage-findings`** (the tech-debt dashboard is produced as part of that run; pass `--all` for a full historical sweep, or a `story-key` to scope to one story).

## Steps

> **Note:** This redirect performs no writes. The tech-debt dashboard is produced by `/gaia-triage-findings` Step 5b; the deterministic helpers (`extract-findings.sh`, `td-id-assign.sh`, `triaged-marker.sh`, `action-items-write.sh`) live under that skill's tree.

### Step 1 — Display Deprecation Banner

Display:

```
/gaia-tech-debt-review is retired. The tech-debt review now runs automatically
as a phase of /gaia-triage-findings (Step 5b), which emits the same
tech-debt-dashboard.md. Run /gaia-triage-findings to review technical debt.
```

### Step 2 — Offer the Replacement

If the user confirms they want a tech-debt review, dispatch `/gaia-triage-findings` via the Skill tool, forwarding any `story-key` argument. Otherwise stop.
