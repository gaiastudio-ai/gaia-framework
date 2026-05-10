# TC-MTG-USER-5 — manual fixture: AskUserQuestion composition with user-as-attendee

> **Test case:** TC-MTG-USER-5 (E76-S21 / AF-2026-05-10-2 / FR-MTG-10 amended)
> **Tier:** e2e (manual transcript inspection — same evidence standard as
> TC-MTG-AUQ-2/5/8/11/14 from AF-2026-05-10-1).
> **Why manual:** harness Auto Mode halts the LLM turn the moment
> `AskUserQuestion` fires (memory rule
> `feedback_askuserquestion_under_automode.md` records empirical verification
> on 2026-05-09). Live runtime cannot be mocked at the bats tier without
> defeating the substrate-enforced halt — same constraint as the
> AskUserQuestion 5-boundary primitive coverage from E76-S18.

## Setup

1. Initialise a fresh meeting:
   ```
   /gaia-meeting --invitees alice,me,bob --charter "decide whether to ship X"
   ```
2. Verify session-state is created with `user_attendance: true`:
   ```
   grep '^user_attendance:' _memory/meeting-sessions/$(ls -t _memory/meeting-sessions/ | head -1)
   # expected: user_attendance: true
   ```

## Expected runtime evidence

At the post-CHARTER yield boundary, an `AskUserQuestion` call MUST fire with
the canonical 5 options ([c]ontinue / [p]ause / [w]rap-up / [a]bort + the
free-text auto-Other [i]nterject) per E76-S18 / FR-MTG-32 amended.

When the user selects auto-Other and supplies a free-text response (the
[i]nterject channel), the response text MUST be recorded in the live
transcript as a user attendee turn carrying:

- `Speaker:` set to the resolved user name from `scripts/resolve-user-name.sh`
  (FR-MTG-10 user-name labeling).
- `Role: User`
- `origin: interject` (per E76-S8 hard rule — only `interject` origins are
  permitted for user-attributed turns).
- The verbatim user text under the per-turn body.

Reference transcript pattern (the literal pattern this fixture verifies):

```
Speaker: ${USER_NAME}
Role: User
Phase: CHARTER
origin: interject

[i]nterject "I want to add risk to the agenda before we start."
```

## Composition invariants

- The 5-option AskUserQuestion call is the SAME mechanism used for LLM-agent
  yields — pure composition with E76-S18, no new infrastructure.
- The 4 explicit options ([c]ontinue / [p]ause / [w]rap-up / [a]bort) double
  as user-attendee response choices when `user_attendance: true`.
- The carve-out does NOT broaden TC-MTG-NOFAB-2's auto-emit invariant — the
  user STILL never receives an auto-emitted DISCUSS turn between yields. They
  only contribute via AskUserQuestion response AT yield boundaries.

## Pass/fail signal

PASS:

- `user_attendance: true` recorded in session-state file at meeting start.
- AskUserQuestion fires at every yield boundary (5 boundaries per full
  lifecycle — same as TC-MTG-AUQ-1..15).
- User free-text response appears in transcript with `origin: interject`.
- No fabricated user turn appears between yields (TC-MTG-NOFAB-2 invariant
  preserved).

FAIL:

- session-state shows `user_attendance: false` despite user-token in
  `--invitees`.
- AskUserQuestion is replaced by a stdout-sentinel emission
  (`<<YIELD-STOP ...`) — defeats the auto-mode-bypass mitigation; the bats
  anti-pattern check `gaia-meeting-stdout-sentinel-forbid.bats` (E76-S15)
  also catches this in CI.
- A user-attributed turn appears with `origin: subagent` /
  `dispatched_via: subagent` / no `origin:` line at all — fabricated turn,
  TC-MTG-NOFAB-2 violation.

## See also

- `gaia-meeting-user-as-attendee-carve-out.bats` — SKILL.md prose verification
  (TC-MTG-USER-7, owned by E76-S20).
- `no-fabricated-user-turns.bats` — TC-MTG-NOFAB-1/2 invariant regression.
- `user-as-attendee.bats` — TC-MTG-USER-1..4/6 + TC-MTG-NOFAB-3a (this story).
