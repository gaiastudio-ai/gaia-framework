# Token Budget Harness — NFR-VCP-2 verification

> Off-line sampling harness for VCP-FIX-08 (E44-S2 AC5). Covers AC-EC8
> (measurement unavailable fallback).

## Purpose

NFR-VCP-2 sets two targets for the auto-fix loop:

- per-iteration cost ≤ 2x single-pass `/gaia-val-validate` baseline,
- 3-iteration total cost ≤ 6x single-pass baseline.

Per-iteration `tokens_consumed` is captured live in the checkpoint
`custom.val_loop_iterations` array (see SKILL.md § "Iteration Log Record
Shape"). When the runtime token-counting primitive is unavailable, this
harness produces equivalent measurements off-line so AC5 can still be
verified.

## Inputs

- A representative artifact at `.gaia/artifacts/planning-artifacts/test-artifact.md`
  sized 5–10 KB.
- A controllable upstream skill that can drive the loop deterministically
  for 1, 2, or 3 iterations (e.g., the VCP-FIX-07 thrash setup).

## Procedure

1. **Baseline pass.** Run a single Val invocation against a clean copy of
   the artifact (no fix step, no loop). Record `tokens_consumed = B`.
2. **Loop pass.** Run a 3-iteration loop. For each iteration, record
   `tokens_consumed[i]` from the iteration log. If unavailable, capture
   the prompt-token count from the LLM runtime (off-line) by replaying
   the iteration's input context plus the Val response.
3. **Compute ratios.** For each `i ∈ {1, 2, 3}`: `r_i = tokens_consumed[i] / B`.
4. **Compute total ratio.** `R = (Σ tokens_consumed[i]) / B`.

## Pass criteria

- `r_1, r_2, r_3 <= 2.0`
- `R <= 6.0`

## Failure handling

If any `r_i > 2.0` or `R > 6.0`, file a Finding (severity HIGH, type
performance) on the upstream consumer skill that triggered the regression
and record the actual ratios in the Findings table. Do NOT change the loop
contract — the cap is normative; the offending iteration's input shaping is
the variable to tune.

## AC-EC8 fallback

When the runtime token-counting primitive is unavailable at runtime, the
loop still proceeds — the iteration record carries `tokens_consumed = null`
and a single note. AC5 is then verified by re-running this harness off-line
on a saved transcript. The loop's correctness is independent of measurement
availability.
