#!/usr/bin/env bats
# statusline-context-bar.bats — E82-S9 context-window progress bar coverage.
#
# Story: E82-S9 (FR-450, FR-430 implementation of the `<context-%>` segment).
#
# Covers the 11 ACs from the story spec: color bands (OK/WARN/DIRTY), null vs
# zero distinction, ASCII fallback, NO_COLOR, width-ladder interaction, and
# the extended-context (1M) case.

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

# Build stdin JSON with the given context_window block. The function is
# pure helper — does not export, does not pollute global env.
_stdin_with_context() {
  local pct="$1" current_usage="$2"
  if [ "$current_usage" = "null" ]; then
    printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":%s,"current_usage":null}}' \
      "$TEST_TMP" "$pct"
  else
    printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":%s,"current_usage":%s}}' \
      "$TEST_TMP" "$pct" "$current_usage"
  fi
}

# ---------- AC6: null current_usage -> empty chunk -------------------------

@test "E82-S9 / AC6: null current_usage produces no bar (chunk suppressed)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 50 null)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # No filled/empty glyphs present in output.
  ! echo "$output" | grep -q "#"
  ! echo "$output" | grep -q -- "----------"
}

# ---------- AC7: 0% with non-null current_usage -> visible empty bar ------

@test "E82-S9 / AC7: 0% with non-null current_usage renders 10 empty glyphs" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 0 1000)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # 10 empty glyphs in a row (ASCII: `-`).
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q -- "----------"
}

# ---------- AC1: floor(pct/10) filled, remainder empty --------------------

@test "E82-S9 / AC1: 25% renders 2 filled + 8 empty (ASCII)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 25 1000)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Strip SGR escape sequences before substring match (color reset sits
  # between filled run and empty run).
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q "##--------"
}

@test "E82-S9 / AC1: 50% renders 5 filled + 5 empty (ASCII)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 50 1000)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q "#####-----"
}

@test "E82-S9 / AC8: 100% renders 10 filled + 0 empty (ASCII)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 100 5000)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q "##########"
}

# ---------- AC5: ASCII fallback glyphs are `#` and `-` --------------------

@test "E82-S9 / AC5: ASCII mode uses # for filled and - for empty" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 40 1000)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # 4 filled + 6 empty for 40%.
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q "####------"
}

# ---------- AC2/AC3/AC4: color bands --------------------------------------

@test "E82-S9 / AC2: <50% uses COLOR_OK (green truecolor)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 30 1000)"
  # Use truecolor by setting COLORTERM=truecolor.
  run bash -c "COLUMNS=200 COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  # COLOR_OK is `[38;2;46;204;113m` per statusline-colors.sh.
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;46;204;113m'
}

@test "E82-S9 / AC3: 50..<80% uses COLOR_WARN (amber truecolor)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 65 1000)"
  run bash -c "COLUMNS=200 COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  # COLOR_WARN truecolor `[38;2;255;176;0m`.
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;255;176;0m'
}

@test "E82-S9 / AC4: >=80% uses COLOR_DIRTY (orange truecolor)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 85 1000)"
  run bash -c "COLUMNS=200 COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  # COLOR_DIRTY truecolor `[38;2;255;120;0m`.
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;255;120;0m'
}

# ---------- Boundary tests at color-band edges ----------------------------

@test "E82-S9 / band boundary: pct=49 is OK (not WARN)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 49 1000)"
  run bash -c "COLUMNS=200 COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;46;204;113m'    # OK green
  ! echo "$output" | LC_ALL=C grep -q $'\033\[38;2;255;176;0m'   # not WARN amber
}

@test "E82-S9 / band boundary: pct=80 is DIRTY (not WARN)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 80 1000)"
  run bash -c "COLUMNS=200 COLORTERM=truecolor printf '%s' '$stdin' | env COLUMNS=200 COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | LC_ALL=C grep -q $'\033\[38;2;255;120;0m'    # DIRTY orange
}

# ---------- AC11: NO_COLOR suppresses SGR escapes -------------------------

@test "E82-S9 / AC11: NO_COLOR set -> no SGR escapes in bar" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 50 1000)"
  run bash -c "COLUMNS=200 NO_COLOR=1 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 NO_COLOR=1 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Bar structure still rendered (5 #, 5 -), but no SGR escape sequences.
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q "#####-----"
  ! echo "$output" | LC_ALL=C grep -q $'\033\['
}

# ---------- AC10: width-ladder — bar survives narrow COLS, branch dropped ----

@test "E82-S9 / AC10: COLUMNS<50 keeps bar, drops branch" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  stdin="$(_stdin_with_context 50 1000)"
  run bash -c "COLUMNS=45 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x printf '%s' '$stdin' | env COLUMNS=45 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q "#####-----"
  ! echo "$stripped" | grep -q "feature/x"
}

# ---------- AC9: extended-context (1M) — still 10-char percentage bar -----

@test "E82-S9 / AC9: extended-context window still renders 10-char bar (percentage-based)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  # 1M-window model with 50% used.
  stdin='{"model":{"id":"opus-1m","display_name":"Opus 1M"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":50,"current_usage":500000,"context_window_size":1000000}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Still 10-char bar (5 filled, 5 empty), not 1,000,000-char.
  stripped="$(printf '%s' "$output" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g')"
  echo "$stripped" | grep -q "#####-----"
}
