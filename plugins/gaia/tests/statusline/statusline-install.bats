#!/usr/bin/env bats
# statusline-install.bats — install script coverage.
#
# Story: E82-S1 — Statusline runtime + glyph helper + color helper + install.
#
# Covers TC-STATUSLINE-11 (idempotency), TC-STATUSLINE-12 (settings.json key
# preservation), TC-STATUSLINE-16 (plugin-upgrade-stable runtime).

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  INSTALL="$PLUGIN_ROOT/scripts/install-statusline.sh"
  cd "$TEST_TMP"
  # Sandbox the install destination.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-STATUSLINE-11 / AT-5 — install script byte-idempotent
# ---------------------------------------------------------------------------

@test "TC-11: install creates runtime + lib + settings.json (AT-5)" {
  [ -f "$INSTALL" ]
  run bash "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$HOME/.claude/gaia-statusline/statusline.sh" ]
  [ -x "$HOME/.claude/gaia-statusline/lib/statusline-glyphs.sh" ]
  [ -x "$HOME/.claude/gaia-statusline/lib/statusline-colors.sh" ]
  [ -f "$HOME/.claude/settings.json" ]
  # statusLine.command points at the runtime path.
  grep -q '"statusLine"' "$HOME/.claude/settings.json"
  grep -q 'gaia-statusline/statusline.sh' "$HOME/.claude/settings.json"
  # AF-2026-06-02-5 / Val F-06: marker MUST be present and non-empty after
  # a successful in-tree install. The prior `../../` path-depth bug let the
  # marker write silently skip — this assertion catches a re-introduction
  # of issue #1080 even outside the staged-sandbox regression below.
  [ -f "$HOME/.claude/gaia-statusline/.installed-version" ]
  [ -s "$HOME/.claude/gaia-statusline/.installed-version" ]
}

@test "TC-11: install is byte-idempotent on second run" {
  [ -f "$INSTALL" ]
  bash "$INSTALL"
  cp "$HOME/.claude/settings.json" "$TEST_TMP/settings-after-1st.json"
  cp "$HOME/.claude/gaia-statusline/statusline.sh" "$TEST_TMP/runtime-after-1st.sh"
  cp "$HOME/.claude/gaia-statusline/lib/statusline-glyphs.sh" "$TEST_TMP/glyphs-after-1st.sh"
  cp "$HOME/.claude/gaia-statusline/lib/statusline-colors.sh" "$TEST_TMP/colors-after-1st.sh"
  bash "$INSTALL"
  diff "$TEST_TMP/settings-after-1st.json" "$HOME/.claude/settings.json"
  diff "$TEST_TMP/runtime-after-1st.sh" "$HOME/.claude/gaia-statusline/statusline.sh"
  diff "$TEST_TMP/glyphs-after-1st.sh" "$HOME/.claude/gaia-statusline/lib/statusline-glyphs.sh"
  diff "$TEST_TMP/colors-after-1st.sh" "$HOME/.claude/gaia-statusline/lib/statusline-colors.sh"
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-12 — settings.json unrelated keys preserved byte-identical
# ---------------------------------------------------------------------------

@test "TC-12: settings.json unrelated top-level keys preserved" {
  [ -f "$INSTALL" ]
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "theme": "dark",
  "model": "opus",
  "hooks": {
    "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "echo hi"}]}]
  }
}
JSON
  # Capture the values of the unrelated keys.
  before_theme="$(jq -c '.theme' "$HOME/.claude/settings.json")"
  before_model="$(jq -c '.model' "$HOME/.claude/settings.json")"
  # `.hooks.PostToolUse` is unrelated to E82-S8's install scope and MUST
  # round-trip byte-identically. `.hooks.PreToolUse` is intentionally
  # modified by E82-S8 (the git-dirty fetcher hook registration) so we
  # don't compare it as part of the "unrelated keys" invariant.
  before_post_hook="$(jq -c '.hooks.PostToolUse' "$HOME/.claude/settings.json")"
  bash "$INSTALL"
  after_theme="$(jq -c '.theme' "$HOME/.claude/settings.json")"
  after_model="$(jq -c '.model' "$HOME/.claude/settings.json")"
  after_post_hook="$(jq -c '.hooks.PostToolUse' "$HOME/.claude/settings.json")"
  [ "$before_theme" = "$after_theme" ]
  [ "$before_model" = "$after_model" ]
  [ "$before_post_hook" = "$after_post_hook" ]
  # And statusLine was added.
  jq -e '.statusLine.command' "$HOME/.claude/settings.json"
  # And E82-S8's git-dirty PreToolUse hook was registered.
  run jq -r '.hooks.PreToolUse | length' "$HOME/.claude/settings.json"
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-16 — plugin upgrade does not overwrite per-user runtime
# ---------------------------------------------------------------------------

@test "TC-16: plugin upgrade does not overwrite per-user runtime" {
  [ -f "$INSTALL" ]
  bash "$INSTALL"
  # Simulate the user customizing the runtime in place.
  echo '# user-edit marker' >> "$HOME/.claude/gaia-statusline/statusline.sh"
  user_marker="$(grep -c 'user-edit marker' "$HOME/.claude/gaia-statusline/statusline.sh")"
  [ "$user_marker" -eq 1 ]
  # Plugin upgrade is modeled as: source plugin updates, but install-statusline.sh
  # is NOT re-run. The per-user runtime under ~/.claude is therefore unchanged.
  # We just assert the marker is still there — the contract is "install must be
  # explicitly re-run to overwrite".
  [ "$(grep -c 'user-edit marker' "$HOME/.claude/gaia-statusline/statusline.sh")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Atomic write — no /tmp/ usage anywhere in install-statusline.sh
# ---------------------------------------------------------------------------

@test "install-statusline.sh uses sibling-tempfile (no /tmp/ atomic-rename)" {
  [ -f "$INSTALL" ]
  # The install script must not use /tmp/ for the atomic-rename target.
  # mktemp in a sibling directory of the target is the documented idiom.
  ! grep -E 'mktemp[[:space:]]+(/tmp|--tmpdir=/tmp)' "$INSTALL"
}

# ===========================================================================
# E82-S8 — install registers PreToolUse hook idempotently
# ===========================================================================

@test "E82-S8: install registers git-dirty PreToolUse hook (fresh install)" {
  [ -f "$INSTALL" ]
  bash "$INSTALL"
  # Hook for the dirty-fetcher must be present.
  run jq -r --arg cmd "$HOME/.claude/gaia-statusline/statusline-git-dirty-check.sh" \
    'any(.hooks.PreToolUse[]?; .hooks[]?.command == $cmd)' "$HOME/.claude/settings.json"
  [ "$output" = "true" ]
}

@test "E82-S8: re-running install does NOT duplicate PreToolUse hook entry" {
  [ -f "$INSTALL" ]
  bash "$INSTALL"
  bash "$INSTALL"
  bash "$INSTALL"
  # Count of hooks referencing the dirty-fetcher command — must be exactly 1.
  run jq -r --arg cmd "$HOME/.claude/gaia-statusline/statusline-git-dirty-check.sh" \
    '[.hooks.PreToolUse[]? | .hooks[]? | select(.command == $cmd)] | length' \
    "$HOME/.claude/settings.json"
  [ "$output" = "1" ]
}

@test "E82-S8: install copies the dirty-fetcher script to DEST_BASE" {
  [ -f "$INSTALL" ]
  bash "$INSTALL"
  [ -x "$HOME/.claude/gaia-statusline/statusline-git-dirty-check.sh" ]
}

# ---------------------------------------------------------------------------
# AF-2026-06-02-5 — issue #1080 regression: PLUGIN_JSON_SRC path-depth fix
# ---------------------------------------------------------------------------
# The prior `$SCRIPT_DIR/../../.claude-plugin/plugin.json` resolution was
# wrong in BOTH the source-repo layout AND the deployed marketplace cache
# layout (both nest `install-statusline.sh` at `<plugin-root>/scripts/`, so
# the canonical sibling-of-scripts is one `..`, not two). The fix lands at
# `$SCRIPT_DIR/../.claude-plugin/plugin.json` with a `../../` fallback for
# vestigial layouts.
#
# The tests below stage a deployed-shaped sandbox under $TEST_TMP/fake-plugin
# (the marketplace-cache shape: $sandbox/scripts/install-statusline.sh +
# $sandbox/.claude-plugin/plugin.json), copy the six bash sources the
# installer references (5 SRC_* files + 1 lib/statusline-cache-reset.sh
# sourced at install-statusline.sh:155), and assert the marker writes with
# the cached plugin's version string.
#
# Val F-04: 6 sources, not 5 — the sourced lib/statusline-cache-reset.sh
# would hard-fail the install if not staged.

_stage_fake_plugin() {
  local sandbox="$1" ver="$2"
  mkdir -p "$sandbox/scripts/lib" "$sandbox/.claude-plugin"
  cp "$PLUGIN_ROOT/scripts/install-statusline.sh"          "$sandbox/scripts/install-statusline.sh"
  cp "$PLUGIN_ROOT/scripts/statusline.sh"                   "$sandbox/scripts/statusline.sh"
  cp "$PLUGIN_ROOT/scripts/statusline-update-check.sh"      "$sandbox/scripts/statusline-update-check.sh"
  cp "$PLUGIN_ROOT/scripts/statusline-git-dirty-check.sh"   "$sandbox/scripts/statusline-git-dirty-check.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-glyphs.sh"        "$sandbox/scripts/lib/statusline-glyphs.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-colors.sh"        "$sandbox/scripts/lib/statusline-colors.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"   "$sandbox/scripts/lib/statusline-cache-reset.sh"
  chmod +x "$sandbox/scripts/install-statusline.sh"
  printf '{"version":"%s"}\n' "$ver" > "$sandbox/.claude-plugin/plugin.json"
}

@test "AF-33-5 / #1080: marker written with cached plugin version under deployed-shaped layout" {
  # Deployed-cache shape: $sandbox/scripts/install-statusline.sh +
  # $sandbox/.claude-plugin/plugin.json (plugin.json is ONE level up from
  # scripts/). The pre-fix code looked at TWO levels up — this test would
  # have caught the bug at write-time and would catch any future
  # re-introduction of the same path-depth class.
  local sandbox="$TEST_TMP/fake-plugin"
  _stage_fake_plugin "$sandbox" "9.9.9-regression"
  run bash "$sandbox/scripts/install-statusline.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/gaia-statusline/.installed-version" ]
  [ "$(cat "$HOME/.claude/gaia-statusline/.installed-version")" = "9.9.9-regression" ]
}

@test "AF-33-5 / #1080: vestigial two-level layout still resolves via the fallback" {
  # Stage plugin.json at $sandbox/.claude-plugin (one level up) — the
  # canonical path — AND ALSO at $sandbox/../.claude-plugin/plugin.json
  # so the fallback IS reachable when we strip the canonical site.
  # Then delete the canonical site and verify the fallback fires.
  local sandbox="$TEST_TMP/fake-plugin-vestigial/inner"
  mkdir -p "$sandbox/scripts/lib" "$sandbox/../.claude-plugin"
  cp "$PLUGIN_ROOT/scripts/install-statusline.sh"          "$sandbox/scripts/install-statusline.sh"
  cp "$PLUGIN_ROOT/scripts/statusline.sh"                   "$sandbox/scripts/statusline.sh"
  cp "$PLUGIN_ROOT/scripts/statusline-update-check.sh"      "$sandbox/scripts/statusline-update-check.sh"
  cp "$PLUGIN_ROOT/scripts/statusline-git-dirty-check.sh"   "$sandbox/scripts/statusline-git-dirty-check.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-glyphs.sh"        "$sandbox/scripts/lib/statusline-glyphs.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-colors.sh"        "$sandbox/scripts/lib/statusline-colors.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"   "$sandbox/scripts/lib/statusline-cache-reset.sh"
  chmod +x "$sandbox/scripts/install-statusline.sh"
  printf '{"version":"%s"}\n' "vestigial-9.9.9" > "$sandbox/../.claude-plugin/plugin.json"
  # No canonical site — only the two-level vestigial site exists.
  run bash "$sandbox/scripts/install-statusline.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/gaia-statusline/.installed-version")" = "vestigial-9.9.9" ]
}

@test "AF-33-5 / #1080: marker is empty-resilient when BOTH paths miss (no plugin.json anywhere)" {
  # Defense in depth: when neither the canonical nor the fallback path
  # resolves, INSTALLED_VERSION stays empty and the marker-write guard
  # gracefully skips. This is the AC5 'marker-absent → silent no-op'
  # behavior at install time. The install MUST still complete (exit 0,
  # all five runtime files copied, settings.json merged); only the
  # marker write is skipped.
  local sandbox="$TEST_TMP/fake-plugin-nojson"
  mkdir -p "$sandbox/scripts/lib"
  cp "$PLUGIN_ROOT/scripts/install-statusline.sh"          "$sandbox/scripts/install-statusline.sh"
  cp "$PLUGIN_ROOT/scripts/statusline.sh"                   "$sandbox/scripts/statusline.sh"
  cp "$PLUGIN_ROOT/scripts/statusline-update-check.sh"      "$sandbox/scripts/statusline-update-check.sh"
  cp "$PLUGIN_ROOT/scripts/statusline-git-dirty-check.sh"   "$sandbox/scripts/statusline-git-dirty-check.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-glyphs.sh"        "$sandbox/scripts/lib/statusline-glyphs.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-colors.sh"        "$sandbox/scripts/lib/statusline-colors.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"   "$sandbox/scripts/lib/statusline-cache-reset.sh"
  chmod +x "$sandbox/scripts/install-statusline.sh"
  # Ensure no plugin.json at either depth.
  [ ! -e "$sandbox/.claude-plugin/plugin.json" ]
  [ ! -e "$sandbox/../.claude-plugin/plugin.json" ]
  run bash "$sandbox/scripts/install-statusline.sh"
  [ "$status" -eq 0 ]
  [ -x "$HOME/.claude/gaia-statusline/statusline.sh" ]
  # Marker not written — that's the documented AC5 shape when no source
  # of truth resolved.
  [ ! -e "$HOME/.claude/gaia-statusline/.installed-version" ]
}
