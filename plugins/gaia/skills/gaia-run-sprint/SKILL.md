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

1. **Plan once**, at the start of the run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh" plan \
     --repo "${PROJECT_PATH:-.}" \
     --yaml "${PROJECT_ROOT}/.gaia/state/sprint-status.yaml"
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
   inside `worktree`. A `barrier phase=<n> waiting=<count>` line means the
   phase is full or draining; wait for a dispatched agent to finish before
   calling `next` again. `sprint_complete` ends the loop.

3. **Report what you observed, per completion**:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh" \
     record <key> <done|failed|timeout|merged>
   ```
   `done`/`failed`/`timeout` are exactly what they say. `merged` means the
   dev agent's branch landed but you have not independently confirmed the
   review gate closed — the engine runs the real merge/gate audit and
   decides `done` or a bounded resume re-queue on your behalf; never guess
   this one yourself.

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
- **Re-entry is safe.** A story whose worktree survived a previous run is
  attached rather than started twice, and orphans from a killed run are cleared
  before anything new is created.
- **Clean completion leaves nothing behind.** After a story merges, its
  worktree is removed — including build output and other ignored files, via the
  `--discard-ignored` teardown path, which is used **only** after a successful
  merge and never touches memory or checkpoint state. A worktree holding
  uncommitted work is always kept and reported with a recovery command.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-run-sprint/scripts/finalize.sh
