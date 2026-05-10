# Assessment AF-CANARY — paraphrased bypass-discussion fixture

**Date:** 2026-05-10

This fixture mirrors the structure of `assessment-AF-2026-05-09-5.md` — an
assessment doc that needs to discuss the historical bypass patterns for
documentation/audit purposes WITHOUT quoting the smoking-gun strings verbatim.

Per the AC #6 convention documented in the bats README, the historical bypasses
are paraphrased:

- AF-3 was the patch-mode-auto-judgment pattern (skill self-licensed an
  undocumented patch-mode shortcut and skipped Val dispatch).
- AF-4 was the inline-read-only-verification pattern (skill performed Val
  inline instead of dispatching as a subagent), rationalized by an
  agent-tool-not-surfaced claim.

This fixture MUST exit zero against the bats anti-pattern check — paraphrasing
is the contract, and the scanner must not over-match.

## Val Findings Summary

**Verdict:** PASS via dispatched Val subagent (per ADR-063 / FR-VFC-2).

No CRITICAL, no WARNING. Three INFO findings (omitted for brevity).

## Audit Trail

The convention applied to this canary is the same convention that AF-2026-05-09-5
introduced: paraphrase the bypass patterns, never quote the strings verbatim,
unless the doc is explicitly listed in the historical-file allowlist.
