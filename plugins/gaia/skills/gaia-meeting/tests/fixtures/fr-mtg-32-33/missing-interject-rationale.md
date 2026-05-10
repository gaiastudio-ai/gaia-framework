# Test fixture: FR-MTG-32 missing [i]nterject -> auto-Other rationale

This fixture is canonical EXCEPT FR-MTG-32 lists the 5 options without the
binding rationale paragraph (no mention of "interject -> auto-Other" or
"Other slot"). The verifier MUST FAIL on Check 7.

## 4.39 gaia-meeting

- **FR-MTG-32 — Checkpoint yield contract** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: AskUserQuestion primitive). 4 explicit options `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` plus `[i]nterject`.

- **FR-MTG-33 — Session resumption and state file** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: `yield-gate.sh` becomes side-effect-only, retains session-state writes, no longer emits the YIELD-STOP sentinel).
