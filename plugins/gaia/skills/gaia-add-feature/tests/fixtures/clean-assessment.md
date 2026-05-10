# Assessment AF-EXAMPLE — clean fixture for TC-VFC-11

**Action item:** AI-EXAMPLE-1 — example clarification request
**Classification:** clarification (patch)
**Date:** 2026-05-10

## Pipeline

1. **Step 1** — Triage. Routed to assigned agent for clarification.
2. **Step 2** — Val review gate dispatched as a forked subagent per ADR-063 / FR-VFC-2. Verdict: `PASS` with three INFO findings; no WARNING; no CRITICAL. Findings table below. All factual claims in the intake message verified against codebase.
3. **Step 3** — Clarification answer recorded in the action-item entry.
4. **Step 4** — Action item closed (`status: resolved`).

## Val Findings Summary

**Verdict:** PASS — no CRITICAL, no WARNING, three INFO findings.

| # | Severity | Title | Location | Suggested |
|---|----------|-------|----------|-----------|
| F1 | INFO | Style observation | n/a | none |
| F2 | INFO | Cross-reference suggestion | n/a | follow-up story |
| F3 | INFO | Documentation polish | n/a | next sprint |

## Audit Trail

This assessment doc is intentionally clean — it documents a healthy patch-mode
clarification flow with proper Val subagent dispatch. The three smoking-gun
bypass strings (the patch-mode-auto-judgment pattern, the
inline-read-only-verification pattern, and the agent-tool-not-surfaced
rationalization) are paraphrased here per the AC #6 convention rather than
quoted verbatim, so this fixture is a valid negative control.
