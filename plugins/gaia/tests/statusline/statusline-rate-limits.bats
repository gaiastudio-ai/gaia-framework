#!/usr/bin/env bats
# statusline-rate-limits.bats — E82-S10 rate-limits chunk coverage (FR-451).
#
# Rich-theme-only. Reads `.rate_limits.{five_hour,seven_day}.used_percentage`
# from stdin. Renders `RL: <5h>%/<7d>%` colored by max-of-two.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNTIME="$PLUGIN_ROOT/scripts/statusline.sh"
  cd "$TEST_TMP"
  mkdir -p gaia-public/plugins/gaia/.claude-plugin
  cat > gaia-public/plugins/gaia/.claude-plugin/plugin.json <<'PJ'
{ "name": "gaia", "version": "9.9.9-test" }
PJ
  export PROJECT_PATH="$TEST_TMP"
}
teardown() { common_teardown; }

# Helper: build stdin JSON with given rate-limit percentages.
# Use "null" string to omit a field.
_stdin_rl() {
  local h5="$1" d7="$2"
  local fragment=""
  if [ "$h5" != "null" ] && [ "$d7" != "null" ]; then
    fragment=",\"rate_limits\":{\"five_hour\":{\"used_percentage\":$h5},\"seven_day\":{\"used_percentage\":$d7}}"
  elif [ "$h5" != "null" ]; then
    fragment=",\"rate_limits\":{\"five_hour\":{\"used_percentage\":$h5}}"
  elif [ "$d7" != "null" ]; then
    fragment=",\"rate_limits\":{\"seven_day\":{\"used_percentage\":$d7}}"
  fi
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"current_dir":"%s"}%s}' \
    "$TEST_TMP" "$fragment"
}

# Strip SGR escape sequences for substring grep.
_strip_sgr() {
  printf '%s' "$1" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g'
}

# ---------- AC1: rich theme renders RL: <5h>%/<7d>% ------------------------

@test "E82-S10 / AC1: rich theme renders RL: <5h>%/<7d>%" {
  stdin="$(_stdin_rl 23 41)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "RL: 23%/41%"
}

# ---------- AC2: <50% max -> COLOR_OK -------------------------------------

@test "E82-S10 / AC2: max<50 uses COLOR_OK (truecolor green)" {
  stdin="$(_stdin_rl 23 41)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;46;204;113m'
}

# ---------- AC3: 50..<80% max -> COLOR_WARN -------------------------------

@test "E82-S10 / AC3: 50..<80 max uses COLOR_WARN (truecolor amber)" {
  stdin="$(_stdin_rl 51 60)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;255;176;0m'
}

# ---------- AC4: >=80% max -> COLOR_DIRTY ---------------------------------

@test "E82-S10 / AC4: max>=80 uses COLOR_DIRTY (truecolor orange)" {
  stdin="$(_stdin_rl 85 70)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;255;120;0m'
}

@test "E82-S10 / AC4 boundary: pct=80 is DIRTY (inclusive lower bound)" {
  stdin="$(_stdin_rl 80 50)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;255;120;0m'
}

# ---------- AC5: both fields absent -> empty chunk ------------------------

@test "E82-S10 / AC5: both fields absent -> no RL chunk" {
  stdin="$(_stdin_rl null null)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "RL:"
}

# ---------- AC6/AC7: single-field defensive fallback ----------------------

@test "E82-S10 / AC6: only 5h present -> RL: 23%" {
  stdin="$(_stdin_rl 23 null)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "RL: 23%"
  ! echo "$stripped" | grep -q "RL: 23%/"
}

@test "E82-S10 / AC7: only 7d present -> RL: 41%" {
  stdin="$(_stdin_rl null 41)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "RL: 41%"
}

# ---------- AC7: minimal theme suppresses chunk (sprint-43 update) -------

@test "E82-S10 / AC7: minimal theme does NOT emit RL chunk even with fields present" {
  # sprint-43 update: rich is now the runtime default; minimal is opt-OUT.
  # The original AC7 contract ("default theme suppresses RL") is now
  # served by the minimal-theme branch.
  stdin="$(_stdin_rl 23 41)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=minimal printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=minimal '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "RL:"
}

@test "E82-S10 / AC7 (sprint-43): default theme NOW emits RL chunk (rich is default)" {
  # Companion to the AC7 update — proves the new default behaviour.
  stdin="$(_stdin_rl 23 41)"
  run bash -c "COLUMNS=200 printf '%s' '$stdin' | env -u GAIA_STATUSLINE_THEME COLUMNS=200 '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "RL:"
}

# ---------- AC8: width-ladder drops rate-limits first ---------------------

@test "E82-S10 / AC8: narrow COLS drops rate-limits chunk" {
  stdin="$(_stdin_rl 23 41)"
  # 80 cols keeps everything else but drops rate-limits per ladder.
  run bash -c "COLUMNS=80 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=80 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "RL:"
}

@test "E82-S10 / AC8: wide COLS (>=100) keeps rate-limits chunk" {
  stdin="$(_stdin_rl 23 41)"
  run bash -c "COLUMNS=120 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=120 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "RL: 23%/41%"
}
