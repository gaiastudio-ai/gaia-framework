# Mode B Teammate Round-Trip Contract

This is the **canonical, single-source contract** for how a skill orchestrator
drives one turn of a persistent teammate under Mode B (team orchestration). Every
Mode-B-ready skill references this doc rather than restating the loop; the four
shared bridges (`conversational`, `planning`, `execution`, `research`) and the
per-skill SKILL.md Mode B Readiness sections point here.

It complements the **Mode B Teammate Lifecycle Protocol** (spawn → drive → relay
→ shutdown, in `skills/README.md`), which describes the bash-library *bookkeeping*
phases. This doc describes the **orchestrator-side round-trip** — the part the LLM
performs itself, which the bash library cannot do.

## The core split: the orchestrator sends, the bridge only bookkeeps

A teammate turn is an **orchestrator-driven round-trip**. The SEND and the RECEIVE
are main-turn LLM tool operations the orchestrator performs itself. The
bridge/library functions do ONLY bookkeeping — they have no way to emit
`SendMessage`, and a teammate's reply auto-delivers into the orchestrator's own
conversation, so there is no bash buffer to fetch it from.

Concretely:

- `drive_turn HANDLE PROMPT` is **pre-send bookkeeping**: it increments the turn
  counter and raises relay-pending. It does NOT send. (A teammate that was driven
  but never sent-to will simply never reply.)
- `await_reply HANDLE` is a **relay-pending state query**, NOT a blocking fetch. It
  reports whether a relay is still outstanding; it never blocks and never returns
  teammate content.
- `<cohort>_relay_turn HANDLE BODY` (and `relay_to_team_lead`) is **post-receive
  bookkeeping**: it appends the received reply to the transcript / artifact and
  clears relay-pending. It always succeeds; it does not fetch.

If a skill calls only the bridge functions and never emits a real `SendMessage`,
the teammate is spawned and then never driven — the spawn-and-forget failure mode.

## The round-trip — exact order, every teammate turn

When `SESSION_MODE == team` and the teammate was spawned at the skill's spawn step,
each turn proceeds in this exact order:

1. **Bookkeeping (bash).** Run `drive_turn <handle> "<prompt>"` (via the cohort
   bridge or `dispatch-teammate.sh` directly) to increment the turn counter and
   raise relay-pending. This records that a send is about to happen — it does not
   send.

2. **Send (LLM tool — the actual dispatch).** Emit a main-turn
   `SendMessage(to: "<handle>", summary: "<short>", message: "<prompt>")` tool call.
   This is what reaches the teammate; there is no bash substitute. **The `message`
   MUST end with the reply-routing reminder** — e.g. *"Reply to me by calling
   `SendMessage(to: \"team-lead\")` with your full response; do not go idle without
   sending it."* The teammate's plain output is invisible to the orchestrator; only
   its own `SendMessage` reaches you. Omitting the reminder is the single most
   common reason a teammate finishes its work, goes idle, and you receive nothing.

3. **Receive (teammate replies via SendMessage).** The teammate replies via
   `SendMessage(to: "team-lead")`; that message is delivered into the
   orchestrator's conversation — typically on the next orchestrator turn. Do NOT
   poll and do NOT call a bash `await` to fetch it (`await_reply` is only a
   relay-pending state query). **Recovery:** if a teammate transitions to idle
   WITHOUT a reply landing, re-`SendMessage` it ONCE with an explicit *"deliver your
   response now via `SendMessage(to: team-lead)`"* nudge before treating the turn as
   failed — a freshly-spawned teammate sometimes treats the first message as an ack.
   Never fabricate the reply.

   **Substrate caveat — the reply leg may be absent (honest fallback, not failure).**
   The return leg requires the SPAWNED teammate to have the `SendMessage` tool in
   its own context. The harness grants that tool, not GAIA — and in some contexts
   it is absent: the teammate spawns and runs, but cannot emit `SendMessage`, so its
   reply comes back only as the Agent's TERMINAL return value (one task → one
   return). When you observe this — the teammate reports *"SendMessage isn't enabled
   in this context"*, or its reply arrives as the Agent's final result rather than a
   `SendMessage` — treat it as a `MODE_B_FALLBACK`: the dispatch has honestly
   degraded to the Agent-return (Mode-A-equivalent) path. Consume that returned
   reply, surface the degradation plainly, and do NOT claim a live persistent
   round-trip occurred. This is a known substrate gap tracked upstream; the spawn
   half works, the persistent reply leg does not yet.

4. **Relay (bash bookkeeping).** Run the cohort relay function
   (`<cohort>_relay_turn <handle> "<body>"`) to append the received reply to the
   transcript / artifact with teammate identity metadata and clear relay-pending.

5. **Surface.** Render the turn with teammate provenance (`dispatched_via:
   teammate`, not `subagent`) and relay the body to the user as user-visible turn
   text where the skill streams output. A subagent/teammate reply returns to the
   ORCHESTRATOR — Claude Code does not auto-show it to the user — so a skill that
   surfaces per-turn output MUST re-emit the body itself.

## Cross-turn-boundary note

Because the reply arrives across an orchestrator turn boundary (step 3), a single
teammate turn may span more than one LLM turn. That is expected and composes with
any checkpoint-yield model the skill uses. Do NOT fabricate a teammate reply to
avoid the boundary.

## The only legitimate fall-through to Mode A

The team-mode round-trip is **MANDATORY** when `SESSION_MODE == team`. A skill MUST
NOT fall back to one-shot Mode A subagent dispatch as a matter of preference
("it's a small / focused / quick step" is NOT a license), and MUST NOT fall back
because a reply was slow to arrive (that is the cross-turn-boundary case — wait or
re-prompt once).

The ONLY legitimate fall-through is a real `MODE_B_FALLBACK` token emitted by the
bridge at spawn time, which means the live substrate is genuinely unavailable. In
that case the bridge has already degraded to foreground Mode A dispatch and the
Mode A behaviour documented in the skill is the source of truth for that run.
