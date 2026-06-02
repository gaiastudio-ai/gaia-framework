---
name: gaia-statusline-enable
description: Enable the GAIA Claude Code statusline by adding the canonical statusLine block to ~/.claude/settings.json. Thin wrapper that delegates to gaia-statusline-toggle.sh in --enable mode. Idempotent — no write when already enabled. Pre-flight refuses if the runtime ~/.claude/gaia-statusline/statusline.sh is not installed and points at install-statusline.sh.
allowed-tools: [Bash]
orchestration_class: light-procedural
---

## Mission

You are the `/gaia-statusline-enable` wrapper. This skill flips the GAIA statusline on by adding the canonical `statusLine` block to `~/.claude/settings.json`. The runtime path it points at is `~/.claude/gaia-statusline/statusline.sh` with `refreshInterval = 10000` (10s — sprint-43 update from 1h) — both authored by E82-S1's `install-statusline.sh`.

This wrapper preserves the user-visible `/gaia-statusline-enable` slash command while delegating the actual file edit to the shared toggle script `gaia-framework/plugins/gaia/scripts/gaia-statusline-toggle.sh`.

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
!bash gaia-framework/plugins/gaia/scripts/gaia-statusline-toggle.sh --enable
```

## Self-heal at toggle time (FR-448 AC8 / E82-S11 / AF-2026-06-02-3)

After the executable-bit pre-flight (AC7) and before the AC2 settings.json idempotency check, the toggle script compares the installed runtime's `.installed-version` marker (written by `install-statusline.sh` per E82-S6) against the cached plugin.json `.version` under the highest-semver dir of `~/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia` (resolved via the shared `lib/statusline-plugin-cache-dir.sh` helper). The cache-dir literal is sourced from the same helper that `statusline-update-check.sh` uses — single source of truth.

When the marker disagrees with the cached version AND both stdin and stdout are TTYs AND `GAIA_YOLO_FLAG != 1`, the toggle script surfaces a one-shot consent prompt:

```
gaia-statusline-enable: installed runtime is <X>, cached plugin is <Y>. Re-install runtime? [y/N]
```

- **Default is decline.** Empty answer, `N`, or any non-`y` response → no install runs, no cache mutation occurs. The existing FR-448 AC3 hot-path daily WARN segment continues to fire on the next render so the staleness signal is not lost.
- **On `y` (case-insensitive)** the cached `install-statusline.sh` is re-run AND the update-check-owned keys (`checked_at_iso`, `latest_tag`, `current_tag`, `update_available`, `installed_version_stale`) are surgically deleted from `~/.claude/gaia-statusline/cache/latest-release.json` via `jq del(...)` written atomically. The `git_dirty` field is preserved per ADR-091. A one-line note `gaia-statusline-enable: refreshed runtime from cached <version> (was stale).` is emitted before the settings.json merge fires.

**FR-448 AC6 contract preserved.** Non-TTY invocations (bats tests, CI, the substrate-toggle path, piped stdin) suppress the prompt entirely; `GAIA_YOLO_FLAG=1` also suppresses it. The runtime is overwritten only on explicit user consent — a user with hand-edits to `~/.claude/gaia-statusline/statusline.sh` must answer `y` to lose them.

**Marker-absent silent no-op.** First-install fixtures (no `.installed-version` marker file) skip the staleness check entirely, matching FR-448 AC5.

**Defense in depth.** `install-statusline.sh` itself also performs the same surgical cache reset on every successful install, so manual re-installs invoked outside the toggle path get the same fresh-render guarantee.

## Round-trip caveat

The canonical write format is `jq -S` (sorted keys, 2-space indent). For `enable` followed by `disable` to produce a byte-identical result against the original `settings.json`, the original must already be in canonical jq format. If the original was hand-edited with comments, custom whitespace, or unsorted keys, the round-trip will normalize it on first write. This caveat mirrors the install-script behavior (E82-S1) and is by design — `jq` does not preserve comments or arbitrary whitespace.

## References

- Delegate: `gaia-framework/plugins/gaia/scripts/gaia-statusline-toggle.sh` (full enable + disable procedure).
- Sibling: `gaia-framework/plugins/gaia/skills/gaia-statusline-disable/SKILL.md` (`--disable` wrapper).
- Pattern: `gaia-framework/plugins/gaia/skills/gaia-bridge-enable/SKILL.md` (semantic precedent — thin wrapper around a shared toggle).
- Runtime installer: `gaia-framework/plugins/gaia/scripts/install-statusline.sh` (E82-S1).
- FR-439 — Statusline toggle slash commands.
- FR-448 AC8 — Consent-gated self-heal at toggle time (E82-S11 / AF-2026-06-02-3).
- TC-STATUSLINE-13 — Idempotent enable/disable.
- TC-STATUSLINE-14 — Round-trip enable + disable preserves byte-identity.
- TC-STATUSLINE-17 — `install-statusline.sh` surgical cache reset preserves `git_dirty`.
- TC-STATUSLINE-18 — Consent-prompt three-branch coverage (marker-matches no-op / 'y' refresh / 'N' warn-only).
- T-STATUSLINE-1 addendum — two new authorized writers to `~/.claude/gaia-statusline/cache/latest-release.json` documented.
