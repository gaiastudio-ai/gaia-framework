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
  mkdir -p gaia-framework/plugins/gaia/.claude-plugin
  cat > gaia-framework/plugins/gaia/.claude-plugin/plugin.json <<'PJ'
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

# ---------------------------------------------------------------------------
# AF-2026-05-27-5: the update arrow must clear the moment the installed version
# catches up to (or passes) the cached latest_tag — not linger until the 24h
# fetcher TTL refreshes the cache. The gate is strict semver "latest > installed",
# not a bare "latest != installed". Installed version is the 1.0.0 fixture.
# ---------------------------------------------------------------------------

@test "AF-27-5: installed == cached latest_tag -> no arrow (just-updated, stale cache)" {
  [ -f "$RUNTIME" ]
  ts_recent="$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)"
  # Cache still says update_available=true with latest_tag=1.0.0 (the value the
  # fetcher saw BEFORE the user updated), but installed is now also 1.0.0.
  printf '%s' '{"checked_at_iso":"'"$ts_recent"'","latest_tag":"1.0.0","current_tag":"0.9.0","update_available":true}' > "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '\[update\]'
}

@test "AF-27-5: installed NEWER than cached latest_tag -> no arrow (the reported bug)" {
  [ -f "$RUNTIME" ]
  ts_recent="$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)"
  # Stale cache from before the update: latest_tag=0.9.0 < installed 1.0.0, yet
  # update_available=true. The old `latest != installed` gate lit the arrow here.
  printf '%s' '{"checked_at_iso":"'"$ts_recent"'","latest_tag":"0.9.0","current_tag":"0.9.0","update_available":true}' > "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '\[update\]'
}

@test "AF-27-5: cached latest_tag strictly NEWER than installed -> arrow shows" {
  [ -f "$RUNTIME" ]
  ts_recent="$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)"
  # A genuine newer release (1.1.0 > installed 1.0.0) — arrow MUST appear.
  printf '%s' '{"checked_at_iso":"'"$ts_recent"'","latest_tag":"1.1.0","current_tag":"1.0.0","update_available":true}' > "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\[update\]'
}

@test "AF-27-5: semver-aware — 1.10.0 installed, latest 1.9.0 -> no arrow" {
  [ -f "$RUNTIME" ]
  # Re-pin the in-tree fixture to 1.10.0 for this case.
  cat > "$TEST_TMP/gaia-framework/plugins/gaia/.claude-plugin/plugin.json" <<'PJ'
{ "name": "gaia", "version": "1.10.0" }
PJ
  ts_recent="$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)"
  printf '%s' '{"checked_at_iso":"'"$ts_recent"'","latest_tag":"1.9.0","current_tag":"1.9.0","update_available":true}' > "$CACHE"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # 1.9.0 is NOT > 1.10.0 under semver -> no arrow (a string '>' would wrongly fire).
  ! echo "$output" | grep -q '\[update\]'
}
