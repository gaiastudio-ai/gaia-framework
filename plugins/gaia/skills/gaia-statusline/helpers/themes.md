# gaia-statusline — Theme Details (JIT helper)

This helper expands the theme summary in `SKILL.md` with worked-example outputs at column boundaries 80, 60, 50, 40, and 32. JIT-loaded so the SKILL.md proper stays under the 1500-token cap.

## minimal

`GAIA_STATUSLINE_THEME=minimal` selects the minimal theme. Surface is identical to the `<32` cols width-ladder fallback — only the brand chunk renders.

```
◆ GAIA 1.139.0
```

Use case: very narrow terminals; users who explicitly want only the version + brand mark.

## default

`GAIA_STATUSLINE_THEME=default` (or unset) selects the default theme. Canonical one-liner:

```
◆ GAIA 1.139.0 | claude-opus | gaia-framework/feat/E82-S4 | 42%
```

The format is fixed by FR-430:

```
◆ GAIA <version> | <model> | <project>/<branch> | <context-%>
```

### Width-ladder worked examples (default theme)

Assuming version=`1.139.0`, model=`claude-opus`, project=`gaia-framework`, branch=`feat/E82-S4`, context=`42%`:

| Cols | Output |
|---|---|
| `>= 80` | `◆ GAIA 1.139.0 | claude-opus | gaia-framework/feat/E82-S4 | 42%` |
| `60..79` | `◆ GAIA 1.139.0 | claude-opus | gaia-framework | feat/E82-S4` (sprint dropped) |
| `50..59` | `◆ GAIA 1.139.0 | claude-opus | gaia-framework` (branch dropped) |
| `40..49` | `◆ GAIA 1.139.0 | claude-opus` (project dropped — branch was already dropped at 50–59) |
| `32..39` | `◆ GAIA 1.139.0 | claude-opus` |
| `< 32` | `◆ GAIA 1.139.0` |

The `<50` cols branch-before-project rule is critical: when space is tight, the project name is more useful than the branch name for orientation.

## rich

`GAIA_STATUSLINE_THEME=rich` adds a second line `sprint | story | agent`. Sprint is read directly from `docs/implementation-artifacts/sprint-status.yaml` with a tiny `grep` (NOT routed through `scripts/sprint-status-dashboard.sh` — that would over-budget the hot path per FR-436).

```
◆ GAIA 1.139.0 | claude-opus | gaia-framework/feat/E82-S4 | 42%
sprint-40 | E82-S4 | dev-story
```

The rich line drops first under width pressure (it is at the top of the drop order). When sprint-status.yaml is missing the second line collapses to empty without error.

## Theme selection precedence

```
GAIA_STATUSLINE_THEME unset → default
GAIA_STATUSLINE_THEME=default → default
GAIA_STATUSLINE_THEME=minimal → minimal
GAIA_STATUSLINE_THEME=rich   → rich
GAIA_STATUSLINE_THEME=<other> → default (silent)
```

Unknown theme values are treated as `default` with no warning — the runtime never emits diagnostics on the hot path (NFR-STATUSLINE-1).

## Adding a fourth theme

A fourth theme is **out of scope by design**. R4 ("theme bikeshedding") is mitigated by hard-coding the surface to three. Any expansion requires:

1. A new ADR documenting the rationale, content, and cost.
2. A PRD amendment via `/gaia-add-feature`.
3. Updated tests pinning the new theme's surface contract.

This is not a config flag and not a future-proofed extension point.
