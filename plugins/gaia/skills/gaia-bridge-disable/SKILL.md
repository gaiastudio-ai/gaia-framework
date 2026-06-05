---
name: gaia-bridge-disable
description: Disable the Test Execution Bridge by delegating to gaia-bridge-toggle with mode=disable. Thin wrapper that preserves the user-visible /gaia-bridge-disable slash command. Edits test_execution_bridge.bridge_enabled = false in .gaia/config/project-config.yaml. Flag takes effect immediately under the native plugin. Idempotent — no write when already disabled. Skips post-flip checks.
allowed-tools: [Read, Edit, Bash]
orchestration_class: light-procedural
---

## Mission

You are the `/gaia-bridge-disable` wrapper. This skill preserves the existing user-visible slash command while delegating the full toggle semantics to `gaia-bridge-toggle`.

This skill is part of the native Claude Code conversion. The legacy `bridge-toggle` workflow is converted to `gaia-bridge-toggle/SKILL.md`; this wrapper keeps the disable-specific alias working.

## Critical Rules

- **Delegate to `gaia-bridge-toggle` with mode=disable.** Do NOT duplicate the toggle logic here.
- **Hard-code mode=disable.** This wrapper is disable-only. Ignore any `$ARGUMENTS` that attempt to override the mode.
- **Preserve the user-visible slash command.** `/gaia-bridge-disable` must continue to resolve for OSS users with zero behavioral change.
- **Skip post-flip checks on disable.** The disable path does not run the test-environment.yaml stat — the summary only confirms the new state.

## Delegation

Follow the full `gaia-bridge-toggle` skill body with `mode = disable`:

1. Resolve the current `test_execution_bridge.bridge_enabled` value via `scripts/resolve-config.sh` (the flag lives at `test_execution_bridge.bridge_enabled` in `config/project-config.yaml`; the legacy v1 location `_gaia/_config/global.yaml` is retired and no longer used).
2. If the section is missing, fail fast with `test_execution_bridge block missing — run /gaia-ci-setup first`.
3. If already `false`, report `Bridge already disabled` and exit without writing.
4. Otherwise, perform the regex-based in-place edit to `.gaia/config/project-config.yaml` to flip `bridge_enabled: true` → `bridge_enabled: false`, preserving all comments and formatting.
5. Skip Post-Flip Checks (disable mode does not run them).
6. Emit the summary. Under the native plugin the flag change takes effect immediately — no config rebuild is required.

The full step-by-step procedure is documented in `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md`. This wrapper inherits all behavior from that skill, with Step 4 explicitly skipped.

## References

- Delegate: `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md` (full five-step procedure).
- Two-file config split (`.gaia/config/project-config.yaml` shared + `config/global.yaml` machine-local).
- Native Skill Format Compliance (slash-command continuity).
- Wrapper pattern for one-to-many slash-command mappings.
