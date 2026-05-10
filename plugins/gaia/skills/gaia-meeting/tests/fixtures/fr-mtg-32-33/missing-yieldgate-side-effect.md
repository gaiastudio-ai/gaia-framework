# Test fixture: FR-MTG-33 missing yield-gate.sh side-effect-only language

This fixture is canonical EXCEPT FR-MTG-33 omits the side-effect-only /
YIELD-STOP-removed language under AF-2026-05-10-1. The verifier MUST FAIL
on Check 4.

## 4.39 gaia-meeting

- **FR-MTG-32 — Checkpoint yield contract** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1: AskUserQuestion primitive). 4 explicit options `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` plus `[i]nterject` auto-Other (interject -> auto-Other rationale).

- **FR-MTG-33 — Session resumption and state file** (amended AF-2026-05-08-4 and amended AF-2026-05-10-1). The session-state file at `_memory/meeting-sessions/{date}-{slug}.yaml` is the source of truth for re-entry.
