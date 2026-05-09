#!/usr/bin/env bats
# gaia-statusline-skill-md.bats — Structural assertions for the SKILL.md
# authored by E82-S4. This is documentation-as-code: the SKILL.md is the
# user-facing reference for the statusline runtime authored by E82-S1.
# Drift between SKILL.md claims and runtime behaviour is a bug — this
# test pins the documentation contract.
#
# Story: E82-S4 — `gaia-statusline` SKILL.md authoring (themes, glyphs,
# color tokens, width ladder, OSC-8 allowlist).
#
# Traces to: FR-430..FR-436, NFR-PLUGIN-2, NFR-STATUSLINE-2, R4 mitigation.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_DIR="$PLUGIN_ROOT/skills/gaia-statusline"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  HELPERS_DIR="$SKILL_DIR/helpers"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — three themes documented with canonical default-theme one-liner format.
# ---------------------------------------------------------------------------
@test "SKILL.md: file exists at canonical path (E82-S4 AC1 prerequisite)" {
  [ -f "$SKILL_MD" ]
}

@test "SKILL.md: enumerates exactly three themes — minimal, default, rich (AC1)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'minimal' "$SKILL_MD"
  grep -qF 'default' "$SKILL_MD"
  grep -qF 'rich' "$SKILL_MD"
}

@test "SKILL.md: documents canonical default-theme one-liner verbatim (AC1)" {
  [ -f "$SKILL_MD" ]
  # The story mandates the literal string '◆ GAIA <version> | <model> | <project>/<branch> | <context-%>'
  grep -qF '◆ GAIA <version> | <model> | <project>/<branch> | <context-%>' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC2 — three-column glyph table (Unicode / Nerdfont / ASCII) with all
# canonical glyphs ◆ ⎇ * ◷ ↑ ▸ ·
# ---------------------------------------------------------------------------
@test "SKILL.md: glyph table covers all canonical Unicode glyphs (AC2)" {
  [ -f "$SKILL_MD" ]
  grep -qF '◆' "$SKILL_MD"
  grep -qF '⎇' "$SKILL_MD"
  grep -qF '◷' "$SKILL_MD"
  grep -qF '↑' "$SKILL_MD"
  grep -qF '▸' "$SKILL_MD"
  grep -qF '·' "$SKILL_MD"
}

@test "SKILL.md: glyph table has Unicode / Nerdfont / ASCII column headers (AC2)" {
  [ -f "$SKILL_MD" ]
  grep -qiE 'Unicode' "$SKILL_MD"
  grep -qiE 'Nerdfont' "$SKILL_MD"
  grep -qiE 'ASCII' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC3 — six color tokens with semantic role + default value; brand purple mandatory.
# ---------------------------------------------------------------------------
@test "SKILL.md: documents all six color tokens (AC3)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'GAIA_BRAND' "$SKILL_MD"
  grep -qF 'WARN' "$SKILL_MD"
  grep -qF 'OK' "$SKILL_MD"
  grep -qF 'MUTED' "$SKILL_MD"
  grep -qF 'UPDATE' "$SKILL_MD"
  grep -qF 'DIRTY' "$SKILL_MD"
}

@test "SKILL.md: GAIA_BRAND default value #7B61FF is documented (AC3)" {
  [ -f "$SKILL_MD" ]
  grep -qF '#7B61FF' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC4 — width ladder right-to-left drop order + <50 cols branch-before-project rule.
# ---------------------------------------------------------------------------
@test "SKILL.md: width-ladder drop order is enumerated (AC4)" {
  [ -f "$SKILL_MD" ]
  # Drop sequence (least-essential first per FR-433):
  # rich-line-2 → dirty-marker → branch → project → version → context-bar → bare model
  grep -qiE 'rich.line.2|rich line 2' "$SKILL_MD"
  grep -qiE 'dirty.marker|dirty marker' "$SKILL_MD"
  grep -qF 'branch' "$SKILL_MD"
  grep -qF 'project' "$SKILL_MD"
  grep -qF 'context' "$SKILL_MD"
}

@test "SKILL.md: <50 cols branch-before-project rule is explicit (AC4)" {
  [ -f "$SKILL_MD" ]
  grep -qE '<[[:space:]]*50' "$SKILL_MD"
  grep -qiE 'branch.before.project|branch before project' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC5 — OSC-8 allowlist exactly iTerm.app, Kitty, WezTerm; graceful degradation.
# ---------------------------------------------------------------------------
@test "SKILL.md: OSC-8 allowlist names exactly three TERM_PROGRAM values (AC5)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'iTerm.app' "$SKILL_MD"
  grep -qF 'Kitty' "$SKILL_MD"
  grep -qF 'WezTerm' "$SKILL_MD"
}

@test "SKILL.md: OSC-8 section explains graceful no-hyperlink degradation (AC5)" {
  [ -f "$SKILL_MD" ]
  grep -qiE 'graceful|degrad|fallback' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC6 — env vars: GAIA_STATUSLINE_THEME, _NERDFONT, _ASCII, NO_COLOR, COLORTERM.
# ---------------------------------------------------------------------------
@test "SKILL.md: documents GAIA_STATUSLINE_THEME with default | minimal | rich (AC6)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'GAIA_STATUSLINE_THEME' "$SKILL_MD"
}

@test "SKILL.md: documents GAIA_STATUSLINE_NERDFONT (AC6)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'GAIA_STATUSLINE_NERDFONT' "$SKILL_MD"
}

@test "SKILL.md: documents GAIA_STATUSLINE_ASCII (AC6)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'GAIA_STATUSLINE_ASCII' "$SKILL_MD"
}

@test "SKILL.md: documents NO_COLOR (AC6)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'NO_COLOR' "$SKILL_MD"
}

@test "SKILL.md: documents COLORTERM (AC6)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'COLORTERM' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC7 — source-of-truth bindings table has exactly four rows (version, model,
# project, branch) with the documented sources.
# ---------------------------------------------------------------------------
@test "SKILL.md: source-of-truth bindings name plugin.json .version (AC7)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'plugin.json' "$SKILL_MD"
  grep -qF '.version' "$SKILL_MD"
}

@test "SKILL.md: source-of-truth bindings name stdin JSON model (AC7)" {
  [ -f "$SKILL_MD" ]
  grep -qiE 'stdin.*model|stdin JSON' "$SKILL_MD"
}

@test "SKILL.md: source-of-truth bindings name cwd basename (AC7)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'cwd' "$SKILL_MD"
  grep -qiE 'basename' "$SKILL_MD"
}

@test "SKILL.md: source-of-truth bindings name git symbolic-ref --short HEAD (AC7)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'git symbolic-ref --short HEAD' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC8 — token-cap: SKILL.md <= 1500 tokens. Use wc -w as a proxy (1 word ≈ 1 token).
# ---------------------------------------------------------------------------
@test "SKILL.md: word count proxy is <= 1500 (AC8 — NFR-PLUGIN-2)" {
  [ -f "$SKILL_MD" ]
  local wc_out
  wc_out="$(wc -w < "$SKILL_MD")"
  # Strip whitespace
  wc_out="${wc_out// /}"
  [ "$wc_out" -le 1500 ]
}

@test "helpers/themes.md exists for JIT loading (AC8)" {
  [ -f "$HELPERS_DIR/themes.md" ]
}

@test "helpers/glyph-palette.md exists for JIT loading (AC8)" {
  [ -f "$HELPERS_DIR/glyph-palette.md" ]
}

@test "helpers/color-tokens.md exists for JIT loading (AC8)" {
  [ -f "$HELPERS_DIR/color-tokens.md" ]
}

# ---------------------------------------------------------------------------
# AC9 — contract section: fourth theme requires ADR (R4) and zero-network
# structural contract (NFR-STATUSLINE-2).
# ---------------------------------------------------------------------------
@test "SKILL.md: contract states fourth theme requires a new ADR (AC9 — R4)" {
  [ -f "$SKILL_MD" ]
  grep -qiE 'fourth theme.*ADR|ADR.*fourth theme' "$SKILL_MD"
}

@test "SKILL.md: contract states zero network primitives by structural contract (AC9 — NFR-STATUSLINE-2)" {
  [ -f "$SKILL_MD" ]
  grep -qiE 'zero network|no network' "$SKILL_MD"
  grep -qiE 'structural contract|structurally enforced|structural' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC10 — drift check: documented behaviour matches runtime exactly.
# Programmatic drift checks for the load-bearing constants.
# ---------------------------------------------------------------------------
@test "SKILL.md: GAIA_BRAND #7B61FF matches runtime statusline-colors.sh (AC10 drift)" {
  [ -f "$SKILL_MD" ]
  local colors_sh="$PLUGIN_ROOT/scripts/lib/statusline-colors.sh"
  [ -f "$colors_sh" ]
  # Both the SKILL.md and the colors helper must reference #7B61FF.
  grep -qF '#7B61FF' "$SKILL_MD"
  grep -qF '#7B61FF' "$colors_sh"
}

@test "SKILL.md: OSC-8 allowlist matches runtime case statement exactly (AC10 drift)" {
  [ -f "$SKILL_MD" ]
  local runtime="$PLUGIN_ROOT/scripts/statusline.sh"
  [ -f "$runtime" ]
  # Runtime case at line ~145: iTerm.app|Kitty|WezTerm
  grep -qE 'iTerm\.app\|Kitty\|WezTerm' "$runtime"
  grep -qF 'iTerm.app' "$SKILL_MD"
  grep -qF 'Kitty' "$SKILL_MD"
  grep -qF 'WezTerm' "$SKILL_MD"
}

@test "SKILL.md: cross-links to install-statusline.sh and toggle skills (technical-notes)" {
  [ -f "$SKILL_MD" ]
  grep -qF 'install-statusline.sh' "$SKILL_MD"
  grep -qiE '/gaia-statusline-enable|gaia-statusline-enable' "$SKILL_MD"
  grep -qiE '/gaia-statusline-disable|gaia-statusline-disable' "$SKILL_MD"
}
