# Test fixture: duplicate FR-MTG-32 definition row

This fixture is canonical EXCEPT a second FR-MTG-32 definition row appears
(simulating a botched copy-paste during the AF cascade). The verifier MUST
FAIL on Check 6 (definition-row-count == 1).

## 4.39 gaia-meeting

- **FR-MTG-32 — Checkpoint yield contract** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: AskUserQuestion primitive). 4 explicit options `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` plus `[i]nterject` auto-Other (interject -> auto-Other rationale).

- **FR-MTG-32 — Checkpoint yield contract (DUPLICATE)** (amended AF-2026-05-10-1). 4 explicit options `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` plus `[i]nterject` auto-Other (interject -> auto-Other rationale).

- **FR-MTG-33 — Session resumption and state file** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: `yield-gate.sh` becomes side-effect-only, retains session-state writes, no longer emits the YIELD-STOP sentinel).
