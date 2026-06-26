---
name: gaia-sprint-close
description: "Close the active sprint — write status: closed + closed_at to sprint-status.yaml, archive the yaml under .gaia/artifacts/implementation-artifacts/sprint-archive/, and emit a sprint_closed lifecycle event. This skill is the sanctioned boundary-write replacement for manual `yq -i` edits on sprint-status.yaml. Use when 'close the sprint' or /gaia-sprint-close."
allowed-tools: [Bash, Read]
version: "1.0.0"
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-close/scripts/setup.sh

## Mission

Mark the active sprint as closed and emit the close lifecycle artifacts. The skill performs four ordered actions inside `scripts/close.sh` (the action script). A separate `scripts/finalize.sh` is the generic plugin lifecycle hook that writes the checkpoint and emits the `workflow_complete` event:

1. **Pre-conditions** — refuse unless a retro doc exists for the sprint, all stories are `done` (or the operator explicitly opts into `--force-with-rollover`), and the sprint is not already closed.
2. **Yaml write** — `yq -i '.status = "closed" | .closed_at = "<ISO>"'` on `sprint-status.yaml`.
3. **Archive** — copy the closed yaml to `.gaia/artifacts/implementation-artifacts/sprint-archive/{sprint_id}-closed-{YYYY-MM-DD}.yaml`.
4. **Lifecycle event** — append a `sprint_closed` event to `.gaia/memory/lifecycle-events.jsonl` via the shared `lifecycle-event.sh` helper.

This skill is the GAIA-native replacement for manual sprint-boundary writes. The historical restriction on direct `yq -i` against `sprint-status.yaml` (per `feedback_sprint_boundary_yaml_write.md`) is lifted **only** inside this skill's `close.sh` — that helper IS the sanctioned boundary-write path going forward.

## Prerequisites

The close ceremony's hard pre-conditions are non-obvious — driving the
deterministic helpers without these in place hits cryptic gates. Surface
them explicitly here so they are auditable at a glance:

1. **A retrospective document at the EXACT path.** The skill globs
   `.gaia/artifacts/implementation-artifacts/retrospective-{sprint_id}-*.md`
   (both `retrospective-{id}-{date}.md` and the
   `retrospective-{id}-{date}-{HHMM}.md` clobber-avoidance variant emitted by
   `/gaia-retro` are accepted). When the glob is empty the skill refuses with
   `error: retro doc not found for {sprint_id}; run /gaia-retro first`.
   Some projects also use the per-sprint subdir layout
   `…/retrospective/retrospective-{sprint_id}-*.md` — keep the file in one of
   the two locations the close.sh scanner walks.

2. **A Val-dispatch sentinel with the canonical payload schema.** Step 3a
   unconditionally requires sentinel-verified evidence that
   `/gaia-sprint-review` ran and produced a verdict (regardless of whether the
   sprint is `active` or `review`). The sentinel MUST exist at one of:
   - `.gaia/memory/checkpoints/sprint-review-{sprint_id}-val-dispatched.json`
     (dispatch checkpoint, written by `/gaia-sprint-review`
     Step 3 Track A Val dispatch); OR
   - `.gaia/memory/checkpoints/val-envelope-<sha256(sprint_id):0:16>.json`
     (envelope sentinel, written by the orchestrator-side writer).

   Payload schema (REQUIRED fields — strict; the close ceremony refuses on
   missing fields and on a wrong `agent` value):

   ```json
   {
     "agent": "val",
     "status": "PASSED",
     "summary": "<short prose>",
     "findings": []
   }
   ```

   The `agent` field MUST be the literal string `"val"` (lowercase). The
   `status` enum is `PASSED | FAILED | UNVERIFIED`. The recorded verdict can
   also be read back via `${SCRIPTS_DIR}/review-gate.sh status --sprint <id>
   --gate sprint-review` (the ledger mirror of the sentinel verdict). On
   `PASSED` the transition proceeds; on `UNVERIFIED` the skill reads the
   `review_justification` block (requires both `pm_signoff` and
   `val_validation`); on `FAILED` the skill refuses and routes the operator
   to `/gaia-correct-course`; on missing sentinel the skill refuses and
   routes to `/gaia-sprint-review`.

3. **All stories at `status: done`** (or the operator explicitly opts into
   `--force-with-rollover <key1,key2,...>` listing exactly the non-done
   stories — no extras, no missing).

4. **The sprint is not already closed.** Step 2 is idempotent: re-running
   on an already-closed sprint emits a warning and exits 0 with no yaml
   mutation, no new archive copy, and no new lifecycle event.

The orchestrated `/gaia-sprint-review` + `/gaia-retro` skills set these
prerequisites up automatically — the explicit list above is for operators
hand-driving the deterministic scripts.

## Critical Rules

- The skill MUST be idempotent on already-closed sprints — re-running emits a warning and exits 0 with no yaml mutation, no new archive copy, and no new lifecycle event.
- The skill MUST refuse with non-zero exit if the retro doc is absent (glob `.gaia/artifacts/implementation-artifacts/retrospective-{sprint_id}-*.md` — accepts both `retrospective-{id}-{date}.md` and `retrospective-{id}-{date}-{HHMM}.md` clobber-avoidance variants from `/gaia-retro`).
- The skill MUST refuse with non-zero exit if any story is not in `done` state, unless `--force-with-rollover <keys>` lists exactly the non-done stories.
- The archive copy MUST be created AFTER the yaml write so the archived snapshot reflects the closed state.
- Lifecycle event payload uses the nested-`data` schema enforced by `lifecycle-event.sh`. The JSONL line shape is `{timestamp, event_type:"sprint_closed", workflow:"gaia-sprint-close", pid, data:{sprint_id, closed_at, total_points, stories_done, stories_rolled_over, rollover_target_sprint}}`.
- Backward-compat: a sprint-status.yaml with no top-level `status:` field is treated as `active` (the historical default).
- `yq` (mikefarah, Go v4) is a hard runtime dependency for the boundary write.

## Steps

### Step 1 — Pre-condition: retro exists

- Glob `.gaia/artifacts/implementation-artifacts/retrospective-{sprint_id}-*.md`. If empty, refuse with `error: retro doc not found for {sprint_id}; run /gaia-retro first` and exit non-zero.

### Step 1b — Pre-condition: triage has run (mandatory)

`/gaia-triage-findings` is a **mandatory sprint-close prerequisite** — a sprint cannot be closed unless its findings have been triaged (and the tech-debt phase reviewed). This gate mirrors the retro-doc (Step 1) and sprint-review-sentinel (Step 3a) prerequisites.

- Check the per-sprint triage proof-of-run sentinel via:

  ```bash
  !${CLAUDE_PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/triage-sentinel.sh \
    check --sprint-id {sprint_id}
  ```

  The sentinel (`.gaia/memory/checkpoints/triage-findings-{sprint_id}-completed.json`) is written by `/gaia-triage-findings`'s finalize step when it runs against the active sprint.
- On non-zero exit (sentinel absent → triage not run), refuse with `error: triage not run for {sprint_id}; run /gaia-triage-findings {sprint_id} first` and exit non-zero.
- On exit 0 (sentinel present), proceed.

The canonical sprint-close prerequisite sequence is therefore **review → triage → retro → close**: `/gaia-sprint-review` produces the review verdict (Step 3a), `/gaia-triage-findings` triages findings + reviews tech debt (this gate), `/gaia-retro` produces the retro doc (Step 1), and only then does `/gaia-sprint-close` close the sprint.

### Step 2 — Pre-condition: idempotency

- Read top-level `status:` from `sprint-status.yaml`. If already `closed`, emit `warning: sprint {id} already closed at {iso}` to stderr and exit 0 with no further side effects.

### Step 3 — Pre-condition: all-done or force

- Parse `stories[].status` from the yaml. If any story is not `done`:
  - Without `--force-with-rollover`: refuse with an error listing the non-done keys; exit non-zero.
  - With `--force-with-rollover <key1,key2,...>`: validate the comma-separated keys list is **exactly** the non-done set (no extras, no missing). On mismatch, refuse with `error: --force-with-rollover key mismatch; non-done stories are: <keys>; got: <provided>`; exit non-zero.

### Step 3a — Pre-condition: sprint-review sentinel verification (unconditional)

The sprint-review sentinel proves that `/gaia-sprint-review` ran and produced a verdict. This check fires **unconditionally** for all closeable source states (`active`, `review`) — it is NOT gated on the sprint's current `status:` value. Without a sentinel, close is refused unless `--force` is passed.

1. **Verify the sentinel exists** — at least ONE of:
   - dispatch checkpoint: `.gaia/memory/checkpoints/sprint-review-<sprint_id>-val-dispatched.json` (written by `/gaia-sprint-review` Step 3 Track A Val dispatch).
   - envelope sentinel: `.gaia/memory/checkpoints/val-envelope-<sha256(<sprint_id>):0:16>.json` (written by the orchestrator-side writer).
2. **Decide:**
   - Sentinel present — permit close. Continue to Step 4.
   - Sentinel missing, `--force` passed — emit a warning, record the bypass in the close-summary (audited escape hatch matching the pattern used by `GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL`), and continue to Step 4.
   - Sentinel missing, no `--force` — REFUSE with canonical stderr `sprint-close refused: no sprint-review sentinel for {sprint_id}; run /gaia-sprint-review first, OR pass --force for the documented bypass` and exit non-zero.

The `--force` flag is at the close.sh (skill) level, distinct from the `GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL` env var at the `sprint-state.sh` level. Both are audited bypasses; they operate at different layers.

When the `review→closed` path is taken via `sprint-state.sh transition`, Step 4 (legacy yaml write) is SKIPPED — `sprint-state.sh transition` performs the equivalent write through the boundary writer. The Step 5 (Archive) and Step 6 (Lifecycle event) still run regardless of which edge was taken.

### Step 4 — Yaml write

The primary write path routes through `sprint-state.sh transition --to closed`. When the transition succeeds (the `review->closed` edge), `close.sh` stamps only `closed_at` (the status flip was handled by the boundary writer). When `sprint-state.sh` is absent or refuses the transition for a non-sentinel reason (e.g., `active->closed` is not a legal edge in the state machine), `close.sh` falls back to a direct `yq -i` write of both `status: closed` and `closed_at`. This fallback is safe because the sentinel gate (Step 3a) has already passed unconditionally before Step 4 runs, proving that a sprint review verdict exists (or was explicitly bypassed via `--force`).

- Primary: `sprint-state.sh transition --sprint <id> --to closed` (boundary writer).
- Fallback: `yq -i '.status = "closed" | .closed_at = "<ISO 8601 UTC>"' <yaml_path>` — fires when the transition is not a legal state-machine edge (e.g., closing from `active` without an intermediate `review` step) or when `sprint-state.sh` is not available.

### Step 5 — Archive

- `mkdir -p .gaia/artifacts/implementation-artifacts/sprint-archive/`.
- `cp <yaml_path> .gaia/artifacts/implementation-artifacts/sprint-archive/{sprint_id}-closed-{YYYY-MM-DD}.yaml`.
- Date is the close date (today, UTC). Override via `GAIA_SPRINT_CLOSE_DATE` for deterministic tests.

### Step 6 — Lifecycle event

- Invoke `${SCRIPTS_DIR}/lifecycle-event.sh --type sprint_closed --workflow gaia-sprint-close --data '{...}'` with the data payload `{sprint_id, closed_at, total_points, stories_done, stories_rolled_over, rollover_target_sprint}`.
- `stories_rolled_over` is `[]` when there is no `--force-with-rollover`, else the JSON array of rolled-over keys.
- `rollover_target_sprint` is `null` for this story; a later rollover story will populate it.

#### Two-event lifecycle contract

A complete sprint-close ceremony emits two intentionally distinct lifecycle events:

1. **`sprint_closed`** (domain event, emitted by `close.sh` Step 6) — the domain-specific signal that a sprint has closed. Carries the full sprint metadata payload (`sprint_id`, `closed_at`, `total_points`, `stories_done`, `stories_rolled_over`, `rollover_target_sprint`). Domain consumers (brain reindex, rollover planning, sprint-archive queries) key on this event.

2. **`workflow_complete`** (generic event, emitted by `finalize.sh`) — the generic plugin-lifecycle signal that the skill's execution completed. Carries no domain payload. Infrastructure consumers (throughput telemetry, step-report, audit-v2-migration harness) key on this event.

Both events fire for every close ceremony. They are intentionally distinct layers: `sprint_closed` is the domain signal; `workflow_complete` is the infrastructure signal. Downstream telemetry consumers MUST NOT treat them as duplicates — each serves a different consumer set. This two-event pattern mirrors other domain-action skills (e.g., `gaia-deploy` emits both a domain `deploy_completed` event and the generic `workflow_complete`).

### Step 7 — Confirmation

- Emit a single-line confirmation to stdout: `sprint {id} closed at {iso}; archive: {path}; lifecycle event recorded`.

### Step 7b — Advisory: per-story step report (best-effort)

After the close confirmation, surface the per-story step report as a best-effort advisory. This is read-only and never blocks the close ceremony — failures are logged and swallowed.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-report.sh" \
  --events "${MEMORY_PATH:-${PROJECT_PATH:-.}/.gaia/memory}/lifecycle-events.jsonl" 2>/dev/null || true
```

The report joins per-step timing and approximate per-step token estimates into per-story tables with rollup totals. When the events file is empty or absent, the advisory emits nothing. Token estimates are approximate and labelled as such.

## Inputs

- Positional argument: none.
- Optional flag: `--force` — bypass the sprint-review sentinel check (audited; recorded in close-summary). The sole code path that permits closing without review evidence.
- Optional flag: `--force-with-rollover <key1,key2,...>` — comma-separated story keys to roll over.
- Optional env: `GAIA_SPRINT_CLOSE_DATE` — override the close-date stamp used in the archive filename (default: today UTC).
- Optional env: `SPRINT_STATUS_YAML` — override the yaml lookup (default: `.gaia/state/sprint-status.yaml` with fallback to `<project-root>/sprint-status.yaml`).

## Outputs

- Modified `sprint-status.yaml` with `status: closed` + `closed_at: <ISO>`.
- New archive at `.gaia/artifacts/implementation-artifacts/sprint-archive/{sprint_id}-closed-{YYYY-MM-DD}.yaml`.
- Appended `sprint_closed` event in `.gaia/memory/lifecycle-events.jsonl`.
- Single-line confirmation on stdout.

## Action

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-close/scripts/close.sh

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-close/scripts/finalize.sh

## Advancing to the next sprint

After a sprint is closed, the next sprint can be scaffolded without any manual
YAML edit. The `sprint-state.sh advance` subcommand is the sanctioned path for
this hand-off — it validates that the predecessor sprint is closed, then seeds a
fresh `sprint-status.yaml` with `status: planned` for the new sprint ID.

```bash
sprint-state.sh advance --sprint-id <next-sprint-id>
```

The `advance` subcommand accepts the same optional flags as `init`:

- `--start-date YYYY-MM-DD` — set the sprint start date.
- `--end-date YYYY-MM-DD` — set the sprint end date.
- `--sprint-length-days N` — derive the end date from start + N days.

**Behaviour:**

- When the predecessor sprint is **closed** (which it will be after this skill
  runs successfully), `advance` re-seeds the live `sprint-status.yaml` over the
  closed predecessor. The closed state is already preserved in the sprint
  archive by the close ceremony's archive step.
- When the predecessor sprint is **not closed** (planned, active, or review),
  `advance` refuses with a clear message directing the operator to close the
  sprint first via `/gaia-sprint-close`.
- When no `sprint-status.yaml` exists yet (greenfield project), `advance`
  behaves identically to `init` — it seeds a fresh file.

The typical ceremony sequence is:

1. `/gaia-sprint-review` — produce the review verdict.
2. `/gaia-triage-findings` — triage findings and review tech debt.
3. `/gaia-retro` — produce the retrospective document.
4. `/gaia-sprint-close` — close the sprint (this skill).
5. `sprint-state.sh advance --sprint-id <next>` — scaffold the next sprint.
6. `/gaia-sprint-plan` — plan the next sprint (select stories, set goals).

`advance` is a thin alias for `sprint-state.sh init` — it reuses the same
code path, so all of `init`'s guarantees (atomic write, sprint-plan stub
generation) apply.

## Refs

- Sprint close ceremony — boundary write, archive, lifecycle event
- Sprint-archive directory in implementation-artifacts taxonomy
- Scripts-over-LLM principle
- `feedback_sprint_boundary_yaml_write.md` (historical context; this skill is the official replacement)
- `sprint-state.sh detect-auto-close` — upstream signal
- `sprint-state.sh advance` — next-sprint scaffold after close
- Rollover execution + sprint-plan guard — composes on top
