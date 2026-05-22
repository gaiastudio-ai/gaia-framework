---
name: gaia-bridge-enable
description: Enable the Test Execution Bridge by delegating to gaia-bridge-toggle with mode=enable. Thin wrapper that preserves the user-visible /gaia-bridge-enable slash command (AC11, FR-323). Edits test_execution_bridge.bridge_enabled = true in config/project-config.yaml (per ADR-044). Flag takes effect immediately under the native plugin. Idempotent — no write when already enabled.
allowed-tools: [Read, Edit, Bash]
orchestration_class: light-procedural
---

## Mission

You are the `/gaia-bridge-enable` wrapper. This skill preserves the existing user-visible slash command while delegating the full toggle semantics to `gaia-bridge-toggle`.

This skill is part of the native Claude Code conversion under E28-S111 (Cluster 14). The legacy `bridge-toggle` workflow is converted to `gaia-bridge-toggle/SKILL.md`; this wrapper keeps the enable-specific alias working per ADR-041 and AC11 of E28-S111.

## Critical Rules

- **Delegate to `gaia-bridge-toggle` with mode=enable.** Do NOT duplicate the toggle logic here.
- **Hard-code mode=enable.** This wrapper is enable-only. Ignore any `$ARGUMENTS` that attempt to override the mode.
- **Preserve the user-visible slash command.** `/gaia-bridge-enable` must continue to resolve for OSS users with zero behavioral change (AC11).

## Delegation

Follow the full `gaia-bridge-toggle` skill body with `mode = enable`:

1. Resolve the current `test_execution_bridge.bridge_enabled` value via `scripts/resolve-config.sh` (per ADR-044 — the flag lives at `test_execution_bridge.bridge_enabled` in `config/project-config.yaml`; the legacy v1 location `_gaia/_config/global.yaml` is retired and no longer used).
2. If the section is missing, fail fast with `test_execution_bridge block missing — run /gaia-ci-setup first`.
3. If already `true`, report `Bridge already enabled` and exit without writing.
4. Otherwise, perform the regex-based in-place edit to `config/project-config.yaml` to flip `bridge_enabled: false` → `bridge_enabled: true`, preserving all comments and formatting.
5. Run the Post-Flip Checks (enable-only — stat `.gaia/artifacts/test-artifacts/test-environment.yaml`; for absent in YOLO, auto-skip with a warning).
6. Emit the summary. Under the native plugin (ADR-044/ADR-048) the flag change takes effect immediately — no config rebuild is required.

The full step-by-step procedure is documented in `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md`. This wrapper inherits all behavior from that skill.

## References

- Delegate: `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md` (full five-step procedure).
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-044 — Two-file config split (`config/project-config.yaml` shared + `config/global.yaml` machine-local).
- FR-323 — Native Skill Format Compliance (slash-command continuity).
- E28-S111 AC11 — wrapper pattern for one-to-many slash-command mappings.
