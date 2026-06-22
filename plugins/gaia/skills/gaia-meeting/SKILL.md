---
name: gaia-meeting
description: Peer-to-peer multi-agent discussion skill — seven-phase lifecycle (INVITE / CHARTER / RESEARCH / DISCUSS / CLOSE / REVIEW / SAVE) with charter requirement, decide default mode, round-robin turn arbitration, and live-streamed transcript. Use when "/gaia-meeting" or "run a peer-to-peer meeting".
argument-hint: "--charter \"<one-to-three-sentence charter>\" [--mode <mode>] [--invitees <P1,P2,...>]"
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: conversational
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class conversational --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

# gaia-meeting

Peer-to-peer multi-agent discussion orchestrator. GAIA agents and stakeholder
personas take sequential turns through a seven-phase lifecycle. The skill is
deliberately heavier-weight than `/gaia-party`: it requires a charter, drives a
mode-aware closing artifact bias, and enforces a state-free write boundary.

The skill shipped a **lifecycle foundation** — the seven-phase skeleton, charter
gate, default mode, live-stream header format, round-robin substrate, and
write boundary.

It layers on the **research phase** (sidecar load + source-of-truth reads
+ web search + cited prelude), the **cite-or-flag invariant** during
DISCUSS, and **raise-hand arbitration** with a one-per-cycle
defer queue. The downstream capabilities continue to layer:

- **CLOSE phase** decision record + action items + memory write-through, full saved-meeting frontmatter.
- **Scratchpad pin / extraction** (LANDED — see "Scratchpad pin + extraction" section below).
- **Nine non-`decide` modes** (LANDED — see "Mode Registry" section below).
- **Guardrails** (max-turns, per-agent cap, loop detection) + cost-reporting refinements.

The lifecycle leaves deterministic insertion-point hooks in the turn loop and lifecycle
dispatcher so later layers do not need to reshape this skeleton — they plug into the
RESEARCH and DISCUSS hooks rather than reimplementing the lifecycle.

## Path resolution

All artifact path references in this SKILL.md use the canonical locations under `.gaia/artifacts/creative-artifacts/` (meeting notes, scratchpad extractions), `.gaia/state/action-items.yaml` (action-items registry), and `.gaia/artifacts/planning-artifacts/` (cross-references to architecture/threat-model). The `scripts/write-boundary.sh` enforces canonical-only writes — legacy `docs/` prefix is REJECTED at runtime. Sister scripts (memory-writethrough.sh, research-phase-dispatch.sh, yield-gate.sh) resolve memory/session paths under `.gaia/memory/` only — `.gaia/` is the sole tree.

## Critical Rules

- **Charter required.** `--charter "<inline>"` is mandatory.
  `scripts/charter-gate.sh` HALTs with status `BLOCKED` before INVITE if the
  charter is absent — and **no** writes occur to `.gaia/artifacts/creative-artifacts/`,
  `.gaia/memory/action-items/`, or `.gaia/memory/{agent}-sidecar/decisions/`.
- **Sequential only.** Never parallelize per-turn invocations. Never
  reorder turns mid-round. The fork allowlist for read-only agent operations
  remains `[Read, Grep, Glob, Bash]`; no new tool grants are
  introduced.
- **State-free write boundary.** The skill writes ONLY to:
  - `.gaia/artifacts/creative-artifacts/meeting-notes/meeting-*.md`
  - `.gaia/state/action-items.yaml` (canonical)
  - `.gaia/memory/{agent}-sidecar/decisions/*.md`
  Every artifact write MUST be routed through `scripts/write-boundary.sh`.
  Disallowed: sprint-status.yaml, story files, PRD, architecture, test plan,
  threat model, traceability. The legacy root `_memory/action-items/`
  is **retired**.
- **Single-mode-only invariant.** Mode stacking is rejected at
  resolve time by `scripts/resolve-mode.sh`. Only one `--mode` flag is allowed.
- **Live-stream header on every emitted turn.** Format:
  `[round R / turn T / Speaker (Role) / per-turn-cost N tokens / running-total M tokens]`.
  No `>` line prefixes. The cadence counter (10-turn cost-check cadence) is
  advanced **per emitted turn**, not per round-robin slot — this is the
  determinism contract that lets raise-hand and research-interrupt
  insertions remain deterministic against the same cadence.
- **Cite-or-flag is enforced.** Every DISCUSS turn line that asserts a
  factual claim (about a file path, code behavior, prior decision, external
  system, or memory entry) MUST carry either a citation marker (project file
  path, URL, or `.gaia/memory/...` reference) or the literal `[inference]` token.
  The facilitator's pre-persistence check halts round-robin advancement on
  unflagged-inference lines BEFORE they land in the persisted transcript
  (hard guardrail).
- **Research-phase fork is read-only.** The single source-of-
  truth allowlist lives in `scripts/research-phase-dispatch.sh --print-allowlist`:
  `[Read, Grep, Glob, Bash, WebSearch, WebFetch]` (web on) or `[Read, Grep,
  Glob, Bash]` when `--no-web` is set. NEVER add `Write`, `Edit`, or
  `NotebookEdit` to the research fork — fork no-write isolation is a hard
  invariant.
- **Frontmatter persistence is shared with the CLOSE work.** The charter is captured
  into in-memory state and lifecycle markers are written to the live transcript;
  the full meeting-notes file format with required sections lands
  with the CLOSE work. A minimum viable transcript is produced that the CLOSE work extends.
- **Yield boundaries MUST use the substrate `AskUserQuestion` primitive, NOT
  stdout sentinels.** Forbidden
  sentinel strings inside §Procedure yield-boundary subsections:
  `<<YIELD-STOP`, `<<TURN-END`, and any future variant of a turn-terminal
  marker emitted via stdout. The script-side stdout-sentinel mechanism was
  empirically defeated by harness Auto Mode — the harness does
  not stop on stdout content (memory rule
  `feedback_askuserquestion_under_automode.md`). The substrate
  `AskUserQuestion` call halts the LLM turn at the substrate level
  regardless of Auto Mode and is therefore the only correct primitive for
  the five yield boundaries (post-CHARTER, post-RESEARCH, every-N DISCUSS,
  pre-CLOSE, pre-SAVE). Static enforcement:
  `tests/gaia-meeting-stdout-sentinel-forbid.bats` invokes
  `scripts/stdout-sentinel-scan.sh` against this SKILL.md and FAILS the build
  on any forbidden-pattern hit inside §Procedure scope.

### No fabricated user turns

The skill MUST NOT emit a turn attributed to the user under ANY persona,
label, or phase, regardless of mode, **EXCEPT when the user is explicitly invited as an attendee per the user-as-attendee carve-out, with origin=attendee per the schema extension**
(carve-out detail below). The user is not an agent; the user does not
appear as a `Speaker:` in any prelude or DISCUSS turn auto-emitted between
yield boundaries. An earlier regression — where two turns labelled
`${USER_NAME} (user)` (one RESEARCH prelude, one DISCUSS round-1 turn)
were emitted that the user never authored — surfaced this as a hard
correctness defect; this rule converts the prose contract (`The user does not appear in the round-robin order` /
`Resolve user-interjection labels via scripts/resolve-user-name.sh` /
`User interjections allowed at turn boundaries` / `--charter` +
`[i]nterject` / `--interject` authoring channels) into a testable
invariant.

The user has exactly three authoring channels — and only these:

- `--charter "<inline>"` on the initial invocation. The charter
  text is the user's voice for INVITE / CHARTER and is recorded in the
  meeting-notes frontmatter `charter:` field, NOT as a `Speaker:` turn.
- `[i]nterject "..."` (interactive prompt block) and `--interject` (on
  `--resume`) at any yield boundary. An interject turn
  carries `origin: interject` (and `dispatched_via: interject`)
  in its per-turn header.
- `me` / `user` / `<resolved-user-name>` in `--invitees`
  (**user-as-attendee carve-out**) — the user is added as a non-LLM attendee
  with a turn slot at every yield boundary, and the user's response is
  captured via the `AskUserQuestion` 5-option primitive
  (composition; no new substrate needed). An attendee turn carries
  `origin: attendee` per the session-state schema extension.

The `interject` and `attendee` origin markers are the ONLY exemptions to
the no-fabricated-user-turn invariant; both originate from substrate-driven
user input (interactive prompt block or `AskUserQuestion` response), never
from auto-emission between yields.

**User-as-attendee carve-out.** When the user is
explicitly invited via `me` / `user` / `<resolved-user-name>` in
`--invitees`, the user is added as a non-LLM attendee with a turn slot at
every yield boundary (via the `AskUserQuestion` response primitive). The user is **never** auto-emitted as a
DISCUSS turn between yields — the no-fabricated-user-turns invariant
holds for unsolicited / fabricated user turns; the carve-out
authorizes only user turns that originate from a substrate-driven
response (origin=attendee or origin=interject; persisted as
`origin: attendee` / `origin: interject` in the per-turn header per the
schema extension). The carve-out distinguishes (a) unsolicited
/ fabricated user turns — still forbidden — from (b) the invited-attendee
path where each turn originates from an `AskUserQuestion` response, never
from auto-emission.

Static enforcement: `tests/no-fabricated-user-turns.bats` scans a saved
transcript for any turn whose `Speaker:` field matches the resolved user
name (per `scripts/resolve-user-name.sh`) AND whose `origin:` (or
`dispatched_via:`) is not `interject`, and FAILS on detection.

Invitee-token enforcement: `scripts/resolve-invitees.sh` rejects literal
`me` / `user` tokens (case-insensitive) and any token equal to the resolved
user name (case-sensitive). Each offending token produces a single-line
WARNING (`[gaia-meeting] WARNING: invitee token "<token>" resolves to the
user — the user is not an agent and is not auto-included; user authoring
uses --charter / [i]nterject only`) and is dropped from the resolved CSV
without halting the meeting.

## Architectural Anchors

- **Peer-to-peer multi-agent discussion topology** — peer-to-peer on
  top of Claude Agent Teams with a sequential-fork fallback. The skill implements the
  *sequential* substrate that both topology arms share. The
  Agent-Teams-vs-fallback decision is invisible at this layer.
- **Sequential-fork subagent pattern** — turns are sequential.
  Never parallel.
- **Slash-command resolution** — the `/gaia-meeting` slash command resolves via this SKILL.md
  only. **Never** repopulate `gaia-framework/plugins/gaia/commands/`.

## Seven-Phase Lifecycle

| # | Phase | User Involvement | Write Boundary |
|---|-------|------------------|-----------------|
| 1 | INVITE | None directly — invitee list provided via `--invitees` or resolved from agent + stakeholder discovery (the discovery routine is shared with `/gaia-party`; an explicit `--invitees` CSV is accepted). | None (in-memory state only) |
| 2 | CHARTER | `--charter` flag (inline) OR interactive fallback. | None (in-memory state only) |
| 3 | RESEARCH | The marker appears in the transcript so the static check sees the full phase sequence. | None at this stage |
| 4 | DISCUSS | Round-robin turns matching invite order. User interjections allowed at turn boundaries. | Live transcript only (no persistence yet) |
| 5 | CLOSE | Closing-artifact bias depends on active mode. For `decide` (default) — decision record + action items. | None at this stage (decision-record + action-items writes arrive later) |
| 6 | REVIEW | Brief user-facing review pass — confirm decisions, action items, and any open questions. | None |
| 7 | SAVE | Persist the live transcript to `.gaia/artifacts/creative-artifacts/meeting-notes/meeting-{YYYY-MM-DD}-{slug}.md`. | `.gaia/artifacts/creative-artifacts/` only |

The phase-marker emitter is `scripts/lifecycle-marker.sh`. Every phase emits
its marker line into the live transcript so a static check can scan
the saved file for the full sequence.

## `decide` Default Mode

When `--mode` is absent, `scripts/resolve-mode.sh` returns `decide`. The
`decide` mode contract:

- **Default invitees.** `decide` does NOT inject mode-default invitees. The
  invitee list is the user-specified set only.
- **Closing-artifact bias.** `decision-record`. The skill documents the bias and defaults to `decide`
  when `--mode` is absent.

## Mode Registry

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
| `clarify`      | `clarification`, `questions` | (none — user-specified only)             | `clarification-notes`       |

**Single-mode-only invariant.** `scripts/resolve-mode.sh` rejects
two or more `--mode` flags before INVITE — exit code 2 with a stderr message
that lists both supplied values. No transcript /
action-item / per-agent memory entry is written when this fires.

**Alias canonicalisation.** `--mode=ux` resolves to the
canonical `design` entry; the saved-notes frontmatter records `mode: design`.
Likewise `--mode=clarification` and `--mode=questions` both resolve to the
canonical `clarify` entry. Aliases are recorded against their canonical mode in
the saved-notes frontmatter.

**Default-invitee resolution (INVITE phase).**
`scripts/resolve-invitees.sh --mode <m> --invitees "<csv>" --installed <path>`
reads the registry and an "installed" identifier list (one ID per line) and
emits the resolved set, the missing list (when any), the bias, the canonical
mode name, the `invitees_override` flag, and the resolved-default subset.
Identifiers in `default_invitees` are matched against the installed list;
missing entries are omitted from the resolved set and surfaced in the
`missing_invitees` audit field.

**Graceful degradation.** When one or more default
invitees are missing the resolver emits a single-line WARNING to stderr with
the stable prefix `[gaia-meeting] WARNING: missing default invitee(s) for
mode <mode>: <list> (resolved subset: <list>)`. The exit code stays 0 — the
INVITE phase proceeds with the resolved subset. The frontmatter writer
records `missing_invitees: [<list>]` (empty list when all resolved).

**`--invitees` override path.** When `--invitees` is
supplied with `--invitees-override`, the user CSV is authoritative — default
invitees are NOT auto-added, no missing-invitee WARNING fires, and the saved
frontmatter records `invitees_override: true`.

**Closing-artifact bias plumbing.**
`scripts/select-notes-template.sh --bias <bias>` emits the absolute path to
the matching template under the skill's `knowledge/` subtree. The mapping is
one-to-one — every bias has its own template — and selection at CLOSE never
affects what agents say during DISCUSS; it only shapes the facilitator's
notes-drafting prompt.

Unknown modes are rejected with a non-zero exit code at resolve time.

## Round-Robin Turn Arbitration

The DISCUSS-phase turn loop is driven by `scripts/turn-order.sh`. Given an
invitee CSV in invite order and a turn count, the helper emits a deterministic
round-robin sequence — one speaker label per line.

**Pre-dispatch hook.** The orchestrator's turn loop
follows this contract:

```
for slot in invite_order_cycle:
    # Pre-dispatch hook — overridden to inject raise-hand
    # and research-interrupt turns BEFORE the slot's normal dispatch.
    pre_dispatch_hook(slot)
    dispatch(slot)
```

Raise-hand and research-interrupt insertions wire into
`pre_dispatch_hook` without reshaping the loop. The cadence counter
(`turn_count_emitted`) is advanced for every emitted turn — including
inserted ones — preserving per-emitted-turn determinism.

## Live-Stream Header

Every emitted turn — agent turn, raise-hand insertion,
research-interrupt insertion, user interjection — produces a single
deterministic header line via `scripts/turn-header.sh`:

```
[round R / turn T / Speaker (Role) / per-turn-cost N tokens / running-total M tokens]
```

- **No `>` prefix** — per the literal spec.
- **Cadence advances per emitted turn**, not per round-robin slot. This is
  the determinism guarantee that lets insertions remain deterministic
  against the 10-turn cost-check cadence.
- A brief cost check is emitted after every 10 emitted turns.

### User-interjection name resolution

The `Speaker` label for a user interjection is resolved by
`scripts/resolve-user-name.sh` in this order — override wins:

1. `meeting.user_name` from project `settings.json` (or `.claude/settings.json`).
2. `git config user.name` (fallback).

The skill **does not** fall through to OS username — the spec is
explicit. If neither source resolves a name, the resolver exits non-zero and
the orchestrator surfaces a guidance message ("set `meeting.user_name` in
`settings.json` or run `git config --global user.name '<name>'`").

## State-Free Write Boundary

Every artifact write in this skill MUST be gated by
`scripts/write-boundary.sh`. The asserter accepts a relative path and exits 0
only if the path is one of:

- `.gaia/artifacts/creative-artifacts/meeting-notes/meeting-*.md`
- `.gaia/state/action-items.yaml` (canonical registry)
- `.gaia/memory/{any-prefix}-sidecar/decisions/*.md`
- `.gaia/memory/meeting-sessions/*.yaml` (interactive checkpoint mode session-state files)

The legacy path `_memory/action-items/` is **retired** —
the canonical action-items registry is now the single-file YAML at
`.gaia/state/action-items.yaml`. New writes MUST target the
canonical location.

The `.gaia/memory/meeting-sessions/*.yaml` prefix lets the session-state helper persist session-state fields
across user-driven yields without violating the state-free invariant. Reaping
of stale session files is handled by the SAME 30-day reaper that walks
`.gaia/memory/checkpoints/` (`scripts/lib/checkpoint-reaper.sh`) — single source
of truth for retention policy.

Any other path is REJECTED with exit code 2. This is the invariant that keeps
`/gaia-meeting` truly state-free — sprint status, story files, PRD,
architecture, test plan, threat model, and traceability are NEVER touched by
this skill, ever.

## Interactive Checkpoint Mode

The Claude Code skill runtime is one-input/one-output per LLM turn. The
"live screen output + user interjections" promise cannot be fulfilled inside a
single LLM turn — it requires re-entry across top-level user turns. The topology decision
makes checkpoint-yield re-entry the canonical
interactivity surface, with **identical user-visible behaviour** under
Substrate A (Claude Agent Teams) and Substrate B (sequential-fork fallback).

### Canonical user-prompt block

Every checkpoint yield emits a substrate `AskUserQuestion` tool call with
the canonical five-option composition: 4 explicit options
(`[c]ontinue`, `[p]ause`, `[w]rap-up`, `[a]bort`) plus the substrate's
auto-Other slot which accepts `[i]nterject` free-text. The auto-Other free-text
binding is the substrate-natural mapping for [i]nterject — it is the only
one of the five options that carries a payload (per the
`--interject "<text>"` semantics).

The legacy single-line text rendition is preserved here verbatim as a
documentation marker (single source of truth for the option labels — do not
paraphrase):

```
[c]ontinue / [p]ause / [i]nterject "..." / [w]rap-up / [a]bort
```

The prompt is rendered by the substrate
`AskUserQuestion` primitive — NOT by the script-side stdout-sentinel
mechanism (which was empirically defeated by harness Auto Mode;
see §Procedure §Substrate-enforced turn-terminal yield contract).

| Option | Effect |
|--------|--------|
| `[c]ontinue` | Persist session state, advance to the next phase or turn group. |
| `[p]ause` | Persist session state, exit cleanly. The user resumes later via `/gaia-meeting --resume <session-id>`. |
| `[i]nterject "..."` | Inject a user turn at the resume point with the user's name resolved by `scripts/resolve-user-name.sh`. The injection consumes one emitted-turn slot and ticks the cost-cadence counter. The substrate captures the free-text via the auto-Other slot of `AskUserQuestion`. |
| `[w]rap-up` | Skip remaining DISCUSS turns and jump directly to CLOSE. Research and discussion state are preserved. |
| `[a]bort` | Persist session state and exit without writing CLOSE/SAVE artifacts. |

### Five mandatory yield boundaries

Every `/gaia-meeting` invocation yields at exactly these points:

1. **Post-CHARTER yield** — after `charter-gate.sh` accepts the charter and BEFORE INVITE proceeds. The yield message MUST surface a one-line note that the charter has been written to the session file and `--no-web` should be set for sensitive contexts.
2. **Post-RESEARCH yield** — after every invitee's prelude has landed in the shared message log and BEFORE DISCUSS starts.
3. **Every-N DISCUSS-turn yield** — after every `meeting.checkpoint_every_n_turns` emitted DISCUSS turns. The cadence is loaded by `scripts/checkpoint-cadence.sh` (default 4, clamp `[1, 10]`, single-line WARNING on out-of-range values).
4. **Pre-CLOSE yield** — BEFORE the CLOSE phase emits its draft set. The pre-CLOSE yield invokes `scripts/secret-scrubber.sh` against the in-memory state (charter + scratchpad pins) BEFORE `session-state.sh update` persists across the boundary.
5. **Pre-SAVE yield** — BEFORE the SAVE phase performs the three writes accepted at REVIEW.

### Session-state helper

`scripts/session-state.sh` is the single source of truth for persisting
session state to `.gaia/memory/meeting-sessions/{YYYY-MM-DD}-{slug}.yaml`. Schema
(every field round-trips losslessly):

| Field | Type | Purpose |
|-------|------|---------|
| `session_id` | string | `{date}-{slug}` |
| `phase` | enum | One of `INVITE`, `CHARTER`, `RESEARCH`, `DISCUSS`, `CLOSE`, `REVIEW`, `SAVE` |
| `round` | integer | DISCUSS round counter |
| `turn_counter` | integer | Total emitted turns (including insertions) |
| `cadence_counter` | integer | Modulo-10 cost-check ticker — round-trips through `session-state.sh` so the 10-turn cadence stays deterministic across yields |
| `raise_hand_ledger` | string | One-per-cycle record |
| `scratchpad_state` | string | Latest-wins SP-N → content digest map |
| `cumulative_cost` | integer | Running token total |
| `last_checkpoint_at` | ISO-8601 | UTC timestamp of the most recent yield |
| `last_checkpoint_phase` | enum | The phase the next `--resume` enters at |
| `last_yield_emitted_at` | ISO-8601 | UTC timestamp written by `scripts/yield-gate.sh` immediately before the turn-terminal sentinel — read by `--resume` for consistency regardless of whether the LLM honoured the STOP |

CLI shape:

```
session-state.sh create --file <path> --session-id <id>
session-state.sh read   --file <path> --field <name>
session-state.sh update --file <path> --field <name> --value <value>
```

Writes are atomic via `mktemp` + `mv`. Every persist call MUST first pass
through `scripts/write-boundary.sh` for the amended invariant.

### Resume flags

Parsed by `scripts/parse-resume-flags.sh` (single source of truth — no inline
flag handling in SKILL.md):

- `--resume <session-id>` — REQUIRED for the next three flags. Re-enters at
  `last_checkpoint_phase` with all session-state fields preserved.
- `--continue` — proceed without user input from the resume point.
- `--interject "<text>"` — inject a user turn at the resume point, labelled
  with the resolved user name (`scripts/resolve-user-name.sh`).
- `--wrap-up` — jump directly to CLOSE preserving research and DISCUSS state.

The four flags are mutually exclusive — at most one of `{--continue,
--interject, --wrap-up}` may accompany `--resume`. The parser exits non-zero
on stacking. A bare `--resume <id>` (no action flag) resolves to
`action=resume_default` — the orchestrator re-issues the canonical prompt
block from `last_checkpoint_phase`.

### Substrate invariance

The user-visible behaviour of the prompt block, yield boundaries, resumed
phase, and cumulative-cost rounding MUST be identical under both substrates.
Substrate selection is invisible at this layer — the checkpoint contract
binds the LLM-driven `/gaia-meeting` orchestration to a substrate-agnostic
re-entry surface.

### Helper-script byte-identity baseline

The pre-story SHA-256 baseline of the five protected helpers is recorded at
`.gaia/memory/checkpoints/meeting-checkpoint-baseline.sha256`. CI verifies the baseline on
every PR — modifying any of the protected helpers MUST be a deliberate,
separate story with an updated baseline:

- `scripts/turn-header.sh`
- `scripts/cite-or-flag-check.sh`
- `scripts/raise-hand-arbiter.sh`
- `scripts/cost-cadence.sh`
- `scripts/substrate-probe.sh` (recorded as `<absent>` until it lands)

The cadence-counter persistence lives ENTIRELY in
`session-state.sh` — `cost-cadence.sh` was NOT modified.

## Procedure

### Substrate-enforced turn-terminal yield contract

The five yield boundaries below (post-CHARTER, post-RESEARCH, every-N
DISCUSS, pre-CLOSE, pre-SAVE) are each implemented as a two-step procedure:

1. **Side-effect step (script).** Exec
   `scripts/yield-gate.sh --phase <phase> --session-id <id> --side-effect-only`.
   The helper writes `last_checkpoint_phase` and `last_yield_emitted_at`
   via `session-state.sh update` and produces ZERO stdout output. The
   side-effect-only behaviour is the default; the
   explicit flag is retained so the procedure prose at every boundary
   documents the intent.
2. **Substrate-halt step (LLM).** Emit a substrate `AskUserQuestion` tool
   call as the FINAL action of the current LLM turn. The substrate halts
   the turn at the harness layer regardless of Auto Mode — the next user
   turn carries the response payload. The question header MUST name the
   yield boundary (e.g., `Yield: post-CHARTER`); the canonical 4 explicit
   options + auto-Other [i]nterject composition is documented under
   §Interactive Checkpoint Mode → §Canonical user-prompt block.

> The substrate `AskUserQuestion` tool call ENDS the current LLM turn at
> the harness layer. The skill MUST NOT emit any further output after the
> AskUserQuestion call until it is re-entered via `/gaia-meeting --resume
> <session-id>` (with optional `--continue` / `--interject "..."` /
> `--wrap-up`) OR via the substrate's response-driven re-entry on the next
> top-level user turn. This is a substrate-enforced boundary, not an LLM
> discipline.

**History.** An early iteration documented these boundaries with prose-side enforcement
which empirically failed (lifecycle ran end-to-end in a single
LLM turn with zero prompt blocks emitted). A follow-up moved enforcement to a
script-side turn-terminal stdout sentinel which also empirically failed — the harness Auto Mode does not stop on stdout content (memory
rule `feedback_askuserquestion_under_automode.md`). The final iteration moved enforcement to the
substrate `AskUserQuestion` primitive which halts the LLM turn at the harness
layer regardless of Auto Mode. The `last_checkpoint_phase` and
`last_yield_emitted_at` session-state writes from yield-gate.sh are preserved
verbatim — the side-effect-ordering invariant still
holds: the script's side-effect writes complete BEFORE the LLM emits the
AskUserQuestion call, so `--resume` reads a consistent state regardless of
how the user responds.

`scripts/checkpoint-cadence.sh` is byte-identical to its baseline
— `yield-gate.sh` consumes its output via stdin/argv and the
cadence-counter round-trip continues to hold.
This work does not introduce a parallel cadence counter.

### Phase 1 — INVITE

1. Resolve the active mode via `scripts/resolve-mode.sh [--mode <m>]`
   (canonicalises aliases — `ux` → `design`).
2. Resolve invitees via
   `scripts/resolve-invitees.sh --mode <canonical> --invitees "<csv>" --installed <path> [--invitees-override]`:
   - When `--invitees-override` is set, the user CSV is authoritative and no
     mode-default lookup runs.
   - Otherwise the resolver merges the user CSV with the mode's
     `default_invitees`, gracefully degrading missing identifiers
     and surfacing a single-line WARNING per missing entry.
3. Emit the `## Phase: INVITE` marker via `scripts/lifecycle-marker.sh`.
4. **Mode-B teammate spawn (when `SESSION_MODE == team`).** After the invitee
   set is resolved, spawn each invitee ONCE as a persistent teammate so the
   RESEARCH/DISCUSS phases can drive the same long-lived agents across turns
   (instead of the Mode A per-turn fresh subagent). For each resolved invitee
   `<persona>`:
   - run `bash scripts/meeting-mode-b-bridge.sh meeting_spawn_participant <persona> "<charter-context>"`
     — the bridge does the registry write + provenance log + **fail-closed
     reviewer clean-room gate** (a reviewer persona is REFUSED here and the
     meeting MUST NOT proceed with it as a teammate) + the 8-teammate ceiling.
     It returns the teammate `<handle>` on stdout. Record the
     `<handle> → <persona>` map (the bridge persists it in the participant map).
   - emit the main-turn `Agent(run_in_background: true, name: "<handle>")` tool
     call with the persona's system prompt to actually launch the background
     teammate. (The bash bridge CANNOT launch the Agent — `Agent`/`SendMessage`
     are main-turn LLM tools; the bridge is bookkeeping.)
   - If the bridge emits `MODE_B_FALLBACK` (substrate unavailable), abandon the
     team path for this meeting and fall back to the Mode A per-turn subagent
     dispatch documented in Phases 3/4.
   Under `SESSION_MODE != team` (Mode A) this step is skipped entirely — no
   teammates are spawned; each turn uses a fresh subagent per Phases 3/4.

### Phase 2 — CHARTER

1. Run `scripts/charter-gate.sh --charter "<inline>"`. If the script exits
   non-zero (BLOCKED), STOP — surface the script's stderr to the user. **No**
   writes are made under `.gaia/artifacts/creative-artifacts/`, `.gaia/memory/action-items/`,
   or `.gaia/memory/{agent}-sidecar/decisions/`.
2. On success, the charter is recorded in `MEETING_STATE_FILE` for later
   persistence (full frontmatter persistence ships with the CLOSE work).
3. Emit the `## Phase: CHARTER` marker.
4. **Post-CHARTER checkpoint yield (substrate-enforced).**
   Persist the initial session state via `scripts/session-state.sh create`
   (or `update` on resume), surface the one-line `--no-web` note for
   sensitive contexts, then exec
   `scripts/yield-gate.sh --phase post-charter --session-id <id> --side-effect-only`.
   The helper writes `last_checkpoint_phase` and `last_yield_emitted_at` via
   `session-state.sh update` and produces no stdout output.
   AFTER the helper returns, emit a substrate `AskUserQuestion` tool call
   as the final action of the current LLM turn:

   - **header:** `Yield: post-CHARTER`
   - **question:** `post-CHARTER yield — review charter and decide how to proceed`
   - **options:** `[c]ontinue`, `[p]ause`, `[w]rap-up`, `[a]bort` (4 explicit options; the substrate appends an auto-Other slot that accepts `[i]nterject` free-text)
   - **multiSelect:** `false`

   Per the §Procedure substrate-enforced turn-terminal contract above, the
   AskUserQuestion call ENDS the current LLM turn at the harness layer —
   the lifecycle resumes via `/gaia-meeting --resume <id>` or via the
   substrate's response-driven re-entry on the next top-level user turn.

### Phase 3 — RESEARCH

Only invited agents post preludes and DISCUSS turns. The user does not appear as a turn author in either phase. (See §No fabricated user turns for the user-as-attendee carve-out at yield boundaries — when the user is explicitly invited via `me` / `user` / `<resolved-user-name>`, the user takes a non-LLM attendee turn slot at each yield, captured via `AskUserQuestion`; never auto-emitted between yields.)

**Dispatch contract.** Each invited agent's prelude (RESEARCH) AND each DISCUSS turn MUST be produced by spawning a subagent via the **main-turn Agent tool** with the per-phase tool allowlist below. After the subagent returns its envelope, `dispatch-agent-turn.sh` wires the post-dispatch envelope assertion: the script parses `.agent` from the envelope, writes the sentinel via `lib/write-val-envelope.sh`, and invokes `assert_agent_envelope --expected-agent <agent>` from `lib/assert-agent-envelope.sh`. On assertion failure, `halt-event.sh` fires. Inline LLM role-play under the agent's persona is FORBIDDEN. The facilitator does not author agent turns; the facilitator orchestrates dispatch.

The canonical wrapper is `scripts/dispatch-agent-turn.sh --agent <id> --phase research --charter-ref <path> --session-id <id>`; every dispatched turn carries `dispatched_via: subagent` in its per-turn header. See `scripts/dispatch-provenance-check.sh` — the **pre-save provenance gate**, wired into Phase 7 SAVE — the SAVE will HALT if any prelude/DISCUSS turn lacks a `dispatched_via:` marker of `subagent` or `teammate`.

**Mode-B dispatch branch (when `SESSION_MODE == team`).** The contract above is
the Mode A path (fresh subagent per turn). Under Mode B the invitees were
already spawned as persistent teammates at INVITE (Phase 1, step 4). Do NOT
spawn a fresh subagent — instead drive the already-spawned teammate:
- run `bash scripts/meeting-mode-b-bridge.sh drive_turn <handle> "<research-prompt>"`
  for the pre-send bookkeeping (relay-pending + turn-counter), then emit the
  main-turn `SendMessage(to: "<handle>", ...)` tool call carrying the research
  prompt and await the reply;
- relay the returned prelude body via
  `bash scripts/meeting-mode-b-bridge.sh meeting_relay_turn <handle> "<body>"`
  (appends to the transcript with teammate identity metadata — the superset
  transcript-fidelity contract);
- render the per-turn header with `--dispatched-via teammate` (not `subagent`).
The bridge cannot itself call `SendMessage` (a main-turn tool) — it does the
bash bookkeeping before/after the LLM tool call. If the bridge emits
`MODE_B_FALLBACK` for a turn, fall back to the Mode A subagent dispatch for that
turn. Inline LLM role-play under the persona is FORBIDDEN in BOTH modes.

**Surface contract (RESEARCH output to the user).** A subagent dispatched via the main-turn Agent tool returns its result TO THE ORCHESTRATOR — Claude Code does NOT auto-show that result to the user (the same auto-collapse that hides Bash output and the Mode-A warning). The facilitator MUST therefore RELAY each invitee's returned prelude body to the user as user-visible LLM turn text, prefixed with the live-stream per-turn header (`[round R / turn T / Speaker (Role) / per-turn-cost N tokens / running-total M tokens]`). The meeting is a "live-streamed transcript" — every prelude the orchestrator sends to a subagent MUST appear on the user's screen as it lands; consuming a prelude silently (asserting its envelope but never re-emitting the body) violates this contract. This mirrors the §Surface contract precedent at the top of this SKILL.md (the Mode-A warning relay), applied to the per-turn agent output.

The RESEARCH phase implements the four-step contract:

1. **Per-agent sidecar load.** For each invited agent, load
   the canonical sidecar at `.gaia/memory/<agent>-sidecar/` via the existing tier-
   aware load contract (§4.10). The intake-shorthand path
   `.gaia/memory/agent-decisions/<agent>/` is NOT canonical — the reconciled path
   is `<agent>-sidecar/`. Resolve via
   `scripts/research-phase-dispatch.sh --sidecar-path <agent>`. Reads MUST be
   read-only — sidecar files MUST NOT be mutated during RESEARCH.
2. **Source-of-truth reads.** Inside a fork whose
   tool allowlist matches the research-phase allowlist (see below), each
   invited agent reads the project files relevant to the charter — typically
   architecture shards under `.gaia/artifacts/planning-artifacts/architecture/`, ADRs in
   `12-12-adr-detail-records.md`, SKILL.md files under
   `gaia-framework/plugins/gaia/skills/`, and other planning artifacts. Every
   path the agent reads MUST appear under `Sources consulted:` in the prelude.
3. **Web search.** When `--no-web` is NOT
   set, the research fork MAY invoke `WebSearch` and `WebFetch`. Each web
   result's URL, title, and snippet MUST be recorded under
   `Sources consulted:`. When `--no-web` IS set, web tools are excluded from
   the allowlist and the SAVE-time frontmatter records `web_search: disabled`.
4. **Cited prelude.** Each invited agent posts a prelude in
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

   The live-stream per-turn header MUST be emitted for every
   prelude turn. The DISCUSS phase MUST NOT start until every invited agent's
   prelude has landed in the shared message log — the prelude is the gate.

**Research-phase fork tool allowlist (single source-of-truth).** The
canonical allowlist is exposed by
`scripts/research-phase-dispatch.sh --print-allowlist [--no-web]`:

| Mode             | Allowlist                                        |
|------------------|--------------------------------------------------|
| Web enabled      | `Read, Grep, Glob, Bash, WebSearch, WebFetch`    |
| `--no-web`       | `Read, Grep, Glob, Bash`                         |

The allowlist NEVER contains `Write`, `Edit`, or `NotebookEdit`. Audit / threat-
model review MUST verify the contract from this single script.

**`--skip-research` audit invariant.** When
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

**Post-RESEARCH checkpoint yield (substrate-enforced).**
After every invitee's prelude has landed AND BEFORE DISCUSS begins, persist
session state via `scripts/session-state.sh update`, then exec
`scripts/yield-gate.sh --phase post-research --session-id <id> --side-effect-only`.
The helper writes `last_checkpoint_phase` and `last_yield_emitted_at` and
produces no stdout output. AFTER the helper returns, emit a substrate
`AskUserQuestion` tool call as the final action of the current LLM turn:

- **header:** `Yield: post-RESEARCH`
- **question:** `post-RESEARCH yield — review preludes and decide how to proceed`
- **options:** `[c]ontinue`, `[p]ause`, `[w]rap-up`, `[a]bort` (4 explicit options; auto-Other slot accepts `[i]nterject` free-text)
- **multiSelect:** `false`

Per the §Procedure substrate-enforced turn-terminal contract, the
AskUserQuestion call ENDS the current LLM turn at the harness layer.

`--resume <session-id> --continue` re-enters DISCUSS with `cadence_counter`,
`raise_hand_ledger`, `scratchpad_state`, and `cumulative_cost` preserved
verbatim from the paused state.

### Phase 4 — DISCUSS

Only invited agents post preludes and DISCUSS turns. The user does not appear as a turn author in either phase. (See §No fabricated user turns for the user-as-attendee carve-out at yield boundaries — when the user is explicitly invited via `me` / `user` / `<resolved-user-name>`, the user takes a non-LLM attendee turn slot at each yield, captured via `AskUserQuestion`; never auto-emitted between yields.)

**Dispatch contract.** Each invited agent's prelude (RESEARCH) AND each DISCUSS turn MUST be produced by spawning a subagent via the **main-turn Agent tool** with the per-phase tool allowlist below. After the subagent returns its envelope, `dispatch-agent-turn.sh` wires the post-dispatch envelope assertion: the script parses `.agent` from the envelope, writes the sentinel via `lib/write-val-envelope.sh`, and invokes `assert_agent_envelope --expected-agent <agent>` from `lib/assert-agent-envelope.sh`. On assertion failure, `halt-event.sh` fires. Inline LLM role-play under the agent's persona is FORBIDDEN. The facilitator does not author agent turns; the facilitator orchestrates dispatch.

The canonical wrapper is `scripts/dispatch-agent-turn.sh --agent <id> --phase discuss --charter-ref <path> --session-id <id>`; every dispatched turn carries `dispatched_via: subagent` in its per-turn header. The DISCUSS allowlist is the read-only minimum `Read, Grep, Glob, Bash`, exposed via `scripts/dispatch-agent-turn.sh --print-discuss-allowlist`. User interjections via `[i]nterject` carry `dispatched_via: interject`; the CHARTER turn carries `dispatched_via: charter`.

**Mode-B dispatch branch (when `SESSION_MODE == team`).** Identical to the
RESEARCH Mode-B branch: each DISCUSS round-robin slot drives the
already-spawned teammate via `meeting-mode-b-bridge.sh drive_turn <handle>` +
the main-turn `SendMessage(to: "<handle>")` tool call, relays the reply via
`meeting_relay_turn`, and renders the per-turn header with
`--dispatched-via teammate`. The round-robin order, cadence counter,
cite-or-flag check, raise-hand arbitration, caps, and loop detector are
mode-agnostic — they operate per emitted turn regardless of whether the turn
came from a persistent teammate or a fresh subagent. `MODE_B_FALLBACK` on a turn
falls back to the Mode A subagent dispatch for that turn.

**Surface contract (DISCUSS output to the user).** Exactly as in RESEARCH: each dispatched DISCUSS turn returns to the orchestrator and is NOT auto-shown to the user. The facilitator MUST RELAY every DISCUSS turn body to the user as user-visible LLM turn text, prefixed with the live-stream per-turn header, as the round-robin advances — including raise-hand insertions, research-interrupts, and facilitator loop-break turns. A DISCUSS turn that is dispatched and envelope-asserted but never re-emitted to the user is a contract violation: the user running the meeting MUST see the discussion unfold turn by turn, not just the final saved transcript.

1. Run `scripts/resolve-mode.sh [--mode <mode>]` to resolve the active mode.
2. Drive the turn loop via `scripts/turn-order.sh --invitees "<csv>" --turns <N>`.
3. For every emitted turn — agent turn AND user interjection — emit the
   per-turn header via `scripts/turn-header.sh`.
4. Resolve user-interjection labels via `scripts/resolve-user-name.sh`.
5. Increment the cadence counter per emitted turn; every 10 emit a cost check.
6. Emit the `## Phase: DISCUSS` marker at the start.
7. **Cite-or-flag check.** Before each draft turn lands in
   the persisted transcript, the facilitator runs
   `scripts/cite-or-flag-check.sh --gate-draft-turn <draft-file>`. If any
   line classifies as `unflagged-inference` (factual claim with neither a
   citation marker nor `[inference]`), the script exits non-zero with `HALT`,
   names the offending lines, and the facilitator HALTs round-robin
   advancement until the agent re-emits the turn with a marker. The offending
   turn MUST NEVER land in the persisted transcript (hard guardrail).
8. **Every-N DISCUSS-turn checkpoint yield (substrate-enforced).**
   After every `meeting.checkpoint_every_n_turns` emitted DISCUSS turns
   (default 4, loaded by `scripts/checkpoint-cadence.sh`), persist
   `cadence_counter` via `scripts/session-state.sh update --field cadence_counter`,
   then exec `scripts/yield-gate.sh --phase discuss-cadence --session-id <id> --side-effect-only`.
   The helper writes `last_checkpoint_phase` and `last_yield_emitted_at`
   and produces no stdout output. AFTER the helper returns, emit a substrate
   `AskUserQuestion` tool call as the final action of the current LLM turn:

   - **header:** `Yield: discuss-cadence`
   - **question:** `discuss-cadence yield — N DISCUSS turns since last yield; review and decide how to proceed`
   - **options:** `[c]ontinue`, `[p]ause`, `[w]rap-up`, `[a]bort` (4 explicit options; auto-Other slot accepts `[i]nterject` free-text)
   - **multiSelect:** `false`

   Per the §Procedure substrate-enforced turn-terminal contract, the
   AskUserQuestion call ENDS the current LLM turn at the harness layer.
   The cadence counter MUST advance per emitted DISCUSS turn (not per
   round-robin slot) and persists across the yield via `session-state.sh`.
   The cadence value is loaded once per session-load (default 4, clamp
   `[1, 10]`, single-line WARNING on out-of-range values). The
   10-turn cost-check cadence is independent of this checkpoint
   cadence — both fire on emitted-turn count and remain mutually deterministic.
9. **Raise-hand arbitration.** When an agent's
   turn ends with `[raise-hand → respond to {Name}]` (em-dash or ASCII `->`),
   the facilitator processes the flag via `scripts/raise-hand-arbiter.sh`:
   - `--detect <body>` extracts the named target.
   - `--record-raise-hand --cycle N --requesting A --target C` records the
     request and returns either `honored` (one raise-hand per cycle) or `deferred-to-next-cycle` (subsequent requests in the same
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

### Phase 5 — CLOSE

**Pre-CLOSE checkpoint yield (substrate-enforced).** BEFORE CLOSE drafts any
artifact, run `scripts/secret-scrubber.sh` over the in-memory state
(charter + scratchpad pins) AND THEN persist session state via
`scripts/session-state.sh update`. The scrubber is the SINGLE source of
truth for the secret-pattern regex set — no duplicated
implementation. The scrubbed payload is what lands in the persisted YAML
across the checkpoint boundary; the in-memory charter is also replaced
with the scrubbed copy so subsequent CLOSE/SAVE artifacts use the redacted
form.

After scrubbing, exec
`scripts/yield-gate.sh --phase pre-close --session-id <id> --side-effect-only`.
The helper writes `last_checkpoint_phase` and `last_yield_emitted_at` and
produces no stdout output. AFTER the helper returns, emit a substrate
`AskUserQuestion` tool call as the final action of the current LLM turn:

- **header:** `Yield: pre-CLOSE`
- **question:** `pre-CLOSE yield — about to draft close-time triage and artifacts; review and decide how to proceed`
- **options:** `[c]ontinue`, `[p]ause`, `[w]rap-up`, `[a]bort` (4 explicit options; auto-Other slot accepts `[i]nterject` free-text)
- **multiSelect:** `false`

Per the §Procedure substrate-enforced turn-terminal contract, the
AskUserQuestion call ENDS the current LLM turn. No CLOSE artifact prose
emits in the same LLM turn as the AskUserQuestion call.

`--resume <session-id> --wrap-up` re-enters at this point even from a paused
DISCUSS — the orchestrator preserves research preludes and accumulated
DISCUSS turns and proceeds directly to CLOSE drafting.

Emit the `## Phase: CLOSE` marker. CLOSE drafts every post-meeting artifact
**in memory only** — no disk writes happen in this phase. The drafts produced
here feed into Phase 6 REVIEW for user disposition before any SAVE write.

The CLOSE draft set:

1. **Action-items batch** — one entry per trackable item surfaced during DISCUSS,
   typed against the eleven canonical action-item types.
2. **Per-agent memory entries** — one draft per participating agent, capturing
   what that agent should carry forward (decided items, constraints, open items
   tracked, sources relied on).
3. **Meeting notes draft** — full notes body assembled from the live transcript
   plus the agreed action-item IDs and memory write-through agent list.

### Phase 6 — REVIEW

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
  `.gaia/state/action-items.yaml` byte-identical to its
  pre-meeting state.** Drop on a per-agent memory entry writes zero files
  under that agent's `.gaia/memory/{agent}-sidecar/decisions/`.

Per-agent memory entries are reviewed **per-agent**: a meeting with N
participating agents may produce K accepted entries with K ≤ N.

### Phase 7 — SAVE

**Pre-SAVE checkpoint yield (substrate-enforced).** BEFORE the three writes happen, persist session
state via `scripts/session-state.sh update --field phase --value SAVE`,
then exec
`scripts/yield-gate.sh --phase pre-save --session-id <id> --side-effect-only`.
The helper writes `last_checkpoint_phase` and `last_yield_emitted_at` and
produces no stdout output. AFTER the helper returns, emit a substrate
`AskUserQuestion` tool call as the final action of the current LLM turn:

- **header:** `Yield: pre-SAVE`
- **question:** `pre-SAVE yield — about to write artifacts to disk; review and decide how to proceed`
- **options:** `[c]ontinue`, `[p]ause`, `[w]rap-up`, `[a]bort` (4 explicit options; auto-Other slot accepts `[i]nterject` free-text)
- **multiSelect:** `false`

Per the §Procedure substrate-enforced turn-terminal contract, the
AskUserQuestion call ENDS the current LLM turn at the harness layer. No
artifact write to `.gaia/artifacts/creative-artifacts/`, `.gaia/memory/{agent}-sidecar/decisions/`,
the action-items registry, or `.gaia/memory/meeting-sessions/` MUST happen in
the same LLM turn as the AskUserQuestion call — the SAVE writes resume on
the next user turn after the user response is captured.

`[c]ontinue` proceeds to the SAVE writes; `[p]ause` exits cleanly so the
user can resume later via `--resume <session-id>`. There is **no undo
semantic in v1** — once `[c]ontinue` is selected, the SAVE writes are atomic
per-file and the gate is the contract.

**Pre-save provenance gate.** AFTER the user responds
`[c]ontinue` to the pre-SAVE AskUserQuestion and BEFORE the three writes
below, the SAVE flow pipes the in-memory transcript through
`scripts/dispatch-provenance-check.sh --stdin`. The audit asserts every
prelude/DISCUSS turn carries `dispatched_via: subagent` (Mode A) or
`dispatched_via: teammate` (Mode B) — or `interject` for a user turn; a
non-zero exit invokes `scripts/halt-event.sh` with the canonical error
format:

```
HALT: dispatch-provenance-check failed — N turn(s) lack a 'dispatched_via: subagent' or 'dispatched_via: teammate' marker. Re-run /gaia-meeting with the canonical Agent-tool (Mode A) / SendMessage (Mode B) dispatch primitive for the affected turns.
```

`halt-event.sh` emits the line to stderr and exits the skill non-zero. ALL
three writes below are aborted — no partial save. The audit follows the
Static-Audit Script Wiring Discipline;
the audit fires on every live save, not just under bats.

SAVE performs the three writes that REVIEW accepted, gated through
`scripts/write-boundary.sh` for the state-free invariant:

1. **Action-items registry** (if accepted at REVIEW). Run
   `scripts/action-items-writer.sh --registry .gaia/state/action-items.yaml --drafts <accepted-drafts.yaml> --source-meeting <slug> --date <YYYY-MM-DD>`.
   The writer:
   - Sets `schema_version: 2` on the registry header (idempotent).
   - Allocates daily-N IDs of the form `AI-{YYYY-MM-DD}-{N}` (N restarts at 1 each
     day, scanned from existing entries).
   - Resolves `target_command` from `type` via the eleven-entry lookup table
     at `scripts/lib/type-target-resolver.sh` — rejecting any unknown type.
   - Appends fully-rendered v2 entries (`id`, `created`, `source_meeting`, `type`,
     `priority`, `status`, `target_command`, `assignee`, `context_for_target`,
     `acceptance`) at the tail of the registry — leaving v1 entries
     byte-identical (no migration).
   - Atomic write via `mktemp` + `mv`.
2. **Per-agent memory entries** (one per accepted draft). Run
   `scripts/memory-writethrough.sh --root . --drafts <accepted-mem-drafts/> --source-meeting <slug> --date <YYYY-MM-DD> --slug <slug>`.
   The writer emits one file per agent at
   `.gaia/memory/{agent}-sidecar/decisions/{YYYY-MM-DD}-{slug}.md` with frontmatter
   (`agent`, `date`, `source_meeting`, `type: decision`, `tags`) and the four
   mandatory H2 sections in fixed order:
   - `## What I decided / agreed to in this meeting`
   - `## Constraints I committed to`
   - `## Open items I'm tracking` (lists action-item IDs where the agent is
     `assignee` or that materially affect the agent's future work)
   - `## Sources I relied on`
3. **Meeting notes** (if accepted at REVIEW). Run
   `scripts/meeting-notes-writer.sh --root . --payload <payload.yaml> --date <YYYY-MM-DD> --slug <slug>`.
   The writer emits `.gaia/artifacts/creative-artifacts/meeting-notes/meeting-{YYYY-MM-DD}-{slug}.md`
   with frontmatter (per-attendee + total token-cost breakdown,
   `scratchpad_extractions:` populated from the payload list — empty `[]` when
   no extractions occurred — and `action_items:` IDs from step 1) and the required body sections (charter, summary, research preludes,
   transcript, decisions, risks identified from `[challenge]` turns, open
   questions, scratchpad final state, action items, memory write-through list).

After all three writes complete, emit the `## Phase: SAVE` marker as the final
line of the live transcript.

**Mode-B teammate teardown (when `SESSION_MODE == team`).** After the three
writes complete and AFTER the `## Phase: SAVE` marker, tear down the persistent
teammates spawned at INVITE by sourcing the shared dispatch library and calling
`shutdown_all`:
`bash -c 'source "$CLAUDE_PLUGIN_ROOT/scripts/lib/dispatch-teammate.sh" && shutdown_all'`.
`shutdown_all` runs the unrelayed-turn fail-safe for each teammate before
deregistering its handle, so no teammate pane is left orphaned. (The meeting
bridge sources the dispatch library lazily per-function, so the teardown runs
`shutdown_all` from the library directly rather than via a bridge wrapper.)
Under `SESSION_MODE != team` this step is skipped (Mode A subagents are one-shot
and already gone).

**Anti-amnesia.** The per-agent memory entries surface
automatically on the next session-load of that agent's sidecar via the §4.10
sidecar load contract (in `gaia-memory-management`) — matched on `tags` or
`source_meeting`. The agent's next workflow that touches a topic carried
forward MUST receive the entry without explicit user prompting. This is the
anti-amnesia property the intake mandates.

**State-free write boundary.** Every disk write in Phase 7 MUST go
through `scripts/write-boundary.sh`. The asserter rejects any path outside
`.gaia/artifacts/creative-artifacts/meeting-notes/meeting-*.md`,
`.gaia/state/action-items.yaml`, and
`.gaia/memory/{agent}-sidecar/decisions/*.md`.

## Scratchpad pin + extraction

The scratchpad is a shared append-only buffer that any agent or the user MAY
pin to during DISCUSS. Every pin receives a monotonic `SP-N` ID (N starts at
1, increments by 1). Re-pinning an existing `SP-N` is **latest-wins** at the
rendered scratchpad block; the prior content is retained in transcript history
for audit. Every agent's per-turn context payload includes the
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

### CLOSE-phase disposition

At CLOSE, the orchestrator walks scratchpad items in ascending `SP-N` order
and prompts the user with the canonical three-option choice from
`scratchpad-disposition.sh --prompt`:

| Disposition | Effect at SAVE |
|-------------|----------------|
| **Extract** | Writes a permanent file under `.gaia/artifacts/creative-artifacts/meeting-scratchpad/{YYYY-MM}/{slug}/`; the path is added to the meeting notes' `scratchpad_extractions:` list. |
| **Keep in notes only** | Item appears in the notes "Scratchpad final state" section; NO extracted file; absent from `scratchpad_extractions:`. |
| **Drop** | Item is omitted from "Scratchpad final state"; NO extracted file; absent from `scratchpad_extractions:`. |

`scratchpad-disposition.sh --check <value>` validates a single disposition
input (case-insensitive). Any value other than the three canonical options
exits 2 — the orchestrator MUST re-prompt.

### Deterministic extraction path

The path is computed entirely from `(meeting-date, meeting-slug, SP-N,
content-type, content, intent)` — the skill MUST NOT prompt the user for a
path:

```
.gaia/artifacts/creative-artifacts/meeting-scratchpad/{YYYY-MM}/{slug}/SP-{N}-{auto-slug}.{ext}
```

- `{YYYY-MM}` = first seven chars of the meeting date.
- `{slug}` = the meeting notes' canonical slug (owned upstream;
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
that runs `find .gaia/artifacts/creative-artifacts/meeting-scratchpad -type d -empty
-delete` MUST not break the skill; subsequent extractions transparently
re-create the directories (empty-bucket policy).

### Extracted-file frontmatter

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

### Replace-at-same-path semantics

A future invocation that pins the same `SP-{N}` at the same source meeting
(same `{YYYY-MM}` AND same `{slug}`) **replaces** the file at the identical
path — atomic via `mktemp` + `mv`. `extracted_at` advances; no duplicate or
appended file is produced. Two distinct meetings (different `{slug}`) NEVER
collide because the path includes the slug.

### Meeting-notes integration

`meeting-notes-writer.sh` reads the payload's `scratchpad_extractions:` list
(project-relative paths in ascending SP-N order) and emits it verbatim into
the notes frontmatter; emits `scratchpad_extractions: []` when the list is
empty. The "Scratchpad final state" body section reflects whatever the
orchestrator pre-rendered (Extract + Keep entries; Drop items already
filtered out).

### State-free invariant

Every extraction write is gated through `scripts/write-boundary.sh`. The
allowlist is unchanged — `.gaia/artifacts/creative-artifacts/*` already
covers the `meeting-scratchpad/` subtree. The scratchpad codepath MUST NOT
mutate `_memory/`, sprint state, story files, PRD, architecture, test plan,
threat model, or traceability.

## Helper Scripts

All helpers live under `scripts/` and are invoked as deterministic CLIs (no
LLM-side parsing inline — this is single-source-of-truth).

| Script | Purpose |
|--------|---------|
| `charter-gate.sh` | Charter requirement guardrail |
| `resolve-mode.sh` | Active-mode resolver + single-mode invariant + alias canonicalisation |
| `resolve-invitees.sh` | INVITE-phase invitee resolver — mode-default lookup + graceful degradation + override path |
| `select-notes-template.sh` | Closing-artifact bias → notes-template selector (one-to-one mapping) |
| `lib/load-mode-registry.sh` | Shared YAML registry loader (canonical + alias lookup, scalar / list field readers) |
| `turn-order.sh` | Round-robin turn-order generator |
| `turn-header.sh` | Per-turn header renderer |
| `resolve-user-name.sh` | User-interjection name resolver (override -> git) |
| `lifecycle-marker.sh` | Seven-phase lifecycle marker emitter |
| `write-boundary.sh` | State-free write-boundary asserter |
| `research-phase-dispatch.sh` | Research-phase fork allowlist + flags + sidecar path + frontmatter audit |
| `lib/prelude-format.sh` | Fixed prelude format renderer |
| `cite-or-flag-check.sh` | Per-line classification + draft-turn gate + transcript verifier |
| `raise-hand-arbiter.sh` | Raise-hand detection + insertion planning + one-per-cycle ledger |
| `review-gate.sh` | REVIEW-phase disposition router (accept/edit/drop) |
| `lib/type-target-resolver.sh` | Eleven-type action-item type → target_command resolver |
| `action-items-writer.sh` | v2 action-items registry writer (idempotent header bump, daily-N IDs, atomic write) |
| `memory-writethrough.sh` | Per-agent sidecar decision write-through (frontmatter + four mandatory H2 sections) |
| `meeting-notes-writer.sh` | Saved meeting-notes writer (frontmatter + body sections) |
| `scratchpad-allocate.sh` | In-memory scratchpad data model: monotonic SP-N + latest-wins replace + render |
| `scratchpad-disposition.sh` | CLOSE-time disposition validator (Extract / Keep / Drop only) |
| `scratchpad-detect-type.sh` | Content-type detection (json / ts / py / sh / md / go / swift / kt / rs / java) |
| `scratchpad-resolve-path.sh` | Deterministic extraction-path resolver (auto-slug + extension) |
| `scratchpad-extractor.sh` | Atomic extracted-file writer (frontmatter linkage + replace-at-same-path) |

## Skill Outputs

- **Live transcript** (stdout). Phase markers + per-turn headers + turn bodies
  + user interjections. Always emitted in real time.
- **Saved meeting transcript** at
  `.gaia/artifacts/creative-artifacts/meeting-notes/meeting-{YYYY-MM-DD}-{slug}.md`. A
  minimum viable file (markers + headers) is produced and later extended to the full
  frontmatter and required sections.

## Threat-Model Mitigations

The research / cite-or-flag / raise-hand surface inherits three threats from
`.gaia/artifacts/planning-artifacts/threat-model.md` §3.15. Mitigations live in the
helpers:

- **Web-search exfiltration.** `--no-web` removes `WebSearch` /
  `WebFetch` from the research-phase fork allowlist and records
  `web_search: disabled` in the meeting frontmatter at SAVE. Recommend
  opt-out via `--no-web` for sensitive charters that involve secrets,
  internal credentials, or unpublished plans. Auditors can verify the
  disabled state from the saved frontmatter alone.
- **Prompt-injection from external pages.** The cite-or-flag
  invariant is the primary mitigation: anything an agent learned
  from an external page MUST cite that page's URL, and any factual claim
  with no citation MUST carry `[inference]`. The facilitator's pre-
  persistence HALT blocks unflagged-inference turns from landing in
  the transcript. The sequential-turn invariant prevents an
  injected page from racing across multiple agents in parallel.
- **Over-broad agent file reads.** The research-phase fork
  allowlist excludes write-capable tools (`Write` / `Edit` / `NotebookEdit`)
  — even an over-eager read cannot mutate any artifact. The
  pre-save secret-pattern scrubber is out of scope for
  this stage and lands separately; the charter is the agent's read-scope
  responsibility note.

## What's Out of Scope

These land in later layers — do **not** retrofit them into the existing substrate:

- Decision record + action items + memory write-through.
- Full saved-meeting frontmatter and required sections.
- Pre-save secret-pattern scrubber —
  separate work.
- The `/gaia-validate-meeting` static-check skill that consumes the
  verifiability — reserved namespace, not implemented.
- ~~Scratchpad pin / extraction.~~ (LANDED — see "Scratchpad pin + extraction".)
- The nine non-`decide` modes.
- ~~Guardrails (max-turns, per-agent cap, loop detection).~~ (LANDED — see "Guardrails + cost-reporting refinements".)
- ~~Cost-reporting refinements beyond the per-turn header.~~ (LANDED — see "Guardrails + cost-reporting refinements".)

## Guardrails + cost-reporting refinements

This layer closes out the operational envelope of `/gaia-meeting` by adding four
hard halts, two caps, a loop detector, and a deterministic cost-check cadence.
All guardrail checks run BEFORE the offending turn is appended to the
persisted transcript — a halted meeting MUST NOT contaminate the saved
artifact.

### Four hard halts

Each halt emits a single canonical line via `scripts/halt-event.sh`:

```
HALT condition=<NAME> agent=<ID|—> fr=<FR-MTG-ID> detail=<text>
```

This is the **terminal** live-stream event — no subsequent turn header, no
cost-check, no farewell. The lifecycle exits cleanly after emission.

| Condition | Trigger | Helper |
|-----------|---------|--------|
| `CHARTER-MISSING` | `/gaia-meeting` invoked without a resolvable charter — halts at the charter-resolution gate before INVITE. | `scripts/charter-gate.sh` |
| `RESEARCH-MISSING` | RESEARCH→DISCUSS transition attempted without one structured prelude per invitee — bypassed only by `--skip-research`. | `scripts/research-gate.sh` |
| `CITE-OR-FLAG` | A draft DISCUSS turn contains a factual claim with no citation marker and no `[inference]` token — checked BEFORE persistence. | `scripts/cite-or-flag-check.sh --gate-draft-turn` |
| `WRITE-BOUNDARY-VIOLATION` | A misdirected write target outside the three-prefix allow-list — refused at the central write helper. | `scripts/write-boundary.sh` |

### Caps and loop detection

| Cap | Default | Override | Helper |
|-----|---------|----------|--------|
| Max turns | 40 | `--max-turns N` | `scripts/max-turns-cap.sh --check --emitted-turns N` |
| Per-agent token cap | 25 000 tokens cumulative across research + discussion + raise-hand + research-interrupts | `--per-agent-cap N` | `scripts/per-agent-cap.sh --accumulate --agent <id> --tokens <N>` |

Per-agent cap muting is **one-way** — once an agent crosses the cap, a single
`MUTED agent=<id> tokens=<N> cap=<CAP>` event is emitted, the
agent is skipped by both round-robin and raise-hand arbitration, and there is
NO unmute path within the same meeting (rationale: the cap exists to bound
spend; allowing unmute defeats the bound).

**Loop detection** — `scripts/loop-detector.sh` inspects the
last three consecutive turns. It fires when EXACTLY two distinct agents
occupy the window AND none of the three turns produced a progress signal
(new citation / new decision / new scratchpad pin). Three-way alternation
(A→B→C) and same-agent triples (A→A→A) do NOT trigger. On fire, the
facilitator injects a forced `FACILITATOR / LOOP-BREAK` turn.

### 10-turn cost-check cadence determinism

`scripts/cost-cadence.sh` owns a single global emitted-turn counter. The
counter `--tick`s on **every** persisted turn header — round-robin, prelude,
raise-hand, research-interrupt, user-interjection, facilitator. The
cost-check fires whenever `counter % 10 == 0`, not when a round-robin slot
fires. This is the determinism contract that lets raise-hand insertions
remain deterministic against the same cadence: a 30-turn meeting
fires cost checks at emitted-turn indices 10, 20, 30 regardless of how many
of those turns are insertions. The fixture asserts identical
fire-indices across a K=0 and a K=4 raise-hand run.

## References

- `/gaia-meeting` peer-to-peer multi-agent discussion skill.
- Subagent fork-context isolation — the dispatch primitive used by the RESEARCH and DISCUSS turns.
- Dispatch contract / verdict surfacing — per-phase tool allowlists, return schema, finding severity routing.
- Peer-to-peer multi-agent discussion topology.
- Yield boundaries use the substrate `AskUserQuestion` primitive, NOT script-side stdout sentinels.
- User-as-first-class-attendee carve-out: when `me` / `user` / `<resolved-user-name>` appears in `--invitees`, the user is added as a non-LLM attendee with a turn slot at every yield boundary (composes with the `AskUserQuestion` primitive). Preserves the no-fabricated-user-turns invariant.
- Audit finding: stdout-sentinel mechanism empirically defeated by harness Auto Mode; substrate-correct primitive is `AskUserQuestion`.
- Audit finding: absolute-prohibition language without an explicit carve-out led downstream readers to extrapolate the wrong behavior. Resolved by the carve-out subsection + EXCEPT clause + 3-channel enumeration + Phase 3/4 back-references.
- Memory rule `feedback_askuserquestion_under_automode.md` — `AskUserQuestion` is substrate-enforced and halts the LLM turn under Auto Mode.
- Research-phase contract (sidecar load → SoT reads → web search → cited prelude).
- Sidecar path reconciliation: `<agent>-sidecar/` under the memory tree is canonical (`.gaia/memory/<agent>-sidecar/`).
- Slash commands resolve via SKILL.md, not via the retired `commands/` directory.
- Reuses agent + stakeholder discovery from `/gaia-party` (the explicit `--invitees` CSV is still required).

## Changelog

- **2026-05-14 — Wire post-dispatch envelope assertion + replace 2 `context:[fork]` (legacy directive) references.** `dispatch-agent-turn.sh` gained a post-dispatch envelope-assertion code path (opt-in via `GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN` for backward-compat during rollout). The path: parse `.agent` from the envelope, compute the sentinel path via `sha256(artifact_path)` first 16 hex, write the sentinel via `lib/write-val-envelope.sh` (agent-agnostic writer), source `lib/assert-agent-envelope.sh`, invoke `assert_agent_envelope $sentinel --expected-agent $envelope_agent`. On failure, `halt-event.sh` fires with `envelope-assertion-failed` reason. The 2 stale `context:[fork]` (legacy directive) references in SKILL.md (Phase 3 RESEARCH dispatch contract + Phase 4 DISCUSS dispatch contract) are replaced with the canonical main-turn Agent dispatch contract. Anti-pattern bats at `tests/meeting-val-bridge-anti-pattern.bats` fails CI if `context:[fork]` (legacy directive) is reintroduced. The defect class closed is "no post-dispatch envelope authentication" — NOT "auto-judges PASS in inline-surrogate mode". `research-phase-dispatch.sh` is a pure emitter (no envelope to assert) and is OUT OF SCOPE.
