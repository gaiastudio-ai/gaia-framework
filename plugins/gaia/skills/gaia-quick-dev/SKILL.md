---
name: gaia-quick-dev
description: Implement a quick spec with auto-detected stack developer. Use when "dev this quick spec" or /gaia-quick-dev. Runs a five-step flow (Load Spec -> Resolve WIP -> Delegate to gaia:stack-dev subagent -> Verify -> Complete) against .gaia/artifacts/implementation-artifacts/quick-spec-{spec-name}.md. Native Claude Code conversion of the legacy quick-dev workflow.
argument-hint: "[spec-name]"
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
orchestration_class: heavy-procedural
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

<!--
  Source: _gaia/lifecycle/workflows/quick-flow/quick-dev/ (workflow.yaml + instructions.xml)
  Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks
  Scripts-over-LLM for Deterministic Operations
  Subagent invocation via context: fork for clean trust boundaries
  Hybrid Memory Loading (delegated to stack-dev subagents; quick-dev itself does not load sidecars)
  Program-close deletion policy for legacy engine/workflows/tasks
  Native Skill Format Compliance
  Subagent delegation parity
  40–55% activation-budget reduction vs legacy workflow engine
  Functional parity with the legacy workflow

  Quick Flow. Pairs with the quick-spec skill.
  Unblocks the end-to-end Quick Flow test gate.
-->

## Mission

You are implementing a quick spec end-to-end — the fastest path from idea to code in GAIA. Given `.gaia/artifacts/implementation-artifacts/quick-spec-{spec-name}.md`, load the spec, check for an in-progress WIP checkpoint, auto-detect the project's stack, delegate implementation to the matching native stack-dev subagent (`typescript-dev`, `angular-dev`, `flutter-dev`, `java-dev`, `python-dev`, `mobile-dev`, or `go-dev`) via `context: fork`, run the project's tests, validate against the spec's acceptance criteria, and archive the checkpoint.

This skill is the native Claude Code conversion of the legacy quick-dev workflow at `_gaia/lifecycle/workflows/quick-flow/quick-dev/`. The five-step order, the WIP checkpoint resume UX (Proceed / Start fresh / Review), the `files_touched` shape with sha256 checksums, and the legacy dev agent auto-detect behavior (rule-76 "Auto-detected developer: {agent_name} based on {detection_source}") are preserved verbatim.

## Critical Rules

- **Five steps, strict order, no skipping.** Load Spec -> Resolve WIP Checkpoint -> Delegate to gaia:stack-dev subagent -> Verify -> Complete. The legacy engine executed these sequentially; the native skill must too.
- **Deterministic operations live in `scripts/`.** Spec loading, sha256 validation on checkpoints, stack auto-detection, and checkpoint archival are handled by the four scripts under `scripts/`. Do NOT inline these operations in prose.
- **Dev agent delegation stays at exactly 1 level of subagent nesting (AC-EC6).** `gaia-quick-dev` spawns one stack-dev subagent via `context: fork`. The stack-dev subagent loads shared skills JIT in-context — it does NOT spawn further nested subagents. The legacy shim pattern is NOT needed here because the native `context: fork` primitive replaces it.
- **Auto-detect first, user-select fallback — same UX as the legacy engine (AC-EC2).** If `auto-detect-stack.sh` emits a stack on stdout (exit 0), use it. If ambiguous (exit 1), ask the user to pick one of the seven supported stacks. Never silently default.
- **Validate the selected stack against the plugin agents tree (AC-EC3).** Before spawning the subagent, confirm `plugins/gaia/agents/{stack}-dev.md` exists. If a user picks a stack that has no corresponding agent file (e.g., `rust-dev`), HALT with a clear message listing the seven available stacks — do NOT silently fall back to another stack.
- **Pass `project_path` explicitly to the subagent (AC-EC8).** The stack-dev subagent must write application code to the resolved `project-path`, not `project-root`. The CLAUDE.md directory-identity rule is enforced here: the skill passes `project_path` as a named parameter, and the subagent prompt asserts the discipline.
- **JIT-load shared skills by section — never pre-load (AC3).** The stack-dev subagent references shared skills via `{skill}#{section}` selectors (e.g., `gaia-testing-patterns#tdd-cycle`, `gaia-git-workflow#commits`, `gaia-code-review-standards#review-gate-completion`). Only the requested section is loaded at runtime.
- **Preserve the legacy WIP checkpoint shape (AC5, AC-EC5).** `.gaia/memory/checkpoints/quick-dev-{spec-name}.yaml` with `files_touched` entries containing `path`, `checksum: "sha256:{hex}"`, and `last_modified: ISO-8601`. The skill writes in this shape so `/gaia-resume` continues to work.
- **Fail fast with the exact legacy message when the spec is missing (AC-EC4).** `load-spec.sh` emits "Quick spec not found — run /gaia-quick-spec first." on stderr and exits 2. The skill surfaces this message and halts — never continues with partial context.
- **Do not load agent memory sidecars from this skill.** `gaia-quick-dev` is routing/orchestration; the stack-dev subagents carry their own ground-truth injection and decision-log loading per their agent frontmatter.

## Inputs

1. **Spec name** — optional via `$ARGUMENTS`. Expands to `.gaia/artifacts/implementation-artifacts/quick-spec-{spec_name}.md`. If missing, prompt for it before Step 1.

## Pipeline Overview

### Step 1 — Load Spec

Run the script to read the quick spec:

```bash
!${CLAUDE_PLUGIN_ROOT}/skills/gaia-quick-dev/scripts/load-spec.sh {spec_name}
```

- Exit 0: stdout carries the spec body — capture it for later steps.
- Exit 2: spec file missing — surface the message "Quick spec not found — run /gaia-quick-spec first." exactly as emitted, then HALT. This matches the legacy `on_error.missing_file: ask_user` contract (AC-EC4).

### Step 2 — Resolve WIP Checkpoint

Run the checkpoint validator:

```bash
!${CLAUDE_PLUGIN_ROOT}/skills/gaia-quick-dev/scripts/wip-checkpoint-resolve.sh {spec_name}
```

Interpret the exit code + stdout table:

- **NONE** (exit 0, stdout contains "NONE"): no active checkpoint — proceed to Step 3 as a fresh run.
- **All MATCH** (exit 0, every row shows MATCH): active checkpoint is consistent with the filesystem. Offer the user Proceed (resume from last step) or Start fresh (delete the checkpoint and begin again).
- **MODIFIED or DELETED entries** (exit 1): one or more files have drifted since the checkpoint was written. Do NOT silently resume (AC-EC5). Offer the three-option prompt:
  - **Proceed** — continue even though files diverged (developer accepts the risk)
  - **Start fresh** — delete the checkpoint and implement from scratch
  - **Review** — surface the drift table and the spec body so the developer can decide

The 3-option UX wording matches the legacy engine rule-10 text. Concurrent invocations (AC-EC7) hit this same branch because the second invocation sees the first invocation's WIP checkpoint and follows the Proceed / Start fresh / Review path.

### Step 3 — Delegate to gaia:stack-dev Subagent (Implement)

Run the auto-detector to resolve the stack:

```bash
!${CLAUDE_PLUGIN_ROOT}/skills/gaia-quick-dev/scripts/auto-detect-stack.sh {spec_name}
```

- **Exit 0**: stdout carries one of `typescript | angular | flutter | java | python | mobile | go`. Log "Auto-detected developer: {stack}-dev based on filesystem signals." (this message matches the legacy engine rule-76 wording). Skip the user prompt.
- **Exit 1**: ambiguous — no conclusive signals, or multiple competing signals with no spec-body hint to disambiguate. Ask the user: "Which stack developer should implement this spec? [typescript / angular / flutter / java / python / mobile / go]". Validate the answer against the seven supported stacks.

Validate the selected stack against the plugin agents tree:

- Verify `plugins/gaia/agents/{stack}-dev.md` exists before spawning.
- If the file is missing (e.g., user picked a non-existent stack like `rust-dev`): HALT with "No native subagent for '{stack}'. Available: typescript, angular, flutter, java, python, mobile, go." (AC-EC3)

Spawn the matching subagent with `context: fork` — this is the isolation pattern. The subagent prompt must carry:

1. **The spec body** captured in Step 1 (so the subagent has full context without re-reading the file).
2. **The resolved `project_path`** as an explicit working-directory parameter (AC-EC8). The subagent MUST write application code to this path, not to the `project-root`. The prompt asserts the discipline: "Write application code to {project_path}, not {project-root}. This is the CLAUDE.md directory-identity rule."
3. **The checkpoint path** `.gaia/memory/checkpoints/quick-dev-{spec_name}.yaml` so the subagent writes checkpoints with `files_touched` (path + sha256 via `shasum -a 256` + ISO-8601 `last_modified`) after each significant step.
4. **JIT shared-skill references** by `{skill}#{section}` selector — never inline content. Typical references for a quick-dev implementation:
   - `gaia-testing-patterns#tdd-cycle` — apply TDD where practical (same as the legacy Step 3 "Apply TDD where practical" directive)
   - `gaia-git-workflow#commits` — conventional commit discipline for any commits the subagent creates
   - `gaia-code-review-standards#review-gate-completion` — referenced if the spec calls for review-gate alignment
   The native plugin loader returns only the requested section (sectioned-loading contract preserved). The parent `gaia-quick-dev` skill MUST NOT pre-load any shared skill content.

**Nesting discipline (AC-EC6):** The quick-dev skill spawns exactly 1 level of subagent. The stack-dev subagent loads shared skills JIT in-context — it does NOT spawn further nested subagents. This respects the 2-level nesting warning and avoids the legacy shim pattern because the native `context: fork` primitive already provides clean isolation.

### Step 4 — Verify

Inside the forked subagent context:

- Run the project's test command via `Bash` (resolved from the stack conventions — e.g., `npm test`, `pytest`, `go test ./...`, `flutter test`, `mvn test`).
- Validate the implementation against the spec's "Acceptance criteria" section (the five-section shape produced by `gaia-quick-spec`).
- Emit a PASS or FAIL verdict on stdout; the verdict surfaces back to the parent skill.
- On FAIL: capture the failing test excerpt and the AC that is not satisfied; report back to the parent skill so the developer can decide to iterate or abort.

### Step 5 — Complete

On PASS, archive the checkpoint:

```bash
!${CLAUDE_PLUGIN_ROOT}/skills/gaia-quick-dev/scripts/checkpoint-archive.sh {spec_name}
```

- Moves `.gaia/memory/checkpoints/quick-dev-{spec_name}.yaml` to `.gaia/memory/checkpoints/completed/quick-dev-{spec_name}.yaml`.
- Exits non-zero on a missing checkpoint or permission error.

Report implementation complete to the user with the final `files_touched` summary (path + sha256 checksum per entry). Suggest the next step:

> Quick spec `{spec_name}` implemented. Files touched: {count}. All tests passing. Checkpoint archived to completed/.

## Edge Cases

- **AC-EC1 — Malformed frontmatter** detected by `.github/scripts/lint-skill-frontmatter.sh`. The CI gate rejects the PR; the story cannot merge until the frontmatter is fixed.
- **AC-EC2 — Ambiguous auto-detect**: `auto-detect-stack.sh` exits 1. The skill falls back to the user prompt matching the legacy engine rule-76 UX. No silent default, no halt.
- **AC-EC3 — Non-existent stack**: user picks a stack with no corresponding `plugins/gaia/agents/{stack}-dev.md` file. HALT with a clear message listing the seven available stacks. Do NOT attempt to spawn a non-existent subagent.
- **AC-EC4 — Missing spec file**: `load-spec.sh` exits 2. Surface the legacy error message verbatim and HALT.
- **AC-EC5 — sha256 mismatch on resume**: `wip-checkpoint-resolve.sh` exits 1 with MODIFIED or DELETED rows. Offer Proceed / Start fresh / Review — never silently resume.
- **AC-EC6 — Nesting discipline**: the quick-dev skill spawns 1 level of subagent (the stack-dev). Shared skills load JIT in-context, NOT as nested subagent spawns. The 2-level nesting warning is respected.
- **AC-EC7 — Concurrent invocations**: the second `/gaia-quick-dev {spec-name}` invocation sees the first's WIP checkpoint via `wip-checkpoint-resolve.sh`. Step 2's Proceed / Start fresh / Review branch handles the collision. No silent clobber.
- **AC-EC8 — project-path vs project-root leakage**: the skill passes the resolved `project_path` explicitly to the subagent. The subagent prompt asserts the CLAUDE.md directory-identity rule. The parity harness diff catches any leakage.

## References

- **Legacy source:** `_gaia/lifecycle/workflows/quick-flow/quick-dev/workflow.yaml` + `instructions.xml` — parity reference.
- **Canonical SKILL.md shape:** `plugins/gaia/skills/gaia-dev-story/SKILL.md` — the dev-delegation template mirrored here.
- **Sibling skill:** `plugins/gaia/skills/gaia-quick-spec/SKILL.md` — upstream spec producer. Ships in parallel.
- **Downstream gate:** end-to-end quick-spec -> quick-dev test.
- **Upstream deps:**
  - plugin directory structure
  - bats-core test harness + frontmatter linter
  - stack-dev subagent schema
  - stack-dev subagent conversions
  - shared dev skills
  - parity harness (`v-parity-baseline`)
