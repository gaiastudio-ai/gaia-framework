# GAIA Skills

This directory holds the canonical SKILL.md files that define GAIA framework slash commands and reusable workflows. Each subdirectory is one skill; `SKILL.md` is the entry point.

For substrate-level skill behavior (frontmatter contract, invocation paths, dynamic context injection, supporting files), see the upstream Claude Code documentation at <https://code.claude.com/docs/en/skills>.

This README documents **GAIA-specific frontmatter extensions** that go beyond the upstream substrate contract.

---

## Orchestration Class

GAIA skills declare an `orchestration_class` frontmatter field that controls how the framework dispatches the skill at invocation time. This field is the routing taxonomy for the orchestrator-as-bridge model.

### Field definition

```yaml
orchestration_class: reviewer | light-procedural | heavy-procedural | conversational
```

- **Type:** enum (string), one of the four values below
- **Required:** yes, for every SKILL.md under `gaia-framework/plugins/gaia/skills/*/`
- **Default:** none — the field MUST be set explicitly; absence is a `/gaia-validate-framework` CRITICAL finding
- **Source of truth:** the orchestrator-as-bridge model §"Decision — Per-Skill Classification Taxonomy"

### The four values — behavioral contracts

#### `reviewer`

A clean-room evaluator that reads project artifacts, applies a ruleset or judgment, and produces a verdict. Reviewers never mutate project state and never carry conversation context across invocations.

- **Invocation:** dispatched as a one-shot `Agent()` call from the orchestrator. The dispatch always uses `context: fork` per the Subagent Dispatch Contract and the Val opus-pin contract where applicable.
- **Mode A (default subagent dispatch):** one-shot fork on every invocation.
- **Mode B (Agent Teams opt-in):** **STILL one-shot fork.** Reviewer skills are NEVER spawned as persistent teammates regardless of Mode B activation. This is the **clean-room invariant** statically verified by `/gaia-validate-framework`.
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
- **Mode A (default):** subagent re-dispatch with structured checkpoint payloads (see the §"Mode A Checkpoint Payload Schema"). Each re-dispatch is a fresh persona context with prior outputs threaded via the payload — sidecar memory loads on every dispatch; in-conversation continuity is lost between dispatches.
- **Mode B (opt-in, requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + `orchestration.mode: team` in `.gaia/config/project-config.yaml`):** persistent teammates per the Mode B Teammate Lifecycle (see the §"Mode B Teammate Lifecycle Protocol"). One teammate per persona per skill execution; teammate session stays alive across the workflow's turns; cleaned up on skill completion. Persona has full in-conversation continuity.
- **State mutation:** allowed.
- **Examples:** `gaia-create-story`, `gaia-dev-story`, `gaia-add-feature`, `gaia-edit-prd`, `gaia-edit-arch`, `gaia-edit-ux`, `gaia-create-prd`, `gaia-create-arch`, `gaia-create-ux`, `gaia-create-epics`, `gaia-deploy`, `gaia-deploy-checklist`.
- **Lossy-mode warning:** **fires once per session** when invoked in Mode A.

#### `conversational`

A multi-turn interactive skill where agents engage in dialogue with each other, with the user, or both. Continuity of in-conversation state across turns is load-bearing for output quality (a brainstorm where participants forget their prior turns is degraded).

- **Invocation:** inline main-turn orchestration. AskUserQuestion calls fire from the main turn at every user-yield boundary (no stdout sentinels, no Stop hooks, no yield-gate scripts).
- **Mode A (default):** subagent re-dispatch with **full conversation-history payload** carried in the structured checkpoint per dispatch. Lossy by design — agents read their own prior turns from a payload rather than remembering them. Output quality degraded relative to Mode B.
- **Mode B (opt-in):** persistent teammates with mailbox messaging. Each attendee is a long-lived session for the duration of the meeting/session/sprint. **This is the recommended mode for conversational skills.**
- **State mutation:** allowed within the documented session-output contract (transcript, action items, decisions).
- **Examples:** `gaia-meeting`, `gaia-party`, `gaia-brainstorming`, `gaia-brainstorm`, `gaia-design-thinking`, `gaia-creative-sprint`, `gaia-retro`, `gaia-problem-solving`.
- **Lossy-mode warning:** **fires once per session** when invoked in Mode A.

### Routing summary

| Class | Default Mode A | Mode B (opt-in) | Lossy warning | Clean-room |
|---|---|---|---|---|
| `reviewer` | one-shot fork | **still** one-shot fork | n/a | yes |
| `light-procedural` | subagent re-dispatch | subagent re-dispatch (same) | no | no |
| `heavy-procedural` | subagent re-dispatch + checkpoint payload | persistent teammate | yes (Mode A only) | no |
| `conversational` | subagent re-dispatch + full convo payload | persistent teammate | yes (Mode A only) | no |

### Cross-references

- Orchestrator-as-Bridge: Main-Turn Inline Skill Execution Model (the binding decision)
- Main-turn inline orchestration of SKILL.md playbooks
- Per-skill `orchestration_class` taxonomy (this field)
- Dual-mode dispatch (Mode A default, Mode B opt-in)
- Lossy-mode warning UX
- Validation Integrity (reviewer clean-room invariant)
- Orchestrator Visibility (every tool call in transcript)
- Single-Spawn-Level Constraint (strengthened by the bridge pattern)
- Native Execution Model (amended for skill-invocation layer)
- `/gaia-meeting` Substrate A/B with Agent Teams (cited as precedent)

### Adoption

The four-class taxonomy is being applied to existing SKILL.md files via:

- schema/documentation definition + memory + CLAUDE.md hard rule
- classify all 64 fork-using SKILL.md files
- strip `context: fork` from non-reviewer plugin SKILL.md files; build the dual-mode runtime + helper scripts + framework-validator checks
- lossy-mode warning UX + `/gaia-meeting` yield-gate cleanup
- silent-Val-bypass incident audit

---

## Mode B Teammate Lifecycle Protocol

This section is the canonical reference for skill authors who write `heavy-procedural` or `conversational` skills that opt into persistent-teammate dispatch. It documents the full lifecycle of a teammate session — from spawn through shutdown — and the `dispatch-teammate.sh` library functions that implement each phase.

> **Bookkeeping vs. the round-trip.** The phase contracts below describe the bash-library *bookkeeping* (`drive_turn` raises relay-pending, `await_reply` is a relay-pending state query, the relay functions append to the transcript). They do NOT themselves move a message to a teammate. The actual per-turn message exchange — the orchestrator emitting a real `SendMessage` with the reply-routing reminder, the teammate replying via `SendMessage(to: team-lead)`, and the relay back — is the orchestrator-driven loop specified in the companion **Mode B teammate round-trip contract** at `knowledge/mode-b-round-trip-contract.md`. Read that contract for how a turn is actually driven; read this section for what the library functions record.

> **Substrate honesty.** The live Mode B primitives (`Agent` with `run_in_background:true` + `SendMessage`) may be unavailable in some Claude Code contexts. When the substrate is unavailable, `dispatch-teammate.sh` degrades silently to foreground Mode A and emits a single machine-parseable token `MODE_B_FALLBACK` to stderr. Skill authors must handle this gracefully; documentation in this section reflects both the live path and the fallback.

### Lifecycle phases

A teammate session passes through four sequential phases. Each phase has a description and a contract that skill authors must honour.

#### SPAWN

**Description.** The orchestrator creates a named, persistent teammate agent for a specific persona (e.g. `gaia:architect`, `gaia:validator`). The teammate is registered in the session registry under a session-scoped handle and remains alive for the duration of the skill workflow.

**Contract.**
- Call `spawn_teammate PERSONA [--context CTX]` to create a teammate. The function returns the handle on stdout.
- The handle is opaque; pass it as-is to subsequent `drive_turn`, `await_reply`, `relay_to_team_lead`, and `shutdown_teammate` calls.
- At most eight teammates may be active concurrently (enforced by the 8-teammate ceiling in the registry).
- If the live substrate is unavailable, `spawn_teammate` emits `MODE_B_FALLBACK` to stderr and degrades to a foreground Mode A dispatch. The returned handle is still valid for subsequent library calls.

#### DRIVE

**Description.** The orchestrator sends one prompt turn to an active teammate. In the live substrate this sends via `SendMessage`; in the fallback path it runs a foreground `Agent()` call.

**Contract.**
- Call `drive_turn HANDLE PROMPT` where `HANDLE` is the value returned by `spawn_teammate`.
- The call is non-blocking in the live path; pair it with `await_reply` to collect the response.
- `drive_turn` will return non-zero if the handle is unknown (teammate was never spawned or has already shut down).
- Do not call `drive_turn` after `shutdown_teammate` for the same handle.

#### RELAY

**Description.** Teammate output is forwarded verbatim to the team lead (the orchestrating skill turn) and appended to the session transcript at `$GAIA_SESSION_TRANSCRIPT`. This creates a persistent, auditable record of inter-agent communication across the workflow.

**Contract.**
- Call `await_reply HANDLE` after `drive_turn` to retrieve the teammate's response.
- Call `relay_to_team_lead HANDLE OUTPUT` to record the output in the session transcript. Empty output is a no-op (no blank entry is appended).
- The transcript is append-only; never truncate or rewrite it during a skill execution.
- If the live substrate is unavailable, both `await_reply` and `relay_to_team_lead` emit `MODE_B_FALLBACK` and no live reply is fetched; the fallback Mode A result is the effective output.

#### SHUTDOWN

**Description.** At skill completion (or on any early-exit path), the orchestrator shuts down all active teammates to release resources and ensure no orphaned panes or background processes remain. Shutdown is idempotent: calling it when no teammates are active is a safe no-op.

**Contract.**
- Call `shutdown_all` at the end of every skill workflow that spawned teammates — including error-exit paths. Wrap the skill's main body in a `trap shutdown_all EXIT` to guarantee cleanup.
- To shut down a single teammate early, call `shutdown_teammate HANDLE`. This removes the handle from the registry; subsequent calls for that handle are errors.
- `shutdown_all` tolerates individual shutdown failures (a teammate that is unreachable produces a warning to stderr but does not abort the sweep). The return code is non-zero if any individual shutdown failed.
- Skill authors MUST NOT rely on process-level cleanup to replace an explicit `shutdown_all` call.

---

### Topologies

Mode B supports two dispatch topologies, declared in the skill SKILL.md frontmatter as `topology: hub` or `topology: mesh`. The topology controls how teammates communicate with each other and with the orchestrator.

#### HUB

**Definition.** One designated team lead (the orchestrator turn) drives all communication. Teammates do not message each other directly; every turn goes through the hub.

**Use-case example.** A `gaia-dev-story` execution where the orchestrator drives a `gaia:architect` teammate for design review and a `gaia:qa` teammate for test planning. The orchestrator relays outputs between them; the two teammates never communicate directly.

**Setup with `dispatch-teammate.sh`:**

```bash
# source the library (GAIA_SESSION_DIR must be set)
source "$PLUGIN_ROOT/scripts/lib/dispatch-teammate.sh"

arch_handle="$(spawn_teammate "gaia:architect" --context "dev-story-design")"
qa_handle="$(spawn_teammate "gaia:qa" --context "dev-story-tests")"

# HUB: orchestrator drives each teammate in sequence
drive_turn "$arch_handle" "Review the proposed API design."
arch_reply="$(await_reply "$arch_handle")"
relay_to_team_lead "$arch_handle" "$arch_reply"

drive_turn "$qa_handle" "Derive test cases from: $arch_reply"
qa_reply="$(await_reply "$qa_handle")"
relay_to_team_lead "$qa_handle" "$qa_reply"
```

#### MESH

**Definition.** Teammates can communicate with each other via the relay mechanism, not only with the orchestrator. The orchestrator still initiates and terminates the session, but inter-teammate communication is permitted within a coordinated round.

**Use-case example.** A `gaia-brainstorming` session where `gaia:brainstorming-coach`, `gaia:analyst`, and `gaia:problem-solver` exchange ideas across multiple rounds. The orchestrator relays each output to the next teammate in the mesh rather than collecting all outputs itself.

**Setup with `dispatch-teammate.sh`:**

```bash
source "$PLUGIN_ROOT/scripts/lib/dispatch-teammate.sh"

coach_handle="$(spawn_teammate "gaia:brainstorming-coach" --context "ideation")"
analyst_handle="$(spawn_teammate "gaia:analyst" --context "ideation")"

# MESH: output of one teammate feeds the next
drive_turn "$coach_handle" "Generate five novel problem framings."
coach_reply="$(await_reply "$coach_handle")"
relay_to_team_lead "$coach_handle" "$coach_reply"

# Forward coach output to analyst (mesh relay)
drive_turn "$analyst_handle" "Critically evaluate these framings: $coach_reply"
analyst_reply="$(await_reply "$analyst_handle")"
relay_to_team_lead "$analyst_handle" "$analyst_reply"
```

---

### Human-interjection routing

When a user sends input during an active teammate session, the orchestrator must route it without breaking the lifecycle protocol.

**Routing contract:**

1. The orchestrator receives the user message on the main turn.
2. Identify which teammate the message is directed at (by handle or by context). If ambiguous, the team lead (orchestrator) handles it directly.
3. Call `drive_turn HANDLE "<user message>"` to forward the interjection to the relevant teammate.
4. Collect the reply with `await_reply HANDLE` and relay it back to the user with `relay_to_team_lead`.

**Mode A fallback.** When the live substrate is unavailable, `drive_turn` and `await_reply` emit `MODE_B_FALLBACK` to stderr and degrade to a foreground Mode A dispatch. User input is still processed, but in-conversation teammate continuity is lost. The orchestrator must treat the Mode A result as the effective response and not assume any prior teammate context was retained.

Skill authors must never pass raw user input directly to a `drive_turn` call without first sanitising it (e.g. stripping terminal escape sequences). This is the only user-trust boundary in the lifecycle.

---

### No-leaked-panes invariant

Teammate sessions must not leave orphaned panes, background processes, or stale registry entries after the skill workflow completes.

**Invariant:** every `spawn_teammate` call must be paired with a corresponding `shutdown_teammate` or covered by a `shutdown_all` call before the skill exits.

**How `shutdown_all` enforces this:**

- `shutdown_all` reads every handle file from the registry directory and calls `shutdown_teammate` on each.
- Individual shutdown failures (e.g. an unreachable or already-terminated teammate) produce a warning to stderr but do not abort the sweep — `shutdown_all` processes all registered handles.
- After a successful `shutdown_all`, the registry directory is empty. Any subsequent `drive_turn` or `await_reply` calls will fail with an unknown-handle error, making leaked-pane bugs visible immediately in tests.
- Use `trap shutdown_all EXIT` at the top of any skill orchestration function that calls `spawn_teammate`. This ensures `shutdown_all` runs even when the orchestrator exits due to an unhandled error.

---

### Minimal end-to-end example

The following snippet shows SPAWN through SHUTDOWN for a two-teammate HUB session. It is substrate-honest: the `MODE_B_FALLBACK` path is handled.

```bash
#!/usr/bin/env bash
# Example: two-teammate HUB session with Mode B degradation awareness.
set -euo pipefail
LC_ALL=C; export LC_ALL

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export GAIA_SESSION_DIR="${GAIA_SESSION_DIR:-$(mktemp -d)}"

# Source the dispatch library.
# shellcheck source=scripts/lib/dispatch-teammate.sh
source "$PLUGIN_ROOT/scripts/lib/dispatch-teammate.sh"

# Guarantee cleanup on any exit path.
trap shutdown_all EXIT

# ---------- SPAWN ----------
arch_handle="$(spawn_teammate "gaia:architect" --context "example")"
qa_handle="$(spawn_teammate "gaia:qa" --context "example")"

# ---------- DRIVE + RELAY ----------
drive_turn "$arch_handle" "Design a minimal REST endpoint for /health."
arch_output="$(await_reply "$arch_handle")"
relay_to_team_lead "$arch_handle" "$arch_output"

drive_turn "$qa_handle" "Write three test cases for: $arch_output"
qa_output="$(await_reply "$qa_handle")"
relay_to_team_lead "$qa_handle" "$qa_output"

# ---------- SHUTDOWN ----------
# The trap fires here automatically on EXIT, calling shutdown_all.
# No orphaned panes remain after the script exits.

# Note: if MODE_B_FALLBACK was emitted to stderr during spawn_teammate or
# drive_turn, the above still succeeds — the library degraded to Mode A and
# both arch_output and qa_output contain the foreground results.
```

`MODE_B_FALLBACK` on stderr is the signal that live persistent teammates were not available. Skill authors should surface this to the user via a lossy-mode warning rather than silently suppressing it.
