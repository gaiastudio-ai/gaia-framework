# Test fixture: FR-MTG-32 missing the AF-2026-05-10-1 amendment marker

This fixture is identical to canonical.md except the FR-MTG-32 definition
row only carries the AF-2026-05-08-4 amendment marker — AF-2026-05-10-1 is
absent. The verifier MUST FAIL on Check 1.

## 4.39 gaia-meeting

- **FR-MTG-32 — Checkpoint yield contract** (amended AF-2026-05-08-4: enforcement moves from LLM-discipline-side prose to script-side `yield-gate.sh` helper). At each yield the skill MUST emit `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` and the `[i]nterject` auto-Other option (interject -> auto-Other binding rationale).

- **FR-MTG-33 — Session resumption and state file** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: `yield-gate.sh` becomes side-effect-only, retains session-state writes, no longer emits the YIELD-STOP sentinel).
