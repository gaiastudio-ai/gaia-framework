---
name: gaia-meeting
description: Peer-to-peer multi-agent discussion skill — seven-phase lifecycle (INVITE / CHARTER / RESEARCH / DISCUSS / CLOSE / REVIEW / SAVE) with charter requirement, decide default mode, round-robin turn arbitration, and live-streamed transcript. Use when "/gaia-meeting" or "run a peer-to-peer meeting".
argument-hint: "--charter \"<one-to-three-sentence charter>\" [--mode <mode>] [--invitees <P1,P2,...>]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
---

# gaia-meeting (E76 — S1 scaffolding)

Peer-to-peer multi-agent discussion orchestrator. GAIA agents and stakeholder
personas take sequential turns through a seven-phase lifecycle. The skill is
deliberately heavier-weight than `/gaia-party`: it requires a charter, drives a
mode-aware closing artifact bias, and enforces a state-free write boundary.

This SKILL.md is the **S1 foundation** — the lifecycle skeleton, charter gate,
default mode, live-stream header format, round-robin substrate, and write
boundary. The downstream stories layer onto this scaffold:

- **E76-S2:** RESEARCH phase, cite-or-flag (FR-MTG-5), raise-hand, research-interrupt.
- **E76-S3:** CLOSE phase decision record + action items + memory write-through, full FR-MTG-27 saved-meeting frontmatter.
- **E76-S4:** Scratchpad pin / extraction.
- **E76-S5:** Eight non-`decide` modes.
- **E76-S6:** Guardrails (max-turns, per-agent cap, loop detection) + cost-reporting refinements.

S1 leaves deterministic insertion-point hooks in the turn loop and lifecycle
dispatcher so S2..S6 do not need to reshape this skeleton.

## Critical Rules

- **Charter required (FR-MTG-2, AC1, AC2).** `--charter "<inline>"` is mandatory.
  `scripts/charter-gate.sh` HALTs with status `BLOCKED` before INVITE if the
  charter is absent — and **no** writes occur to `docs/creative-artifacts/`,
  `_memory/action-items/`, or `_memory/{agent}-sidecar/decisions/`.
- **Sequential only (ADR-045).** Never parallelize per-turn invocations. Never
  reorder turns mid-round. The fork allowlist for read-only agent operations
  (full arrival in E76-S2) remains `[Read, Grep, Glob, Bash]` per NFR-048; S1
  introduces no new tool grants.
- **State-free write boundary (FR-MTG-31, AC8).** The skill writes ONLY to:
  - `docs/creative-artifacts/`
  - `_memory/action-items/`
  - `_memory/{agent}-sidecar/decisions/`
  Every artifact write MUST be routed through `scripts/write-boundary.sh`.
  Disallowed: sprint-status.yaml, story files, PRD, architecture, test plan,
  threat model, traceability. **S1's SAVE phase only writes to
  `docs/creative-artifacts/`** — the action-items and sidecar-decisions write
  paths fully arrive in E76-S3.
- **Single-mode-only invariant (FR-MTG-16).** Mode stacking is rejected at
  resolve time by `scripts/resolve-mode.sh`. Only one `--mode` flag is allowed.
- **Live-stream header on every emitted turn (FR-MTG-10, NFR-MTG-1).** Format:
  `[round R / turn T / Speaker (Role) / per-turn-cost N tokens / running-total M tokens]`.
  No `>` line prefixes. The cadence counter (10-turn cost-check cadence) is
  advanced **per emitted turn**, not per round-robin slot — this is the
  determinism contract that lets E76-S2's raise-hand and research-interrupt
  insertions remain deterministic against the same cadence.
- **Cite-or-flag is NOT enforced in S1.** That gate (FR-MTG-5) lands in E76-S2.
  S1 builds the substrate against which S2 will enforce.
- **Frontmatter persistence is shared with E76-S3.** S1 captures the charter
  into in-memory state and writes lifecycle markers to the live transcript;
  the full meeting-notes file format with required sections (FR-MTG-27) lands
  in E76-S3. S1 produces a minimum viable transcript that S3 will extend.

## Architectural Anchors

- **ADR-083** — peer-to-peer multi-agent discussion topology: peer-to-peer on
  top of Claude Agent Teams with a sequential-fork fallback. S1 implements the
  *sequential* substrate that both topology arms share. The
  Agent-Teams-vs-fallback decision is invisible at this layer.
- **ADR-045 family** — sequential-fork subagent pattern. Turns are sequential.
  Never parallel.
- **FR-329** — the `/gaia-meeting` slash command resolves via this SKILL.md
  only. **Never** repopulate `gaia-public/plugins/gaia/commands/`.

## Seven-Phase Lifecycle

| # | Phase | User Involvement | Write Boundary |
|---|-------|------------------|-----------------|
| 1 | INVITE | None directly — invitee list provided via `--invitees` or resolved from agent + stakeholder discovery (out-of-scope-for-S1: the discovery routine is shared with `/gaia-party` per FR-MTG-3; S1 accepts an explicit `--invitees` CSV). | None (in-memory state only) |
| 2 | CHARTER | `--charter` flag (inline) OR interactive fallback. | None (in-memory state only) |
| 3 | RESEARCH | Skipped placeholder in S1 — research-phase semantics ship in **E76-S2** under ADR-084. The marker still appears in the transcript so AC3's static check sees the full phase sequence. | None in S1 |
| 4 | DISCUSS | Round-robin turns matching invite order. User interjections allowed at turn boundaries. | Live transcript only (no persistence yet) |
| 5 | CLOSE | Closing-artifact bias depends on active mode. For `decide` (default) — decision record + action items. The full close-phase artifact emission lands in **E76-S3**; S1 emits the marker. | None in S1 (decision-record + action-items writes arrive in E76-S3) |
| 6 | REVIEW | Brief user-facing review pass — confirm decisions, action items, and any open questions. | None |
| 7 | SAVE | Persist the live transcript to `docs/creative-artifacts/meeting-{YYYY-MM-DD}-{slug}.md`. | `docs/creative-artifacts/` only in S1 |

The phase-marker emitter is `scripts/lifecycle-marker.sh`. Every phase emits
its marker line into the live transcript so AC3 / TC-MTG-CHARTER-3 can scan
the saved file for the full sequence.

## `decide` Default Mode (FR-MTG-17, AC4)

When `--mode` is absent, `scripts/resolve-mode.sh` returns `decide`. The
`decide` mode contract:

- **Default invitees.** `decide` does NOT inject mode-default invitees. The
  invitee list is the user-specified set only. (Other modes — landing in
  E76-S5 — may inject mode-default invitees per their PRD §4.39 row.)
- **Closing-artifact bias.** "decision record + action items". The full close
  artifact emission lands in E76-S3; S1's contract is to **document** the bias
  and to **default** to `decide` when `--mode` is absent.

The known-mode allowlist (full set documented for parity with PRD §4.39; only
`decide` is functionally wired in S1):

```
decide brainstorm research-deepdive incident review
estimate retro design-critique architecture
```

Unknown modes are rejected with a non-zero exit code at resolve time.

## Round-Robin Turn Arbitration (FR-MTG-7, AC5)

The DISCUSS-phase turn loop is driven by `scripts/turn-order.sh`. Given an
invitee CSV in invite order and a turn count, the helper emits a deterministic
round-robin sequence — one speaker label per line.

**Pre-dispatch hook (substrate for E76-S2).** The orchestrator's turn loop
follows this contract:

```
for slot in invite_order_cycle:
    # Pre-dispatch hook — E76-S2 overrides this to inject raise-hand
    # and research-interrupt turns BEFORE the slot's normal dispatch.
    pre_dispatch_hook(slot)
    dispatch(slot)
```

E76-S2 will wire raise-hand and research-interrupt insertions into
`pre_dispatch_hook` without reshaping S1's loop. The cadence counter
(`turn_count_emitted`) is advanced for every emitted turn — including
inserted ones — preserving NFR-MTG-1's per-emitted-turn determinism.

## Live-Stream Header (FR-MTG-10, NFR-MTG-1, AC6, AC7)

Every emitted turn — agent turn, raise-hand insertion (E76-S2),
research-interrupt insertion (E76-S2), user interjection — produces a single
deterministic header line via `scripts/turn-header.sh`:

```
[round R / turn T / Speaker (Role) / per-turn-cost N tokens / running-total M tokens]
```

- **No `>` prefix** — per FR-MTG-10's literal spec.
- **Cadence advances per emitted turn**, not per round-robin slot. This is
  the determinism guarantee that lets E76-S2's insertions remain deterministic
  against the 10-turn cost-check cadence (NFR-MTG-1).
- A brief cost check is emitted after every 10 emitted turns.

### User-interjection name resolution (AC7, TC-MTG-STREAM-3)

The `Speaker` label for a user interjection is resolved by
`scripts/resolve-user-name.sh` in this order — override wins:

1. `meeting.user_name` from project `settings.json` (or `.claude/settings.json`).
2. `git config user.name` (fallback).

The skill **does not** fall through to OS username — the FR-MTG-10 spec is
explicit. If neither source resolves a name, the resolver exits non-zero and
the orchestrator surfaces a guidance message ("set `meeting.user_name` in
`settings.json` or run `git config --global user.name '<name>'`").

## State-Free Write Boundary (FR-MTG-31, AC8)

Every artifact write in this skill MUST be gated by
`scripts/write-boundary.sh`. The asserter accepts a relative path and exits 0
only if the path is under one of the allowed roots:

- `docs/creative-artifacts/`
- `_memory/action-items/`
- `_memory/{any-prefix}-sidecar/decisions/`

Any other path is REJECTED with exit code 2. This is the invariant that keeps
`/gaia-meeting` truly state-free — sprint status, story files, PRD,
architecture, test plan, threat model, and traceability are NEVER touched by
this skill, ever.

## Procedure

### Phase 1 — INVITE

1. Resolve invitees:
   - If `--invitees "P1,P2,..."` is supplied, use that CSV in order.
   - Otherwise, defer to the agent + stakeholder discovery routine (shared
     with `/gaia-party` per FR-MTG-3 — full discovery wiring lands in E76-S2;
     S1 requires the explicit `--invitees` CSV).
2. Emit the `## Phase: INVITE` marker via `scripts/lifecycle-marker.sh`.

### Phase 2 — CHARTER

1. Run `scripts/charter-gate.sh --charter "<inline>"`. If the script exits
   non-zero (BLOCKED), STOP — surface the script's stderr to the user. **No**
   writes are made under `docs/creative-artifacts/`, `_memory/action-items/`,
   or `_memory/{agent}-sidecar/decisions/`.
2. On success, the charter is recorded in `MEETING_STATE_FILE` for later
   persistence (full frontmatter persistence ships with E76-S3 / FR-MTG-27).
3. Emit the `## Phase: CHARTER` marker.

### Phase 3 — RESEARCH (skipped placeholder in S1)

Emit the `## Phase: RESEARCH (skipped — research-phase semantics land in
E76-S2 / ADR-084)` marker. Do not gather research preludes; do not invoke
cite-or-flag (FR-MTG-5 is an E76-S2 gate).

### Phase 4 — DISCUSS

1. Run `scripts/resolve-mode.sh [--mode <mode>]` to resolve the active mode.
2. Drive the turn loop via `scripts/turn-order.sh --invitees "<csv>" --turns <N>`.
3. For every emitted turn — agent turn AND user interjection — emit the
   per-turn header via `scripts/turn-header.sh`.
4. Resolve user-interjection labels via `scripts/resolve-user-name.sh`.
5. Increment the cadence counter per emitted turn; every 10 emit a cost check.
6. Emit the `## Phase: DISCUSS` marker at the start.

### Phase 5 — CLOSE

In S1: emit the `## Phase: CLOSE` marker. The full decision-record + action-items
emission ships in E76-S3 (which writes through `scripts/write-boundary.sh` to
`_memory/action-items/` and `_memory/{agent}-sidecar/decisions/`).

### Phase 6 — REVIEW

Emit the `## Phase: REVIEW` marker. A brief user-facing pass to confirm
decisions, action items, and open questions. Full review semantics in E76-S3.

### Phase 7 — SAVE

1. Compute the saved-transcript path:
   `docs/creative-artifacts/meeting-{YYYY-MM-DD}-{slug}.md`.
2. Gate the write through `scripts/write-boundary.sh`. If the gate exits
   non-zero, STOP — surface the script's stderr.
3. Persist the live transcript (markers + per-turn headers + interjections).
4. Emit the `## Phase: SAVE` marker as the final line of the transcript.

## Helper Scripts

All helpers live under `scripts/` and are invoked as deterministic CLIs (no
LLM-side parsing inline — this is single-source-of-truth per ADR-057, ADR-073).

| Script | Purpose | AC / FR |
|--------|---------|---------|
| `charter-gate.sh` | Charter requirement guardrail | AC1, AC2, FR-MTG-2 |
| `resolve-mode.sh` | Active-mode resolver + single-mode invariant | AC4, FR-MTG-17, FR-MTG-16 |
| `turn-order.sh` | Round-robin turn-order generator | AC5, FR-MTG-7 |
| `turn-header.sh` | Per-turn header renderer | AC6, FR-MTG-10, NFR-MTG-1 |
| `resolve-user-name.sh` | User-interjection name resolver (override -> git) | AC7, FR-MTG-10 |
| `lifecycle-marker.sh` | Seven-phase lifecycle marker emitter | AC3, FR-MTG-1 |
| `write-boundary.sh` | State-free write-boundary asserter | AC8, FR-MTG-31 |

## Skill Outputs

- **Live transcript** (stdout). Phase markers + per-turn headers + turn bodies
  + user interjections. Always emitted in real time.
- **Saved meeting transcript** at
  `docs/creative-artifacts/meeting-{YYYY-MM-DD}-{slug}.md`. S1 produces a
  minimum viable file (markers + headers); E76-S3 extends to the full
  FR-MTG-27 frontmatter and required sections.

## What's Out of Scope for S1

These land in E76-S2..S6 — do **not** retrofit them into S1's substrate:

- Research phase, research preludes, cite-or-flag (FR-MTG-5) — E76-S2.
- Raise-hand insertion, research-interrupt insertion — E76-S2.
- Decision record + action items + memory write-through — E76-S3.
- Full FR-MTG-27 saved-meeting frontmatter and required sections — E76-S3.
- Scratchpad pin / extraction — E76-S4.
- The eight non-`decide` modes — E76-S5.
- Guardrails (max-turns, per-agent cap, loop detection) — E76-S6.
- Cost-reporting refinements beyond the per-turn header — E76-S6.

## References

- PRD §4.39 — `/gaia-meeting` peer-to-peer multi-agent discussion skill (FR-MTG-1, FR-MTG-2, FR-MTG-7, FR-MTG-8, FR-MTG-10, FR-MTG-16, FR-MTG-17, FR-MTG-31, NFR-MTG-1).
- ADR-083 — Peer-to-peer multi-agent discussion topology.
- Test plan §11.56 — TC-MTG-CHARTER-1..3, TC-MTG-TURN-1, TC-MTG-STREAM-1, TC-MTG-STREAM-3.
- FR-329 — Slash commands resolve via SKILL.md, not via the retired `commands/` directory.
- FR-MTG-3 — Reuses agent + stakeholder discovery from `/gaia-party` (full wiring in E76-S2).
