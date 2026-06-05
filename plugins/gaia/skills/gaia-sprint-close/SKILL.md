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

2. **A Val-dispatch sentinel with the canonical payload schema.** When the
   sprint is in `status: review`, Step 3a requires sentinel-verified evidence
   that `/gaia-sprint-review` ran and produced a verdict. The sentinel MUST
   exist at one of:
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
   `status` enum is `PASSED | FAILED | UNVERIFIED`. On `PASSED` the
   transition proceeds; on `UNVERIFIED` the skill reads the
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

### Step 2 — Pre-condition: idempotency

- Read top-level `status:` from `sprint-status.yaml`. If already `closed`, emit `warning: sprint {id} already closed at {iso}` to stderr and exit 0 with no further side effects.

### Step 3 — Pre-condition: all-done or force

- Parse `stories[].status` from the yaml. If any story is not `done`:
  - Without `--force-with-rollover`: refuse with an error listing the non-done keys; exit non-zero.
  - With `--force-with-rollover <key1,key2,...>`: validate the comma-separated keys list is **exactly** the non-done set (no extras, no missing). On mismatch, refuse with `error: --force-with-rollover key mismatch; non-done stories are: <keys>; got: <provided>`; exit non-zero.

### Step 3a — Pre-condition: review→closed sentinel verification

When the sprint's current `status:` is `review` (per the sprint-level state machine), the `review → closed` edge requires sentinel-verified evidence that `/gaia-sprint-review` actually ran and produced a verdict. This step is gated on `status: review` — when the sprint is in `active` status, SKIP this step entirely (preserves backward-compat — the legacy `active → closed` direct edge runs unchanged).

When gated on `status: review`:

1. **Read the sprint-review verdict** via `${SCRIPTS_DIR}/review-gate.sh status --sprint <id> --gate sprint-review`.
2. **Verify the sentinel exists** — at least ONE of:
   - dispatch checkpoint: `.gaia/memory/checkpoints/sprint-review-<sprint_id>-val-dispatched.json` (written by `/gaia-sprint-review` Step 3 Track A Val dispatch).
   - envelope sentinel: `.gaia/memory/checkpoints/val-envelope-<sha256(<sprint_id>):0:16>.json` (written by the orchestrator-side writer).
3. **Decide based on verdict:**
   - `PASSED` — permit transition. Route via `sprint-state.sh transition --sprint <id> --to closed` (the review→closed edge handler in `cmd_transition_sprint`; via the boundary writer; never direct `yq -i`).
   - `UNVERIFIED` with bypass — read the `review_justification` block from the sentinel (written by `set-review-justification`). When `pm_signoff` and `val_validation` are both present, permit transition via the same `sprint-state.sh transition` path.
   - `FAILED` — REFUSE with canonical stderr `HALT: sprint-close refused — sprint-review verdict is FAILED; run /gaia-correct-course first`.
   - Missing sentinel — REFUSE with canonical stderr `HALT: sprint-close refused — sprint-review verdict is MISSING; run /gaia-sprint-review first`.

When the new review→closed path is taken, Step 4 (legacy yaml write) is SKIPPED — `sprint-state.sh transition` performs the equivalent write through the boundary writer. The Step 5 (Archive) and Step 6 (Lifecycle event) still run regardless of which edge was taken.

### Step 4 — Yaml write

- `yq -i '.status = "closed" | .closed_at = "<ISO 8601 UTC>"' <yaml_path>`.

### Step 5 — Archive

- `mkdir -p .gaia/artifacts/implementation-artifacts/sprint-archive/`.
- `cp <yaml_path> .gaia/artifacts/implementation-artifacts/sprint-archive/{sprint_id}-closed-{YYYY-MM-DD}.yaml`.
- Date is the close date (today, UTC). Override via `GAIA_SPRINT_CLOSE_DATE` for deterministic tests.

### Step 6 — Lifecycle event

- Invoke `${SCRIPTS_DIR}/lifecycle-event.sh --type sprint_closed --workflow gaia-sprint-close --data '{...}'` with the data payload `{sprint_id, closed_at, total_points, stories_done, stories_rolled_over, rollover_target_sprint}`.
- `stories_rolled_over` is `[]` when there is no `--force-with-rollover`, else the JSON array of rolled-over keys.
- `rollover_target_sprint` is `null` for this story; a later rollover story will populate it.

### Step 7 — Confirmation

- Emit a single-line confirmation to stdout: `sprint {id} closed at {iso}; archive: {path}; lifecycle event recorded`.

## Inputs

- Positional argument: none.
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

## Refs

- Sprint close ceremony — boundary write, archive, lifecycle event
- Sprint-archive directory in implementation-artifacts taxonomy
- Scripts-over-LLM principle
- `feedback_sprint_boundary_yaml_write.md` (historical context; this skill is the official replacement)
- `sprint-state.sh detect-auto-close` — upstream signal
- Rollover execution + sprint-plan guard — composes on top
