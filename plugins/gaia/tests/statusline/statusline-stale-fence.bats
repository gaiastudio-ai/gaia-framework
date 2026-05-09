#!/usr/bin/env bats
# statusline-stale-fence.bats — runtime 7-day stale-fence coverage.
#
# Story: E82-S2 — Background update-check fetcher.
#
# Covers TC-STATUSLINE-7, AT-4: when cache `checked_at_iso` is older than
# 7 days, every update signal in the runtime render is suppressed regardless
# of `update_available`.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNTIME="$PLUGIN_ROOT/scripts/statusline.sh"
  cd "$TEST_TMP"
  mkdir -p gaia-public/plugins/gaia/.claude-plugin
  cat > gaia-public/plugins/gaia/.claude-plugin/plugin.json <<'PJ'
{ "name": "gaia", "version": "1.0.0" }
PJ
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude/gaia-statusline/cache"
  CACHE="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  export CACHE
  export PROJECT_PATH="$TEST_TMP"
  STDIN_JSON='{"model":{"id":"claude-opus-4-7","display_name":"Opus 4.7"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  export STDIN_JSON
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-STATUSLINE-7 / AT-4: cache > 7d stale -> update glyph suppressed
# ---------------------------------------------------------------------------

@test "TC-7: cache older than 7d suppresses update glyph in default theme" {
  [ -f "$RUNTIME" ]
  ts_old="$(date -u -v-8d +%FT%TZ 2>/dev/null || date -u -d '8 days ago' +%FT%TZ)"
  printf '%s' '{"checked_at_iso":"'"$ts_old"'","latest_tag":"2.0.0","current_tag":"1.0.0","update_available":true}' > "$CACHE"
  run bash -c "printf '%s' '$STDIN_JSON' | env HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # No update arrow glyph (↑) and no [update] prefix.
  ! echo "$output" | grep -q '↑'
  ! echo "$output" | grep -q '\[update\]'
}

@test "TC-7: cache older than 7d suppresses [update] in ASCII theme" {
  [ -f "$RUNTIME" ]
  ts_old="$(date -u -v-10d +%FT%TZ 2>/dev/null || date -u -d '10 days ago' +%FT%TZ)"
  printf '%s' '{"checked_at_iso":"'"$ts_old"'","latest_tag":"2.0.0","current_tag":"1.0.0","update_available":true}' > "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '\[update\]'
}

@test "TC-7: cache fresh (< 7d) with update_available=true shows update glyph" {
  [ -f "$RUNTIME" ]
  ts_recent="$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)"
  printf '%s' '{"checked_at_iso":"'"$ts_recent"'","latest_tag":"2.0.0","current_tag":"1.0.0","update_available":true}' > "$CACHE"
  # In ASCII theme to make the assertion unicode-agnostic.
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\[update\]'
}

@test "TC-7: cache fresh with update_available=false hides update signal" {
  [ -f "$RUNTIME" ]
  ts_recent="$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)"
  printf '%s' '{"checked_at_iso":"'"$ts_recent"'","latest_tag":"1.0.0","current_tag":"1.0.0","update_available":false}' > "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '\[update\]'
}

@test "TC-7: cache missing -> no update signal, exit 0" {
  [ -f "$RUNTIME" ]
  rm -f "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '\[update\]'
}

@test "TC-7: cache malformed -> no update signal, exit 0 (silent on miss)" {
  [ -f "$RUNTIME" ]
  printf 'not json' > "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '\[update\]'
}
