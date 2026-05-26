---
name: gaia-history
description: "Display a read-only project-history dashboard — velocity trend across the last N closed sprints, estimate accuracy (estimated points vs measured agent throughput derived from lifecycle-events), and recurring-finding patterns from retros. Reads sprint-archive yamls, lifecycle-events.jsonl, and retro docs (all read-only). Use when 'show project history', 'velocity trend', or /gaia-history."
argument-hint: "[--last-n N?]"
allowed-tools: [Read, Bash]
version: "1.0.0"
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-history/scripts/setup.sh

## Mission

Display a read-only history dashboard for the project. The skill surfaces three views (E106-S1 AC5), all derived from data that already exists on disk:

1. **Velocity trend** across the last N closed sprints — read from the sprint-archive yamls under `.gaia/artifacts/implementation-artifacts/sprint-archive/`.
2. **Estimate accuracy** — estimated story points vs. *measured* agent throughput. The measured figure (median minutes/story and minutes/point) is DERIVED from `state_transition` events in `.gaia/memory/lifecycle-events.jsonl` by `throughput-telemetry.sh` (there is NO `duration` field — wall-clock is derived by differencing consecutive transition timestamps).
3. **Recurring-finding patterns** — themes that appear in the "What Could Improve" sections of more than one retro.

This is the read-only consumer of the telemetry-first foundation (ADR-128): `throughput-telemetry.sh` derives the medians; `/gaia-history` renders them alongside trend and retro patterns. E106-S2 (dual-track estimation) and E106-S3 (agent-native SM capacity check) consume the same derivation layer.

This skill is modeled on the other read-only dashboards (`/gaia-sprint-status`, `/gaia-epic-status`). Per the story's technical notes, the deterministic mechanics live in the helper scripts (ADR-042 scripts-over-LLM); the skill body only invokes them and relays output.

## Critical Rules

- **READ-ONLY (AC6).** This skill MUST NOT write, edit, or delete any artifact, config, or state file *under inspection* (sprint yamls, the lifecycle-events log content, retros). `allowed-tools` is `[Read, Bash]` — there is no `Write`/`Edit`. The Bash invocations call only read-only renderers (`history-render.sh`, `throughput-telemetry.sh`), which themselves write nothing and emit only on stdout. The framework's own orchestration telemetry (the `setup.sh`/`finalize.sh` checkpoint write + lifecycle-event append) is exempt plumbing — identical to the cited read-only peers `/gaia-sprint-status` and `/gaia-epic-status`.
- Wall-clock is DERIVED, never read from a field. Do not look for a `duration` field on lifecycle events — difference consecutive `state_transition` timestamps (handled inside `throughput-telemetry.sh`).
- The dashboard degrades gracefully: with no closed sprints / no events / no retros, render the corresponding empty-history placeholder rather than erroring.
- Median (not mean) is used for throughput to resist outliers (one stalled story must not skew the figure).

## Steps

### Step 1 — Render the history dashboard

Run the renderer, passing the canonical runtime paths:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/gaia-history/scripts/history-render.sh" \
  --archive-dir "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/sprint-archive" \
  --retros-dir "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" \
  --events "${CLAUDE_PROJECT_ROOT}/.gaia/memory/lifecycle-events.jsonl" \
  --sprint-yaml "${CLAUDE_PROJECT_ROOT}/.gaia/state/sprint-status.yaml" \
  ${ARG_LAST_N:+--last-n "$ARG_LAST_N"}
```

`history-render.sh` emits a Markdown report with three sections (Velocity Trend, Estimate Accuracy, Recurring Finding Patterns). Relay its stdout to the user verbatim.

### Step 2 — Surface the measured-throughput caveat

After rendering, remind the user that the measured throughput is agent-native: it reflects wall-clock between story state transitions (how fast the LLM agent actually worked), not points-per-calendar-day. A stable minutes/point across sprints is the signal that estimates track measured throughput (ADR-128).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-history/scripts/finalize.sh

## Refs

- **ADR-128** — agent-native sprint model (telemetry-first estimation foundation).
- **ADR-042** — scripts-over-LLM (derivation math lives in shell/awk).
- **FR-549, FR-550** — allocated for E106-S1 (PRD shard pending; allocated in epics-and-stories.md).
- **E106-S1** — this story (throughput-telemetry derivation layer + /gaia-history).
- **E106-S2 / E106-S3** — downstream consumers of the derivation layer.
- Read-only dashboard peers: `/gaia-sprint-status`, `/gaia-epic-status`.
