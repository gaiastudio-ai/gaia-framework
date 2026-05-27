---
name: gaia-help
description: Context-sensitive help with project-state-aware routing (greenfield / brownfield / post-update / healthy). Analyzes the user's query and current project state (which docs/ artifacts exist + ADR-102 stale-flag markers) to suggest the most relevant GAIA slash command. Primary intent-to-command map is ${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv; every suggestion is cross-checked against ${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv so the skill never invents command names. Use when "help" or /gaia-help, when the framework detects configuration drift (`.framework-version-stale` or `.config-stale` markers present), or when the user asks "what should I do" / "project state".
argument-hint: "[optional — free-text description of what you want to do]"
allowed-tools: [Read, Grep, Glob]
orchestration_class: light-procedural
---

## Mission

You are the **GAIA help system**. Your job is to route the user to the most relevant slash command given their query and the current project state. You do that by (1) loading the intent-to-command map, (2) detecting which lifecycle phase the project is in by inspecting the `docs/` artifact tree, (3) suggesting the top three to five candidate commands with one-line rationales, and (4) offering to activate the selected workflow.

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/help.md` task (45 lines). Per **ADR-041** (Native Execution Model) and **ADR-042** (Scripts-over-LLM for Deterministic Operations), the legacy task-runner engine is retired. Because the engine no longer mediates suggestions, this skill is the last line of defense against hallucinated commands — it MUST cross-check every suggestion against `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv`.

## Critical Rules

- **Only suggest commands that exist in `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv` — never invent command names.** This mandate originates in `_gaia/core/engine/workflow.xml` (engine Step 7: Completion — "Only suggest commands that exist in workflow-manifest.csv — never invent command names") and is propagated into this skill because the native model removes the engine layer. Every suggested command MUST appear in `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv` at runtime. If a candidate from `${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv` is not in the manifest, drop it from the suggestion list.
- **Load `${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv` as the primary intent-to-command map.** That file encodes which slash command handles which user intent (e.g., "I want to start a new project" → `/gaia-brainstorm-project`). It is authored by the team and must not be hard-coded into this skill.
- **Detect lifecycle phase from canonical `.gaia/artifacts/` first, then legacy `docs/` fallback** — inspect `.gaia/artifacts/planning-artifacts/`, `.gaia/artifacts/implementation-artifacts/`, `.gaia/artifacts/test-artifacts/`, and `.gaia/artifacts/creative-artifacts/` with the Glob tool (per ADR-111). If none are present, fall back to the legacy `docs/planning-artifacts/`, `docs/implementation-artifacts/`, `docs/test-artifacts/`, and `docs/creative-artifacts/` locations for pre-migration installs. Determine which Phase the project is in (see Phase Guide below).
- **If `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv` is missing** (AC-EC2): refuse to suggest any command and fall back to `/gaia` with a clear warning. Do NOT invent. This is the non-negotiable no-hallucination rule. The behavior contract for this fallback mirrors the shared bash helper at `plugins/gaia/scripts/lib/missing-file-fallback.sh` (E28-S162) — emit a clear notice and degrade gracefully to a safe no-op rather than erroring. Bash consumers of the same pattern source the helper directly; this skill, being LLM prose, implements the same contract in Step 1 of the instructions below.
- Do NOT emit write operations. This skill is read-only and produces text suggestions only.

## Inputs

- `$ARGUMENTS`: optional free-text description of what the user wants to do. If empty, show the top-level categories + Phase Guide summary.

## Instructions

### Step 1 — Load the Command Map

- Use the Read tool to load `${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv`. This is the primary intent-to-command map authored by the team.
- Use the Read tool to load `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv`. This is the authority for which commands exist.
- If `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv` is missing or unreadable, emit the warning `workflow-manifest.csv missing — cannot validate command suggestions, falling back to /gaia` and exit with only `/gaia` as the suggestion. Do NOT hallucinate commands. This follows the same graceful-missing-file contract as `plugins/gaia/scripts/lib/missing-file-fallback.sh` (E28-S162): print a clear notice, degrade to a safe no-op, never error unless a strict-mode opt-in is set (not applicable for this skill).

### Step 2 — Parse the User Query

- If `$ARGUMENTS` is empty and the user said plain "help": show top-level categories + the Phase Guide (see §Phase Guide below).
- If `$ARGUMENTS` describes a task: match the text against the intents column of `${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv` and collect candidate commands.
- If the user is clearly mid-workflow: base suggestions on the most recent artifacts under `docs/` rather than the free-text query.

### Step 3a — Project State Detection

> **E86-S4 / FR-471 / ADR-103 — 4-state enum for project-state-aware help.**
> Run this BEFORE Step 3 (lifecycle-phase ranking) and BEFORE returning any
> suggestion. The result is written to the `$PROJECT_STATE` context variable
> read by Step 3 and Step 5.

**4-state enum with first-match-wins priority:**

```
greenfield > brownfield > post-update > healthy
```

**Bounded I/O contract (ADR-103 §Implementation Contract):** at most 4 stat
+ 1 readdir, zero file reads. Existence and emptiness checks only — never
`cat`, `head`, `tail`, `grep -r`, or `find` recursion on project files. The
detection runs once per `/gaia-help` invocation.

**Detection pseudocode** (the LLM follows this prose; Step 3 of this SKILL
reads the resulting `$PROJECT_STATE` value):

```bash
# Step 3a — Project State Detection (ADR-103, ADR-111)
# 4-state enum: greenfield > brownfield > post-update > healthy
# First-match-wins. Bounded I/O: 4 stat + 1 readdir, zero file reads.
#
# E97-S1 / ADR-111: prefer canonical `.gaia/{config,artifacts,memory}/` paths
# first; fall back to legacy `config/` and `docs/` on pre-migration installs.
# The legacy `_memory/` fallback was removed in AF-2026-05-27-3 — `.gaia/memory/`
# is the only memory tree. The first present path of each pair wins; absent
# canonical AND absent legacy means "missing".

PROJECT_STATE="healthy"  # default fall-through

# (1) Greenfield: config absent in BOTH canonical and legacy locations — short-circuit
if [ ! -f ".gaia/config/project-config.yaml" ] && [ ! -f "config/project-config.yaml" ]; then
  PROJECT_STATE="greenfield"

# (2) Brownfield: config present AND planning-artifacts missing-or-empty AND a build-system file exists
elif { [ ! -d ".gaia/artifacts/planning-artifacts" ] || [ -z "$(ls -A .gaia/artifacts/planning-artifacts 2>/dev/null)" ]; } \
  && { [ ! -d "docs/planning-artifacts" ]            || [ -z "$(ls -A docs/planning-artifacts 2>/dev/null)" ]; }; then
  BUILD_FILES=("package.json" "pyproject.toml" "go.mod" "Cargo.toml" "pom.xml" "Gemfile")
  for bf in "${BUILD_FILES[@]}"; do
    if [ -f "$bf" ]; then
      PROJECT_STATE="brownfield"
      break  # short-circuit on first match
    fi
  done
  # If no build-system file matched, fall through to post-update / healthy below
  if [ "$PROJECT_STATE" != "brownfield" ]; then
    if [ -f ".gaia/memory/.framework-version-stale" ]; then
      PROJECT_STATE="post-update"
    fi
    # else: healthy (default already set)
  fi

# (3) Post-update: config present, planning-artifacts non-empty, drift marker present
elif [ -f ".gaia/memory/.framework-version-stale" ]; then
  PROJECT_STATE="post-update"
fi
# else: healthy (default)
```

**Privacy contract (SR-58 / T-FVD-7):** when the detected state is
`brownfield`, the user-visible suggestion text MUST NOT name which
build-system file triggered detection. The detection logic internally
knows which file matched (for telemetry/debug), but the suggestion stays
generic — see "Suggestion text by state" below.

**Suggestion text by state:**

- **greenfield:** No prepended state-aware text. Promote `/gaia-init` to
  suggestion position #1 in Step 3's ranking; remaining slots follow the
  existing help-csv heuristics.
- **brownfield:** Prepend "Existing project detected. Run
  `/gaia-brownfield` to onboard." to the output. Promote `/gaia-brownfield`
  to position #1. SR-58 forbids naming the triggering build-file.
- **post-update:** Prepend "Framework update detected. Run `/gaia-migrate`
  to reconcile your config, or `/gaia-help --verbose` for details." to the
  output. Promote `/gaia-migrate` to position #1.
- **healthy:** No state-aware text. Step 3 lifecycle-phase ranking proceeds
  unchanged.

### Step 3 — Detect Lifecycle Phase

> **E86-S4 / AC8 — `$PROJECT_STATE` integration.** Read `$PROJECT_STATE`
> from Step 3a. Apply priority promotion per the rules in Step 3a's
> "Suggestion text by state" — `greenfield` promotes `/gaia-init` to #1;
> `brownfield` promotes `/gaia-brownfield` to #1; `post-update` promotes
> `/gaia-migrate` to #1; `healthy` leaves the lifecycle-phase ranking
> below unchanged. State-aware promotion happens BEFORE the lifecycle-
> phase ranking executes.

Inspect the artifact tree with Glob to determine the current phase (canonical `.gaia/artifacts/` first, legacy `docs/` fallback for pre-ADR-111 projects):

- No artifacts in any of the four artifact subdirectories → **Phase 1 (Analysis)**.
- PRD present in `.gaia/artifacts/planning-artifacts/` (or legacy `docs/planning-artifacts/`) but no architecture → **Phase 2/3 (Planning / Solutioning)**.
- Architecture present but no sprint plan in `.gaia/artifacts/implementation-artifacts/` (or legacy `docs/implementation-artifacts/`) → **Phase 3/4 (Solutioning / Implementation)**.
- Sprint plan / stories present in `.gaia/artifacts/implementation-artifacts/` (or legacy `docs/implementation-artifacts/`) → **Phase 4 (Implementation)** — suggest specific story or review workflows.
- Test plans in `.gaia/artifacts/test-artifacts/` (or legacy `docs/test-artifacts/`) and release material → **Phase 5 (Deployment)**.

#### Phase 5 config-shape routing (E99-S5 / FR-524 / ADR-112 §(f))

When the heuristics route the user into Phase 5, source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-shape-detect.sh` and call `gaia_config_shape_detect <project-config.yaml>`. The detector reads `environments[*].kind` (with the E99-S1 read-time default to `deployable`) and the presence/absence of the top-level `distribution:` section, emitting exactly one of four tokens. Apply the suggestion table:

| Detector token | Phase 5 primary suggestion | Notes |
|---|---|---|
| `deploy-only` | `/gaia-deploy` | All envs `deployable`, no `distribution:` — historical baseline (NFR-080 byte-identical). Do NOT suggest `/gaia-publish`. |
| `publish-primary` | `/gaia-publish` | No env is `deployable` (all `branch-only` / `distribution-only`) — publish-via-channel is the canonical release path. Do NOT suggest `/gaia-deploy` (it would HALT per E99-S1's TC-EKD-2 gate). |
| `deploy-and-publish` | BOTH `/gaia-deploy` AND `/gaia-publish` | Mixed shape — at least one `deployable` env + `distribution:` present. The body MUST distinguish which envs are reachable via which command. |
| `unknown` | Fall back to the gaia-help.csv lookup unchanged. | environments[] absent — caller decides. |

The routing is config-shape-driven (NOT intent-keyword-driven); `gaia-help.csv` intent map remains the canonical lookup for non-Phase-5 intents. State-detection (ADR-103) is orthogonal — Phase 5 routing runs after the state-aware pre-filter completes.

Use these heuristics to rank which `${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv` matches are most relevant given where the project is.

### Step 4 — Cross-Check Against the Manifest

For every candidate command produced by Step 2 or Step 3:

- Grep `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv` for the exact command name.
- If the command is NOT in the manifest: drop it silently (do NOT emit a suggestion that fails this check).
- If fewer than three candidates survive the cross-check, backfill with `/gaia` as the catch-all.

This is the canonical no-hallucination gate. The skill MUST refuse to suggest any command that is not in `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv`.

### Step 5 — Present Suggestions

Render the top three to five surviving suggestions as:

```
Suggested next command(s):

1. /gaia-{cmd} — {one-line description from ${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv}
   Why: {brief rationale — what Phase the project is in, what artifact already exists or is missing}

2. …
```

> **E86-S5 / AC8 / SR-56 — verbose-mode visibility for the drift-check
> bypass.** When `/gaia-help` is invoked with `--verbose` (`$ARGUMENTS`
> contains the `--verbose` flag) AND the environment variable
> `GAIA_SKIP_VERSION_CHECK=1` is set, append the following passive note
> verbatim to the rendered output (after the suggestion list, before
> the Step 6 prompt):
>
> ```
> Note: version drift check is disabled (GAIA_SKIP_VERSION_CHECK=1).
> ```
>
> The note informs the user that the drift detection hook in
> `resolve-config.sh` is short-circuited (see E86-S5). It does NOT
> recommend any action; suppressing the check is an intentional opt-out
> for batch/test contexts. Do NOT emit the note when `--verbose` is
> absent (the env var alone is not a trigger) or when
> `GAIA_SKIP_VERSION_CHECK` is unset / `0` / any value other than the
> literal string `1`.

### Step 6 — Offer To Activate

Conclude with: `Run one of these now? Reply with the command name, or say "no" to exit.` — preserve the legacy "offer to activate the selected workflow" behavior.

## Phase Guide

(Canonical from `_gaia/core/tasks/help.md` — ported verbatim so the skill does not re-prose the mapping.)

| Phase | Key Artifact | Slash Command |
|-------|--------------|---------------|
| 1 — Analysis | Product brief | `/gaia-brainstorm-project` |
| 2 — Planning | PRD | `/gaia-create-prd` |
| 3 — Solutioning | Architecture doc | `/gaia-create-architecture` |
| 4 — Implementation | Sprint plan | `/gaia-sprint-planning` |
| 5 — Deployment | Release plan | `/gaia-release-plan` |

## Quick Actions

(Canonical quick-intent rows from `_gaia/core/tasks/help.md` — ported verbatim.)

- "I want to start a new project" → `/gaia-brainstorm-project`
- "I have an existing codebase" → `/gaia-brownfield-onboarding`
- "I need to write code" → `/gaia-dev-story`
- "Review my code" → `/gaia-code-review`
- "Run tests" → `/gaia-test-design`
- "I need to brainstorm" → `/gaia-brainstorming`

Every one of the above MUST survive the Step 4 manifest cross-check before being emitted — this skill never hard-codes a suggestion that is not validated against `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv` at runtime.

## References

- Source: `_gaia/core/tasks/help.md` (legacy 45-line task body — ported per ADR-041 + ADR-042).
- `${CLAUDE_PLUGIN_ROOT}/knowledge/gaia-help.csv` — primary intent-to-command map (loaded at runtime; ships inside the plugin).
- `${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-manifest.csv` — authority for valid command names (cross-checked at runtime; ships inside the plugin).
- `_gaia/core/engine/workflow.xml` — origin of the "never invent command names" mandate propagated into this skill's Critical Rules.
- ADR-041: Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042: Scripts-over-LLM for Deterministic Operations.
- ADR-048: Engine Deletion as Program-Closing Action — legacy task coexists with this skill until program close.
- FR-323: Skill Conversion — slash-command identity preserved.
- NFR-053: Full v1.127.2-rc.1 Feature Parity.
- `plugins/gaia/scripts/lib/missing-file-fallback.sh` (E28-S162): shared bash helper whose missing-file contract this skill mirrors in prose.
