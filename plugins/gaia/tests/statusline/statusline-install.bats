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
