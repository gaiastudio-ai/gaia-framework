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
2. If the section is missing, scaffold a minimal stub instead of halting (AF-2026-05-22-9 Bug-7, hardened by AF-2026-05-24-7 / Test02 F-2). Run the deterministic helper `bash ${CLAUDE_PLUGIN_ROOT}/skills/gaia-bridge-enable/scripts/bridge-stub-scaffold.sh` — it idempotently appends the canonical minimal block (resolves the canonical `.gaia/config/project-config.yaml` path with legacy `config/project-config.yaml` fallback). The helper exits 0 on append OR when the section is already present (idempotent). Do NOT inline the YAML block in the LLM prose — that pattern was fragile under Mode A subagent dispatch (Test02 F-2). Then continue with the toggle below. The operator can run `/gaia-ci-setup` later to populate the full block.
   > **Why scaffold-then-flip is two steps (F-009, Test04).** On a greenfield
   > config the stub is written with `bridge_enabled: false` (step 2) and then
   > flipped to `true` (step 4). This is intentional, not an oversight: the
   > scaffold helper is shared with `/gaia-bridge-disable` and `gaia-bridge-toggle`
   > (it only guarantees the section EXISTS in canonical shape), while the
   > enable/disable VALUE is owned by the toggle step. Collapsing them into a
   > single write would duplicate the canonical-block definition across the
   > scaffold helper and the toggle, reintroducing the inline-YAML fragility
   > Test02 F-2 fixed. Both steps are deterministic and idempotent, so the
   > two-write sequence is safe and re-runnable.
3. If already `true`, report `Bridge already enabled` and exit without writing.
4. Otherwise, perform the regex-based in-place edit to `config/project-config.yaml` to flip `bridge_enabled: false` → `bridge_enabled: true`, preserving all comments and formatting.
5. Run the Post-Flip Checks (enable-only — stat the manifest at the canonical post-ADR-110 location `.gaia/config/test-environment.yaml`. AF-2026-05-29-2 / Test09 F-27: the previous reference to `.gaia/artifacts/test-artifacts/test-environment.yaml` was the legacy location — the producer (`test-environment-manifest.sh`) writes to `.gaia/config/` per ADR-110, so stating the legacy path produced a false "manifest absent" verdict even when a valid manifest existed at the canonical location. For pre-ADR-110 projects whose manifest still lives at the legacy `.gaia/artifacts/test-artifacts/test-environment.yaml`, the `migrate-test-environment-path.sh` helper invoked in Step 4 of `/gaia-bridge-toggle` has already moved it; if it hasn't been invoked, also accept the legacy path as a fallback. For absent in YOLO, auto-skip with a warning).
6. Emit the summary. Under the native plugin (ADR-044/ADR-048) the flag change takes effect immediately — no config rebuild is required.

The full step-by-step procedure is documented in `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md`. This wrapper inherits all behavior from that skill.

## References

- Delegate: `plugins/gaia/skills/gaia-bridge-toggle/SKILL.md` (full five-step procedure).
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-044 — Two-file config split (`config/project-config.yaml` shared + `config/global.yaml` machine-local).
- FR-323 — Native Skill Format Compliance (slash-command continuity).
- E28-S111 AC11 — wrapper pattern for one-to-many slash-command mappings.
