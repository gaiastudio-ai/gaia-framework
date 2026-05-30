# GAIA Skills

This directory holds the canonical SKILL.md files that define GAIA framework slash commands and reusable workflows. Each subdirectory is one skill; `SKILL.md` is the entry point.

For substrate-level skill behavior (frontmatter contract, invocation paths, dynamic context injection, supporting files), see the upstream Claude Code documentation at <https://code.claude.com/docs/en/skills>.

This README documents **GAIA-specific frontmatter extensions** that go beyond the upstream substrate contract.

---

## Orchestration Class

GAIA skills declare an `orchestration_class` frontmatter field that controls how the framework dispatches the skill at invocation time. This field is the routing taxonomy for the orchestrator-as-bridge model defined in **ADR-093** (and required by **FR-444**).

### Field definition

```yaml
orchestration_class: reviewer | light-procedural | heavy-procedural | conversational
```

- **Type:** enum (string), one of the four values below
- **Required:** yes, for every SKILL.md under `gaia-public/plugins/gaia/skills/*/`
- **Default:** none — the field MUST be set explicitly; absence is a `/gaia-validate-framework` CRITICAL finding
- **Source of truth:** ADR-093 §"Decision — Per-Skill Classification Taxonomy"

### The four values — behavioral contracts

#### `reviewer`

A clean-room evaluator that reads project artifacts, applies a ruleset or judgment, and produces a verdict. Reviewers never mutate project state and never carry conversation context across invocations.

- **Invocation:** dispatched as a one-shot `Agent()` call from the orchestrator. The dispatch always uses `context: fork` per the Subagent Dispatch Contract (ADR-063) and the Val opus-pin contract where applicable (ADR-074 C2).
- **Mode A (default subagent dispatch):** one-shot fork on every invocation.
- **Mode B (Agent Teams opt-in):** **STILL one-shot fork.** Reviewer skills are NEVER spawned as persistent teammates regardless of Mode B activation. This is the **clean-room invariant** enforced by **NFR-060** and statically verified by `/gaia-validate-framework`.
- **State mutation:** prohibited. Reviewers MUST NOT write to project files outside their own findings output (and any explicitly-allowed sidecar memory write).
- **Examples:** `gaia-val-validate`, `gaia-validate-story`, `gaia-validate-prd`, `gaia-code-review`, `gaia-review-security`, `gaia-review-a11y`, `gaia-adversarial`, `gaia-tdd-reviewer`, `gaia-validate-framework` itself, `gaia-validate-rubric`.
- **Static enforcement:** `/gaia-validate-framework` MUST flag any SKILL.md with `orchestration_class: reviewer` that ALSO declares team-mode-eligible behavior (CRITICAL finding).

#### `light-procedural`

A deterministic, script-heavy skill with at most one or two subagent dispatches. Low context cost. Outputs are structured (file writes, status transitions, deterministic reports) rather than free-form dialogue.

- **Invocation:** inline main-turn orchestration. The orchestrator reads the SKILL.md as a playbook and executes each step via direct tool calls (Bash, Read, Edit, Write, Agent).
- **Mode A:** subagent re-dispatch with structured checkpoint payloads where needed.
- **Mode B:** same as Mode A — light-procedural skills do not require persistent teammates because their dispatch count is too small to benefit from continuity. No lossy-mode warning fires.
- **State mutation:** allowed within the skill's documented scope.
- **Examples:** `gaia-sprint-status`, `gaia-epic-status`, `gaia-changelog`, `gaia-config-show`, `gaia-list-tools`, `gaia-help`, `gaia-shard-doc`, `gaia-merge-docs`, `gaia-index-docs`.
- **Lossy-mode warning:** **does NOT fire** for light-procedural skills.

#### `heavy-procedural`

A multi-step orchestration skill with three or more subagent dispatches, often with output from earlier dispatches feeding inputs to later dispatches. Context-heavy and benefits materially from persona continuity when available.

- **Invocation:** inline main-turn orchestration. Orchestrator drives each step explicitly.
- **Mode A (default):** subagent re-dispatch with structured checkpoint payloads (see ADR-093 §"Mode A Checkpoint Payload Schema"). Each re-dispatch is a fresh persona context with prior outputs threaded via the payload — sidecar memory loads on every dispatch; in-conversation continuity is lost between dispatches.
- **Mode B (opt-in, requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + `orchestration.mode: team` in `.gaia/config/project-config.yaml`):** persistent teammates per the Mode B Teammate Lifecycle (ADR-093 §"Mode B Teammate Lifecycle Protocol"). One teammate per persona per skill execution; teammate session stays alive across the workflow's dispatches; cleaned up on skill completion. Persona has full in-conversation continuity.
- **State mutation:** allowed.
- **Examples:** `gaia-create-story`, `gaia-dev-story`, `gaia-add-feature`, `gaia-edit-prd`, `gaia-edit-arch`, `gaia-edit-ux`, `gaia-create-prd`, `gaia-create-arch`, `gaia-create-ux`, `gaia-create-epics`, `gaia-deploy`, `gaia-deploy-checklist`.
- **Lossy-mode warning:** **fires once per session** when invoked in Mode A (FR-446).

#### `conversational`

A multi-turn interactive skill where agents engage in dialogue with each other, with the user, or both. Continuity of in-conversation state across turns is load-bearing for output quality (a brainstorm where participants forget their prior turns is degraded).

- **Invocation:** inline main-turn orchestration. AskUserQuestion calls fire from the main turn at every user-yield boundary (no stdout sentinels, no Stop hooks, no yield-gate scripts per ADR-093 §"Precedent Citation — ADR-083").
- **Mode A (default):** subagent re-dispatch with **full conversation-history payload** carried in the structured checkpoint per dispatch. Lossy by design — agents read their own prior turns from a payload rather than remembering them. Output quality degraded relative to Mode B.
- **Mode B (opt-in):** persistent teammates with mailbox messaging per ADR-083 precedent. Each attendee is a long-lived session for the duration of the meeting/session/sprint. **This is the recommended mode for conversational skills.**
- **State mutation:** allowed within the documented session-output contract (transcript, action items, decisions).
- **Examples:** `gaia-meeting`, `gaia-party`, `gaia-brainstorming`, `gaia-brainstorm`, `gaia-design-thinking`, `gaia-creative-sprint`, `gaia-retro`, `gaia-problem-solving`.
- **Lossy-mode warning:** **fires once per session** when invoked in Mode A (FR-446).

### Routing summary

| Class | Default Mode A | Mode B (opt-in) | Lossy warning | Clean-room |
|---|---|---|---|---|
| `reviewer` | one-shot fork | **still** one-shot fork (NFR-060) | n/a | yes |
| `light-procedural` | subagent re-dispatch | subagent re-dispatch (same) | no | no |
| `heavy-procedural` | subagent re-dispatch + checkpoint payload | persistent teammate | yes (Mode A only) | no |
| `conversational` | subagent re-dispatch + full convo payload | persistent teammate | yes (Mode A only) | no |

### Cross-references

- **ADR-093** — Orchestrator-as-Bridge: Main-Turn Inline Skill Execution Model (the binding decision)
- **FR-443** — Main-turn inline orchestration of SKILL.md playbooks
- **FR-444** — Per-skill `orchestration_class` taxonomy (this field)
- **FR-445** — Dual-mode dispatch (Mode A default, Mode B opt-in)
- **FR-446** — Lossy-mode warning UX
- **NFR-060** — Validation Integrity (reviewer clean-room invariant)
- **NFR-061** — Orchestrator Visibility (every tool call in transcript)
- **NFR-046** — Single-Spawn-Level Constraint (strengthened by the bridge pattern)
- **ADR-041** (amended for skill-invocation layer) — Native Execution Model
- **ADR-083** (cited as precedent) — `/gaia-meeting` Substrate A/B with Agent Teams

### Adoption (epic E84)

The four-class taxonomy is being applied to existing SKILL.md files via:

- **E84-S1** (this story) — schema/documentation definition + memory + CLAUDE.md hard rule
- **E84-S2** — classify all 64 fork-using SKILL.md files
- **E84-S3** — strip `context: fork` from non-reviewer plugin SKILL.md files; build the dual-mode runtime + helper scripts + framework-validator checks
- **E84-S4** — lossy-mode warning UX + `/gaia-meeting` yield-gate cleanup
- **E84-S5** — silent-Val-bypass incident audit
