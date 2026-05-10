---
name: gaia-meeting-fixture-with-sentinel
description: Regression fixture for E76-S15 — contains forbidden stdout-sentinel patterns inside a yield-boundary procedure section.
---

# Fixture: SKILL.md with stdout-sentinel anti-pattern

This fixture intentionally embeds `<<YIELD-STOP` and `<<TURN-END` patterns inside
yield-boundary procedure sections so the scanner trips on it. The fixture is a
regression guard: any future SKILL.md that drifts back to script-side stdout
sentinels MUST fail the bats check.

## Procedure

### Phase 2 — CHARTER

1. Run `scripts/charter-gate.sh --charter "<inline>"`.
2. Emit the `## Phase: CHARTER` marker.
3. **Post-CHARTER yield boundary.** Persist session state via
   `scripts/session-state.sh update`, then exec
   `scripts/yield-gate.sh --phase post-charter --session-id <id>`. The helper
   emits the canonical 3-line block ending with the
   `<<YIELD-STOP phase=post-charter session=<id>>>` sentinel. The sentinel ENDS
   the current LLM turn.

### Phase 4 — DISCUSS

8. **Every-N DISCUSS-turn yield boundary.** After every `meeting.checkpoint_every_n_turns`
   emitted DISCUSS turns, persist `cadence_counter` and exec
   `scripts/yield-gate.sh --phase discuss-cadence --session-id <id>`. The helper
   emits the canonical block ending with
   `<<TURN-END phase=discuss-cadence session=<id>>>`.
