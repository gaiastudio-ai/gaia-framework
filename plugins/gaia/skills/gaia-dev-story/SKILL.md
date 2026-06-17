---
name: gaia-dev-story
description: Implement a user story end-to-end -- validate, dev, test, PR. Use when "dev this story" or /gaia-dev-story.
argument-hint: [story-key]
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
hooks:
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: ${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/checkpoint.sh write gaia-dev-story
orchestration_class: heavy-procedural
yolo_steps: [5, 6, 7, 15]
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/setup.sh

**YOLO activation.** `setup.sh` detects `yolo` / `--yolo` in the invocation
arguments (via `$ARGUMENTS`, since the `!`-Setup directive does not forward
positional args) and, when present, runs `yolo-mode.sh set` to create the
`.gaia/state/.yolo-active` sentinel. The sentinel — not a bare env export — is
the activation signal, because env-var exports do not survive across Bash
tool-call boundaries under Claude Code. The downstream `yolo-mode.sh is_yolo`
gate (Step 4 planning gate, plus `yolo_steps: [5, 6, 7, 15]`) is the single
source of truth that reads this state; never re-implement detection inline.
This activates YOLO for THIS skill's run; subagent dispatches still require the
explicit `GAIA_YOLO_MODE=1` inheritance export documented at Step 4.

## Brain Context

!${CLAUDE_PLUGIN_ROOT}/scripts/brain/brain-reliance-loader.sh gaia-dev-story:load-story

## Mission

You are orchestrating a user story end-to-end: loading the story spec, planning the implementation, writing tests (TDD red), implementing code (TDD green), refactoring, verifying the Definition of Done, committing, pushing, creating a PR, waiting for CI, and merging. This is the most comprehensive dev workflow in GAIA.

**You are the bridge, not the engineer.** The plan authoring (Step 4) and the TDD implementation (Steps 5/6/7) are delegated to a **stack-matched developer subagent** resolved from project knowledge (Step 3b) — exactly as `/gaia-quick-dev` delegates to `gaia:stack-dev`. The main turn resolves the developer, dispatches the engineering work, and owns the gates: the Val plan-validation gate (Step 4), the risk-gated `tdd-reviewer` gates (Steps 5a/6a/7a), the Step 7b Val-in-TDD pass, and the push/PR/CI/merge tail. The orchestrator never writes production code or tests inline.

This skill is the native Claude Code conversion of the legacy dev-story workflow. The playbook contains all LLM reasoning guidance. The scripts directory contains all mechanical operations. The PostToolUse hook automatically writes a checkpoint after every Edit or Write tool invocation.

## Operator Quickstart

Implementing a story end-to-end. Load the story, plan with you, write failing tests (red), implement code (green), refactor, verify the Definition of Done, commit, push, open a PR, wait for CI to go green, then merge. The skill drives every step; you confirm choices and approve transitions.

**First-time invocation.**

```
/gaia-dev-story <story-key>
```

This loads `.gaia/artifacts/implementation-artifacts/.../<story-key>-*.md`, resolves the stack-matched developer for your project (Step 3b), and dispatches that developer to plan and implement through the TDD cycle on a feature branch — while the orchestrator runs the gates and lands a merged PR on staging (or your configured promotion target) once all checks pass.

**When to use which option.**

| You want to                                   | Run                                |
|-----------------------------------------------|------------------------------------|
| Implement a single story end-to-end           | `/gaia-dev-story <key>`            |
| Resume after the harness restarted mid-story  | `/gaia-dev-story <key>` (re-runs idempotently from the latest checkpoint) |
| Skip the PR + merge tail (push only)          | Set `ci_cd.promotion_chain: null` in `project-config.yaml` |
| Auto-advance past confirmation gates          | Pass `yolo` (or `--yolo`) as an argument |
| Implement a quick fix that doesn't need a story | `/gaia-quick-spec` then `/gaia-quick-dev` |

**Common gotchas.**

- The story file MUST exist and be `status: ready-for-dev` or `in-progress` -- any other status HALTS at Step 1.
- The PostToolUse hook checkpoints after every Edit/Write -- do not manually call `checkpoint.sh`.
- Steps 13-16 (push / PR / CI / merge) are mandatory when `ci_cd.promotion_chain` is set -- never skip them or ask "should I create the PR".

## Critical Rules

- A story file MUST exist at `.gaia/artifacts/implementation-artifacts/{story_key}-*.md` before starting. If missing, fail fast with "Story file not found -- run /gaia-create-story first."
- Story status MUST be `ready-for-dev` or `in-progress`. Any other status is a HALT condition.
- Plan authoring (Step 4) and TDD implementation (Steps 5/6/7) MUST be delegated to the stack-matched developer subagent resolved in Step 3b (`{stack}-dev`, via `load-stack-persona.sh --story-file`). The main-turn orchestrator MUST NOT author the plan or write tests/production code inline — it dispatches the developer and runs the gates. The orchestrator's own `Edit`/`Write` are reserved for gate-owned, non-code artifacts (the story file's Findings/Review-Gate tables, checkpoints). This mirrors the `/gaia-quick-dev` developer-delegation model.
- If no stack-developer persona can be resolved (Step 3b exit 2), HALT — do NOT fall back to an orchestrator-authored implementation.
- Follow TDD cycle strictly: Red (failing tests) -> Green (minimal implementation) -> Refactor. Each phase is a separate step -- NEVER combine them.
- Do NOT write implementation code during the Red phase.
- Do NOT skip the Refactor phase even if Green code looks acceptable.
- All tests MUST pass before marking complete.
- Definition of Done checklist MUST be verified -- every item checked before moving to review.
- When reading or running application source code, use the project path as the base directory.
- All mechanical operations (git, checkpoint, sprint-state, sha256, PR, CI, merge) are handled by scripts -- do NOT inline shell commands in the conversation.
- The PostToolUse hook fires `checkpoint.sh` automatically after every Edit/Write -- you do not need to manually checkpoint file mutations.
- Story status MUST only be changed via `transition-story-status.sh`. Direct edits to `status:` fields in story frontmatter, sprint-status.yaml, epics-and-stories.md, story-index.yaml, or per-epic shards under `.gaia/artifacts/planning-artifacts/epics/` are FORBIDDEN.

## Observability: per-step timing and token instrumentation

Each principal step emits a `step_boundary` lifecycle event via `emit-step-boundary.sh`. Token capture is automatic: the statusline runtime is the only component the substrate hands the context-window usage snapshot to (via hook stdin), so it persists the latest cumulative snapshot to `${MEMORY_PATH}/.context-window-snapshot.json`, and `emit-step-boundary.sh` reads that file at every step boundary. No manual flag is required for the common case -- as long as the GAIA statusline is enabled, real runs land per-step token data automatically. The explicit `--tokens <json>` flag still exists as an override (it wins over the persisted file) for callers that already hold a snapshot. When neither the file nor the flag is available, the event lands with timing data only and the token column renders `n/a` (graceful-skip).

**Substrate constraint:** the context-window usage snapshot is observable only by the statusline (the substrate delivers it to that hook's stdin), not via a shell-callable API any step can query mid-turn -- which is why the producer→consumer file bridge above exists. Per-step token numbers are therefore best-effort estimates derived from differencing consecutive cumulative snapshots. They are NEVER exact per-step counts -- cache reads, context compaction, and out-of-band turns confound the diff. Every downstream consumer labels these numbers as approximate.

**Privacy hard guarantee:** the `--tokens` payload MUST contain ONLY numeric fields (token counts). The script validates that all scalar values are numbers and silently drops any payload containing a string -- prompt/response text can never land in the telemetry stream.

**Usage:** `emit-step-boundary.sh <step> <name> <key> [--tokens '{"input_tokens":N,"output_tokens":N,"cache_creation_input_tokens":N,"cache_read_input_tokens":N}']`

Sub-step timing (2a, 2b, 3b, 5a, 6a, 6b, 7a, 7b, 14b) is out of scope for v1 -- only the 16 principal steps emit boundary events.

## Steps

### Step 1 -- Load Story

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 1 load-story {story_key}` to record the step-boundary event.

- Parse the story key from the argument (e.g., `/gaia-dev-story <story-key>`).
- Run `scripts/load-story.sh {story_key}` to validate the story exists and read its
  current status. `load-story.sh` is a thin wrapper around `sprint-state.sh get
  --story` — it prints the story **status** to stdout (exit 0) or fails (exit 1) when
  the story is unknown. It does NOT emit a path; it is a status check only.

<!-- step1 script-wiring begin -->
Resolve the absolute story path with the canonical resolver, then drive frontmatter
parsing, mode detection, and dependency-readiness through the deterministic helper
scripts — the LLM no longer parses the YAML frontmatter or computes the
FRESH/REWORK/RESUME verdict inline.

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh {story_key}` and capture
  its stdout as `{story_path}`. The resolver walks the three-tier layout precedence
  (per-story nested > legacy-nested > flat) and prints exactly one absolute path on
  exit 0; non-zero exit means the story file could not be located — HALT with the
  resolver's stderr. This is the single source of truth for `{story_key}` →
  `{story_path}`; do NOT fall back to an ad-hoc `find`. (`load-story.sh` above only
  reads status — it never resolves the path.)

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/story-parse.sh {story_path}`
  and `eval` its stdout to populate the canonical 10-variable env-var contract
  (`STORY_KEY`, `STATUS`, `RISK`, `EPIC_KEY`, `TYPE`, `DEPENDS_ON`, `SUBTASK_COUNT`,
  `SUBTASK_CHECKED`, `AC_COUNT`, `STORY_PATH`). Exit 2 = malformed frontmatter; HALT
  with the script's stderr. The parser reads canonical `key:` / `epic:` frontmatter
  and falls back to the `story_key:` / `epic_key:` alias convention when canonical
  fields are absent (canonical takes precedence; issue #1091) — so story files
  authored under either convention dev-story cleanly. `pr-body.sh` and `commit-msg.sh`
  honour the same alias.
- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/detect-mode.sh {story_path}`.
  Stdout is exactly one of `FRESH | REWORK | RESUME` — capture it as the execution
  mode. Do NOT re-derive the mode from `$STATUS` inline; the script is the single
  source of truth.
- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/check-deps.sh {story_path}`.
  Exit 0 = all `depends_on:` stories are status `done`; exit 1 = at least one dep is
  not done (stderr lists `<KEY>: <STATUS>`); exit 2 = at least one dep file is missing
  on disk. HALT on exit 1 or 2 — surface stderr to the user before proceeding.

  **`--bypass-deps` flag.** When the operator passes `--bypass-deps`
  to `/gaia-dev-story`, skip the `check-deps.sh` HALT and proceed with a single
  `[BYPASS] dependency check bypassed for {story_key} — depends_on entries not
  validated` line on stderr. Record the bypass in `.gaia/state/sprint-status.yaml`
  under the per-story `overrides:` block (`overrides.{story_key}.bypassed_checks:
  ["check-deps"]`) via `sprint-state.sh override --story {story_key} --add-check
  check-deps --reason "operator --bypass-deps at dev-story launch"` so retro
  reviewers see the bypass count and reason. Bypass MUST NOT be the default —
  the flag has to be explicit on the command line.

**Narrative Fallback (deprecated v1.131.x → v1.132.0):**
For brownfield projects on a stale plugin where these scripts are not yet present,
fall back to the legacy LLM narrative path. Each fallback is gated on the absence
of the new script:

```
if ! command -v story-parse.sh >/dev/null 2>&1; then
  # legacy narrative: read frontmatter inline, derive mode from $STATUS
else
  # new script path (above)
fi
```

This fallback is retained for ONE minor version (v1.131.x → v1.132.0) so brownfield
users with stale plugins do not break mid-upgrade. It will be removed in v1.132.0.
<!-- step1 script-wiring end -->

### Step 2 -- Update Status

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 2 update-status {story_key}` to record the step-boundary event.

- For FRESH mode: run `${CLAUDE_PLUGIN_ROOT}/scripts/transition-story-status.sh {story_key} --to in-progress`.
  - **Single activation path.** For a sprint-bound story (`sprint_id:` set), the
    expected pre-transition status is `ready-for-dev` — the activation
    `backlog → ready-for-dev` is owned by `/gaia-sprint-plan` Step 4a (Val-gated),
    NOT by dev-story. dev-story FRESH mode owns only `ready-for-dev → in-progress`.
    If a sprint-bound story is still `backlog` at this point, that means
    sprint-plan's activation gate did not run or did not pass for it — HALT and
    direct the user to re-run `/gaia-sprint-plan` (Step 4a) or
    `/gaia-validate-story {story_key}`; do NOT silently transition
    `backlog → in-progress` and bypass the validation gate.
  - **Pure backlog dev (`sprint_id: null`).** A backlog dev with no sprint binding
    is the one sanctioned `backlog → in-progress` case (the story-state-machine
    edge exists for exactly this path) — transition directly, no sprint-plan gate
    applies.
- For REWORK/RESUME: skip -- story is already in-progress.

**Step 2a — Auto-activate sprint if planned.** After the story transition completes, read `.gaia/state/sprint-status.yaml` (the canonical sprint-status home). If the sprint's `status:` is `planned` AND the just-transitioned story belongs to that sprint (its `sprint_id:` matches), invoke `${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh transition --sprint {sprint_id} --to active` to flip the sprint to `active`. Log: `auto-activated sprint {sprint_id}: planned → active (first dev-story transition)`. Skip silently when the sprint is already `active` or when the story has no sprint binding (sprint_id: null / unset — a backlog dev). The planned→active readiness gate was specced as a separate skill but never wired into the actual create-story → sprint-plan → dev-story chain; without this auto-activation step the sprint stays `planned` for the entire lifecycle and `/gaia-sprint-review` Step 1 then refuses to open because it expects `active`. Operators previously had to manually `sprint-state.sh transition --to active` between stories. Auto-activation on the first dev-story transition closes the gap with no operator burden.

<!-- step 2b atdd gate begin -->
### Step 2b -- ATDD Gate (high-risk stories only)

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/atdd-gate.sh {story_key}`.
- The script reads the story's `risk` frontmatter field (canonical) — `risk_level` is a longhand alias for the same semantic field. If `risk: high`, the script requires at least one ATDD scenarios file matching `atdd-{epic_key}*.md` OR `atdd-{story_key}*.md` under `.gaia/artifacts/test-artifacts/`. For `medium`, `low`, or unset risk it exits 0 unconditionally.
- On non-zero exit (high-risk story, no ATDD file): HALT with the script's stderr message naming the expected paths under `.gaia/artifacts/test-artifacts/`. Direct the user to `/gaia-atdd {story_key}` to generate the scenarios file before re-running `/gaia-dev-story`.
- On exit 0: proceed to Step 3.
- **Sequencing trade-off:** Step 2b sits AFTER Step 2 (status is already `in-progress`) but BEFORE Step 3 (no feature branch yet). Halting at 2b leaves the story status updated but no branch created — the user reverts status manually (or re-runs /gaia-dev-story after producing the ATDD file) to recover.
<!-- step 2b atdd gate end -->

### Step 3 -- Create Feature Branch

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 3 create-branch {story_key}` to record the step-boundary event.

- Run `scripts/git-branch.sh {story_key} {slug}` to create a feature branch.
- The script handles collision detection and offers resume if branch exists.

### Step 3b -- Resolve Stack Developer

The engineering work in this workflow — authoring the implementation plan (Step 4) and writing the tests and production code (Steps 5/6/7 TDD Red/Green/Refactor) — is performed by a **stack-matched developer subagent selected from project knowledge**, NOT by the main-turn orchestrator. The orchestrator stays a bridge: it resolves the developer, dispatches the work, and owns the gates (Val plan-validation, the risk-gated TDD review gates, the Step 7b Val-in-TDD pass, and the push/PR/CI/merge tail). This mirrors the proven `/gaia-quick-dev` delegation model — `gaia-dev-story` is the more comprehensive workflow and enforces the same clean-room boundary.

Resolve the developer persona via the shared resolver (it runs in the parent context BEFORE any fork dispatch):

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file {story_path}
```

`eval` the script's stdout to populate `stack`, `agent_file`, and `sidecar_file`. Resolution order inside the script: the story's `stack:` frontmatter field wins; otherwise it falls back to `project.stack` from config, then to filesystem markers under the project root (`angular.json` → angular-dev, `package.json`/`tsconfig.json` → ts-dev, `pom.xml`/`build.gradle` → java-dev, `requirements.txt`/`pyproject.toml` → python-dev, `go.mod` → go-dev, `pubspec.yaml` → flutter-dev, `Podfile`/`AndroidManifest.xml` → mobile-dev). The resolved `agent_file` is the absolute path to the matching `${CLAUDE_PLUGIN_ROOT}/agents/{stack}-dev.md` developer persona.

- **Exit 0:** log `Resolved developer: {stack} (persona {agent_file})` and carry `stack` / `agent_file` forward to Steps 4–7. Derive the subagent registration name from the persona filename — `basename {agent_file} .md` (e.g. `typescript-dev`, `angular-dev`, `flutter-dev`, `java-dev`, `python-dev`, `go-dev`, `mobile-dev`). Note the canonical `stack` token `ts-dev` maps to the `typescript-dev` persona/registration name; always dispatch by the filename-derived name, never the raw `ts-dev` token.
- **Exit 2 (unsupported stack / persona file not found):** HALT with the script's stderr. Do NOT silently fall back to a non-stack-aware orchestrator-authored implementation — the absence of a developer persona is a stop condition, not a license to self-implement. Direct the user to set the story's `stack:` frontmatter (or `project.stack` in config) to one of: ts-dev, angular-dev, flutter-dev, java-dev, python-dev, go-dev, mobile-dev.

**Stack-developer dispatch contract (used by Steps 4–7).** Whenever this workflow dispatches the developer, it dispatches the resolved developer subagent via the **main-turn Agent tool** (`subagent_type: gaia:<persona-name>`, where `<persona-name>` is the `basename {agent_file} .md` resolved above — e.g. `gaia:typescript-dev`, `gaia:python-dev`) with exactly ONE level of subagent nesting. The dispatch prompt MUST carry:

1. **The story context** — the resolved `{story_path}`, the story key, and (for REWORK) the failed review reports the developer must address.
2. **The resolved `project_path`** as an explicit working-directory parameter. The developer MUST write application code to `project_path`, NOT to `project-root` (the CLAUDE.md directory-identity rule). The prompt asserts this discipline verbatim.
3. **The checkpoint path** so the developer records `files_touched` (path + `shasum -a 256` + ISO-8601 `last_modified`) after each significant change — the PostToolUse `checkpoint.sh` hook also fires on the orchestrator side.
4. **JIT shared-skill references** by `{skill}#{section}` selector — never pre-loaded inline. Typical: `gaia-testing-patterns#tdd-cycle`, `gaia-git-workflow#commits`, `gaia-code-review-standards#review-gate-completion`.

**Nesting discipline.** The developer subagent loads shared skills JIT in-context — it does NOT spawn further nested subagents. The orchestrator's own gate dispatches (Val, `tdd-reviewer`) are sibling single-level dispatches, never nested inside the developer.

**YOLO inheritance.** When the orchestrator is in YOLO mode, it MUST `export GAIA_YOLO_MODE=1` into the developer dispatch's environment — a child does not inherit YOLO intent implicitly (see the Subagent YOLO inheritance note at Step 4).

### Step 4 -- Plan Implementation

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 4 plan {story_key}` to record the step-boundary event.

> **Developer-authored (Step 3b).** The implementation plan is authored by the resolved `{stack}-dev` developer subagent, dispatched per the Step 3b contract — NOT by the main-turn orchestrator. The orchestrator dispatches the developer to produce the plan, then receives the rendered plan back and runs the planning gate (validation / approval) below. Do NOT have the orchestrator author the plan inline.

- Dispatch the `{stack}-dev` developer subagent (Step 3b contract) to author the plan. The developer loads the playbook (`playbook.md`) for reasoning guidance and produces a detailed implementation plan covering: context, implementation steps, files to modify, testing strategy, risks.
  - For FRESH mode: the developer reads architecture.md and ux-design.md for context.
  - For REWORK mode: the developer reads the failed review reports and focuses the plan on fixing review issues.
  - For RESUME mode: the developer continues from checkpoint state.
- The developer returns the rendered plan to the orchestrator, which renders it to the user and runs the planning gate below. The orchestrator does NOT author or substitute its own plan.

<!-- figma graceful-degrade begin -->
**Figma graceful-degrade:** Before rendering the plan, if the story frontmatter has a `figma:` block, probe the Figma MCP server (e.g., `mcp__claude_ai_Figma__whoami`). If the probe fails (server unavailable, auth error, timeout, or the server is not listed):

- Log a single-line warning to stderr: `figma_mcp_unavailable: server={name} fallback=text-only` (single-line gate-log convention).
- Proceed with text-only context — DO NOT halt, no exception. Plan rendering continues with whatever non-Figma context is available.

Stories without a `figma:` frontmatter block proceed unchanged — this region only fires when Figma context was requested.
<!-- figma graceful-degrade end -->

<!-- planning gate begin -->
<!-- plan-structure validator hook -->

**Plan-structure validator:** BEFORE the planning gate halt fires and BEFORE the YOLO auto-validation loop, run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/validate-plan-structure.sh` against the rendered plan. Pass `--rework` when the execution mode is REWORK so the `Root Cause` section is required; otherwise the script enforces 8 sections (REWORK-only `Root Cause` skipped).

- The validator reports the FIRST missing canonical section on stderr and exits non-zero. Do NOT advance to the gate halt or the YOLO branch until the validator passes.
- On non-zero exit: log the missing section, instruct the agent to regenerate the plan with the missing section included, then re-run the validator.
- Cap the regenerate loop at 5 attempts to avoid infinite agent loops on a structurally broken plan template. On cap exhaustion, HALT with the last validator stderr and the attempt count so the user can intervene before the gate fires.
- Homoglyph mitigation: the validator uses `grep -F` with literal ASCII section names — Cyrillic homoglyphs (e.g., `Сontext` U+0421) are correctly treated as MISSING.

After the plan is rendered, the planning gate halts the workflow. YOLO mode detection is the single source of truth that selects the branch -- never re-implement detection inline.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo` to detect YOLO mode. The exit status is the verdict (0 = YOLO active, non-zero = interactive).

> **Subagent YOLO inheritance.** `is_yolo` reads `GAIA_YOLO_FLAG` / `GAIA_YOLO_MODE` from the environment (see `yolo-mode.sh` §Precedence). When this skill — or any step — is dispatched as a SUBAGENT, that subagent does NOT automatically inherit the parent's YOLO intent: a child process only sees env vars the parent exported into the dispatch. So when the orchestrator is in YOLO mode and dispatches a subagent, it MUST `export GAIA_YOLO_MODE=1` into that dispatch's environment, otherwise the child's `is_yolo` returns non-zero and silently takes the interactive branch. Do NOT rely on implicit inheritance; set it explicitly per dispatch (and per `feedback_yolo_session_env_export`, export per-subshell or session-wide and verify `yolo-mode.sh is_yolo` exits 0 before each gated step).

If `is_yolo` returns non-zero (non-YOLO branch -- default):
  - The next tool invocation MUST be `AskUserQuestion`. Do NOT invoke any other tool first. In particular, do NOT issue any `Edit` or `Write` tool call to a test file or implementation file between the plan render and the user's response -- the plan the user sees is the plan that gets implemented.
  <!-- three-option prompt body (labels: approve, revise, validate) -->
  - The `AskUserQuestion` prompt body offers exactly three labeled options -- `approve`, `revise`, `validate` -- lowercase, no punctuation, no synonyms. Do NOT add a fourth option (no `skip`, `verify`, `cancel`, etc.).
  - On `approve`: advance to Step 5 TDD Red. Only an explicit `approve` response advances; any other response (including silence) keeps the workflow halted.
  - On `revise`: ask the user for free-form feedback text via a follow-up `AskUserQuestion` (or harness-equivalent). Re-dispatch the `{stack}-dev` developer subagent (Step 3b contract) with the feedback so the developer — the plan author — regenerates the plan reflecting it. Then re-ask the same three-option question. The `revise` loop is user-driven and unbounded -- there is NO iteration cap; the user decides when to `approve`.
  - On `validate`: route the rendered plan to the `gaia-val-validate` skill via the **main-turn Agent tool**. After the Agent call returns, the skill MUST source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invoke `assert_agent_envelope {sentinel_path}` where `{sentinel_path} = .gaia/memory/checkpoints/val-envelope-{sha256(plan_path) first 16 hex}.json`. On non-zero exit, HALT with the canonical error string `HALT: Val agent envelope assertion failed — sentinel absent, malformed, or forged at {path}` — DO NOT fall through to a self-judged validation verdict. Then render Val's findings inline, grouped into CRITICAL / WARNING / INFO buckets, and re-ask the same three-option question. The `validate` loop is user-driven and unbounded -- there is NO iteration cap; the user decides when to `approve` or `revise`. This is intentionally distinct from the YOLO branch's 3-iteration auto-fix cap.
  - Emit a single-line gate log to stderr: `step4_gate: yolo=false verdict=halted` on entry, then `step4_gate: yolo=false verdict=passed` once the user responds with `approve`. Emit `step4_gate: yolo=false verdict=revise` and `step4_gate: yolo=false verdict=validate` per loop iteration on the corresponding branch.

If `is_yolo` returns zero (YOLO branch):
  <!-- YOLO Val auto-validation loop -->
  - The rendered plan auto-routes to Val for up to 3 iterations of CRITICAL+WARNING auto-fix. The YOLO branch MUST NOT issue any user-prompt tool call; the next tool invocation MUST be the `gaia-val-validate` skill on the rendered plan via the **main-turn Agent tool**. After the Agent call returns and BEFORE classifying findings, the skill MUST source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invoke `assert_agent_envelope {sentinel_path}` (sentinel path derived from `sha256(plan_path)` first 16 hex chars); on non-zero exit, HALT with the canonical error — DO NOT fall through to self-judged validation. Plan auto-fixes are applied by re-dispatching the `{stack}-dev` developer subagent (Step 3b contract) — the plan is developer-authored, so its revisions route to the developer, NOT to orchestrator-inline `Edit`/`Write`. The orchestrator owns the loop control; the developer dispatch stays single-level (no nested subagent spawn inside the loop).
  - **Path-traversal mitigation (AC5):** BEFORE constructing the audit-file path, validate `story_key` against the regex `^E[0-9]+-S[0-9]+$`. On mismatch, abort the YOLO branch with a clear error and emit no writes — never sanitize-and-continue. Reference shell idiom: `printf '%s\n' "$story_key" | grep -Eq '^E[0-9]+-S[0-9]+$'`.
  - **Audit file (AC2):** persist findings to `.gaia/memory/checkpoints/{story_key}-yolo-plan-findings.md` on every iteration. Append per iteration — never overwrite, never truncate. Two consecutive YOLO runs on the same story append a fresh set of `## Iteration {N} — {timestamp}` sections under the existing ones; entries from prior runs MUST be preserved verbatim. Each section body is the structured findings JSON or YAML returned by Val.
  - **Checkpoint persistence (AC4):** record the YOLO flag, the current iteration count, and the `last-findings-hash` (sha256 of the latest findings JSON) via `${CLAUDE_PLUGIN_ROOT}/scripts/append-val-iteration.sh` (which delegates to `write-checkpoint.sh`). Comparing `last-findings-hash` across iterations identifies oscillation; log stalls to the Dev Agent Record but DO NOT short-circuit the loop — the 3-iteration cap is the hard backstop.
  - **Canonical pseudocode (DoD documentation requirement):**

```
iteration = 0
while iteration < 3:
  findings = val.validate(plan)            # gaia-val-validate, severity in {CRITICAL, WARNING, INFO}
  critical = filter(findings, severity="CRITICAL")
  warning  = filter(findings, severity="WARNING")
  audit_append(iteration, findings)        # .gaia/memory/checkpoints/{story_key}-yolo-plan-findings.md
  checkpoint_record(yolo=true, iteration, sha256(findings))
  if not critical and not warning:         # INFO-only or empty -> break (AC3)
    break
  dispatch_developer(fixes=critical + warning)  # {stack}-dev subagent revises the plan (single-level)
  iteration += 1
if iteration == 3 and (critical or warning):
  HALT with remaining findings + audit-file path -> /gaia-fix-story  # AC2 cap
else:
  proceed to Step 5
```

  - **Halt-on-exhaust behavior (AC2):** if the loop exhausts the 3-iteration cap with remaining CRITICAL or WARNING findings, HALT with an actionable message that names the remaining findings and points to `.gaia/memory/checkpoints/{story_key}-yolo-plan-findings.md`. Direct the user to `/gaia-fix-story` or to re-run with the audit file as context. YOLO MUST NOT bypass the cap.
  - **INFO-only break (AC3):** if Val returns INFO-only findings (or no findings) on any iteration, break the loop and proceed to Step 5 immediately — INFO findings are advisory and never gating.
  - **Resume semantics (AC4):** when `/gaia-resume` re-enters this branch, read the checkpoint to recover yolo flag + iteration count + last-findings-hash, then re-enter the loop at the recorded iteration. If the next iteration's findings hash matches the recorded one, log the stall and continue.
  - **No inline YOLO detection (AC6):** YOLO detection has already happened at the gate dispatch above. This branch body MUST NOT redefine or re-implement YOLO detection — single-source-of-truth. The branch is selected by the surrounding gate; the body simply consumes the verdict.
  - **`yolo_steps:` wiring:** the per-step YOLO list selects this branch via the wired entry point; if it has not landed, this branch is reached via the script-call fallback at the gate dispatch above — never inline.
  - Emit a single-line gate log to stderr per iteration: `step4_gate: yolo=true iteration={N} outcome={clean|info_only|findings_present}` (the `outcome` enum mirrors `append-val-iteration.sh --revalidation-outcome`). On loop exit emit a terminal verdict: `step4_gate: yolo=true verdict=passed` when the loop broke on clean / info_only, or `step4_gate: yolo=true verdict=halted` when the 3-iteration cap was reached with remaining CRITICAL or WARNING findings.

Backward-compatibility note: a resumed in-progress story with no Step 4 gate-clearance record on the checkpoint is treated as "halt not yet presented" and re-issues the halt -- it does NOT silently advance to Step 5.

<!-- planning gate end -->

### Step 5 -- TDD Red Phase (Write Failing Tests)

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 5 tdd-red {story_key}` to record the step-boundary event.

> [!yolo]
> Step 5 is covered by the declarative `yolo_steps: [5, 6, 7, 15]` frontmatter declaration. Under YOLO, the cumulative TDD diff (Steps 5/6/7) is validated by the single post-Refactor Val pass at Step 7b — that pass owns the 3-iteration auto-fix loop and the cap-exhaustion gate. The Step 5 body itself stays pause-free — the pause-free TDD invariant is non-negotiable. Step 5a (risk-gated TDD review hook) is the separate gate point that fires after Step 5 completes; it is OUTSIDE this YOLO branch's scope.

> **Developer-authored (Step 3b).** The failing tests in this step are written by the resolved `{stack}-dev` developer subagent, dispatched per the Step 3b contract — NOT by the main-turn orchestrator. The orchestrator does NOT write tests or implementation code inline; it dispatches the developer and then runs the Step 5a gate on the result.

- The developer follows the playbook's test strategy reasoning.
- For each subtask: the developer writes failing test(s) that define expected behavior.
- Run the test suite -- verify all new tests FAIL.
- Tests MUST fail because implementation does not exist yet. If a test passes without implementation, it is vacuous and must be rewritten.

### Step 5a -- TDD Review Gate (Red phase)

<!-- step5 tdd-review-gate begin -->
After Step 5 completes with all new tests failing, invoke the risk-gated TDD review hook. The gate is a deterministic SKIP / PROMPT / QA_AUTO decision driven by the story's `risk` frontmatter, the configured `dev_story.tdd_review.threshold` and `phases`, and YOLO mode. The wiring is single-source-of-truth — never re-implement the decision matrix inline.

This gate sits OUTSIDE the Step 5 TDD body so the pause-free TDD invariant is preserved — the body of Step 5 itself contains no `AskUserQuestion` and no `HALT` directive.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/tdd-review-gate.sh {story_key} red`. The script prints exactly one of `SKIP`, `PROMPT`, `QA_AUTO` on stdout; capture it as `decision`.
- **`SKIP`:** Continue silently to Step 6. NO `AskUserQuestion` is presented. Emit a single-line gate log to stderr: `step5_tdd_gate: phase=red verdict=skip`.
- **`PROMPT`:** The next tool invocation MUST be `AskUserQuestion`. The prompt body offers exactly three labeled options — verbatim labels `review-myself`, `route-to-qa`, `proceed-anyway` (case-sensitive, hyphen-sensitive, in that exact order, no synonyms, no fourth option). The question stem names the gate trigger (story risk, configured threshold, current phase = `red`).
  - On `review-myself`: HALT for user-driven review. Resume via `/gaia-resume` re-enters at this same gate point.
  - On `route-to-qa`: dispatch the `tdd-reviewer` subagent (`gaia-framework/plugins/gaia/agents/tdd-reviewer.md`, persona "Tex") in fork context with the Red-phase diff. Surface the verdict (PASSED / FAILED / UNVERIFIED + findings line-by-line for WARNING-only). HALT on any `severity: CRITICAL` finding — YOLO MUST NOT auto-resolve CRITICAL findings; the halt fires in BOTH YOLO and non-YOLO. Findings persist to `.gaia/memory/checkpoints/{story_key}-tdd-review-findings.md` (append-only).
  - **WARNING-only routing (PASSED verdict).** A WARNING-only verdict is `PASSED`: surface each WARNING line-by-line and CONTINUE to the next phase — WARNINGs are carried to the Step 7b Val-in-TDD pass or captured as Findings. The gate MUST NOT auto-fix a WARNING inside this hook. If a code/test fix is undertaken at all, it routes ONLY by re-dispatching the `{stack}-dev` developer subagent (Step 3b contract, `subagent_type: gaia:<persona>`) — NEVER orchestrator-inline `Edit`/`Write`, and NEVER a bare general-purpose `Agent()` with no `subagent_type`. The orchestrator is the bridge, not the engineer; the `tdd-reviewer` never writes source.
  - On `proceed-anyway`: record a timestamped decision in the dev-story checkpoint via the PostToolUse `checkpoint.sh` write hook — the entry MUST include the timestamp (UTC ISO-8601), the phase (`red`), and the free-form reason captured from the user. Continue to Step 6.
  - Emit `step5_tdd_gate: phase=red verdict=prompt choice={review-myself|route-to-qa|proceed-anyway}` to stderr.
- **`QA_AUTO`:** YOLO + `qa_auto_in_yolo=true` branch. Dispatch the `tdd-reviewer` subagent with the same payload as `route-to-qa` (the only difference is the user did not explicitly choose). Surface the verdict; HALT on CRITICAL in BOTH modes. Emit `step5_tdd_gate: phase=red verdict=qa_auto`.

The hook fires exactly once per Step 5. If the gate returns `SKIP`, no subagent is dispatched and no prompt is presented.
<!-- step5 tdd-review-gate end -->

### Step 6 -- TDD Green Phase (Implement to Pass)

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 6 tdd-green {story_key}` to record the step-boundary event.

> [!yolo]
> Step 6 is covered by the declarative `yolo_steps: [5, 6, 7, 15]` frontmatter declaration. Under YOLO, the cumulative TDD diff (Steps 5/6/7) is validated by the single post-Refactor Val pass at Step 7b — that pass applies the INFO-only break (Green-phase INFO-only findings auto-proceed to Refactor without dev-agent intervention) and counts timed-out Val attempts against the 3-iteration cap. The Step 6 body itself stays pause-free — the pause-free TDD invariant is non-negotiable. Step 6a (risk-gated TDD review hook) is OUTSIDE this YOLO branch's scope.

> **Developer-authored (Step 3b).** The implementation code in this step is written by the resolved `{stack}-dev` developer subagent, dispatched per the Step 3b contract — NOT by the main-turn orchestrator. The orchestrator does NOT write implementation code inline; it dispatches the developer and then runs the Step 6a gate on the result.

- The developer follows the playbook's design approach reasoning.
- For each subtask: the developer implements the minimum code to make failing tests pass.
- Run the test suite -- verify all tests PASS.
- The developer marks each completed subtask in the story file.

### Step 6a -- TDD Review Gate (Green phase)

<!-- step6 tdd-review-gate begin -->
After Step 6 completes with all tests green, invoke the risk-gated TDD review hook. Decision matrix and dispatch contract mirror Step 5a — the only difference is `phase=green`.

This gate sits OUTSIDE the Step 6 TDD body so the pause-free TDD invariant is preserved — the body of Step 6 itself contains no `AskUserQuestion` and no `HALT` directive.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/tdd-review-gate.sh {story_key} green`. Capture stdout as `decision`.
- **`SKIP`:** Continue silently to Step 6b. NO `AskUserQuestion`. Emit `step6_tdd_gate: phase=green verdict=skip`.
- **`PROMPT`:** Next tool invocation MUST be `AskUserQuestion` with the three verbatim labels — `review-myself`, `route-to-qa`, `proceed-anyway` (case-sensitive, hyphen-sensitive, in that order, no fourth option).
  - On `review-myself`: HALT for user-driven review; `/gaia-resume` re-enters at this gate point.
  - On `route-to-qa`: dispatch the `tdd-reviewer` subagent in fork context with the Green-phase diff. Surface the verdict (line-by-line for WARNING-only). HALT on `severity: CRITICAL` in BOTH YOLO and non-YOLO. Findings append to `.gaia/memory/checkpoints/{story_key}-tdd-review-findings.md`.
  - **WARNING-only routing (PASSED verdict).** A WARNING-only verdict is `PASSED`: surface each WARNING line-by-line and CONTINUE to the next phase — WARNINGs are carried to the Step 7b Val-in-TDD pass or captured as Findings. The gate MUST NOT auto-fix a WARNING inside this hook. If a code/test fix is undertaken at all, it routes ONLY by re-dispatching the `{stack}-dev` developer subagent (Step 3b contract, `subagent_type: gaia:<persona>`) — NEVER orchestrator-inline `Edit`/`Write`, and NEVER a bare general-purpose `Agent()` with no `subagent_type`. The orchestrator is the bridge, not the engineer; the `tdd-reviewer` never writes source.
  - On `proceed-anyway`: record a timestamped decision (UTC ISO-8601 + phase=`green` + reason) in the dev-story checkpoint via the PostToolUse `checkpoint.sh` write hook. Continue to Step 6b.
  - Emit `step6_tdd_gate: phase=green verdict=prompt choice={review-myself|route-to-qa|proceed-anyway}`.
- **`QA_AUTO`:** Dispatch the `tdd-reviewer` subagent with the same payload as `route-to-qa`. Surface the verdict; HALT on CRITICAL in BOTH modes. Emit `step6_tdd_gate: phase=green verdict=qa_auto`.

The hook fires exactly once per Step 6 and ALWAYS BEFORE Step 6b advisory hints.
<!-- step6 tdd-review-gate end -->

<!-- step 6b begin -->
### Step 6b -- Conditional Check Advisory Hints

After Step 6 Green completes with all tests passing, run a single advisory pass over the staged diff to surface change patterns that commonly carry hidden risk. Step 6b is PURELY ADVISORY — it MUST NOT halt the workflow under any condition. The agent reads the advisory output and either addresses each item within the current story or captures it as a Finding, then proceeds to Step 7 Refactor.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/conditional-check-hints.sh` against the staged diff. The helper reads `git diff --cached --name-only` and emits one advisory line per matched category. Exit code is ALWAYS 0.
- The helper checks three patterns and emits AT MOST one advisory line per category (advisory output is informational; never multiple per category):
  1. **API route changes** — any path matching `*/routes/*.{ts,py,go}` OR `*/api/*.{ts,py,go}` triggers a contract-test advisory.
  2. **Schema/migration changes** — any path matching `*/migrations/*.sql` OR a filename containing `schema` with extension `.ts` / `.py` / `.sql` triggers a migration-script verification advisory.
  3. **Large blast radius** — total staged file count >= `BLAST_RADIUS_THRESHOLD` (default 10) triggers a feature-flag candidacy advisory.
- The advisories run in BOTH YOLO and non-YOLO modes — there is no `is_yolo` gate at Step 6b. The same staged set produces identical output regardless of run mode (distinct from the YOLO-gated steps).
- Each advisory line lists at most 10 file paths; longer lists are truncated with a trailing `,...`. This avoids advisory spam when many files in the same category change.
- **Non-halting contract:** Step 6b MUST NOT halt the workflow. The skill always proceeds to Step 7 Refactor after the advisory pass — even when all three advisories fire.
- Emit a single-line gate log to stderr: `step6b_gate: advisories={count}` where `count` is the number of advisory lines emitted (0, 1, 2, or 3).
<!-- step 6b end -->

### Step 7 -- TDD Refactor Phase

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 7 tdd-refactor {story_key}` to record the step-boundary event.

> [!yolo]
> Step 7 is covered by the declarative `yolo_steps: [5, 6, 7, 15]` frontmatter declaration. Under YOLO, the cumulative TDD diff (Steps 5/6/7) is validated by the single post-Refactor Val pass at Step 7b — that pass surfaces refactor-introduced test regressions (previously-green tests now failing tagged in Val's input context). The 3-iteration auto-fix loop owned by Step 7b enforces the attempt-cap gate: 3 attempts max, cap exhaustion stops with finding list, no silent pass. The Step 7 body itself stays pause-free — the pause-free TDD invariant is non-negotiable. Step 7a (risk-gated TDD review hook) is OUTSIDE this YOLO branch's scope.

> **Developer-authored (Step 3b).** The refactoring in this step is performed by the resolved `{stack}-dev` developer subagent, dispatched per the Step 3b contract — NOT by the main-turn orchestrator. The orchestrator does NOT refactor code inline; it dispatches the developer and then runs the Step 7a gate and the Step 7b Val-in-TDD pass on the result.

- The developer improves code quality while keeping all tests green.
- The developer extracts shared utilities, decomposes large functions, improves naming, removes duplication.
- Run the test suite -- verify all tests STILL PASS.

### Step 7a -- TDD Review Gate (Refactor phase)

<!-- step7 tdd-review-gate begin -->
After Step 7 completes with all tests still green, invoke the risk-gated TDD review hook. Decision matrix and dispatch contract mirror Steps 5a and 6a — the only difference is `phase=refactor`.

This gate sits OUTSIDE the Step 7 TDD body so the pause-free TDD invariant is preserved — the body of Step 7 itself contains no `AskUserQuestion` and no `HALT` directive.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/tdd-review-gate.sh {story_key} refactor`. Capture stdout as `decision`.
- **`SKIP`:** Continue silently to Step 7b. NO `AskUserQuestion`. Emit `step7_tdd_gate: phase=refactor verdict=skip`.
- **`PROMPT`:** Next tool invocation MUST be `AskUserQuestion` with the three verbatim labels — `review-myself`, `route-to-qa`, `proceed-anyway` (case-sensitive, hyphen-sensitive, in that order, no fourth option).
  - On `review-myself`: HALT for user-driven review; `/gaia-resume` re-enters at this gate point.
  - On `route-to-qa`: dispatch the `tdd-reviewer` subagent in fork context with the Refactor-phase diff. Surface the verdict (line-by-line for WARNING-only). HALT on `severity: CRITICAL` in BOTH YOLO and non-YOLO. Findings append to `.gaia/memory/checkpoints/{story_key}-tdd-review-findings.md`.
  - **WARNING-only routing (PASSED verdict).** A WARNING-only verdict is `PASSED`: surface each WARNING line-by-line and CONTINUE to the next phase — WARNINGs are carried to the Step 7b Val-in-TDD pass or captured as Findings. The gate MUST NOT auto-fix a WARNING inside this hook. If a code/test fix is undertaken at all, it routes ONLY by re-dispatching the `{stack}-dev` developer subagent (Step 3b contract, `subagent_type: gaia:<persona>`) — NEVER orchestrator-inline `Edit`/`Write`, and NEVER a bare general-purpose `Agent()` with no `subagent_type`. The orchestrator is the bridge, not the engineer; the `tdd-reviewer` never writes source.
  - On `proceed-anyway`: record a timestamped decision (UTC ISO-8601 + phase=`refactor` + reason) in the dev-story checkpoint via the PostToolUse `checkpoint.sh` write hook. Continue to Step 7b.
  - Emit `step7_tdd_gate: phase=refactor verdict=prompt choice={review-myself|route-to-qa|proceed-anyway}`.
- **`QA_AUTO`:** Dispatch the `tdd-reviewer` subagent with the same payload as `route-to-qa`. Surface the verdict; HALT on CRITICAL in BOTH modes. Emit `step7_tdd_gate: phase=refactor verdict=qa_auto`.

The hook fires exactly once per Step 7 and ALWAYS BEFORE Step 7b Val-in-TDD pass.
<!-- step7 tdd-review-gate end -->

<!-- step 7b begin -->
### Step 7b -- Val-in-TDD single post-Refactor pass

After Step 7 Refactor completes with all tests green, run a SINGLE Val pass over the diff (artifacts touched during Steps 5-7) before moving on to Step 8 Capture Findings. This restores V1's Val-in-TDD capability without re-introducing per-phase pauses inside the TDD body — Steps 5/6/7 remain pause-free per the contract enforced by `tests/skills/gaia-dev-story-step7b-val.bats`.

This loop runs unconditionally — both YOLO and non-YOLO. There is NO YOLO-mode gate at Step 7b; YOLO-mode detection lives only at the Step 4 planning gate. The body MUST NOT redefine or re-implement YOLO-mode detection — single-source-of-truth.

Loop semantics mirror the planning-gate YOLO loop: 3-iteration cap, CRITICAL+WARNING gating, INFO-only break, audit-file append, HALT-on-exhaustion. The differences are the input (TDD diff vs. plan) and the audit-file name (`{story_key}-tdd-val-findings.md` vs. `{story_key}-yolo-plan-findings.md`).

- The next tool invocation MUST be the `gaia-val-validate` skill on the diff (artifacts touched during Steps 5-7) via the **main-turn Agent tool**. After the Agent call returns and BEFORE classifying findings, the skill MUST source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invoke `assert_agent_envelope {sentinel_path}` (sentinel path derived from `sha256(diff_anchor_path)` first 16 hex chars, e.g. the story file path); on non-zero exit, HALT with the canonical error string `HALT: Val agent envelope assertion failed — sentinel absent, malformed, or forged at {path}` — DO NOT fall through to self-judged validation.
- **Auto-fix routes to the developer.** Because the diff is application code (Step 3b: code is developer-authored), each iteration's CRITICAL+WARNING auto-fixes are applied by re-dispatching the `{stack}-dev` developer subagent (Step 3b contract) with the finding set — NOT by the orchestrator's own `Edit`/`Write`. The orchestrator owns the loop control (iteration cap, audit append, HALT-on-exhaustion) but never writes production code itself. The developer dispatch stays single-level (no nested subagent spawn inside the loop).
- **Path-traversal mitigation:** BEFORE constructing the audit-file path, validate `story_key` against the regex `^E[0-9]+-S[0-9]+$`. On mismatch, abort Step 7b with a clear error and emit no writes — never sanitize-and-continue. Reference shell idiom: `printf '%s\n' "$story_key" | grep -Eq '^E[0-9]+-S[0-9]+$'`. The regex check MUST run before any path is constructed and before any audit-file write.
- **Audit file:** persist findings to `.gaia/memory/checkpoints/{story_key}-tdd-val-findings.md` on every iteration. Append per iteration — never overwrite, never truncate. Two consecutive end-of-story runs append a fresh set of `## Iteration {N} — {timestamp}` sections under the existing ones; entries from prior runs MUST be preserved verbatim. Each section body is the structured findings JSON or YAML returned by Val.
- **Auto-fix vocabulary** for diff-level findings: line edits, function-signature corrections, missing test assertions, dead code removal. Anything beyond the diff (e.g., cross-cutting refactors) is logged as Dev Notes and deferred — auto-fix MUST stay scoped to the diff.
- **Canonical pseudocode (DoD documentation requirement):**

```
diff = gather_diff(steps=[5,6,7])
iteration = 0
while iteration < 3:
  findings = val.validate(diff)              # gaia-val-validate, severity in {CRITICAL, WARNING, INFO}
  critical = filter(findings, severity="CRITICAL")
  warning  = filter(findings, severity="WARNING")
  audit_append(iteration, findings)          # .gaia/memory/checkpoints/{story_key}-tdd-val-findings.md
  if not critical and not warning:           # INFO-only or empty -> break
    break
  dispatch_developer(fixes=critical + warning)  # {stack}-dev subagent applies code fixes (single-level)
  iteration += 1
if iteration == 3 and (critical or warning):
  HALT with remaining findings + audit-file path
else:
  proceed to Step 8 (Capture Findings)
```

- **Halt-on-exhaust behavior (AC2):** if the loop exhausts the 3-iteration cap with remaining CRITICAL or WARNING findings, HALT with an actionable message that names the remaining findings and points to `.gaia/memory/checkpoints/{story_key}-tdd-val-findings.md`. Direct the user to `/gaia-fix-story` or to re-run with the audit file as context. The 3-iteration cap MUST NOT be bypassed.
- **INFO-only break:** if Val returns INFO-only findings (or no findings) on any iteration, break the loop and proceed to Step 8 immediately — INFO findings are advisory and never gating.
- **Single Val pass per story:** Step 7b runs Val ONCE per story-end, not once per Refactor cycle. Multiple Refactor iterations within Step 7 are part of the TDD body — they do NOT each trigger a Val pass.
- Emit a single-line gate log to stderr per iteration: `step7b_gate: iteration={N} outcome={clean|info_only|findings_present}`. On loop exit emit a terminal verdict: `step7b_gate: verdict=passed` when the loop broke on clean / info_only, or `step7b_gate: verdict=halted` when the 3-iteration cap was reached with remaining CRITICAL or WARNING findings.
<!-- step 7b end -->

### Step 8 -- Capture Findings

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 8 capture-findings {story_key}` to record the step-boundary event.

- Review any out-of-scope issues discovered during implementation.
- Add findings to the story file's Findings table.

<!-- step 9 dod-check wire begin -->
### Step 9 -- Definition of Done

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 9 definition-of-done {story_key}` to record the step-boundary event.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/dod-check.sh` (export `STORY_FILE` to the absolute story path so the subtask check fires). The script runs build / tests / lint / secrets / subtask checks and emits one YAML row per check: `- { item: <name>, status: PASSED|FAILED, output: <captured output> }`. Exit 0 = all PASSED; non-zero = at least one FAILED.
- **Tool-presence guards.** Any optional tool invoked from
  `dod-check.sh` (coverage, mypy, ruff, black, eslint, etc.) MUST be wrapped
  with a presence guard before invocation. Pattern:
  ```bash
  if command -v coverage >/dev/null 2>&1; then
    coverage report || true
  else
    echo "[WARN] coverage not installed; skipping coverage report" >&2
  fi
  ```
  Without the guard, a missing tool produces a fatal `command not found`
  that the DoD loop counts as a FAILED row and burns an auto-fix iteration
  on a non-actionable error. Guard each optional tool individually — do
  not stack them under one umbrella `command -v` because partial chains
  (coverage installed, mypy missing) still need to run coverage.
- Parse the YAML output and render a human-readable summary; the helper script holds the deterministic mechanics — DO NOT re-implement build/test/lint/secrets/subtask checks inline in this skill.
- On any FAILED row: auto-fix the underlying issue (test failure, lint warning, staged secret, unchecked subtask) and re-run `dod-check.sh`. Cap at 3 auto-fix iterations; on cap exhaustion, HALT with the failing rows and direct the user to intervene.
- ACs met / docs updated remain LLM-evaluated since they are intent-level checks, not script-checkable.
<!-- step 9 dod-check wire end -->

<!-- step 10 git-push wire begin -->
### Step 10 -- Commit and Push

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 10 commit-push {story_key}` to record the step-boundary event.

<!-- step10 script-wiring begin -->
At the top of the CI section — before any commit / push action — the orchestrator
MUST consult the deterministic promotion-chain guard. This replaces the LLM
narrative that previously inferred CI configuration inline.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/promotion-chain-guard.sh`.
  Exit 0 with `PRESENT:<branch>` on stdout = resolved first promotion-chain branch;
  exit 1 = `ABSENT` (stderr names the missing config and points to `/gaia-ci-edit`);
  exit 0 with empty stdout AND a `skipped (non-git CWD)` line on stderr = non-git
  workspace skip (the project-root `docs/` layout is outside any git work tree).
  On `ABSENT` or non-git skip, Steps 10–13 (push, PR, CI, merge) MUST be skipped —
  the story can still complete locally but the promotion gates do not fire. On
  `PRESENT`, capture the branch as `$PR_BASE` for use by `pr-create.sh --base`.

  **Non-git skip surface.** When the guard emits the `skipped
  (non-git CWD)` stderr line, the orchestrator MUST mirror it as a top-level
  `[NOTICE] non-git workspace — promotion gates skipped (CWD outside any git
  tree)` operator surface line before continuing. Otherwise the skip is
  invisible in the run log and operators only discover Steps 10–13 didn't
  fire after the fact.
- For commit-message construction, run
  `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/commit-msg.sh {story_path}`
  and feed its stdout to `git commit -F -`. Do NOT compose Conventional Commit
  subject lines inline — `commit-msg.sh` is the single source of truth. The script enforces the
  `<type>(<story_key>): <title>` schema and the no-`Claude` / no-`AI` /
  no-`Co-Authored-By` policy from CLAUDE.md.

**Narrative Fallback (deprecated v1.131.x → v1.132.0):**
For brownfield projects on a stale plugin where these scripts are not yet present,
fall back to the legacy LLM narrative path:

```
if ! command -v promotion-chain-guard.sh >/dev/null 2>&1; then
  # legacy narrative: infer CI config from project-config.yaml inline
fi
if ! command -v commit-msg.sh >/dev/null 2>&1; then
  # legacy narrative: compose Conventional Commit subject inline
fi
```

This fallback is retained for ONE minor version (v1.131.x → v1.132.0) so brownfield
users with stale plugins do not break mid-upgrade. It will be removed in v1.132.0.
<!-- step10 script-wiring end -->

- Run `scripts/git-branch.sh` to verify branch state.
- Stage and commit with conventional commit format.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/git-push.sh` to push the current branch to `origin`. The shared helper (a) refuses to push from `main` / `staging` (delegating to `lib/dev-story-security-invariants.sh::assert_branch_not_protected` when present), (b) retries ONCE on transient network errors (e.g., `Could not resolve host`, `Operation timed out`) with a 5-second backoff, and (c) fails LOUDLY on auth / permission errors with no retry. DO NOT inline `git push` here — the helper is the single source of truth.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/transition-story-status.sh {story_key} --to review` after all gates pass.
<!-- step 10 git-push wire end -->

### Step 11 -- Create PR

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 11 create-pr {story_key}` to record the step-boundary event.

<!-- step 11a forbidden-sentinel scan begin -->

**Step 11a — Forbidden-sentinel scan.**

BEFORE invoking `pr-body.sh` / `pr-create.sh`, scan the production-path slice of the diff (feature branch vs the promotion-chain base) for any forbidden sentinel listed in the taxonomy SSOT at `knowledge/taxonomy/forbidden-sentinels.txt`. The scan is implemented in `scripts/lib/forbidden-sentinel-scan.sh` — the LLM does NOT inline the taxonomy or re-implement the matcher.

```bash
# $PROMOTION_BASE is captured in Step 10 via promotion-chain-guard.sh.
# Optional --allow-stub <reason> is forwarded from the dev-story args.
ALLOW_STUB_REASON="$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/forbidden-sentinel-scan.sh \
  --base-ref "$PROMOTION_BASE" \
  ${ALLOW_STUB:+--allow-stub "$ALLOW_STUB"})" || exit 1
```

**Behaviour:**
- exits 0 if no forbidden sentinels in the production-path diff slice (or `--allow-stub` accepted).
- exits 1 with canonical stderr `HALT: forbidden sentinel <S> in <path>:<line> — add a Finding row or pass --allow-stub=<reason> to /gaia-dev-story` on a production-path match.
- exits 1 with `--allow-stub reason must cite a story ID (Ex-Sx) or AI ID (AI-YYYY-MM-DD-N) — got: <reason>` on a malformed `--allow-stub` value.

**Production-path filter (AC6):** the scan EXEMPTS `gaia-framework/plugins/gaia/tests/**`, any `**/tests/fixtures/**` subtree, `.gaia/memory/**`, `docs/**`, `.github/**`, and any `*.bats` file (defense-in-depth).

**`--allow-stub` reason regex (AC4):** `^(E[0-9]+-S[0-9]+|AI-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+):` — must end with a colon so the reason is at minimum `<id>: <prose>`. Bare prose is rejected.

**HALT delivery:** inline `printf` to stderr + `exit 1`. `halt-event.sh` is gaia-meeting-scoped (not a shared library); a future relocation to `scripts/lib/` is a separate cross-cutting refactor and explicitly out of scope here.

**Reason forwarding (AC5):** on `--allow-stub` accept, the helper echoes the reason on stdout. The Step 11 caller MUST capture it and forward it to `pr-body.sh` via `--allow-stub-reason "$ALLOW_STUB_REASON"` so the override appears as a fifth section in the PR body.

<!-- step 11a forbidden-sentinel scan end -->

<!-- step11 script-wiring begin -->
The PR body is sourced from `pr-body.sh` — the LLM no longer composes the body
inline.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/pr-body.sh {story_path}
  [--allow-stub-reason "$ALLOW_STUB_REASON"]` and capture stdout as `$PR_BODY`.
  The script emits the four canonical Markdown sections (Acceptance Criteria,
  Definition of Done, Diff Stat, Story-link); when `--allow-stub-reason` is
  supplied (forwarded from Step 11a), pr-body.sh emits a fifth
  section `## Allow-stub override` containing the reason.
- Then invoke `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/pr-create.sh
  {story_key} {title} --body-file <(printf '%s\n' "$PR_BODY")` (or pipe `$PR_BODY`
  via the helper's body-file convention) so that `pr-create.sh` consumes the
  pre-rendered body rather than constructing one inline. Do NOT hand-craft the PR
  body in chat — `pr-body.sh` is the single source of truth.

**Narrative Fallback (deprecated v1.131.x → v1.132.0):**
For brownfield projects on a stale plugin where `pr-body.sh` is not yet present,
fall back to the legacy LLM narrative path:

```
if ! command -v pr-body.sh >/dev/null 2>&1; then
  # legacy narrative: pr-create.sh composes a default body from $STORY_KEY
fi
```

This fallback is retained for ONE minor version (v1.131.x → v1.132.0) so brownfield
users with stale plugins do not break mid-upgrade. It will be removed in v1.132.0.
<!-- step11 script-wiring end -->

- `pr-create.sh` targets the first promotion chain environment as resolved by `promotion-chain-guard.sh` in Step 10.

### Step 12 -- Wait for CI

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 12 wait-ci {story_key}` to record the step-boundary event.

- Run `scripts/ci-wait.sh {pr_number}` to poll CI status.
- The script handles timeout, transient errors, and failure reporting.

### Step 13 -- Merge PR

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 13 merge-pr {story_key}` to record the step-boundary event.

- Run `scripts/merge.sh {pr_number} {story_key}` to merge the PR.
- The script handles conflict detection, branch protection, and strategy selection.

### Step 14 -- Post-Completion Gate

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 14 post-completion-gate {story_key}` to record the step-boundary event.

- After the dev-story subagent returns `status=done`, the orchestrator verifies that a merge commit containing the story key actually exists on the target branch before accepting the done transition.
- Run `scripts/verify-pr-merged.sh {story_key} {target_branch}` where `{target_branch}` is derived from `ci_cd.promotion_chain[0].branch` in global.yaml.
- If no promotion chain is configured, pass `--no-chain` instead of a branch name. The script exits 3 (skip) and the gate passes silently for backward compatibility.
- **Exit code 0 (pass):** Merge commit found on target branch. Proceed to Step 15.
- **Exit code 2 (fail):** No merge commit found. The orchestrator re-runs Steps 10-13 (commit, push, create PR, wait for CI, merge) in the main orchestrator context before advancing the story to done. This handles the case where the subagent completed implementation but failed to push or merge.
- **Word-boundary matching:** The script uses `\b{story_key}\b` grep patterns to avoid false positives on partial key matches (e.g., a shorter key must not match a longer one sharing the same prefix). Matching is case-insensitive to handle squash-merge message rewrites.
- **Historical failure modes that motivated this gate:**
  - **No push:** Dev-story subagent completed implementation but never pushed commits. Orchestrator accepted `status=done` at face value. Sprint closed with unmerged code.
  - **Reviews without merge:** Dev-story subagent completed all reviews but skipped push/PR/merge steps. Same outcome -- orchestrator trusted the status and sprint closed without the code landing.

<!-- step 14b cache-refresh advisory begin -->
### Step 14b -- Post-merge cache-refresh advisory (non-blocking)

After Step 14's post-completion gate confirms the merge commit landed, surface a single advisory line if the PR diff touched any cacheable plugin file (SKILL.md, scripts/*.sh, agents/*.md, hooks/*.json). The advisory mirrors Step 6b's non-blocking contract — it MUST NOT halt the workflow under any condition.

- Build the touched-files list from the merged feature branch: `git diff --name-only "$PROMOTION_BASE..HEAD"` (or the squash-commit's name-only listing on the target branch).
- Pipe the list through `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/cache-refresh-advisory.sh --diff-files <path>` (or via stdin). The helper applies the deterministic filter and emits AT MOST one `step14b_advisory: plugin-cache refresh recommended — touched files: <list>` line to stderr.
- Exit code is ALWAYS 0 — the advisory never blocks Step 15. The reminder points the operator at the README's "Plugin cache refresh after merge" section.
- Why this matters: the Claude Code substrate caches plugin SKILL.md / scripts at `~/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/<version>/` at session start. Without a refresh, the same-session re-invocation of a changed skill runs the PRE-merge code (dogfooding-loop-specific friction). See the README's playbook section.

Emit a single-line gate log to stderr: `step14b_gate: advisories={count}` where `count` is 0 or 1.
<!-- step 14b cache-refresh advisory end -->

<!-- step 15 init-review-gate wire begin -->
### Step 15 -- Update Review Gate

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 15 update-review-gate {story_key}` to record the step-boundary event.

- Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh {story_file}` to seed (or replace) the Review Gate table with the canonical 6-row UNVERIFIED block. The helper is idempotent — re-running on a story file that already has the block yields a byte-identical result.
- Update story status to `review` via `${CLAUDE_PLUGIN_ROOT}/scripts/transition-story-status.sh {story_key} --to review`.

> **Grace window note.** Within
> the **7-day post-flip grace window** after `/gaia-bridge-enable` flips
> `test_execution_bridge.bridge_enabled: true`, a review→done transition is
> permitted even when the composite `review-gate-check` returns PENDING
> (i.e. one or more of the six Review Gate rows is still UNVERIFIED) —
> the transition emits a WARNING rather than BLOCKING. This is the
> documented graceful-onboarding behavior for projects that just turned
> the bridge on: it gives operators a week to backfill the three
> test-execution gates (qa-tests, test-review, test-automate-review) on
> stories that completed dev BEFORE the bridge was wired. After 7 days
> the same composite PENDING verdict is BLOCKING: review→done is refused
> until every row is PASSED. To verify the active mode at any moment,
> run `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/gating-flip-guard.sh
> --scan --impl-dir <impl-artifacts-dir>` — it enumerates status:review
> stories whose Review Gate still has non-PASSED rows. Mid-window
> approval is correct-by-spec but worth flagging in retro: a not-all-
> PASSED composite does NOT block done within the grace window.
<!-- step 15 init-review-gate wire end -->

<!-- step 16 begin -->
### Step 16 -- Auto-Reviews (YOLO-only)

**Timing.** Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/emit-step-boundary.sh 16 auto-reviews {story_key}` to record the step-boundary event.

> [!yolo]
> Step 16 honors the declarative `yolo_steps: [15]` frontmatter declaration (the dispatch is logically the post-Step-15 hook; the framework split the dispatch into Step 16). Under YOLO, the six review skills run sequentially via the aggregator and ALL FAILED verdicts surface in the user-visible `## Review Summary` block — YOLO never silences a FAILED review. The Step 14 Post-Completion Gate remains a hard gate — `yolo_steps` does NOT include `14`.

YOLO-gated invocation of the six reviews that populate the Review Gate. Non-YOLO runs MUST NOT auto-fire reviews — the user manually invokes each review from the Review Gate UNVERIFIED rows. Silently auto-firing reviews in non-YOLO would erase user oversight.

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo` to detect YOLO mode (single source of truth — never re-implement detection inline).

- If `is_yolo` returns non-zero (non-YOLO branch — default):
  - SKIP Step 16 entirely. Review Gate rows remain UNVERIFIED for manual user review.
  - Emit a single-line gate log to stderr: `step16_gate: yolo=false verdict=skipped`.
  - Proceed to skill end.

- If `is_yolo` returns zero (YOLO branch):
  - Invoke `gaia-run-all-reviews` via Skill-to-Skill delegation. The aggregator runs all six reviews (Code Review, QA Tests, Security Review, Test Automation, Test Review, Performance Review) sequentially in subagents.
  - Each review writes its verdict (PASSED / FAILED) into the matching Review Gate row via `review-gate.sh`. After the aggregator completes, the Review Gate table is fully populated — no row remains UNVERIFIED.
  - Emit `step16_gate: yolo=true verdict=invoked` on entry and `step16_gate: yolo=true verdict=complete` on aggregator return.

- **FAILED-verdict surfacing.** After the aggregator returns, emit a `## Review Summary` block to the user. The block MUST list every review verdict on its own line (`- {review_name}: {PASSED|FAILED} — {report_path}`); the literal `FAILED` token is uppercase so downstream scanners can grep it. Then surface the composite verdict from `${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check`: exit 0 → `**Composite Review Gate:** COMPLETE`; exit 1 → `**Composite Review Gate:** BLOCKED — {N} FAILED review(s) must be addressed before merge.`; exit 2 → `**Composite Review Gate:** PENDING — {N} UNVERIFIED row(s) remain.` YOLO MUST NOT collapse a BLOCKED verdict into a PASS.

- **Dispatch-failure error path.** If the aggregator fails to dispatch entirely (skill not installed, subagent errors before returning verdicts, or dispatch times out), emit the canonical YOLO dispatch failed error: `**YOLO dispatch failed:** auto-run-reviews dispatch did not return verdicts ({reason}). Review Gate rows remain UNVERIFIED. Run \`/gaia-run-all-reviews {story_key}\` manually.` YOLO MUST NOT silent-pass a dispatch failure as if reviews completed successfully — the user must be in the loop for the manual fallback.

- **Sequencing invariant (AC4):** Step 14 (post-completion gate) MUST run BEFORE Step 16. Step 16 NEVER precedes Step 14. The skill ordering above enforces this — Step 14's begin marker precedes Step 16's begin marker.
<!-- step 16 end -->

### Step timing — sub-step instrumentation scope

The 16 principal `### Step N` boundaries above are instrumented with `step_boundary` lifecycle events for per-step wall-clock derivation. The following 9 lettered sub-steps are explicitly **out of scope for v1** and do not emit timing events: 2a, 2b, 3b, 5a, 6a, 6b, 7a, 7b, 14b. Sub-step instrumentation is a documented follow-up.

## Changelog

- **2026-05-14 — Step 11a forbidden-sentinel scan.** Added Step 11a between Step 10 (Commit and Push) and the existing Step 11 (Create PR) body. The new step invokes `scripts/lib/forbidden-sentinel-scan.sh --base-ref "$PROMOTION_BASE" [--allow-stub <reason>]` which sources the taxonomy SSOT (`knowledge/taxonomy/forbidden-sentinels.txt`) and scans the production-path slice of the feature-branch-vs-base diff for forbidden sentinels (STUB, MOCK, FIXME, XXX). Production-path filter EXEMPTS `tests/`, `**/tests/fixtures/`, `_memory/`, `docs/`, `.github/`, and any `*.bats` file (defense-in-depth). The `--allow-stub <reason>` override is gated on a story-ID or action-item-ID prefix regex; bare prose is rejected. Accepted reasons are forwarded to `pr-body.sh --allow-stub-reason` and emitted as a fifth `## Allow-stub override` section in the PR body. The scan fires BEFORE the PR is opened. HALT delivery is inline `printf + exit 1` (NOT halt-event.sh) — halt-event.sh is gaia-meeting-scoped, not a shared library; a future relocation is a separate refactor.
- **2026-05-13 — Sentinel-Write Writer Shift.** The Val sentinel write has been relocated from the Val sub-agent context to the orchestrator's main turn at three callsites in this skill: Step 4 `validate` user-branch, Step 4 YOLO auto-validation loop, and Step 7b Val-in-TDD post-Refactor pass. Val now RETURNS the sentinel content inside the envelope; each callsite writes the sentinel via the helper `plugins/gaia/scripts/lib/write-val-envelope.sh` BEFORE invoking `assert_agent_envelope`. The writer accepts Val's returned envelope shape DIRECTLY — it unwraps a nested `sentinel_envelope` (passing `persona_sig` through verbatim) or accepts a flat top-level sentinel, so each callsite pipes Val's returned envelope straight into the writer with no caller-side reshaping. Forgery resistance preserved via `persona_sig` binding to validator.md's on-disk sha256. Closes the substrate content-integrity false-fire that affected all three Val dispatch sites.
- **2026-05-12 — Val Bridge Migration.** Retargeted three Val dispatch sites to the main-turn Agent-tool dispatch model: Step 4 `validate` user-branch (planning gate), Step 4 YOLO auto-validation loop, and Step 7b Val-in-TDD post-Refactor pass. Each dispatch site now sources `assert-agent-envelope.sh` and invokes `assert_agent_envelope` immediately after the Agent call with HALT on assertion failure. Steps 10-16 (push/PR/CI/merge/review-gate) are intentionally untouched — they don't dispatch Val. Forgery resistance and promotion-chain regression are covered by `plugins/gaia/tests/val-bridge-migration.bats`.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/finalize.sh
