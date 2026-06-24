# Val Auto-Fix Loop — Test Runbooks

LLM-checkable runbooks for the Val Auto-Fix Loop Pattern (canonical spec in
`../SKILL.md` § "Auto-Fix Loop Pattern"). The companion script-verifiable
bats coverage lives at
`plugins/gaia/tests/e44-s2-val-auto-fix-loop-pattern.bats`.

These runbooks are executed by the broader VCP test orchestrator (not bats).
Each runbook describes setup, the exact invocation sequence, and the
assertion the orchestrator verifies after the run.

## Inventory

| File | Test ID | AC coverage | Type |
|---|---|---|---|
| `vcp-fix-01-happy-path.md` | VCP-FIX-01 | AC1 | LLM-checkable |
| `vcp-fix-02-warning-then-clean.md` | VCP-FIX-02 | AC1 | LLM-checkable |
| `vcp-fix-03-iter3-prompt.md` | VCP-FIX-03 | AC2 | LLM-checkable |
| `vcp-fix-04-user-continue.md` | VCP-FIX-04 | AC3 | LLM-checkable |
| `vcp-fix-05-accept-as-is.md` | VCP-FIX-05 | AC2, AC-EC6 | LLM-checkable |
| `vcp-fix-06-abort.md` | VCP-FIX-06 | AC2 | LLM-checkable |
| `vcp-fix-07-thrash.md` | VCP-FIX-07 | AC4, AC-EC4 | LLM-checkable |
| `vcp-fix-08-token-budget.md` | VCP-FIX-08 | AC5 | Integration / harness |
| `vcp-valv-03-flag-deprecation.md` | VCP-VALV-03 | (AC1 contract) | LLM-checkable |
| `ec-runbooks.md` | AC-EC1..AC-EC10 | edge cases | LLM-checkable |
| `token-budget-harness.md` | NFR-VCP-2 | AC5, AC-EC8 | Off-line sampling harness |

## How To Run

These runbooks are not executed by `bats`. They are consumed by the VCP test
orchestrator (or executed manually by a developer running through the steps
in a forked Claude Code conversation). Each runbook is structured so that
the assertion at the bottom is mechanically checkable from the resulting
artifact, checkpoint, and iteration log.

The companion bats file `e44-s2-val-auto-fix-loop-pattern.bats` covers the
spec-encoding side: that the SKILL.md actually documents the pattern, the
prompt verbatim, the severity contract, the YOLO invariant, the checkpoint
custom-namespace key, and the token-budget targets. The runbooks here cover
the runtime side: that an actual loop run obeys the documented contract.
