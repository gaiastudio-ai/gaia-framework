# gaia-dev-story

Implement a user story end-to-end: load story, plan, TDD (red/green/refactor), commit, push, PR, CI, merge.

## Hooks-in-Skill-Frontmatter Pattern

This skill is the canonical reference implementation of the PostToolUse hook pattern in GAIA skill frontmatter. The pattern works as follows:

### Why `context: fork`

Dev-story uses `context: fork` to run in an isolated subagent context. This scopes the PostToolUse hook's `Edit|Write` matcher to only this skill's execution — preventing the hook from firing on Edit/Write calls in other skills or the main conversation.

Without `context: fork`, the PostToolUse hook would fire globally for every Edit/Write in the session, creating unwanted checkpoint files from unrelated operations.

### How the PostToolUse Hook Works

```yaml
hooks:
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: ${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/checkpoint.sh write gaia-dev-story
```

1. Claude Code detects that a tool call matching `Edit|Write` just completed within this skill's fork context.
2. It invokes `scripts/checkpoint.sh write gaia-dev-story` as a post-tool-use hook.
3. The skill-local `checkpoint.sh` wrapper translates this into the shared foundation `checkpoint.sh`'s `--workflow gaia-dev-story --step 0` contract, where `--step 0` is a sentinel value for hook-triggered checkpoints.
4. The shared `checkpoint.sh` writes a YAML checkpoint file to `_memory/checkpoints/gaia-dev-story.yaml` with an atomic temp-file + rename operation.

### Adapting This Pattern

To add PostToolUse hooks to another skill:

1. Copy the `hooks:` block from `_reference-frontmatter.md` into your SKILL.md frontmatter.
2. Change the workflow name in the command to match your skill.
3. Add `context: fork` to isolate hook scope.
4. Ensure your `scripts/checkpoint.sh` wrapper delegates to the shared foundation script.

## Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Config resolution, gate validation, checkpoint load |
| `finalize.sh` | Terminal checkpoint write, lifecycle event |
| `load-story.sh` | Story file lookup via sprint-state.sh |
| `story-parse.sh` | Parse story frontmatter into 10-variable env-var contract (Step 1) |
| `detect-mode.sh` | Resolve FRESH / REWORK / RESUME execution mode (Step 1) |
| `check-deps.sh` | Verify `depends_on` stories are status `done` (Step 1) |
| `atdd-gate.sh` | Enforce ATDD scenarios for high-risk stories (Step 2b) |
| `git-branch.sh` | Feature branch creation with collision detection (Step 3) |
| `validate-plan-structure.sh` | Plan-structure validator: 8 canonical sections, +Root Cause for REWORK (Step 4) |
| `checkpoint.sh` | PostToolUse hook target (wraps shared checkpoint.sh) |
| `tdd-review-gate.sh` | Risk-gated TDD review hook (SKIP / PROMPT / QA_AUTO) for Steps 5a / 6a / 7a |
| `conditional-check-hints.sh` | Advisory hints for API / schema / large-blast-radius diffs (Step 6b) |
| `dod-check.sh` | Definition-of-Done helper: build / tests / lint / secrets / subtask checks (Step 9) |
| `commit-msg.sh` | Compose Conventional Commit subject in canonical format (Step 10) |
| `promotion-chain-guard.sh` | Resolve first promotion-chain branch or signal absence (Step 10) |
| `pr-body.sh` | Render canonical 4-section PR body: ACs / DoD / Diff Stat / Story-link (Step 11) |
| `pr-create.sh` | PR creation via gh CLI (Step 11) |
| `ci-wait.sh` | CI status polling with timeout (Step 12) |
| `merge.sh` | PR merge with conflict/protection handling (Step 13) |
| `verify-pr-merged.sh` | Post-completion gate: verify merge commit on target branch (Step 14) |
| `init-review-gate.sh` | Seed canonical 6-row UNVERIFIED Review Gate table (Step 15) |
| `sprint-state.sh` | Story state machine transitions |
| `frontmatter-lib.sh` | Shared frontmatter-parsing library |
