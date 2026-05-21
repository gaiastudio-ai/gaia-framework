---
name: gaia-statusline-enable
description: Enable the GAIA Claude Code statusline by adding the canonical statusLine block to ~/.claude/settings.json. Thin wrapper that delegates to gaia-statusline-toggle.sh in --enable mode. Idempotent — no write when already enabled. Pre-flight refuses if the runtime ~/.claude/gaia-statusline/statusline.sh is not installed and points at install-statusline.sh.
allowed-tools: [Bash]
orchestration_class: light-procedural
---

## Mission

You are the `/gaia-statusline-enable` wrapper. This skill flips the GAIA statusline on by adding the canonical `statusLine` block to `~/.claude/settings.json`. The runtime path it points at is `~/.claude/gaia-statusline/statusline.sh` with `refreshInterval = 10000` (10s — sprint-43 update from 1h) — both authored by E82-S1's `install-statusline.sh`.

This wrapper preserves the user-visible `/gaia-statusline-enable` slash command while delegating the actual file edit to the shared toggle script `gaia-public/plugins/gaia/scripts/gaia-statusline-toggle.sh`.

This skill is part of the E82 statusline epic. The shape mirrors the `/gaia-bridge-enable` precedent (thin wrapper + shared toggle) but the implementation language differs because settings.json is JSON, not YAML — see the toggle script for `jq` + atomic-rename idioms.

## Critical Rules

- **Delegate to `gaia-statusline-toggle.sh --enable`.** Do NOT duplicate the toggle logic here.
- **Hard-code mode = enable.** This wrapper is enable-only. Ignore any `$ARGUMENTS` that attempt to override the mode.
- **Preserve the user-visible slash command.** `/gaia-statusline-enable` must continue to resolve with zero behavioral change.
- **Pre-flight is enforced inside the toggle script** — when `~/.claude/gaia-statusline/statusline.sh` is missing, the script exits non-zero with a clear referral to `install-statusline.sh`. The wrapper does NOT recover from this; it surfaces the exit code as-is.

## Delegation

Invoke the toggle script directly. The script handles:

1. Pre-flight: confirm `~/.claude/gaia-statusline/statusline.sh` is present and executable. If missing, exit non-zero with a referral to `install-statusline.sh`.
2. Read `~/.claude/settings.json` (treating absence as `{}`, malformed JSON as a fatal error).
3. Idempotency: if the existing `statusLine` block already matches the canonical fragment `{command, refreshInterval}`, emit `gaia-statusline-enable: no-op (already enabled)` and exit without writing.
4. Atomic merge: shallow-merge the canonical `statusLine` block over the existing top-level keys, preserving all unrelated keys (theme, model, hooks, etc.) by value.
5. Atomic write: sibling-tempfile under `~/.claude/` + `mv -f`. NEVER `/tmp/`.

```bash
!bash gaia-public/plugins/gaia/scripts/gaia-statusline-toggle.sh --enable
```

## Round-trip caveat

The canonical write format is `jq -S` (sorted keys, 2-space indent). For `enable` followed by `disable` to produce a byte-identical result against the original `settings.json`, the original must already be in canonical jq format. If the original was hand-edited with comments, custom whitespace, or unsorted keys, the round-trip will normalize it on first write. This caveat mirrors the install-script behavior (E82-S1) and is by design — `jq` does not preserve comments or arbitrary whitespace.

## References

- Delegate: `gaia-public/plugins/gaia/scripts/gaia-statusline-toggle.sh` (full enable + disable procedure).
- Sibling: `gaia-public/plugins/gaia/skills/gaia-statusline-disable/SKILL.md` (`--disable` wrapper).
- Pattern: `gaia-public/plugins/gaia/skills/gaia-bridge-enable/SKILL.md` (semantic precedent — thin wrapper around a shared toggle).
- Runtime installer: `gaia-public/plugins/gaia/scripts/install-statusline.sh` (E82-S1).
- FR-439 — Statusline toggle slash commands.
- TC-STATUSLINE-13 — Idempotent enable/disable.
- TC-STATUSLINE-14 — Round-trip enable + disable preserves byte-identity.
