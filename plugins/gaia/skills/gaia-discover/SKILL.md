---
name: gaia-discover
description: Manage the Discovery Board -- capture, research, evaluate, prioritize, graduate, park, and review pre-backlog ideas with a frictionless gesture set.
argument-hint: "<gesture> [args]"
allowed-tools: [Bash, Read]
orchestration_class: light-procedural
version: "1.0.0"
---

# gaia-discover

`/gaia-discover` is the user-facing gesture layer for the Discovery Board. Every
mutating gesture routes through `discovery-board.sh` -- the skill never writes
`discovery-board.yaml` directly.

## Gestures

| Gesture     | Maps to                                             | Mutates? |
|-------------|-----------------------------------------------------|----------|
| `capture`   | `discovery-board.sh capture --title <t> --source <s>` | yes      |
| `board`     | `discovery-board.sh board [--horizon <h>] [--priority <p>]` | no |
| `research`  | `discovery-board.sh transition --id <id> --to Researching` | yes  |
| `advance`   | alias for `research`                                | yes      |
| `evaluate`  | `discovery-board.sh transition --id <id> --to Evaluated` | yes    |
| `graduate`  | `discovery-board.sh transition --id <id> --to Graduated` | yes    |
| `park`      | `discovery-board.sh transition --id <id> --to Parked` | yes      |
| `revive`    | `discovery-board.sh transition --id <id> --to <parked_from>` | yes |
| `prioritize`| `discovery-board.sh prioritize --id <id> --priority <p> --horizon <h>` | yes |

## Mission

Provide a low-friction pipeline for pre-backlog ideas. Capture is instant (no
Val gate, no subagent), board is read-only, and every write goes through the
single sanctioned writer.

## Critical Rules

1. **Every mutating gesture routes through `discovery-board.sh`.** The skill
   never writes `discovery-board.yaml` directly -- all state mutations use the
   script's subcommands.
2. **`capture` is deterministic.** No Val gate, no subagent dispatch. It takes
   one sentence and a source tag, mints the id, and writes a `Captured` item.
   Priority and horizon are optional at capture time.
3. **`board` is read-only.** It renders the board to stdout with optional
   `--horizon` and `--priority` filters. Idle advisories at 30/60/90 days are
   computed at display time from `now - last_activity` and never mutate state.
4. **`park`/`revive` are explicit manual transitions.** Nothing auto-parks. The
   idle advisory on `board` is presentation-only -- it never triggers a state
   change.
5. **`prioritize` sets priority and horizon together.** Both fields are required.
   Horizon changes only via an explicit gesture (`prioritize`), never implicitly.
6. **`graduate` routes to `transition --to Graduated`.** When `--from-discovery`
   is set on `/gaia-add-feature`, the bridge populates the intake from the
   graduated item's synthesis. Graduate is the only downstream edge from
   Discovery into the formal backlog.

## Lifecycle Positioning

Discovery is a **pre-backlog** lifecycle stage that sits strictly upstream of
`/gaia-add-feature`. Ideas flow through the Discovery Board pipeline
(Captured -> Researching -> Evaluated -> Graduated) before entering the formal
GAIA lifecycle. The only downstream edge is **graduate**, which bridges a
validated idea into `/gaia-add-feature --from-discovery`.

Discovery does not replace Phase 1 (Analysis). It is an informal staging area
where ideas are captured, researched, and evaluated before they become formal
change requests. Ideas that do not graduate are parked or remain on the board
indefinitely.

## Operator Guidance

- **Discovery synthesis is internal-only.** The synthesis text, notes, and
  research captured on the board are private project artifacts. They must never
  appear verbatim in published source, user-facing documentation, or commit
  messages.
- **Never paste secrets into capture.** The `capture` gesture writes its input
  directly to `discovery-board.yaml`. API keys, credentials, tokens, and any
  other sensitive material must never be used as the title or source tag.
  Sanitize inputs before capture.

## Steps (orchestration)

1. Parse the gesture from the user's input.
2. Map the gesture to the corresponding `discovery-board.sh` subcommand per the
   table above.
3. Invoke the script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/discovery-board.sh" <subcommand> [flags]
   ```
4. Report the result to the user.

For `research`/`advance`, `evaluate`, `graduate`, `park`, and `revive`: these
are ergonomic names that map to `transition --to <state>`. The skill translates
the gesture name to the target state before invoking the script.

For `revive`: read the item's `parked_from` field via `get --id <id>` first,
then invoke `transition --id <id> --to <parked_from>`.

## Examples

Capture a new idea:
```
/gaia-discover capture "Add dark mode support" --source "user-feedback"
```

View the board filtered by horizon:
```
/gaia-discover board --horizon Now
```

Prioritize an item (use the id shown in `board` output):
```
/gaia-discover prioritize --id <item-id> --priority High --horizon Now
```

Park an item for later:
```
/gaia-discover park --id <item-id>
```
