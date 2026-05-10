# Test fixture: AF-2026-05-10-1 introduces a new FR-MTG-34 (forbidden)

This fixture is canonical EXCEPT it adds a new FR-MTG-34 — violating the
in-place revision invariant from AF-2026-05-10-1. The verifier MUST FAIL on
Check 5.

## 4.39 gaia-meeting

- **FR-MTG-32 — Checkpoint yield contract** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: AskUserQuestion primitive). 4 explicit options `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` plus `[i]nterject` auto-Other (interject -> auto-Other rationale).

- **FR-MTG-33 — Session resumption and state file** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: `yield-gate.sh` becomes side-effect-only, retains session-state writes, no longer emits the YIELD-STOP sentinel).

- **FR-MTG-34 — Bogus new FR introduced by the AF-2026-05-10-1 cascade.** This MUST NOT exist; the cascade is in-place revision only.
