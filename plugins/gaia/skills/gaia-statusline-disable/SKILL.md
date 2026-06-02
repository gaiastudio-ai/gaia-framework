---
name: gaia-statusline-disable
description: Disable the GAIA Claude Code statusline by removing the statusLine block from ~/.claude/settings.json. Thin wrapper that delegates to gaia-statusline-toggle.sh in --disable mode. Idempotent — no write when already disabled. Does NOT remove the runtime files under ~/.claude/gaia-statusline/ (only the settings.json toggle).
allowed-tools: [Bash]
orchestration_class: light-procedural
---

## Mission

You are the `/gaia-statusline-disable` wrapper. This skill flips the GAIA statusline off by removing the `statusLine` block from `~/.claude/settings.json`. The runtime files under `~/.claude/gaia-statusline/` are left in place — disable is a switch, not an uninstall. To fully uninstall, the user removes `~/.claude/gaia-statusline/` directly.

This wrapper preserves the user-visible `/gaia-statusline-disable` slash command while delegating the actual file edit to the shared toggle script `gaia-framework/plugins/gaia/scripts/gaia-statusline-toggle.sh`.

This skill is part of the E82 statusline epic. The shape mirrors the `/gaia-bridge-disable` precedent (thin wrapper + shared toggle) but the implementation language differs because settings.json is JSON, not YAML — see the toggle script for `jq` + atomic-rename idioms.

## Critical Rules

- **Delegate to `gaia-statusline-toggle.sh --disable`.** Do NOT duplicate the toggle logic here.
- **Hard-code mode = disable.** This wrapper is disable-only. Ignore any `$ARGUMENTS` that attempt to override the mode.
- **Preserve the user-visible slash command.** `/gaia-statusline-disable` must continue to resolve with zero behavioral change.
- **Disable does NOT touch the runtime files.** Only `settings.json` is modified. The runtime stays under `~/.claude/gaia-statusline/` so re-enabling is a one-shot.

## Delegation

Invoke the toggle script directly. The script handles:

1. Read `~/.claude/settings.json` (treating absence as already disabled, malformed JSON as a fatal error).
2. Idempotency: if no `statusLine` block is present (or the file is absent), emit `gaia-statusline-disable: no-op (already disabled)` and exit without writing.
3. Remove the `statusLine` key. All unrelated top-level keys (theme, model, hooks, etc.) are preserved by value.
4. Atomic write: sibling-tempfile under `~/.claude/` + `mv -f`. NEVER `/tmp/`.

```bash
!bash gaia-framework/plugins/gaia/scripts/gaia-statusline-toggle.sh --disable
```

## Round-trip caveat

The canonical write format is `jq -S` (sorted keys, 2-space indent). For `enable` followed by `disable` to produce a byte-identical result against the original `settings.json`, the original must already be in canonical jq format. If the original was hand-edited with comments, custom whitespace, or unsorted keys, the round-trip will normalize it on first write. This caveat mirrors the install-script behavior (E82-S1) and is by design — `jq` does not preserve comments or arbitrary whitespace.

## References

- Delegate: `gaia-framework/plugins/gaia/scripts/gaia-statusline-toggle.sh` (full enable + disable procedure).
- Sibling: `gaia-framework/plugins/gaia/skills/gaia-statusline-enable/SKILL.md` (`--enable` wrapper).
- Pattern: `gaia-framework/plugins/gaia/skills/gaia-bridge-disable/SKILL.md` (semantic precedent — thin wrapper around a shared toggle).
- Runtime installer: `gaia-framework/plugins/gaia/scripts/install-statusline.sh` (E82-S1).
- FR-439 — Statusline toggle slash commands.
- TC-STATUSLINE-13 — Idempotent enable/disable.
- TC-STATUSLINE-14 — Round-trip enable + disable preserves byte-identity.
