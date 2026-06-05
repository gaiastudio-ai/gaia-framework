---
name: gaia-bridge-toggle
description: Toggle the Test Execution Bridge on or off by flipping test_execution_bridge.bridge_enabled in config/project-config.yaml, preserving comments and YAML formatting. Idempotent — no write when already in target state. Under the native plugin, the flip takes effect immediately — no config rebuild step is required. Use via /gaia-bridge-enable or /gaia-bridge-disable. Native Claude Code conversion of the legacy bridge-toggle workflow.
argument-hint: "enable|disable"
allowed-tools: [Read, Edit, Bash]
orchestration_class: light-procedural
---

## Mission

You are toggling the Test Execution Bridge. The bridge flag lives at `test_execution_bridge.bridge_enabled` in `config/project-config.yaml` (a two-file config split — shared project config is versioned alongside the project, machine-local overlay lives in `config/global.yaml`). Reads resolve via `scripts/resolve-config.sh`; writes are direct regex-based in-place edits against `config/project-config.yaml`. The legacy v1 location `_gaia/_config/global.yaml` is retired and no longer used. When enabled, dev-story and review workflows run real test runners via the bridge (Layer 1 → Layer 2 → Layer 3) and emit evidence under `.gaia/artifacts/test-artifacts/test-results/`. When disabled, workflows fall back to narrative test reporting.

Two slash commands front this skill via wrapper aliases:
- `/gaia-bridge-enable` → delegates here with mode=`enable`
- `/gaia-bridge-disable` → delegates here with mode=`disable`

This skill is the native Claude Code conversion of the legacy bridge-toggle workflow at `_gaia/core/workflows/bridge-toggle/instructions.xml`. The legacy 69-line XML body is preserved here as explicit prose. No workflow engine, no engine-specific XML step tags.

## Critical Rules

- **Modify `.gaia/config/project-config.yaml` in place, preserving ALL comments, key ordering, and formatting.** Never regenerate the full file. A successful toggle emits a single-line change.
- **Use regex-based in-place edit targeting ONLY the `bridge_enabled:` line — never regenerate the full file.** Two cases:
  - **Key present** — pattern `/^(\s+bridge_enabled:\s*)(true|false)/m`. Replace capture group 2 with the target value. This is the steady-state path.
  - **Key absent (section present, key missing)** — the section header exists at `^test_execution_bridge:\s*$` but no `bridge_enabled:` line follows. INSERT a new line `  bridge_enabled: <target>` immediately after the `test_execution_bridge:` header. Preserve the existing `# reconciled by ...` trailing comment block. This is the AC-EC3 path documented in Step 1 ("treat as `false` when key missing") — the regex-only flip-path has no expression for it.
- **Idempotent: if the flag is already in the target state, do NOT write the file.** A byte-level diff must show zero changes. Report `Bridge already {enabled|disabled}` and exit with status ok.
- **Fail fast when the test_execution_bridge block is missing (AC-EC2).** Emit `test_execution_bridge block missing — run /gaia-ci-setup first` and exit non-zero. Do NOT create a new block silently.
- **The flag flip takes effect immediately.** Under the native plugin there is no pre-compiled config cache to refresh — the `.resolved/` chain was retired. Downstream workflows read `config/project-config.yaml` directly via `scripts/resolve-config.sh` on their next invocation.

## Inputs

1. **Mode** — `enable` or `disable`, via `$ARGUMENTS`. When invoked via the wrapper aliases, the mode is hard-coded in the wrapper SKILL.md.

## Pipeline Overview

The skill runs five steps in strict order, mirroring the legacy `bridge-toggle/instructions.xml`:

1. **Read Current Bridge State** — extract bridge_enabled from global.yaml
2. **Idempotency Check** — no write if current == target
3. **Write Updated State** — regex-based in-place edit
4. **Post-Flip Checks (Enable Only)** — detect test-environment.yaml and validate
5. **Post-Toggle Summary** — confirm new state (no rebuild step — native plugin reads global.yaml directly)

## Step 1 — Read Current Bridge State

- Resolve the current config via `scripts/resolve-config.sh` and inspect the `test_execution_bridge` block. The authoritative file on disk is `config/project-config.yaml`. The legacy v1 location `_gaia/_config/global.yaml` is retired and no longer used — do NOT probe it.
- Extract the `test_execution_bridge.bridge_enabled` value.
- **AC-EC2 / AC3:** If the `test_execution_bridge` section is missing entirely, or the section exists but the `bridge_enabled` key is missing, treat `bridge_enabled` as `false`. In the missing-section case, fail fast with `test_execution_bridge block missing — run /gaia-ci-setup first` and exit non-zero — do NOT create a new block silently.
- Capture the raw file bytes of `.gaia/config/project-config.yaml` for idempotency verification.
- Report: `Current bridge state: {enabled|disabled}`.

## Step 2 — Idempotency Check

- Compare the current state against the target mode (`enable` → `true`, `disable` → `false`).
- If `current_state == target_state`: report `Bridge already {enabled|disabled}` and exit with status ok. Do NOT write global.yaml. A byte-level diff must show zero changes.

## Step 3 — Write Updated State

- Use a regex-based in-place edit (`Edit` tool) against `.gaia/config/project-config.yaml` to update ONLY the `bridge_enabled:` line within the `test_execution_bridge:` section.
- **Key-present path** — pattern `/^(\s+bridge_enabled:\s*)(true|false)/m` — replace capture group 2 with the target value. Preserves inline comments on the same line and all surrounding YAML content.
- **Key-absent path (AC-EC3)** — when `bridge_enabled` is not present under `test_execution_bridge:` (e.g. the section was hydrated by `gaia-reconcile-v2` with only a `# reconciled by ...` comment), INSERT the new line `  bridge_enabled: <target>` immediately after the `^test_execution_bridge:\s*$` header. Insertion regex: replace `^test_execution_bridge:\s*$` with `test_execution_bridge:\n  bridge_enabled: <target>`. The existing trailing comment lines under the section are preserved unchanged.
- If the `test_execution_bridge` section is missing entirely: emit the error from Step 1 (`test_execution_bridge section not found in .gaia/config/project-config.yaml — cannot toggle. Add the section first.`) and exit non-zero — do NOT create the section silently (AC-EC2).
- Write the updated content back to `.gaia/config/project-config.yaml`.

## Step 4 — Post-Flip Checks (Enable Only)

- **disable mode:** skip this step entirely (AC7). Set `post_flip_result = {kind: "skipped", reason: "disable-mode"}` and proceed to Step 5.
- **enable mode, no state change (idempotent path):** skip (Step 2 already exited). Set `post_flip_result = {kind: "skipped", reason: "idempotent"}` and proceed to Step 5.
- **Backward-compat migration:** BEFORE the stat-canonical-path decision, invoke `${CLAUDE_PLUGIN_ROOT}/scripts/migrate-test-environment-path.sh --target <project-root>` to detect-and-move any legacy file at `.gaia/artifacts/test-artifacts/test-environment.yaml` to the canonical `.gaia/config/test-environment.yaml`. The helper is idempotent (no-op if no legacy file or if already migrated) and emits the deprecation warning + INFO log line at most once per project (sentinel-suppressed). Helper exit non-zero is non-fatal — surface the stderr and proceed.
- **enable mode, state changed:** stat `.gaia/config/test-environment.yaml` (resolved relative to `{project-root}`):
  - **present + valid:** collect detected runners (name + tier) for inclusion in Step 5's summary. Proceed.
  - **present + invalid:** collect schema errors as warnings. Per AC5, do NOT roll back the flag flip — the user can repair the manifest and re-run `/gaia-bridge-enable` if desired. Proceed.
  - **absent (non-YOLO):** render the 3-option prompt — option `[a]` is the PRIMARY path (auto-generate stack-specific manifest inline), option `[b]` is the schema-doc-starter fallback for advanced users. Ask the user to select:
    - `[a]` Auto-generate a stack-specific `.gaia/config/test-environment.yaml` for your project (recommended). The orchestrator invokes `${CLAUDE_PLUGIN_ROOT}/scripts/lib/test-environment-manifest.sh --target <project-root> --write` to detect the project stack and emit a populated manifest. On exit non-zero (defensive fallback), Step 4 falls back to option [b]'s template-copy behavior via `install-test-environment-manifest.sh` and emits a clear warning instead of crashing. On generator success, set `GAIA_BRIDGE_JUST_GENERATED=1` (or `post_flip_result.just_generated = true`) so Step 5 knows to emit the post-install edit prompt.
    - `[b]` Copy the schema example template (advanced users / schema documentation starter). The orchestrator invokes `${CLAUDE_PLUGIN_ROOT}/scripts/install-test-environment-manifest.sh --target <project-root>` which copies `.gaia/.gaia/config/test-environment.yaml.example` → `.gaia/config/test-environment.yaml` with copy-if-absent semantics. On exit 1 (the `.example` source is missing — e.g., the install hasn't run on this project yet), surface the helper's stderr; the user can run `/gaia-init` to materialize the `.example` first.
    - `[c]` Skip — bridge is enabled but will fail-fast at Layer 1 with a clear error message until the manifest is created
  - **absent (YOLO):** auto-invoke `${CLAUDE_PLUGIN_ROOT}/scripts/lib/test-environment-manifest.sh --target <project-root> --write` (inline generator — replaces the prior template-copy behavior). On success, log `auto-generated .gaia/config/test-environment.yaml for detected stack: <stack>` where `<stack>` is read from the `# detected-stack:` comment in the generator output. On generator non-zero exit (defensive fallback), invoke `${CLAUDE_PLUGIN_ROOT}/scripts/install-test-environment-manifest.sh --target <project-root>` to fall back to the schema-doc template-copy and log a warning. On both helpers failing, preserve the prior auto-skip behavior: log `Bridge is enabled but .gaia/config/test-environment.yaml is missing — Layer 1 will fail-fast until the manifest is created.` and proceed without halting. This keeps the "no interrupting" YOLO contract intact in all cases.
- Pass `post_flip_result` to Step 5.

(Removed AC-EC9 "serialization against concurrent /gaia-build-configs" — under the native plugin there is no concurrent build-configs process to race against; the pre-compilation step was retired.)

## Step 5 — Post-Toggle Summary

- Display a summary containing: previous state, new state, mode, whether a write occurred.
- If `mode == enable` and `post_flip_result.kind == 'present_valid'`: include the canonical path `.gaia/config/test-environment.yaml` and the detected runners table (name + tier).
  - **If the manifest was just-generated in this invocation** (the helper produced fresh output in Step 4 — signaled by `GAIA_BRIDGE_JUST_GENERATED=1` or `post_flip_result.just_generated == true`), append the one-line edit prompt: `edit .gaia/config/test-environment.yaml to fine-tune for your project`.
  - **If the manifest was already present** (not just-generated), emit canonical path + runners table but OMIT the edit prompt — the user is presumed to have already engaged with their manifest.
- If `mode == enable` and `post_flip_result.kind == 'present_invalid'`: include the schema validation errors as warnings AND surface the canonical path `.gaia/config/test-environment.yaml` on a separate line so the user knows where to look. The `bridge_enabled` flag is NOT rolled back (AC5).
- If `mode == enable` and `post_flip_result.kind == 'absent'`: include the user's selected option (a/b/c) or the YOLO auto-generate result. When YOLO just-generated successfully, replace the edit prompt with the gentler nudge: `auto-generated for detected stack — review .gaia/config/test-environment.yaml if needed.`.
- **AC6 — the summary confirms the flag change is effective immediately.** Under the native plugin there is no pre-compiled config cache to refresh — downstream workflows read `.gaia/config/project-config.yaml` directly via `scripts/resolve-config.sh` on their next invocation.
- If `mode == disable`: the summary only confirms the new state. No post-flip check output (AC7 — Step 4 was skipped).

## Edge Cases

- **AC-EC2 — test_execution_bridge block missing:** fail fast with `test_execution_bridge block missing — run /gaia-ci-setup first`. Do NOT create the block silently.
- **AC-EC9 (retired):** the legacy concurrent-/gaia-build-configs race no longer applies — native-plugin resolution is per-invocation, not pre-compiled.
- **Idempotent path:** zero bytes written; zero side effects.
- **YAML parse errors on read:** surface the parser error; do NOT attempt a regex edit on malformed YAML.

## References

- Legacy source: `_gaia/core/workflows/bridge-toggle/instructions.xml` (69 lines) — parity reference.
- Authoritative file edited: `config/project-config.yaml` at `test_execution_bridge.bridge_enabled`. The legacy v1 location `_gaia/_config/global.yaml` is retired and no longer used.
- No post-edit trigger required under the native plugin — the `.resolved/` pre-compilation step was retired, and downstream readers pick up changes on next invocation.
- Wrapper aliases: `plugins/gaia/skills/gaia-bridge-enable/SKILL.md`, `plugins/gaia/skills/gaia-bridge-disable/SKILL.md`.
- Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- Scripts-over-LLM for Deterministic Operations (inline `!` bash for the regex edit and the build-configs re-run).
- Test Execution Bridge architecture (origin of the `test_execution_bridge` YAML block).
- Program-close deletion policy for legacy engine/workflows/tasks.
- Native Skill Format Compliance.
- Functional parity with the legacy workflow.
- Reference implementation: `plugins/gaia/skills/gaia-fix-story/SKILL.md`.
