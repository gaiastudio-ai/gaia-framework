---
name: gaia-meeting-fixture-clean
description: Clean fixture for E76-S15 — represents the post-AF-2026-05-10-1 SKILL.md where yield boundaries use the substrate AskUserQuestion primitive instead of stdout sentinels.
---

# Fixture: SKILL.md clean (post-AF-2026-05-10-1)

This fixture mirrors the post-amendment SKILL.md shape: yield-boundary procedure
sections invoke the substrate `AskUserQuestion` primitive (which halts the LLM
turn at the substrate level under Auto Mode), NOT script-side stdout sentinels.

The bats check MUST exit zero against this fixture — that is the regression
guard against false positives.

## Procedure

### Phase 2 — CHARTER

1. Run `scripts/charter-gate.sh --charter "<inline>"`.
2. Emit the `## Phase: CHARTER` marker.
3. **Post-CHARTER yield boundary.** Persist session state via
   `scripts/session-state.sh update`, then invoke the substrate
   `AskUserQuestion` primitive with the canonical five-option prompt block.
   AskUserQuestion halts the LLM turn at the substrate level regardless of
   Auto Mode (memory rule `feedback_askuserquestion_under_automode.md`).

### Phase 4 — DISCUSS

8. **Every-N DISCUSS-turn yield boundary.** After every checkpoint cadence
   tick, persist `cadence_counter` and invoke `AskUserQuestion` with the
   canonical five-option prompt. The substrate halts the turn — the skill
   MUST NOT emit any further output until re-entered via
   `/gaia-meeting --resume <session-id>`.
