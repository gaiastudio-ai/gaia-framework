---
name: gaia-party
description: Multi-agent group discussion with dynamic participant selection. Use when "party mode".
argument-hint: "[discussion topic]"
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: conversational
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class conversational --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

# gaia-party

Multi-participant group discussion orchestrator. Gaia acts as moderator while a
**dynamic** set of participants — GAIA agents and/or stakeholder personas
selected at runtime — take turns through sequential `context: fork` subagent
invocations. Converted under ADR-041 (native execution model) and ADR-045
(sequential fork-subagent pattern) with full parity against
`_gaia/core/workflows/party-mode/` (NFR-053).

**Architectural parallel with `gaia-run-all-reviews` (E28-S72):** both skills
orchestrate sequential fork-subagent invocations. `gaia-run-all-reviews` is the
**fixed-sequence** variant (6 canonical reviewers); `gaia-party` is the
**dynamic** variant — the participant set is resolved at invitation time from
`${CLAUDE_PLUGIN_ROOT}/knowledge/agent-manifest.csv` + `custom/stakeholders/*.md`. Orchestration
pattern is the same (sequential, never parallel, never reordered); only the
input-resolution step differs.

## Critical Rules

- **Sequential only (ADR-045, AC-EC10):** Never parallelize per-round
  participant invocations. Never reorder participants mid-round. Refuse any
  `--parallel` flag or equivalent parallel-invocation request with an error;
  deterministic turn-taking is the whole point of the round structure.
- **Fork-within-fork (ADR-041):** This skill itself runs under `context: fork`,
  and each participant invocation within a round is **also** its own
  `context: fork` subagent — matching the E28-S72 topology.
- **Log-and-continue on subagent failure (AC-EC8):** If a participant subagent
  crashes, times out, or exits non-zero, log the failure with the participant
  name and continue with the remaining participants for that round. Never
  abort the session.
- **State-free:** This skill does not transition sprint status, update story
  frontmatter, or touch the state machine. It writes ONLY to
  `.gaia/artifacts/creative-artifacts/party-mode-{date}.md`.
- **Name disambiguation (FR-159):** GAIA agents always win on name collision.
  Stakeholders get the `[Stakeholder]` prefix in the invite list **and** during
  discussion attribution, preserved for the entire session.

## Procedure

### Phase 1: Agent + Stakeholder Loading

#### Source 1: GAIA agent discovery

1. Read `${CLAUDE_PLUGIN_ROOT}/knowledge/agent-manifest.csv` to enumerate all
   installed GAIA agents. The registry ships inside the plugin under ADR-041's
   `knowledge/` convention.
2. For each row, extract `name`, `displayName`, `title`, `module`. The manifest
   schema is intentionally id-only — party invokes subagents by id, and the
   plugin file path is derivable as `plugins/gaia/agents/{name}.md` when needed.
3. Build the GAIA agent list (existing behavior, unchanged).

#### Source 2: Stakeholder discovery (AC-EC1, AC-EC2, AC-EC3, AC-EC9)

4. Glob `custom/stakeholders/*.md`.
   - **AC-EC1:** If the `custom/stakeholders/` directory does not exist,
     silently produce zero stakeholders — no error, no warning. Proceed with
     GAIA-agents-only flow.
   - Skip empty files (0 bytes) silently.
   - **AC-EC2:** If a file has malformed YAML frontmatter, skip it with a
     single warning: `Skipping {filename}: invalid YAML frontmatter` and
     continue discovery. Do not crash.
5. Parse only YAML frontmatter from each discovered file — extract:
   `name` (required), `role` (required), `tags` (optional array).
   - Build a tag-to-stakeholder index: map each tag (case-insensitive) to the
     list of stakeholders whose `tags` array contains it. Stakeholders with
     multiple tags appear under every tag they have. Stakeholders with no
     `tags` field are excluded from tag-based searches but remain available
     for individual selection.
   - Do **not** load the full Markdown body at discovery time — frontmatter
     only.
6. **AC-EC3:** Enforce a 50-file cap. If more than 50 stakeholder files are
   found, warn `Stakeholder cap exceeded: {count} files found, using first 50
   alphabetically` and truncate to the first 50 sorted alphabetically.
7. **AC-EC9 (NFR-029):** Track token budget during frontmatter scan — estimate
   each file's frontmatter at ~100 tokens (approx 400 chars). Total discovery
   across all stakeholder files must stay within a **5K token** budget. If
   cumulative budget reaches 80% (~4K tokens), warn and stop scanning
   additional files; proceed with already-discovered stakeholders.
8. If `custom/stakeholders/` does not exist or is empty, display hint:
   `Tip: Create stakeholder personas with /gaia-create-stakeholder to invite
   domain experts to discussions.` (FR-162)

#### Merge + display invite list

9. Build a combined invite list from GAIA agents + stakeholders:
   - GAIA agents: `{displayName} — {title} ({module})`
   - Stakeholders: `[S] {name} — {role}`
10. **Name disambiguation (FR-159):** compare each stakeholder name against
    GAIA agent `displayName`s case-insensitively. On collision, prefix the
    stakeholder with `[Stakeholder]` in the invite list and during discussion
    attribution. GAIA agents retain their original name unchanged.
11. Ask the user which participants to invite — present the five invitation
    modes (verbatim semantics from the legacy workflow):

    - **Option A — All agents.** GAIA agents only (unchanged from original
      behavior).
    - **Option B — By module.** Let the user pick GAIA modules: `lifecycle`,
      `dev`, `creative`, `testing`. Filter the GAIA agent list accordingly.
    - **Option C — Specific agents.** Let the user pick individual
      participants from the combined GAIA + stakeholder list.
    - **Option D — Stakeholders only.** Let the user pick from stakeholders
      only (FR-160). A zero-GAIA, stakeholder-only party is valid — the
      moderator manages discussion flow.
    - **Option E — By tag.** Prompt for a tag name. Look it up in the
      tag-to-stakeholder index (case-insensitive). All stakeholders whose
      `tags` array contains the tag are invited. Tag-based invitations can be
      combined with individual selections. Alternative syntax: `invite all
      {tag}` (e.g., `invite all hotel-ops`) resolves via the same tag index.
      **AC-EC6:** if the tag matches zero stakeholders, display
      `Tag '{tag}' matches no stakeholders` and continue with any other
      invitees — non-blocking.

#### Validation (AC-EC4)

12. Validate the final selection — four cases, verbatim from the legacy
    workflow:

    | GAIA agents | Stakeholders | Result |
    |-------------|--------------|--------|
    | 0 | ≥1 | **valid** — stakeholder-only party (FR-160) |
    | ≥1 | 0 | **valid** — original behavior |
    | ≥1 | ≥1 | **valid** — mixed party |
    | 0 | 0 | **INVALID** — halt with the exact message below |

    **AC-EC4 halt message (exact):**
    `Cannot start party: no agents or stakeholders selected. Select at least
    one participant.`

#### Load participant personas

13. For each selected GAIA agent: extract a persona summary from their agent
    file (name, title, communication style, core principles). Do NOT load full
    agent files — summary only for the invite step.
14. For each selected stakeholder: use the frontmatter already parsed at
    discovery time for the persona summary. Full file content (Markdown body)
    is loaded JIT only when the stakeholder actually speaks — not at selection
    time. **AC-EC7:** when loading the full body, if the file exceeds 100
    lines, display `Stakeholder file {filename} exceeds 100 lines — consider
    trimming for optimal context usage.` The warning is advisory only —
    participation is not blocked.

#### Confirm + topic

15. Present the guest list to the user for confirmation.
16. Ask for the discussion topic or question.

### Phase 2: Discussion Orchestration (ADR-045 sequential contract)

Gaia (this skill) is the moderator. The discussion runs in **rounds**.
Participant invocation is **sequential only** — never parallel, never
reordered mid-round (AC-EC10). `--parallel` or any equivalent parallel-mode
flag is **rejected**: there is no parallel orchestration path. If an operator
passes such a flag, respond with `Parallel orchestration refused —
/gaia-party is sequential-only per ADR-045.` and continue in sequential mode.

For each round:

1. Select **2–3 participants** to speak this round (rotate across rounds so
   every invitee gets airtime over the session).
2. For each selected participant, in deterministic order:
   a. Invoke the participant as a `context: fork` subagent with: the
      discussion topic, the prior-round moderator summary, the participant's
      persona (JIT-loaded only now — Phase 1 §13/§14), and a 2–3 paragraph
      response budget.
   b. Capture the response and append it to the running transcript.
   c. **AC-EC8 (log-and-continue):** if the subagent fails (crash, non-zero
      exit, timeout), log `Participant {name} failed this round — skipping`
      and continue with the next participant. The session is NOT aborted.
3. After all selected participants respond, Gaia (moderator) summarizes the
   round's key points in 1–2 paragraphs — agreements, disagreements, ideas
   worth building on.
4. Enforce per-response voice: each participant stays in character, speaks
   from their domain expertise, and cap at 2–3 paragraphs. Voices must sound
   distinct.
5. Every 3–4 rounds, check in with the user:
   - Continue discussion?
   - Change topic?
   - Ask a specific agent to elaborate?
   - Wrap up?

### Phase 3: Graceful Exit

1. Gaia summarizes the key takeaways from the discussion.
2. List the action items that emerged, each attributed to the relevant
   participant.
3. Offer the user three next steps:
   - **Save transcript** — write the session to
     `.gaia/artifacts/creative-artifacts/party-mode-{date}.md` (`{date}` as `YYYY-MM-DD`).
   - **Activate agent for follow-up** — hand off to a single agent for a
     deeper 1:1.
   - **Start a workflow** from a discussed idea (e.g., `/gaia-create-prd`,
     `/gaia-quick-spec`).
4. On save: write the transcript to `.gaia/artifacts/creative-artifacts/party-mode-{date}.md`.
   Structure: header (topic, participants, date), full round-by-round
   transcript with attribution, closing summary, action items.
5. Thank the participants and close the session.

## Transcript Format

```markdown
# Party Mode — {topic}

**Date:** {YYYY-MM-DD}
**Participants:** {comma-separated invite list, with [Stakeholder] prefixes preserved}

## Round 1

**{Participant A}:** …response…

**{Participant B}:** …response…

**Moderator summary:** …1–2 paragraphs…

## Round 2

…

## Summary

…key takeaways…

## Action Items

- [ ] {Participant X}: {action}
- [ ] {Participant Y}: {action}
```

## References

- ADR-041 — Native Execution Model (skills replace framework workflows)
- ADR-045 — Review Gate via Sequential `context: fork` Subagents (analogous
  pattern; party-mode is the dynamic-participant variant)
- FR-159 — Stakeholder/agent name disambiguation
- FR-160 — Stakeholders-only party is valid
- FR-161 — Invite by tag
- FR-162 — Hint when `custom/stakeholders/` is empty
- FR-323 — Skill-to-workflow conversion mapping
- FR-330 — Sequential fork subagents for review-gate / discussion patterns
- NFR-029 — Stakeholder discovery token budget (5K)
- NFR-048 — Conversion token-reduction target
- NFR-053 — Functional parity with legacy workflow
- Reference implementation: `plugins/gaia/skills/gaia-run-all-reviews/SKILL.md`
  (E28-S72 — fixed-sequence variant of the same pattern)
- Legacy parity source:
  - `_gaia/core/workflows/party-mode/workflow.yaml`
  - `_gaia/core/workflows/party-mode/steps/step-01-agent-loading.md`
  - `_gaia/core/workflows/party-mode/steps/step-02-discussion-orchestration.md`
  - `_gaia/core/workflows/party-mode/steps/step-03-graceful-exit.md`
