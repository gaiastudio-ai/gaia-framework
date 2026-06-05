---
name: gaia-statusline-refresh
description: Refresh the GAIA Claude Code statusline runtime by re-running the cached install-statusline.sh unconditionally. Use when /gaia-statusline-enable reported success but the rendered version is still stale — typical after a framework upgrade when /gaia-statusline-enable runs from inside Claude Code's Bash tool channel (non-TTY) and the consent prompt cannot fire. Explicit slash-command invocation IS the consent gate; no TTY check, no YOLO suppression. Idempotent — install-statusline.sh's cmp-only-if-different copies make this a no-op when the runtime already matches the cached version.
allowed-tools: [Bash]
orchestration_class: light-procedural
---

## Mission

You are the `/gaia-statusline-refresh` wrapper. This skill closes a discoverability gap: the consent prompt fires only when both stdin and stdout are TTYs, which means it cannot trigger from inside Claude Code's Bash tool channel — the very channel a user reports the stale-runtime bug from. `/gaia-statusline-refresh` is the explicit, no-prompt refresh surface.

The skill resolves the highest-semver dir under `~/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/` via the shared `lib/statusline-plugin-cache-dir.sh` helper and re-runs the cached `install-statusline.sh` from that version. The installer copies the five runtime files (cmp-only-if-different), writes the `.installed-version` marker, and performs its own surgical cache reset as defense-in-depth.

This skill is part of the statusline epic. The shape mirrors the sibling `/gaia-statusline-enable` and `/gaia-statusline-disable` wrappers (thin delegate + idempotency + canonical one-line output messages).

## Critical Rules

- **Delegate to the cached `install-statusline.sh`.** Resolve the path via `_statusline_resolve_cached_install_script` from `lib/statusline-plugin-cache-dir.sh`. Do NOT hard-code the cache slug or version — the shared helper is the single source of truth (mirrors the cache-dir resolution that `statusline-update-check.sh` uses).
- **Hard-code mode = refresh.** This wrapper is refresh-only. Ignore any `$ARGUMENTS` that attempt to override the mode.
- **Preserve the user-visible slash command.** `/gaia-statusline-refresh` must continue to resolve with zero behavioral change.
- **No consent prompt — explicit slash-command invocation IS the consent.** Unlike `/gaia-statusline-enable` (which gates re-install behind the TTY-prompt to preserve the hand-edit consent contract), this skill overwrites the runtime unconditionally. The slash command name `refresh` is the consent gate. This is intentional — a softer "this will overwrite your runtime; proceed? [y/N]" interactive confirmation would re-introduce the exact bug being closed (suppress under non-TTY → never refresh).
- **Hand-edit reconciliation — slash-command invocation satisfies the consent requirement.** The hand-edit consent contract reads "the user's edits are not overwritten — they must run install-statusline.sh themselves to consent to the refresh." A slash command IS the user running install-statusline.sh themselves, just through a sanctioned UX surface. Users with hand-edits to `~/.claude/gaia-statusline/statusline.sh` MUST NOT invoke `/gaia-statusline-refresh` — they must continue to manage refresh manually via direct `install-statusline.sh` invocation, just as the consent contract always required. This skill does not weaken that contract; it adds a discoverable surface to the same explicit-action contract.
- **Pre-flight refuses cleanly when no cached `install-statusline.sh` resolves.** If the plugin cache dir is absent or contains no semver-named subdirectories, exit non-zero with a canonical stderr referring the user to `/plugin marketplace add gaiastudio-ai/gaia-framework`. The wrapper does NOT attempt to recover by hunting for an in-tree fallback — the cached version is the source of truth.

## Delegation

Invoke the cached installer directly via the shared helper. The script handles:

1. Resolve `_statusline_resolve_cached_install_script` from `${CLAUDE_PLUGIN_ROOT}/scripts/lib/statusline-plugin-cache-dir.sh`.
2. Pre-flight: refuse with `gaia-statusline-refresh: no cached install-statusline.sh found under $HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/<version>/scripts/ — install the marketplace plugin first via /plugin marketplace add gaiastudio-ai/gaia-framework` when the helper returns empty.
3. Read the pre-install `.installed-version` marker (for no-op detection).
4. Exec the resolved `install-statusline.sh`. The installer copies the five runtime files (cmp-only-if-different), writes the marker, performs surgical cache reset (preserves `git_dirty`).
5. Read the post-install marker and emit either:
   - `gaia-statusline-refresh: no-op (already at <version>)` when pre-marker value equals post-marker value (idempotent path).
   - `gaia-statusline-refresh: refreshed runtime to <version>` when the marker changed.

```bash
!bash -c '
  set -euo pipefail
  . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/statusline-plugin-cache-dir.sh"
  installer="$(_statusline_resolve_cached_install_script)"
  if [ -z "$installer" ]; then
    printf "gaia-statusline-refresh: no cached install-statusline.sh found under %s/<version>/scripts/ — install the marketplace plugin first via /plugin marketplace add gaiastudio-ai/gaia-framework\n" "$(_statusline_plugin_cache_dir)" >&2
    exit 1
  fi
  marker="$HOME/.claude/gaia-statusline/.installed-version"
  before=""
  if [ -r "$marker" ]; then
    before="$(head -n1 "$marker" 2>/dev/null | tr -d "[:space:]" || printf "")"
  fi
  bash "$installer" >/dev/null
  after=""
  if [ -r "$marker" ]; then
    after="$(head -n1 "$marker" 2>/dev/null | tr -d "[:space:]" || printf "")"
  fi
  if [ -n "$after" ] && [ "$before" = "$after" ]; then
    printf "gaia-statusline-refresh: no-op (already at %s)\n" "$after"
  elif [ -n "$after" ]; then
    printf "gaia-statusline-refresh: refreshed runtime to %s\n" "$after"
  else
    printf "gaia-statusline-refresh: refresh completed (marker unavailable — install-statusline.sh may have run from a checkout without plugin.json)\n"
  fi
'
```

## When to use this skill

- **You upgraded the marketplace plugin and the statusline still shows the old version.** Typical pattern: `/plugin marketplace add gaiastudio-ai/gaia-framework` succeeds, `/gaia-statusline-enable` reports `enabled`, but the rendered version is unchanged. Root cause: the substrate refreshed the plugin cache but did not touch the runtime under `~/.claude/gaia-statusline/`. The consent prompt would normally cover this — but only when /gaia-statusline-enable runs from a real terminal. From Claude Code's Bash tool channel, the prompt is suppressed. `/gaia-statusline-refresh` is the unconditional fix.
- **You are scripting an automated environment.** YOLO mode or CI scripts that need a known-fresh runtime can invoke `/gaia-statusline-refresh` directly. The `GAIA_YOLO_FLAG` is not consulted — explicit invocation is the consent regardless of mode.
- **Diagnostic re-install.** If you suspect a partial copy or corrupted runtime, `/gaia-statusline-refresh` re-runs the canonical writer. Cheap to invoke; cmp-only-if-different means a no-op when nothing diverged.

## When NOT to use this skill

- **You have hand-edited `~/.claude/gaia-statusline/statusline.sh`.** The per-user runtime is yours to customize. `/gaia-statusline-refresh` WILL overwrite your changes. Manage refresh by hand instead — copy the upstream changes you want into your customized runtime, or vendor your customizations into a wrapper script.

## References

- Delegate: `${CLAUDE_PLUGIN_ROOT}/scripts/install-statusline.sh` (the canonical runtime writer).
- Resolver: `${CLAUDE_PLUGIN_ROOT}/scripts/lib/statusline-plugin-cache-dir.sh` (the shared cache-dir + cached-install-script resolver).
- Sibling: `${CLAUDE_PLUGIN_ROOT}/skills/gaia-statusline-enable/SKILL.md` — TTY-gated consent prompt at toggle time.
- Sibling: `${CLAUDE_PLUGIN_ROOT}/skills/gaia-statusline-disable/SKILL.md` — disable wrapper.
- Pattern: `${CLAUDE_PLUGIN_ROOT}/skills/gaia-bridge-enable/SKILL.md` — semantic precedent for a thin wrapper around an idempotent writer.
