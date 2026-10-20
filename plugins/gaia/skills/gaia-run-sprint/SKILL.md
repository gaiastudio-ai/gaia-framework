---
name: gaia-run-sprint
description: "Execute the active sprint's stories phase by phase — running the stories of one dependency phase concurrently up to the configured dev-slot budget, each in its own worktree, with a barrier before the next phase and an honest fall back to one-story-at-a-time whenever concurrency is unavailable. Use when 'run the sprint' or /gaia-run-sprint."
allowed-tools: [Bash, Read]
version: "1.0.0"
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-run-sprint/scripts/setup.sh

## Mission

Run the committed sprint. Stories that share a dependency phase carry no
ordering constraint between them, so they may run at the same time; stories in
a later phase may not start until every story of the current phase has
finished. This skill is a thin driver — all scheduling lives in
`scripts/phase-parallel-orchestrator.sh`, so the rules below describe tested
behaviour rather than instructions an agent must remember.

The orchestrator is a re-entrant step engine, not a script that blocks until
the sprint finishes: it admits and tracks stories, but only this skill's own
turn can actually drive a dev-agent through a story (spawning and messaging a
teammate is a live tool call, not something a background script can do on
its own). So this skill loops, one real turn at a time:

1. **Resolve sprint argument and bind**, at the start of the run:
   ```bash
   # Resolve the --sprint argument. The resolver enforces that --sprint
   # must match the bound sprint (or be absent); a different ID is refused.
   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/session-binding.sh"
   RESOLVED_SPRINT="$(resolve_sprint_arg --command run-sprint "$@")"
   # Bind the session to a sprint (concurrent mode only).
   # In single-sprint mode this is a no-op.
   BOUND_SPRINT=""
   BOUND_SPRINT="$(bash "${CLAUDE_PLUGIN_ROOT}/skills/gaia-run-sprint/scripts/bind.sh" "$@")" || true
   # Resolve the sprint state file path.
   SPRINT_YAML="${PROJECT_ROOT}/.gaia/state/sprint-status.yaml"
   if [ -n "$BOUND_SPRINT" ]; then
     SPRINT_YAML="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh" resolve-file --sprint "$BOUND_SPRINT")"
   fi
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh" plan \
     --repo "${PROJECT_PATH:-.}" \
     --yaml "$SPRINT_YAML"
   ```
   This runs every degradation check up front and prints `mode=parallel
   reason=none` or `mode=sequential reason=<token>` (see the table below).
   On `mode=sequential`, run the printed worklist one story at a time and
   skip the loop below entirely.

2. **Loop `next`, one call per turn**, on `mode=parallel`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh" next
   ```
   Each `dispatch story=<key> phase=<n> persona=<stack> worktree=<path>
   handle=<id>` line names a story this call admitted (a real worktree, a
   real teammate registry entry) — for each one, spawn that persona's dev
   agent with the Agent tool in the background on `/gaia-dev-story <key>`
   inside `worktree` (include the story key as the first token in the
   description field, followed by a colon and a task summary, so the
   sprint dashboard can map the running agent to its story). A `barrier phase=<n> waiting=<count>` line means the
   phase is full or draining; wait for a dispatched agent to finish before
   calling `next` again. `sprint_complete` ends the loop.

3. **Report what you observed, per completion**:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh" \
     record <key> <done|failed|timeout|merged|deferred>
   ```
   `done`/`failed`/`timeout` are exactly what they say. `merged` means the
   dev agent's branch landed but you have not independently confirmed the
   review gate closed — the engine runs the real merge/gate audit and
   decides `done` or a bounded resume re-queue on your behalf; never guess
   this one yourself. `deferred` means merge.sh exited 3 (promotion-lock
   contention): the dev slot is released, the worktree and branch are kept,
   the story stays in `review`, and the next cycle's resume re-enters at
   the merge step.

4. **Check `status` every turn**, and record `timeout` for anything overdue:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh" status
   ```
   This lists running stories with elapsed time against the per-story
   budget — there is no other signal for "this dev agent's turn silently
   died," so an overdue entry is your cue to call `record <key> timeout`
   rather than waiting indefinitely.

The story workflow itself is unchanged: this skill schedules `/gaia-dev-story`
runs, it does not reimplement them.

## Prerequisites

Parallel execution requires the `flock` command-line utility for kernel-level
file locking. On Linux it is installed by default (part of `util-linux`). On
stock macOS it is absent — install it with:

```
brew install flock
```

Without `flock`, the skill reports `reason=flock-unavailable` and proceeds
sequentially. No sprint is ever refused; concurrency is simply unavailable
until the locking primitive is present.

## Turning concurrency on

Concurrency is opt-in on three independent switches, and **all three** must be
set or the sprint runs one story at a time:

| Switch | Meaning |
| --- | --- |
| `GAIA_PARALLEL_EXECUTION=1` | the operator is asking for concurrency |
| `GAIA_WORKTREE_MODE=1` | per-story worktree isolation is available |
| `parallel_execution.max_parallel_dev_slots` > 1 | the budget allows it |

Worktree isolation is a precondition, not an option. Several developers editing
one checkout at the same time is exactly the cross-contamination the isolation
exists to prevent, so this skill will not switch the mode on for an operator who
did not ask for it — it says so and runs sequentially instead.

Two further budget keys live in the same config section:
`teammate_dispatch_ceiling` (total concurrent agents of every class, which must
leave headroom above the slot budget for gate agents) and
`story_timeout_minutes` (the per-story wall-clock budget, 90 by default).

## What you will see

Running sequentially is a normal outcome, never a failure, and it is **always
explained**. One of these reasons is printed, and the sprint proceeds:

| Reason | What happened |
| --- | --- |
| `parallel-opt-in-off` | concurrency was not requested |
| `flock-unavailable` | the locking primitive is missing, or forced off |
| `worktree-mode-off` | per-story isolation is not switched on |
| `slots-1` | the budget allows no concurrency |
| `sprint-unreadable` | the sprint file is missing, malformed or unparseable — the run still ends cleanly, but with no stories to list |
| `no-phase-fields` | the sprint parses but carries no phase assignments |
| `ceiling-cannot-admit` | the agent ceiling is saturated with no headroom |
| `admission-lock-timeout` | the admission lock could not be acquired, so no story was admitted without it |
| `mode-b-fallback` | the persistent-agent substrate is unavailable |
| `admission-error` | an unclassified admission failure |

A sprint planned before phases existed hits `no-phase-fields`: re-plan it, or
assign phases to its rows, and concurrency becomes available.

**On the locking primitive, one deliberate difference.** The sprint-state
writer *refuses* when concurrency is requested without it, because a single
state write has nothing to fall back to. This skill instead reports the reason
and keeps going, because it does have somewhere to fall back to and a sprint
that does not run is worse than a sprint that runs slowly. That difference is
intentional — please do not "fix" one to match the other.

## Behaviour worth knowing

- **A failing story does not stop its siblings.** The rest of the phase keeps
  running, the failure is recorded for the sprint review, and the barrier waits
  for every story to finish — successfully or not — before the next phase.
- **A saturated ceiling is never a story failure.** The story is queued and
  retried when a slot frees.
- **A stalled story is bounded.** After `story_timeout_minutes` its slot is
  freed so the rest of the phase proceeds; the story is reported as timed out
  and **its worktree is preserved**, because a story that ran out of wall clock
  is the one most likely to hold work nobody has committed yet.
- **Correction dispatch guard.** Correction dispatch after a FAILED review is guarded inside `/gaia-dev-story` REWORK mode (`assert-round-complete`). Run-sprint relies on that guard rather than dispatching corrections itself.
- **Re-entry is safe.** A story whose worktree survived a previous run is
  attached rather than started twice, and orphans from a killed run are cleared
  before anything new is created.
- **Clean completion leaves nothing behind.** After a story merges, its
  worktree is removed — including build output and other ignored files, via the
  `--discard-ignored` teardown path, which is used **only** after a successful
  merge and never touches memory or checkpoint state. A worktree holding
  uncommitted work is always kept and reported with a recovery command.

## Session-to-sprint binding

When running in concurrent-sprint mode (`sprint.max_concurrent_active` > 1 and
per-sprint state files exist), the session is bound to exactly one sprint at
activation time. The binding is immutable for the session's lifetime.

1. **Binding at activation.** When `--sprint <id>` is passed, the session binds
   to that sprint. Without `--sprint`: 0 active sprints = no binding (existing
   behavior), 1 active sprint = auto-bind, multiple active sprints = refuse
   with listing.
2. **Re-entry.** Re-invoking with the same sprint (or without `--sprint` in a
   bound session) reuses the binding idempotently. A different sprint ID is
   refused.
3. **Binding file.** The binding is stored at `$GAIA_BINDING_DIR/bound_sprint_id`
   (write-once via `set -C`). Consumers re-derive the binding from this file on
   every Bash call — each call is a fresh shell.
4. **Closed-sprint guard.** When the bound sprint is closed (by this or another
   session), planning-level subcommands (`init`, `advance`, `rollover`,
   `set-story-sprint`) are refused. Other mutating subcommands proceed normally.
   Read-only commands always work. Planning the next sprint requires a new
   session.

In single-sprint mode (the default), no binding file is written or read, and
all behavior is unchanged.

## Cross-session resource ledger lifecycle

When running in concurrent-sprint mode (`sprint.max_concurrent_active` > 1 and
per-sprint state files exist), the run-sprint skill integrates with the
cross-session resource ledger to share dev-slot and teammate budgets across
sessions:

1. **On start:** resolve the session PID (the parent of the skill's shell) and
   export `GAIA_LEDGER_PID` and `GAIA_LEDGER_SPRINT` for all child scripts.
   Install an exit-cleanup hook that calls `concurrent-resource-ledger.sh
   cleanup` on normal or abnormal exit. Start the background heartbeat writer
   at `GAIA_LEDGER_HEARTBEAT_INTERVAL` (default 60s) via
   `concurrent-resource-ledger.sh start-heartbeat-loop`.
2. **Per story:** the orchestrator claims one dev slot before `ppo_next` and
   releases the unused portion immediately after `ppo_next` returns (the full
   grant on `barrier`, `sprint_complete`, or zero admits). After
   `ppo_record_outcome`, one dev slot is released. Teammate slots are claimed
   and released by `dispatch-teammate.sh` on spawn and shutdown.
3. **On completion:** the cleanup hook removes the session's ledger entry, stops
   the background heartbeat loop, and removes the heartbeat PID file
   (`.gaia/state/.ledger-heartbeat-{session_id}.pid`).

In single-sprint mode (the default), all ledger operations are no-ops: no ledger
file is created, no lock is acquired, and no heartbeat process is started.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-run-sprint/scripts/finalize.sh
