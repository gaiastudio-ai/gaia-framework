---
name: gaia-bridge-enable
description: Enable the Test Execution Bridge by delegating to gaia-bridge-toggle with mode=enable. Thin wrapper that preserves the user-visible /gaia-bridge-enable slash command. Edits test_execution_bridge.bridge_enabled = true in .gaia/config/project-config.yaml. Flag takes effect immediately under the native plugin. Idempotent — no write when already enabled.
allowed-tools: [Read, Edit, Bash]
orchestration_class: light-procedural
---

## Mission

You are the `/gaia-bridge-enable` wrapper. This skill preserves the existing user-visible slash command while delegating the full toggle semantics to `gaia-bridge-toggle`.

This skill is part of the native Claude Code conversion. The legacy `bridge-toggle` workflow is converted to `gaia-bridge-toggle/SKILL.md`; this wrapper keeps the enable-specific alias working.

## Critical Rules

- **Delegate to `gaia-bridge-toggle` with mode=enable.** Do NOT duplicate the toggle logic here.
- **Hard-code mode=enable.** This wrapper is enable-only. Ignore any `$ARGUMENTS` that attempt to override the mode.
- **Preserve the user-visible slash command.** `/gaia-bridge-enable` must continue to resolve for OSS users with zero behavioral change.

## Delegation

Follow the full `gaia-bridge-toggle` skill body with `mode = enable`:

1. Resolve the current `test_execution_bridge.bridge_enabled` value via `scripts/resolve-config.sh` (the flag lives at `test_execution_bridge.bridge_enabled` in `config/project-config.yaml`; the legacy v1 location `_gaia/_config/global.yaml` is retired and no longer used).
2. If the section is missing, scaffold a minimal stub instead of halting. Run the deterministic helper `bash ${CLAUDE_PLUGIN_ROOT}/skills/gaia-bridge-enable/scripts/bridge-stub-scaffold.sh` — it idempotently appends the canonical minimal block (resolves the canonical `.gaia/config/project-config.yaml` path with legacy `config/project-config.yaml` fallback). The helper exits 0 on append OR when the section is already present (idempotent). Do NOT inline the YAML block in the LLM prose — that pattern was fragile under Mode A subagent dispatch. Then continue with the toggle below. The operator can run `/gaia-ci-setup` later to populate the full block.
   > **Why scaffold-then-flip is two steps.** On a greenfield
   > config the stub is written with `bridge_enabled: false` (step 2) and then
   > flipped to `true` (step 4). This is intentional, not an oversight: the
   > scaffold helper is shared with `/gaia-bridge-disable` and `gaia-bridge-toggle`
   > (it only guarantees the section EXISTS in canonical shape), while the
   > enable/disable VALUE is owned by the toggle step. Collapsing them into a
   > single write would duplicate the canonical-block definition across the
   > scaffold helper and the toggle, reintroducing the inline-YAML fragility
   > that was fixed earlier. Both steps are deterministic and idempotent, so the
   > two-write sequence is safe and re-runnable.
3. If already `true`, report `Bridge already enabled` and exit without writing.
4. Otherwise, perform the regex-based in-place edit to `.gaia/config/project-config.yaml` to flip `bridge_enabled: false` → `bridge_enabled: true`, preserving all comments and formatting.
5. Run the Post-Flip Checks (enable-only — stat the manifest at the canonical location `.gaia/config/test-environment.yaml`. The previous reference to `.gaia/artifacts/test-artifacts/test-environment.yaml` was the legacy location — the producer (`test-environment-manifest.sh`) writes to `.gaia/config/`, so stating the legacy path produced a false "manifest absent" verdict even when a valid manifest existed at the canonical location. For projects whose manifest still lives at the legacy `.gaia/artifacts/test-artifacts/test-environment.yaml`, the `migrate-test-environment-path.sh` helper invoked in Step 4 of `/gaia-bridge-toggle` has already moved it; if it hasn't been invoked, also accept the legacy path as a fallback. For absent in YOLO, auto-skip with a warning).
5a. **Manifest-readiness guidance (template / `*.example` case).** The Post-Flip manifest check fails Layer 0 when the manifest is absent, OR when it still carries the `# GAIA-MANIFEST-TEMPLATE:` sentinel line (an un-edited template — including a freshly-copied `test-environment.yaml.example`). The sentinel is intentional: the framework will NOT auto-promote a template manifest, because its `runners[]` are placeholders that would produce nonsensical tier commands. When you hit either condition, walk the operator through the copy-and-edit flow rather than leaving a bare "manifest absent / not ready" error:
   - If NO manifest exists at `.gaia/config/test-environment.yaml`, copy the shipped template into place: `cp ${CLAUDE_PLUGIN_ROOT}/templates/test-environment.yaml.example .gaia/config/test-environment.yaml` (or regenerate a stack-matched manifest via `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/test-environment-manifest.sh` when a stack is detected — that path emits NO sentinel and is ready immediately).
   - Then edit `.gaia/config/test-environment.yaml`: set the real `runners[]` (per-tier `command`) for the project's stack, and **remove the `# GAIA-MANIFEST-TEMPLATE:` line** — Layer 0 stays RED until that sentinel line is gone.
   - Re-run `/gaia-bridge-enable` (idempotent — it will not re-flip an already-enabled flag) so Step 5b can populate `test_execution` from the now-real manifest.
   Surface this as actionable guidance, not a hard halt: the flag flip in Step 4 already succeeded, and the manifest is the remaining operator-owned input.

5b. **Auto-populate `test_execution` tiers.** Invoke `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/bridge-populate-test-execution.sh` after the flag flip. The helper reads `runners[]` from `.gaia/config/test-environment.yaml` and writes the corresponding `test_execution.tier_N.{placement,command,required,timeout_seconds}` entries to `.gaia/config/project-config.yaml`. Idempotent — leaves explicitly-set tiers alone. This closes the silent-skip bug: prior to this step the bridge flag flipped but `test_execution: {}` stayed empty, so `qa-test-runner.sh` skipped with a false-PASS verdict in every code review. Post-step, the runner can resolve a real tier command for every story. The helper exits 1 if the manifest is absent (advise the operator to run the manifest generator); the wrapper continues but logs the gap so the operator can wire `test_execution` manually via `/gaia-config-test`.
6. Emit the summary. Under the native plugin the flag change takes effect immediately — no config rebuild is required. **Confirm `test_execution` is populated** — invoke `/gaia-doctor` or directly inspect `.gaia/config/project-config.yaml`'s `test_execution:` block. If any tier the operator expects to run is missing a `command`, wire it via `/gaia-config-test set tier_N.command '...'`.

The full step-by-step procedure is documented in `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md`. This wrapper inherits all behavior from that skill.

## References

- Delegate: `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md` (full five-step procedure).
- Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- Two-file config split (`.gaia/config/project-config.yaml` shared + `config/global.yaml` machine-local).
- Native Skill Format Compliance (slash-command continuity).
- Wrapper pattern for one-to-many slash-command mappings.
