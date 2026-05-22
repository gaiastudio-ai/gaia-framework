---
name: gaia-statusline
description: Reference documentation for the GAIA Claude Code statusline runtime — themes, glyph palette, color tokens, width ladder, OSC-8 allowlist, environment variables, and source-of-truth bindings. Documentation-only skill; the runtime ships under `gaia-public/plugins/gaia/scripts/`. Authored by E82-S4; describes the runtime authored by E82-S1.
allowed-tools: [Read]
orchestration_class: light-procedural
---

## Overview

The GAIA statusline is a Claude Code `statusLine` script rendered on every prompt cycle. The runtime lives at `gaia-public/plugins/gaia/scripts/statusline.sh` and is installed per-user at `~/.claude/gaia-statusline/statusline.sh` by `install-statusline.sh`. Toggle it via `/gaia-statusline-enable` and `/gaia-statusline-disable`. This SKILL.md is the authored reference; helper docs under `helpers/` carry extended detail and are JIT-loaded.

## Themes

The runtime supports **exactly three themes** selected via `GAIA_STATUSLINE_THEME`:

| Theme | Selector | Surface |
|---|---|---|
| `minimal` | `GAIA_STATUSLINE_THEME=minimal` | Brand chunk only — `◆ GAIA <version>`. Identical to the `<32` cols width-ladder fallback. |
| `default` | unset OR `GAIA_STATUSLINE_THEME=default` | One-liner: `◆ GAIA <version> | <model> | <project>/<branch> | <context-%>` |
| `rich` | `GAIA_STATUSLINE_THEME=rich` | Default one-liner PLUS a second line `sprint | story | agent` (sprint comes from `.gaia/artifacts/implementation-artifacts/sprint-status.yaml`). |

**Hard contract (R4 mitigation): a fourth theme variant requires a new ADR.** This is not a config flag and not a future-proofed extension point. Any addition is a deliberate architectural change.

Session cost is NEVER rendered in any GAIA theme — that surface is owned by Claude Code's native `/statusline`. See `helpers/themes.md` for per-theme worked-example outputs at column boundaries 80 / 60 / 50 / 40 / 32.

## Glyph Palette

Three columns: Unicode (default), Nerdfont (opt-in via `GAIA_STATUSLINE_NERDFONT=1`), ASCII (`GAIA_STATUSLINE_ASCII=1`). ASCII wins when both flags are set.

| Role | Unicode | Nerdfont | ASCII |
|---|---|---|---|
| Brand mark | `◆` | `nf-fa-diamond` | `*` |
| Git branch | `⎇` | `nf-pl-branch` | `@` |
| Activity / pulse | `*` | `nf-fa-star` | `*` |
| Timer / age | `◷` | `nf-fa-clock` | `t` |
| Update available | `↑` | `nf-fa-arrow_up` | `^` |
| Segment chevron | `▸` | `nf-fa-chevron_right` | `>` |
| Middle dot | `·` | `nf-md-circle_small` | `-` |

The single source of truth is `gaia-public/plugins/gaia/scripts/lib/statusline-glyphs.sh`. See `helpers/glyph-palette.md` for codepoint rationale.

## Color Tokens

Six tokens emitted by `gaia-public/plugins/gaia/scripts/lib/statusline-colors.sh`:

| Token | Role | Default |
|---|---|---|
| `GAIA_BRAND` | GAIA brand mark | `#7B61FF` (purple) — **mandatory** |
| `WARN` | Warnings | amber `#FFB000` |
| `OK` | Success / fresh | green `#2ECC71` |
| `MUTED` | Secondary / subdued text | grey `#808080` |
| `UPDATE` | Update-available signal (bold + `WARN`) | bold amber |
| `DIRTY` | Git-dirty marker | orange `#FF7800` |

`NO_COLOR` (or `GAIA_STATUSLINE_NO_COLOR=1`) suppresses all SGR escape sequences. `COLORTERM=truecolor` (or `24bit`) activates 24-bit `\033[38;2;R;G;Bm` sequences; otherwise the runtime falls back to 256-color SGR. Non-truecolor terminals fall back to the `MUTED` token for the brand mark. See `helpers/color-tokens.md` for contrast notes.

## Width Ladder

The runtime trims segments **right-to-left** when the available width drops below the budget. `$COLUMNS` is consulted first, then `tput cols`, then `80` as the final fallback.

**Drop order (least-essential first):**

`rich-line-2 → dirty-marker → branch → project → version → context-bar → bare model`

**Critical rule:** at `<50` cols the runtime drops **branch BEFORE project** — the project name is the stronger orientation cue (`branch-before-project` rule, FR-433).

| Cols | Surface |
|---|---|
| `>= 80` | All segments |
| `60..79` | Drop sprint (rich line 2) |
| `50..59` | Drop sprint + branch |
| `40..49` | Drop sprint + branch + project |
| `32..39` | Brand + model |
| `< 32` | Brand only |

## OSC-8 Hyperlink Allowlist

The brand chunk `◆ GAIA <version>` is wrapped in an OSC-8 hyperlink (target = the active or latest release-notes URL) **only when** `$TERM_PROGRAM` matches one of:

- `iTerm.app`
- `Kitty`
- `WezTerm`

These three are the literal `$TERM_PROGRAM` strings emitted by each terminal (note `iTerm.app`, NOT `iTerm2`). Other terminals receive the unwrapped chunk — graceful no-hyperlink degradation, no error, no warning (R5 mitigation).

## Environment Variables

| Variable | Effect |
|---|---|
| `GAIA_STATUSLINE_THEME` | Theme selector — `default` (omit), `minimal`, or `rich` |
| `GAIA_STATUSLINE_NERDFONT` | `1` swaps the glyph table to the Nerdfont row |
| `GAIA_STATUSLINE_ASCII` | `1` forces the ASCII fallback row (wins over `NERDFONT`) |
| `NO_COLOR` | Any non-empty value suppresses all SGR escape sequences |
| `COLORTERM` | `truecolor` or `24bit` activates 24-bit color |

## Source-of-Truth Bindings

Every rendered field has exactly one authoritative source:

| Field | Source |
|---|---|
| `version` | `plugin.json` `.version` (read via `jq` from `gaia-public/plugins/gaia/.claude-plugin/plugin.json`) |
| `model` | stdin JSON `model.display_name` (fallback `model.id`) |
| `project` | stdin JSON `cwd` basename (final fallback: `$PWD` basename) |
| `branch` | `git symbolic-ref --short HEAD` |

CLAUDE.md is **NOT** a source of truth for the rendered version — `plugin.json` is the only authority (FR-440).

## Contract

- **Fourth theme requires an ADR.** The runtime locks the surface to three themes — adding a fourth is an architectural change, not a config flag (R4 mitigation).
- **Zero network primitives by structural contract.** The runtime contains no `curl`, `wget`, `nc`, or `gh api` calls — enforced as a structural contract by `tests/statusline/statusline-static-check.bats` (NFR-STATUSLINE-2). Update freshness comes exclusively from the background `refreshInterval` fetcher writing the cache file.

## Cross-References

- **Install / uninstall:** `gaia-public/plugins/gaia/scripts/install-statusline.sh` (E82-S1).
- **Toggle on/off:** `/gaia-statusline-enable` and `/gaia-statusline-disable` (E82-S3) — thin wrappers over `gaia-statusline-toggle.sh`.
- **Background update fetcher:** `gaia-public/plugins/gaia/scripts/statusline-update-check.sh` (E82-S2). Writes the canonical `~/.claude/gaia-statusline/cache/latest-release.json` schema `{checked_at_iso, latest_tag, current_tag, update_available, installed_version_stale}` (ADR-091 + ADR-094 amendment).
- **Staleness detection (E82-S6 / ADR-094):** the fetcher computes `installed_version_stale` by comparing `~/.claude/gaia-statusline/.installed-version` (written atomically by `install-statusline.sh` as the last action of a successful install) against `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`. The renderer surfaces a one-shot daily WARN segment `[stale: rerun install-statusline]` when stale, gated by a per-UTC-day marker at `~/.claude/gaia-statusline/cache/staleness-warning-shown.<YYYY-MM-DD>`. Zero new hot-path I/O — the boolean is read from the existing cache JSON.
- **Helpers (JIT):** `helpers/themes.md`, `helpers/glyph-palette.md`, `helpers/color-tokens.md`.
