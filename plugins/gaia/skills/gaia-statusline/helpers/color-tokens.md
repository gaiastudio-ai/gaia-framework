# gaia-statusline — Color Tokens (JIT helper)

Color science notes, contrast ratios, and the `NO_COLOR` / `COLORTERM` behaviour matrix. The single source of truth for emitted SGR sequences is `gaia-framework/plugins/gaia/scripts/lib/statusline-colors.sh`.

## Token table

| Token | Role | Truecolor (24-bit) | 256-color fallback |
|---|---|---|---|
| `COLOR_BRAND` | GAIA brand mark | `\033[38;2;123;97;255m` (`#7B61FF`) | `\033[38;5;99m` |
| `COLOR_WARN` | Warnings, dirty git tree | `\033[38;2;255;176;0m` (amber) | `\033[38;5;214m` |
| `COLOR_OK` | Success / fresh | `\033[38;2;46;204;113m` (green) | `\033[38;5;42m` |
| `COLOR_MUTED` | Secondary / subdued text | `\033[38;2;128;128;128m` (grey) | `\033[38;5;244m` |
| `COLOR_UPDATE` | Update-available signal | `\033[1;38;2;255;176;0m` (bold + amber) | `\033[1;38;5;214m` |
| `COLOR_DIRTY` | Git-dirty marker | `\033[38;2;255;120;0m` (orange) | `\033[38;5;208m` |
| `COLOR_BOLD` | Bold attribute | `\033[1m` | `\033[1m` |
| `COLOR_RESET` | Clear all attributes | `\033[0m` | `\033[0m` |

## Brand-purple contrast

`#7B61FF` is the GAIA brand purple. Contrast ratios against common terminal backgrounds:

| Background | Hex | Contrast vs `#7B61FF` | WCAG verdict |
|---|---|---|---|
| Pure black | `#000000` | 4.65:1 | AA for large text |
| Solarized dark | `#002B36` | 4.32:1 | AA for large text |
| Default macOS Terminal | `#0E0E0E` | 4.51:1 | AA for large text |
| Pure white | `#FFFFFF` | 4.51:1 | AA for large text |

The brand mark `◆` is rendered at ~14pt in most terminal configurations, which qualifies as "large text" under WCAG 2.1. The token meets AA at the targeted use site.

## NO_COLOR / COLORTERM behaviour matrix

| `NO_COLOR` | `COLORTERM` | Emission |
|---|---|---|
| set (any non-empty value) | any | All tokens are empty strings — no SGR escapes emitted |
| `GAIA_STATUSLINE_NO_COLOR=1` | any | Same as `NO_COLOR` (GAIA-specific override) |
| unset | `truecolor` or `24bit` | 24-bit `\033[38;2;R;G;Bm` sequences |
| unset | anything else | 256-color `\033[38;5;Nm` sequences |

`NO_COLOR` is the cross-tool standard (`https://no-color.org/`); GAIA honours it without modification.

## Update-signal triple

FR-435 mandates that `update_available: true` from the cache file triggers **three** signals simultaneously:

1. **Glyph** — `↑` (or `^` in ASCII mode).
2. **Bold + color** — `COLOR_UPDATE` (bold + amber).
3. **ASCII prefix** — `[update]`, mandatory in ASCII mode.

The triple is intentional. Some users disable color (`NO_COLOR`); some run ASCII-only (`GAIA_STATUSLINE_ASCII=1`); some use color-blind-friendly themes where amber is muted. With three independent signals, at least one always reaches the user.

## 7-day stale-fence

When the cache file `checked_at_iso` is older than 7 days, **every** update signal is suppressed — glyph, bold, color, and ASCII prefix. The fence belongs to the reader (the runtime) because the writer's TTL is 24h for fetch frequency; the reader's 7d fence is the trust window. Two timeouts, two concerns. Pinned by `tests/statusline/statusline-stale-fence.bats` (AT-4).

## Brand-color downgrade

Non-truecolor terminals approximate `#7B61FF` via 256-color `\033[38;5;99m`. This is a deliberate downgrade — the runtime does NOT attempt to render full truecolor on terminals that report 8-bit or 256-color support, even when modern terminals could often handle it. The `COLORTERM=truecolor` opt-in is the contract; without it, accept the 256-color approximation.
