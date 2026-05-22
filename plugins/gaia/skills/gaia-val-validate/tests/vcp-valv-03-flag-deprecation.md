# VCP-VALV-03 — Upstream participation in auto-fix loop

> Covers AC7 (test-plan §11.46.17) of E44-S2. LLM-checkable.

## Setup

Upstream consumer skill that uses the canonical loop-pattern snippet (E44-S3..S6 wire-in shape). The upstream skill writes an artifact then enters the loop.

## Steps

1. Upstream skill writes `.gaia/artifacts/planning-artifacts/test-artifact.md`.
2. Iteration 1: `/gaia-val-validate` invoked per the Upstream Integration Contract; returns one CRITICAL finding.
3. Upstream skill applies a fix.
4. Iteration 2: re-invoke; Val returns `findings: []`.
5. Loop exits cleanly.

## Assertions

- The upstream skill respects the Val response schema fields (`severity`, `description`, `location`).
- Severity `CRITICAL` correctly drove the loop (as opposed to being treated as INFO or a fatal error).
- The empty `findings` array on iteration 2 correctly terminated the loop.
- Iteration log records were appended to `checkpoint.custom.val_loop_iterations` with the canonical record shape.
- No `val_validate_output: true` flag handling is required for the loop to operate (the deprecation no-op contract from E44-S1 is honored).
