# gaia-statusline — Glyph Palette (JIT helper)

Extended glyph palette with rationale for each Unicode choice. The single source of truth is `gaia-public/plugins/gaia/scripts/lib/statusline-glyphs.sh` — drift between this helper and the runtime helper is a bug.

## Full palette

| Variable | Unicode | Codepoint | Nerdfont | ASCII | Rationale |
|---|---|---|---|---|---|
| `GLYPH_BRAND` | `◆` | U+25C6 BLACK DIAMOND | `nf-fa-diamond` | `*` | Filled diamond renders cleanly at small sizes; pairs visually with the brand purple. |
| `GLYPH_BRANCH` | `⎇` | U+2387 ALTERNATIVE KEY SYMBOL | `nf-pl-branch` | `@` | Compact branching glyph; available in most modern monospace fonts. |
| `GLYPH_SPARK` | `*` | U+002A ASTERISK | `nf-fa-star` | `*` | Kept as ASCII asterisk by default for terminal robustness — Unicode upgrade is opt-in via Nerdfont. |
| `GLYPH_CLOCK` | `◷` | U+25F7 WHITE CIRCLE WITH UPPER RIGHT QUADRANT | `nf-fa-clock` | `t` | Clock-quadrant glyph reads as a timer without the visual weight of `🕒`. |
| `GLYPH_UPDATE` | `↑` | U+2191 UPWARDS ARROW | `nf-fa-arrow_up` | `^` | Universal "available upward" semantics; pairs with bold + color for the triple-signal in FR-435. |
| `GLYPH_CHEVRON` | `▸` | U+25B8 BLACK RIGHT-POINTING SMALL TRIANGLE | `nf-fa-chevron_right` | `>` | Subtle separator — lighter than `>` but still directional. |
| `GLYPH_DOT` | `·` | U+00B7 MIDDLE DOT | `nf-md-circle_small` | `-` | Visually quiet separator for low-contrast joins. |

## Activation precedence

```
GAIA_STATUSLINE_ASCII=1     → ASCII column wins (overrides Nerdfont)
GAIA_STATUSLINE_NERDFONT=1  → Nerdfont column wins (when ASCII is NOT set)
neither flag                → Unicode column (default)
```

ASCII deliberately wins over Nerdfont so that `GAIA_STATUSLINE_ASCII=1` is a single, unambiguous escape hatch for terminals that mis-render either font (CI logs, headless captures, screen readers).

## ASCII contract (AT-3)

When `GAIA_STATUSLINE_ASCII=1`, the rendered output bytes MUST all be in the printable-ASCII range `0x20..0x7E` plus `0x09` (tab) and `0x0A` (newline). Any non-ASCII byte in ASCII mode is a regression — pinned by `tests/statusline/statusline-static-check.bats`.

## Why the brand mark is a diamond

The 2026-05-09 design meeting (D2) ratified `◆` as the brand mark for two reasons:

1. **Single-codepoint UTF-8.** The diamond is one codepoint, not a grapheme cluster — no fragility on terminals with combining-character bugs.
2. **Color affordance.** Filled glyphs accept color cleanly; the GAIA-purple `#7B61FF` reads as the brand without losing legibility on dark backgrounds. Outline glyphs (e.g., `◇`) lose contrast under truecolor purple.

Non-truecolor terminals fall back to the `MUTED` token for the brand mark — the diamond shape stays, the color is downgraded.
