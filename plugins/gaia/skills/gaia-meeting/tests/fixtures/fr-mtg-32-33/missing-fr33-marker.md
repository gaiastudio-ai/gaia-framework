# Test fixture: FR-MTG-33 missing the AF-2026-05-10-1 amendment marker

This fixture is identical to canonical.md except the FR-MTG-33 definition
row only carries the AF-2026-05-08-4 amendment marker — AF-2026-05-10-1 is
absent. The verifier MUST FAIL on Check 3.

## 4.39 gaia-meeting

- **FR-MTG-32 — Checkpoint yield contract** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: AskUserQuestion primitive). 4 explicit options `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` plus `[i]nterject` auto-Other (interject -> auto-Other rationale).

- **FR-MTG-33 — Session resumption and state file** (amended AF-2026-05-08-4: `yield-gate.sh` updates session-state). yield-gate.sh becomes side-effect-only and no longer emits the YIELD-STOP sentinel; session-state writes preserved.
