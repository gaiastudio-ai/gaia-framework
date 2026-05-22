# VCP-FIX-06 — User chooses "abort"

> Covers AC2 of E44-S2. LLM-checkable.

## Setup

Continue from the post-iteration-3 prompt state of VCP-FIX-03.

## Steps

1. User inputs `x` (or `abort`).
2. Skill preserves the checkpoint at the current iteration.
3. Skill exits with non-zero return code.
4. Skill informs the user that `/gaia-resume` can recover.

## Assertions

- Skill exits non-zero.
- Checkpoint at `.gaia/memory/checkpoints/<skill>-<step>.json` exists and contains the full `val_loop_iterations` array up to the abort point.
- Final iteration record carries `user_decision = abort`.
- A user-facing message references `/gaia-resume`.
- The artifact is NOT modified during abort handling (no `## Open Questions` is created on abort).
