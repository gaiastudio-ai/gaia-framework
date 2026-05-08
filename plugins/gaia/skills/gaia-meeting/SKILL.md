---
name: gaia-meeting
description: Peer-to-peer multi-agent discussion skill — seven-phase lifecycle (INVITE / CHARTER / RESEARCH / DISCUSS / CLOSE / REVIEW / SAVE) with charter requirement, decide default mode, round-robin turn arbitration, and live-streamed transcript. Use when "/gaia-meeting" or "run a peer-to-peer meeting".
argument-hint: "--charter \"<one-to-three-sentence charter>\" [--mode <mode>] [--invitees <P1,P2,...>]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
---

# gaia-meeting (E76 — S1 scaffolding + S2 research / cite-or-flag / raise-hand + S3 close + S4 scratchpad)

Peer-to-peer multi-agent discussion orchestrator. GAIA agents and stakeholder
personas take sequential turns through a seven-phase lifecycle. The skill is
deliberately heavier-weight than `/gaia-party`: it requires a charter, drives a
mode-aware closing artifact bias, and enforces a state-free write boundary.

S1 shipped the **lifecycle foundation** — the seven-phase skeleton, charter
gate, default mode, live-stream header format, round-robin substrate, and
write boundary.

S2 layers onto S1 the **research phase** (sidecar load + source-of-truth reads
+ web search + cited prelude — ADR-084), the **cite-or-flag invariant** during
DISCUSS (FR-MTG-5), and **raise-hand arbitration** with a one-per-cycle
defer queue (FR-MTG-7 / FR-MTG-9). The downstream stories continue to layer:

- **E76-S3:** CLOSE phase decision record + action items + memory write-through, full FR-MTG-27 saved-meeting frontmatter.
- **E76-S4:** Scratchpad pin / extraction (LANDED — see "Scratchpad pin + extraction" section below).
- **E76-S5:** Eight non-`decide` modes (LANDED — see "Mode Registry" section below).
- **E76-S6:** Guardrails (max-turns, per-agent cap, loop detection) + cost-reporting refinements.

S1 left deterministic insertion-point hooks in the turn loop and lifecycle
dispatcher so S2..S6 do not need to reshape this skeleton — S2 plugs into the
RESEARCH and DISCUSS hooks rather than reimplementing the lifecycle.

## Critical Rules

- **Charter required (FR-MTG-2, AC1, AC2).** `--charter "<inline>"` is mandatory.
  `scripts/charter-gate.sh` HALTs with status `BLOCKED` before INVITE if the
  charter is absent — and **no** writes occur to `docs/creative-artifacts/`,
  `_memory/action-items/`, or `_memory/{agent}-sidecar/decisions/`.
- **Sequential only (ADR-045).** Never parallelize per-turn invocations. Never
  reorder turns mid-round. The fork allowlist for read-only agent operations
  (full arrival in E76-S2) remains `[Read, Grep, Glob, Bash]` per NFR-048; S1
  introduces no new tool grants.
- **State-free write boundary (FR-MTG-31, AC10 / AC8).** The skill writes ONLY to:
  - `docs/creative-artifacts/meeting-*.md`
  - `docs/planning-artifacts/action-items.yaml` (canonical, ADR-086 / ADR-052)
  - `_memory/{agent}-sidecar/decisions/*.md`
  Every artifact write MUST be routed through `scripts/write-boundary.sh`.
  Disallowed: sprint-status.yaml, story files, PRD, architecture, test plan,
  threat model, traceability. The legacy E76-S1 root `_memory/action-items/`
  is **retired** by ADR-086.
- **Single-mode-only invariant (FR-MTG-16).** Mode stacking is rejected at
  resolve time by `scripts/resolve-mode.sh`. Only one `--mode` flag is allowed.
- **Live-stream header on every emitted turn (FR-MTG-10, NFR-MTG-1).** Format:
  `[round R / turn T / Speaker (Role) / per-turn-cost N tokens / running-total M tokens]`.
  No `>` line prefixes. The cadence counter (10-turn cost-check cadence) is
  advanced **per emitted turn**, not per round-robin slot — this is the
  determinism contract that lets E76-S2's raise-hand and research-interrupt
  insertions remain deterministic against the same cadence.
- **Cite-or-flag is enforced (E76-S2).** Every DISCUSS turn line that asserts a
  factual claim (about a file path, code behavior, prior decision, external
  system, or memory entry) MUST carry either a citation marker (project file
  path, URL, or `_memory/...` reference) or the literal `[inference]` token.
  The facilitator's pre-persistence check halts round-robin advancement on
  unflagged-inference lines BEFORE they land in the persisted transcript
  (FR-MTG-5 / FR-MTG-28 hard guardrail).
- **Research-phase fork is read-only (E76-S2, NFR-048).** The single source-of-
  truth allowlist lives in `scripts/research-phase-dispatch.sh --print-allowlist`:
  `[Read, Grep, Glob, Bash, WebSearch, WebFetch]` (web on) or `[Read, Grep,
  Glob, Bash]` when `--no-web` is set. NEVER add `Write`, `Edit`, or
  `NotebookEdit` to the research fork — fork no-write isolation is a hard
  invariant (NFR-048, T-MTG-3 mitigation).
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
  invitee list is the user-specified set only.
- **Closing-artifact bias.** `decision-record`. The full close-artifact
  emission lands in E76-S3; S1 documents the bias and defaults to `decide`
  when `--mode` is absent.

## Mode Registry (E76-S5, FR-MTG-17, FR-MTG-18, FR-MTG-16)

The canonical set of supported `--mode` values is sourced from the registry
at `knowledge/modes.yaml`. Each mode entry carries `name`, optional
`aliases`, `default_invitees`, `closing_artifact_bias`, and a
`notes_template_ref` pointing at a notes-drafting prompt template under
`knowledge/notes-template-<bias-name>.md`.

| Mode           | Aliases | Default invitees                                     | Closing-artifact bias       |
|----------------|---------|------------------------------------------------------|-----------------------------|
| `decide`       | —       | (none — user-specified only)                          | `decision-record`           |
| `explore`      | —       | (none — user-specified only)                          | `opportunity-map`           |
| `align`        | —       | Derek, Nate                                           | `alignment-summary`         |
| `red-team`     | —       | Zara, Sable, Nova                                     | `risk-register`             |
| `ac`           | —       | Vera, Sable                                           | `machine-readable-ac-list`  |
| `brainstorm`   | —       | Rex, Orion, Lyra, Elara, Vermeer                      | `brainstorming-document`    |
| `design`       | `ux`    | Christy, Suki, Layla, Talia, Tariq, Lena, Cleo, Freya | `ux-design-notes`           |
| `architecture` | —       | Theo, Soren, Milo, Juno, Omar, Priya                  | `architecture-decisions`    |
| `sprint`       | —       | Nate, Derek, Rafael                                   | `sprint-adjustments`        |

**Single-mode-only invariant (FR-MTG-16).** `scripts/resolve-mode.sh` rejects
two or more `--mode` flags before INVITE — exit code 2 with a stderr message
that lists both supplied values and references FR-MTG-16. No transcript /
action-item / per-agent memory entry is written when this fires.

**Alias canonicalisation (FR-MTG-17, AC6).** `--mode=ux` resolves to the
canonical `design` entry; the saved-notes frontmatter records `mode: design`.
`design`/`ux` is the only alias pair in v1.

**Default-invitee resolution (INVITE phase).**
`scripts/resolve-invitees.sh --mode <m> --invitees "<csv>" --installed <path>`
reads the registry and an "installed" identifier list (one ID per line) and
emits the resolved set, the missing list (when any), the bias, the canonical
mode name, the `invitees_override` flag, and the resolved-default subset.
Identifiers in `default_invitees` are matched against the installed list;
missing entries are omitted from the resolved set and surfaced in the
`missing_invitees` audit field.

**Graceful degradation (FR-MTG-18, AC11-AC13).** When one or more default
invitees are missing the resolver emits a single-line WARNING to stderr with
the stable prefix `[gaia-meeting] WARNING: missing default invitee(s) for
mode <mode>: <list> (resolved subset: <list>)`. The exit code stays 0 — the
INVITE phase proceeds with the resolved subset. The frontmatter writer
records `missing_invitees: [<list>]` (empty list when all resolved).

**`--invitees` override path (FR-MTG-17, AC14).** When `--invitees` is
supplied with `--invitees-override`, the user CSV is authoritative — default
invitees are NOT auto-added, no missing-invitee WARNING fires, and the saved
frontmatter records `invitees_override: true`.

**Closing-artifact bias plumbing (FR-MTG-17, AC15).**
`scripts/select-notes-template.sh --bias <bias>` emits the absolute path to
the matching template under the skill's `knowledge/` subtree. The mapping is
one-to-one — every bias has its own template — and selection at CLOSE never
affects what agents say during DISCUSS; it only shapes the facilitator's
notes-drafting prompt.

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

## State-Free Write Boundary (FR-MTG-31, AC10 — E76-S3 reconciled)

Every artifact write in this skill MUST be gated by
`scripts/write-boundary.sh`. The asserter accepts a relative path and exits 0
only if the path is one of:

- `docs/creative-artifacts/meeting-*.md`
- `docs/planning-artifacts/action-items.yaml` (canonical registry per
  ADR-086 / ADR-052 addendum E36-S4)
- `_memory/{any-prefix}-sidecar/decisions/*.md`

The legacy E76-S1 path `_memory/action-items/` is **retired** by ADR-086 —
the canonical action-items registry is now the single-file YAML at
`docs/planning-artifacts/action-items.yaml`. New writes MUST target the
canonical location.

Any other path is REJECTED with exit code 2. This is the invariant that keeps
`/gaia-meeting` truly state-free — sprint status, story files, PRD,
architecture, test plan, threat model, and traceability are NEVER touched by
this skill, ever.

## Procedure

### Phase 1 — INVITE

1. Resolve the active mode via `scripts/resolve-mode.sh [--mode <m>]`
   (canonicalises aliases — `ux` → `design`).
2. Resolve invitees via
   `scripts/resolve-invitees.sh --mode <canonical> --invitees "<csv>" --installed <path> [--invitees-override]`:
   - When `--invitees-override` is set, the user CSV is authoritative and no
     mode-default lookup runs.
   - Otherwise the resolver merges the user CSV with the mode's
     `default_invitees`, gracefully degrading missing identifiers (FR-MTG-18)
     and surfacing a single-line WARNING per missing entry.
3. Emit the `## Phase: INVITE` marker via `scripts/lifecycle-marker.sh`.

### Phase 2 — CHARTER

1. Run `scripts/charter-gate.sh --charter "<inline>"`. If the script exits
   non-zero (BLOCKED), STOP — surface the script's stderr to the user. **No**
   writes are made under `docs/creative-artifacts/`, `_memory/action-items/`,
   or `_memory/{agent}-sidecar/decisions/`.
2. On success, the charter is recorded in `MEETING_STATE_FILE` for later
   persistence (full frontmatter persistence ships with E76-S3 / FR-MTG-27).
3. Emit the `## Phase: CHARTER` marker.

### Phase 3 — RESEARCH (E76-S2, ADR-084)

The RESEARCH phase implements the four-step contract from ADR-084:

1. **Per-agent sidecar load (FR-MTG-4 step 1).** For each invited agent, load
   the canonical sidecar at `_memory/<agent>-sidecar/` via the existing tier-
   aware load contract (§4.10). The intake-shorthand path
   `_memory/agent-decisions/<agent>/` is NOT canonical — ADR-086 reconciled
   on `<agent>-sidecar/`. Resolve via
   `scripts/research-phase-dispatch.sh --sidecar-path <agent>`. Reads MUST be
   read-only — sidecar files MUST NOT be mutated during RESEARCH.
2. **Source-of-truth reads (FR-MTG-4 step 2, NFR-048).** Inside a fork whose
   tool allowlist matches the research-phase allowlist (see below), each
   invited agent reads the project files relevant to the charter — typically
   architecture shards under `docs/planning-artifacts/architecture/`, ADRs in
   `12-12-adr-detail-records.md`, SKILL.md files under
   `gaia-public/plugins/gaia/skills/`, and other planning artifacts. Every
   path the agent reads MUST appear under `Sources consulted:` in the prelude.
3. **Web search (FR-MTG-4 step 3, FR-MTG-6, T-MTG-1).** When `--no-web` is NOT
   set, the research fork MAY invoke `WebSearch` and `WebFetch`. Each web
   result's URL, title, and snippet MUST be recorded under
   `Sources consulted:`. When `--no-web` IS set, web tools are excluded from
   the allowlist and the SAVE-time frontmatter records `web_search: disabled`.
4. **Cited prelude (FR-MTG-4 step 4).** Each invited agent posts a prelude in
   the fixed format emitted by `scripts/lib/prelude-format.sh`:

   ```
   [Prelude] {Name} ({Role}) — {tokens} tokens
   Sources consulted:
     <source 1>
     <source 2>
     ...
   What I know:
     - <bullet 1>
     - <bullet 2>
     ...
   ```

   The S1 live-stream per-turn header (NFR-MTG-1) MUST be emitted for every
   prelude turn. The DISCUSS phase MUST NOT start until every invited agent's
   prelude has landed in the shared message log — the prelude is the gate.

**Research-phase fork tool allowlist (single source-of-truth, NFR-048).** The
canonical allowlist is exposed by
`scripts/research-phase-dispatch.sh --print-allowlist [--no-web]`:

| Mode             | Allowlist                                        |
|------------------|--------------------------------------------------|
| Web enabled      | `Read, Grep, Glob, Bash, WebSearch, WebFetch`    |
| `--no-web`       | `Read, Grep, Glob, Bash`                         |

The allowlist NEVER contains `Write`, `Edit`, or `NotebookEdit`. Audit / threat-
model review MUST verify the contract from this single script (T-MTG-3).

**`--skip-research` audit invariant (FR-MTG-6, ADR-084).** When
`--skip-research` is set, prelude turns are omitted, the four-step contract
is skipped, and SAVE writes `research_phase: skipped` into the meeting
frontmatter. The cite-or-flag invariant (see DISCUSS) STILL applies during
DISCUSS — agents MUST mark unsourced factual claims `[inference]` even when
the research phase is skipped. The skip-research path MUST be detectable by
a future static check from the saved frontmatter alone.

**Frontmatter audit fields.** At SAVE time the meeting frontmatter records
the research-phase audit fields via
`scripts/research-phase-dispatch.sh --emit-frontmatter [--no-web] [--skip-research]`:

```
research_phase: enabled|skipped
web_search:    enabled|disabled
```

### Phase 4 — DISCUSS

1. Run `scripts/resolve-mode.sh [--mode <mode>]` to resolve the active mode.
2. Drive the turn loop via `scripts/turn-order.sh --invitees "<csv>" --turns <N>`.
3. For every emitted turn — agent turn AND user interjection — emit the
   per-turn header via `scripts/turn-header.sh`.
4. Resolve user-interjection labels via `scripts/resolve-user-name.sh`.
5. Increment the cadence counter per emitted turn; every 10 emit a cost check.
6. Emit the `## Phase: DISCUSS` marker at the start.
7. **Cite-or-flag check (FR-MTG-5, E76-S2).** Before each draft turn lands in
   the persisted transcript, the facilitator runs
   `scripts/cite-or-flag-check.sh --gate-draft-turn <draft-file>`. If any
   line classifies as `unflagged-inference` (factual claim with neither a
   citation marker nor `[inference]`), the script exits non-zero with `HALT`,
   names the offending lines, and the facilitator HALTs round-robin
   advancement until the agent re-emits the turn with a marker. The offending
   turn MUST NEVER land in the persisted transcript (FR-MTG-28 hard guardrail).
8. **Raise-hand arbitration (FR-MTG-7 / FR-MTG-9, E76-S2).** When an agent's
   turn ends with `[raise-hand → respond to {Name}]` (em-dash or ASCII `->`),
   the facilitator processes the flag via `scripts/raise-hand-arbiter.sh`:
   - `--detect <body>` extracts the named target.
   - `--record-raise-hand --cycle N --requesting A --target C` records the
     request and returns either `honored` (one raise-hand per cycle, per
     FR-MTG-7) or `deferred-to-next-cycle` (subsequent requests in the same
     cycle).
   - `--plan-insertion --invitees <csv> --requesting A --target C --cycle N`
     emits the speaker sequence: `C` first (inserted), then the round-robin
     resumes from the slot AFTER `A` in normal invite order. The round-robin
     order MUST NOT be permanently shifted by the insertion.
   - `--pending-deferred --cycle N+1` emits the deferred raise-hands carried
     into the next cycle; they MUST be honored as the FIRST action of that
     cycle. No raise-hand request MUST be silently dropped.
   - `--log-line --cycle N --requesting A --target C --status <s>` produces
     the arbitration record line that lands in the persisted transcript.

### Phase 5 — CLOSE (E76-S3)

Emit the `## Phase: CLOSE` marker. CLOSE drafts every post-meeting artifact
**in memory only** — no disk writes happen in this phase. The drafts produced
here feed into Phase 6 REVIEW for user disposition before any SAVE write.

The CLOSE draft set:

1. **Action-items batch** — one entry per trackable item surfaced during DISCUSS,
   typed against the eleven canonical action-item types (FR-MTG-20).
2. **Per-agent memory entries** — one draft per participating agent, capturing
   what that agent should carry forward (decided items, constraints, open items
   tracked, sources relied on).
3. **Meeting notes draft** — full notes body assembled from the live transcript
   plus the agreed action-item IDs and memory write-through agent list.

### Phase 6 — REVIEW (E76-S3, FR-MTG-12)

Emit the `## Phase: REVIEW` marker. REVIEW is the user's last interception
point — once SAVE starts, writes are atomic per-file. There is **no undo
semantic in v1**; the gate is the contract.

For each drafted artifact, present the draft to the user and capture an
explicit disposition via `scripts/review-gate.sh`:

- **`accept`** — the SAVE write proceeds for that artifact.
- **`edit`**   — the user supplies a revised payload; SAVE proceeds against
  the revised draft.
- **`drop`**   — the SAVE write is suppressed for that artifact. Zero bytes
  are written. **Drop on action-items leaves
  `docs/planning-artifacts/action-items.yaml` byte-identical to its
  pre-meeting state.** Drop on a per-agent memory entry writes zero files
  under that agent's `_memory/{agent}-sidecar/decisions/`.

Per-agent memory entries are reviewed **per-agent**: a meeting with N
participating agents may produce K accepted entries with K ≤ N (FR-MTG-25 /
AC6).

### Phase 7 — SAVE (E76-S3, FR-MTG-21 / FR-MTG-24 / FR-MTG-25 / FR-MTG-27)

SAVE performs the three writes that REVIEW accepted, gated through
`scripts/write-boundary.sh` for the AC10 / FR-MTG-31 state-free invariant:

1. **Action-items registry** (if accepted at REVIEW). Run
   `scripts/action-items-writer.sh --registry docs/planning-artifacts/action-items.yaml --drafts <accepted-drafts.yaml> --source-meeting <slug> --date <YYYY-MM-DD>`.
   The writer:
   - Sets `schema_version: 2` on the registry header (idempotent).
   - Allocates daily-N IDs of the form `AI-{YYYY-MM-DD}-{N}` (N restarts at 1 each
     day, scanned from existing entries).
   - Resolves `target_command` from `type` via the eleven-entry lookup table
     at `scripts/lib/type-target-resolver.sh` — rejecting any unknown type.
   - Appends fully-rendered v2 entries (`id`, `created`, `source_meeting`, `type`,
     `priority`, `status`, `target_command`, `assignee`, `context_for_target`,
     `acceptance`) at the tail of the registry — leaving v1 entries
     byte-identical (no migration; ADR-086 D2).
   - Atomic write via `mktemp` + `mv`.
2. **Per-agent memory entries** (one per accepted draft). Run
   `scripts/memory-writethrough.sh --root . --drafts <accepted-mem-drafts/> --source-meeting <slug> --date <YYYY-MM-DD> --slug <slug>`.
   The writer emits one file per agent at
   `_memory/{agent}-sidecar/decisions/{YYYY-MM-DD}-{slug}.md` with frontmatter
   (`agent`, `date`, `source_meeting`, `type: decision`, `tags`) and the four
   mandatory H2 sections in fixed order:
   - `## What I decided / agreed to in this meeting`
   - `## Constraints I committed to`
   - `## Open items I'm tracking` (lists action-item IDs where the agent is
     `assignee` or that materially affect the agent's future work)
   - `## Sources I relied on`
3. **Meeting notes** (if accepted at REVIEW). Run
   `scripts/meeting-notes-writer.sh --root . --payload <payload.yaml> --date <YYYY-MM-DD> --slug <slug>`.
   The writer emits `docs/creative-artifacts/meeting-{YYYY-MM-DD}-{slug}.md`
   with frontmatter (per-attendee + total token-cost breakdown,
   `scratchpad_extractions:` populated from the payload list — empty `[]` when
   no extractions occurred — and `action_items:` IDs from step 1) and the required body sections (charter, summary, research preludes,
   transcript, decisions, risks identified from `[challenge]` turns, open
   questions, scratchpad final state, action items, memory write-through list).

After all three writes complete, emit the `## Phase: SAVE` marker as the final
line of the live transcript.

**Anti-amnesia (FR-MTG-26 / AC8).** The per-agent memory entries surface
automatically on the next session-load of that agent's sidecar via the §4.10
sidecar load contract (in `gaia-memory-management`) — matched on `tags` or
`source_meeting`. The agent's next workflow that touches a topic carried
forward MUST receive the entry without explicit user prompting. This is the
anti-amnesia property the intake mandates.

**State-free write boundary (AC10).** Every disk write in Phase 7 MUST go
through `scripts/write-boundary.sh`. The asserter rejects any path outside
`docs/creative-artifacts/meeting-*.md`,
`docs/planning-artifacts/action-items.yaml`, and
`_memory/{agent}-sidecar/decisions/*.md`.

## Scratchpad pin + extraction (E76-S4, ADR-085, FR-MTG-11..15)

The scratchpad is a shared append-only buffer that any agent or the user MAY
pin to during DISCUSS. Every pin receives a monotonic `SP-N` ID (N starts at
1, increments by 1). Re-pinning an existing `SP-N` is **latest-wins** at the
rendered scratchpad block; the prior content is retained in transcript history
for audit (FR-MTG-11). Every agent's per-turn context payload includes the
rendered scratchpad block so any agent MAY reference any `SP-N`.

### Pin and render — `scratchpad-allocate.sh`

The scratchpad data model is file-backed (one record per line, pipe-delimited):

```
SP-N|content|content_type|pinning_agent|intent|history_count
```

- `pin --state <file> [--target SP-N] --content <s> --intent <s> --agent <s>`
  appends a new SP-N (or replaces an existing one — `history_count` bumps).
- `list --state <file> --field {id|content|content_type|pinning_agent|intent|history_count}`
  emits the records in pin order.
- `render --state <file>` emits the latest-wins block (one line per SP-N) for
  agent-context injection.

### CLOSE-phase disposition (FR-MTG-12, AC4 / AC13)

At CLOSE, the orchestrator walks scratchpad items in ascending `SP-N` order
and prompts the user with the canonical three-option choice from
`scratchpad-disposition.sh --prompt`:

| Disposition | Effect at SAVE |
|-------------|----------------|
| **Extract** | Writes a permanent file under `docs/creative-artifacts/meeting-scratchpad/{YYYY-MM}/{slug}/`; the path is added to the meeting notes' `scratchpad_extractions:` list. |
| **Keep in notes only** | Item appears in the notes "Scratchpad final state" section; NO extracted file; absent from `scratchpad_extractions:`. |
| **Drop** | Item is omitted from "Scratchpad final state"; NO extracted file; absent from `scratchpad_extractions:`. |

`scratchpad-disposition.sh --check <value>` validates a single disposition
input (case-insensitive). Any value other than the three canonical options
exits 2 — the orchestrator MUST re-prompt.

### Deterministic extraction path (FR-MTG-13, ADR-085, AC5 / AC6 / AC7 / AC11 / AC12)

The path is computed entirely from `(meeting-date, meeting-slug, SP-N,
content-type, content, intent)` — the skill MUST NOT prompt the user for a
path:

```
docs/creative-artifacts/meeting-scratchpad/{YYYY-MM}/{slug}/SP-{N}-{auto-slug}.{ext}
```

- `{YYYY-MM}` = first seven chars of the meeting date.
- `{slug}` = the meeting notes' canonical slug (FR-MTG-27 — owned upstream;
  this skill consumes it).
- `{auto-slug}` = lowercased + alphanumeric-with-`-` + truncated-to-40-chars
  projection. Source: the content's first textual line; fall back to the
  pinning agent's intent statement; final fallback `untitled`.
- `{ext}` = content-type-driven (`json` / `ts` / `py` / `sh` / `md` / `go` /
  `swift` / `kt` / `rs` / `java`); ambiguous content defaults to `md`.

`scratchpad-resolve-path.sh` is the single source of truth for the path
formula. `scratchpad-detect-type.sh` is the single source of truth for
content-type detection. Both are deterministic CLIs.

`{YYYY-MM}` and `{slug}` directories are created **lazily** on first
extraction — there are no `.gitkeep` placeholders. A future repo-wide sweep
that runs `find docs/creative-artifacts/meeting-scratchpad -type d -empty
-delete` MUST not break the skill; subsequent extractions transparently
re-create the directories (ADR-069 empty-bucket policy).

### Extracted-file frontmatter (FR-MTG-14, AC8)

`scratchpad-extractor.sh` writes the extracted file with this frontmatter
contract:

```yaml
---
source_meeting: meeting-{YYYY-MM-DD}-{slug}.md
source_scratchpad_id: SP-{N}
source_action_items: [<AI-IDs related to this SP-N or empty list>]
extracted_by: gaia-meeting
extracted_at: <ISO-8601 UTC>
content_type: <detected-type>
---
```

`source_action_items` is a YAML inline-list (`[]` when no related action items
exist, never omitted). `extracted_at` uses `date -u +%Y-%m-%dT%H:%M:%SZ` for
machine-portable UTC seconds precision.

### Replace-at-same-path semantics (FR-MTG-15, AC10 / AC11)

A future invocation that pins the same `SP-{N}` at the same source meeting
(same `{YYYY-MM}` AND same `{slug}`) **replaces** the file at the identical
path — atomic via `mktemp` + `mv`. `extracted_at` advances; no duplicate or
appended file is produced. Two distinct meetings (different `{slug}`) NEVER
collide because the path includes the slug.

### Meeting-notes integration (FR-MTG-14, AC9 / AC13)

`meeting-notes-writer.sh` reads the payload's `scratchpad_extractions:` list
(project-relative paths in ascending SP-N order) and emits it verbatim into
the notes frontmatter; emits `scratchpad_extractions: []` when the list is
empty. The "Scratchpad final state" body section reflects whatever the
orchestrator pre-rendered (Extract + Keep entries; Drop items already
filtered out).

### State-free invariant (FR-MTG-31, AC14)

Every extraction write is gated through `scripts/write-boundary.sh`. The
allowlist is unchanged from S1/S3 — `docs/creative-artifacts/*` already
covers the `meeting-scratchpad/` subtree. The scratchpad codepath MUST NOT
mutate `_memory/`, sprint state, story files, PRD, architecture, test plan,
threat model, or traceability.

## Helper Scripts

All helpers live under `scripts/` and are invoked as deterministic CLIs (no
LLM-side parsing inline — this is single-source-of-truth per ADR-057, ADR-073).

| Script | Purpose | AC / FR |
|--------|---------|---------|
| `charter-gate.sh` | Charter requirement guardrail | S1 AC1, AC2, FR-MTG-2 |
| `resolve-mode.sh` | Active-mode resolver + single-mode invariant + alias canonicalisation | S1 AC4, S5 AC6 / AC9 / AC10, FR-MTG-17, FR-MTG-16 |
| `resolve-invitees.sh` | INVITE-phase invitee resolver — mode-default lookup + graceful degradation + override path | S5 AC1-AC8, AC11-AC14, FR-MTG-17, FR-MTG-18 |
| `select-notes-template.sh` | Closing-artifact bias → notes-template selector (one-to-one mapping) | S5 AC15, FR-MTG-17 |
| `lib/load-mode-registry.sh` | Shared YAML registry loader (canonical + alias lookup, scalar / list field readers) | S5 (substrate) |
| `turn-order.sh` | Round-robin turn-order generator | S1 AC5, FR-MTG-7 |
| `turn-header.sh` | Per-turn header renderer | S1 AC6, FR-MTG-10, NFR-MTG-1 |
| `resolve-user-name.sh` | User-interjection name resolver (override -> git) | S1 AC7, FR-MTG-10 |
| `lifecycle-marker.sh` | Seven-phase lifecycle marker emitter | S1 AC3, FR-MTG-1 |
| `write-boundary.sh` | State-free write-boundary asserter | S1 AC8, FR-MTG-31 |
| `research-phase-dispatch.sh` | Research-phase fork allowlist + flags + sidecar path + frontmatter audit | S2 AC1, AC3, AC5, AC11, FR-MTG-4, FR-MTG-6, ADR-084, ADR-086 |
| `lib/prelude-format.sh` | Fixed prelude format renderer | S2 AC4, FR-MTG-4 step 4 |
| `cite-or-flag-check.sh` | Per-line classification + draft-turn gate + transcript verifier | S2 AC6, AC7, AC10, FR-MTG-5, FR-MTG-28, NFR-MTG-2 |
| `raise-hand-arbiter.sh` | Raise-hand detection + insertion planning + one-per-cycle ledger | S2 AC8, AC9, FR-MTG-7, FR-MTG-9 |
| `review-gate.sh` | REVIEW-phase disposition router (accept/edit/drop) | S3 AC1, FR-MTG-12 |
| `lib/type-target-resolver.sh` | Eleven-type action-item type → target_command resolver | S3 AC3, FR-MTG-20, ADR-086 |
| `action-items-writer.sh` | v2 action-items registry writer (idempotent header bump, daily-N IDs, atomic write) | S3 AC2, AC5, FR-MTG-21, ADR-086 |
| `memory-writethrough.sh` | Per-agent sidecar decision write-through (frontmatter + four mandatory H2 sections) | S3 AC6, AC7, FR-MTG-24, FR-MTG-25 |
| `meeting-notes-writer.sh` | Saved meeting-notes writer (FR-MTG-27 frontmatter + body sections) | S3 AC9, FR-MTG-27 |
| `scratchpad-allocate.sh` | In-memory scratchpad data model: monotonic SP-N + latest-wins replace + render | S4 AC1-AC3, FR-MTG-11 |
| `scratchpad-disposition.sh` | CLOSE-time disposition validator (Extract / Keep / Drop only) | S4 AC4, AC13, FR-MTG-12 |
| `scratchpad-detect-type.sh` | Content-type detection (json / ts / py / sh / md / go / swift / kt / rs / java) | S4 AC7, FR-MTG-13 |
| `scratchpad-resolve-path.sh` | Deterministic extraction-path resolver (auto-slug + extension) | S4 AC5, AC6, AC11, AC12, FR-MTG-13, ADR-085 |
| `scratchpad-extractor.sh` | Atomic extracted-file writer (frontmatter linkage + replace-at-same-path) | S4 AC8, AC10, AC14, FR-MTG-14, FR-MTG-15 |

## Skill Outputs

- **Live transcript** (stdout). Phase markers + per-turn headers + turn bodies
  + user interjections. Always emitted in real time.
- **Saved meeting transcript** at
  `docs/creative-artifacts/meeting-{YYYY-MM-DD}-{slug}.md`. S1 produces a
  minimum viable file (markers + headers); E76-S3 extends to the full
  FR-MTG-27 frontmatter and required sections.

## Threat-Model Mitigations (E76-S2)

The research / cite-or-flag / raise-hand surface inherits three threats from
`docs/planning-artifacts/threat-model.md` §3.15. Mitigations live in the S2
helpers:

- **T-MTG-1 — web-search exfiltration.** `--no-web` removes `WebSearch` /
  `WebFetch` from the research-phase fork allowlist and records
  `web_search: disabled` in the meeting frontmatter at SAVE. Recommend
  opt-out via `--no-web` for sensitive charters that involve secrets,
  internal credentials, or unpublished plans. Auditors can verify the
  disabled state from the saved frontmatter alone.
- **T-MTG-2 — prompt-injection from external pages.** The cite-or-flag
  invariant (FR-MTG-5) is the primary mitigation: anything an agent learned
  from an external page MUST cite that page's URL, and any factual claim
  with no citation MUST carry `[inference]`. The facilitator's pre-
  persistence HALT (AC7) blocks unflagged-inference turns from landing in
  the transcript. The sequential-turn invariant (ADR-045) prevents an
  injected page from racing across multiple agents in parallel.
- **T-MTG-3 — over-broad agent file reads.** The research-phase fork
  allowlist excludes write-capable tools (`Write` / `Edit` / `NotebookEdit`)
  per NFR-048 — even an over-eager read cannot mutate any artifact. The
  pre-save secret-pattern scrubber (`TC-MTG-SCRUB-1`) is out of scope for
  this story and lands separately; the charter is the agent's read-scope
  responsibility note.

## What's Out of Scope for S2

These land in E76-S3..S6 — do **not** retrofit them into the S1+S2 substrate:

- Decision record + action items + memory write-through — E76-S3.
- Full FR-MTG-27 saved-meeting frontmatter and required sections — E76-S3.
- Pre-save secret-pattern scrubber (`TC-MTG-SCRUB-1`, T-MTG-3 mitigation) —
  separate work.
- The `/gaia-validate-meeting` static-check skill that consumes AC10's
  verifiability — reserved namespace, not implemented.
- ~~Scratchpad pin / extraction — E76-S4.~~ (LANDED — see "Scratchpad pin + extraction".)
- The eight non-`decide` modes — E76-S5.
- ~~Guardrails (max-turns, per-agent cap, loop detection) — E76-S6.~~ (LANDED — see "Guardrails + cost-reporting refinements".)
- ~~Cost-reporting refinements beyond the per-turn header — E76-S6.~~ (LANDED — see "Guardrails + cost-reporting refinements".)

## Guardrails + cost-reporting refinements (E76-S6)

E76-S6 closes out the operational envelope of `/gaia-meeting` by adding four
hard halts, two caps, a loop detector, and a deterministic cost-check cadence.
All guardrail checks run BEFORE the offending turn is appended to the
persisted transcript — a halted meeting MUST NOT contaminate the saved
artifact (FR-MTG-28).

### Four hard halts (FR-MTG-28)

Each halt emits a single canonical line via `scripts/halt-event.sh`:

```
HALT condition=<NAME> agent=<ID|—> fr=<FR-MTG-ID> detail=<text>
```

This is the **terminal** live-stream event — no subsequent turn header, no
cost-check, no farewell. The lifecycle exits cleanly after emission.

| Condition | Trigger | Helper |
|-----------|---------|--------|
| `CHARTER-MISSING` (FR-MTG-28, AC1) | `/gaia-meeting` invoked without a resolvable charter — halts at the charter-resolution gate before INVITE. | `scripts/charter-gate.sh` |
| `RESEARCH-MISSING` (FR-MTG-28, AC2) | RESEARCH→DISCUSS transition attempted without one structured prelude per invitee — bypassed only by `--skip-research`. | `scripts/research-gate.sh` |
| `CITE-OR-FLAG` (FR-MTG-28, FR-MTG-5, AC3) | A draft DISCUSS turn contains a factual claim with no citation marker and no `[inference]` token — checked BEFORE persistence. | `scripts/cite-or-flag-check.sh --gate-draft-turn` |
| `WRITE-BOUNDARY-VIOLATION` (FR-MTG-31, AC8) | A misdirected write target outside the three-prefix allow-list — refused at the central write helper. | `scripts/write-boundary.sh` |

### Caps and loop detection

| Cap | Default | Override | Helper |
|-----|---------|----------|--------|
| Max turns (AC4, FR-MTG-29) | 40 | `--max-turns N` | `scripts/max-turns-cap.sh --check --emitted-turns N` |
| Per-agent token cap (AC5, FR-MTG-29) | 25 000 tokens cumulative across research + discussion + raise-hand + research-interrupts | `--per-agent-cap N` | `scripts/per-agent-cap.sh --accumulate --agent <id> --tokens <N>` |

Per-agent cap muting is **one-way** — once an agent crosses the cap, a single
`MUTED agent=<id> tokens=<N> cap=<CAP> fr=FR-MTG-29` event is emitted, the
agent is skipped by both round-robin and raise-hand arbitration, and there is
NO unmute path within the same meeting (rationale: the cap exists to bound
spend; allowing unmute defeats the bound).

**Loop detection (AC6, FR-MTG-30)** — `scripts/loop-detector.sh` inspects the
last three consecutive turns. It fires when EXACTLY two distinct agents
occupy the window AND none of the three turns produced a progress signal
(new citation / new decision / new scratchpad pin). Three-way alternation
(A→B→C) and same-agent triples (A→A→A) do NOT trigger. On fire, the
facilitator injects a forced `FACILITATOR / LOOP-BREAK` turn.

### 10-turn cost-check cadence determinism (AC7, NFR-MTG-1, TC-MTG-STREAM-2)

`scripts/cost-cadence.sh` owns a single global emitted-turn counter. The
counter `--tick`s on **every** persisted turn header — round-robin, prelude,
raise-hand, research-interrupt, user-interjection, facilitator. The
cost-check fires whenever `counter % 10 == 0`, not when a round-robin slot
fires. This is the determinism contract that lets raise-hand insertions
(E76-S2) remain deterministic against the same cadence: a 30-turn meeting
fires cost checks at emitted-turn indices 10, 20, 30 regardless of how many
of those turns are insertions. The TC-MTG-STREAM-2 fixture asserts identical
fire-indices across a K=0 and a K=4 raise-hand run.

## References

- PRD §4.39 — `/gaia-meeting` peer-to-peer multi-agent discussion skill (FR-MTG-1, FR-MTG-2, FR-MTG-4, FR-MTG-5, FR-MTG-6, FR-MTG-7, FR-MTG-8, FR-MTG-9, FR-MTG-10, FR-MTG-16, FR-MTG-17, FR-MTG-28, FR-MTG-31, NFR-MTG-1, NFR-MTG-2).
- ADR-083 — Peer-to-peer multi-agent discussion topology.
- ADR-084 — Research-phase contract (sidecar load → SoT reads → web search → cited prelude).
- ADR-086 — Sidecar path reconciliation: `_memory/<agent>-sidecar/` is canonical.
- Test plan §11.56 — TC-MTG-CHARTER-1..3, TC-MTG-TURN-1..3, TC-MTG-STREAM-1, TC-MTG-STREAM-3, TC-MTG-RESEARCH-1..6, TC-MTG-GUARD-1.
- Threat model §3.15 — T-MTG-1 (web-search exfiltration), T-MTG-2 (prompt-injection from external pages), T-MTG-3 (over-broad agent file reads).
- FR-329 — Slash commands resolve via SKILL.md, not via the retired `commands/` directory.
- FR-MTG-3 — Reuses agent + stakeholder discovery from `/gaia-party` (full discovery wiring deferred beyond E76-S2; S2 still requires the explicit `--invitees` CSV).
