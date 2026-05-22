# VCP-FIX-01 — Happy path (iter 1 CRITICAL → iter 2 clean)

> Covers AC1 of E44-S2. LLM-checkable runbook executed by the VCP orchestrator.

## Setup

- A planning artifact at `.gaia/artifacts/planning-artifacts/test-artifact.md` containing one auto-correctable CRITICAL finding (e.g., a referenced file path that does not exist on disk because of a typo — the upstream skill knows the correct path).

## Steps

1. Upstream skill writes the artifact.
2. Upstream skill enters the auto-fix loop (`iteration = 1`).
3. Iteration 1: invoke `/gaia-val-validate artifact_path=... artifact_type=...`. Val returns one CRITICAL finding.
4. Apply fix (correct the typo). Append iteration 1 record to `checkpoint.custom.val_loop_iterations`.
5. `iteration = 2`. Re-invoke Val.
6. Iteration 2: Val returns `findings: []`.
7. Append iteration 2 record (`revalidation_outcome = clean`). Exit loop.

## Assertions

- Exactly **2** Val invocations occurred.
- The skill proceeded past the loop (no halt).
- `checkpoint.custom.val_loop_iterations` contains exactly 2 records, distinguishable by `iteration_number = 1` and `iteration_number = 2`.
- Iteration 1 record contains the CRITICAL finding text and a non-empty `fix_diff_summary`.
- Iteration 2 record contains `findings: []` and `revalidation_outcome = clean`.
- The artifact on disk shows the fix applied (the previously-broken reference is now correct).
