#!/usr/bin/env bats
# statusline-rate-limits.bats — rate-limits chunk coverage (FR-451 + AF-27-5
# redesign).
#
# Rich-theme-only. Reads `.rate_limits.{five_hour,seven_day}.{used_percentage,
# resets_at}` from stdin. Renders ONE gradient-colored segment per present
# window: `5h:23% (2h13m)  7d:63% (4d2h)`. resets_at is Unix epoch seconds; the
# parenthetical is the adaptive countdown until reset (<1h "47m", 1-24h
# "2h13m", >24h "4d2h", <=0 "now"). resets_at absent on a present window ->
# no parens. Window absent -> omitted. rate_limits absent -> no chunk.

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
  NOW="$(date +%s)"
}
teardown() { common_teardown; }

# Build stdin JSON with given rate-limit percentages and OPTIONAL reset deltas
# (seconds-from-now). Use "null" to omit a window's percentage; use "" to omit
# only the resets_at on a present window.
#   $1 5h pct ; $2 5h reset-delta-s ; $3 7d pct ; $4 7d reset-delta-s
_stdin_rl() {
  local h5="$1" h5d="$2" d7="$3" d7d="$4" five="" seven="" frag=""
  if [ "$h5" != "null" ]; then
    if [ -n "$h5d" ]; then five="{\"used_percentage\":$h5,\"resets_at\":$(( NOW + h5d ))}"
    else five="{\"used_percentage\":$h5}"; fi
  fi
  if [ "$d7" != "null" ]; then
    if [ -n "$d7d" ]; then seven="{\"used_percentage\":$d7,\"resets_at\":$(( NOW + d7d ))}"
    else seven="{\"used_percentage\":$d7}"; fi
  fi
  if [ -n "$five" ] && [ -n "$seven" ]; then
    frag=",\"rate_limits\":{\"five_hour\":$five,\"seven_day\":$seven}"
  elif [ -n "$five" ]; then
    frag=",\"rate_limits\":{\"five_hour\":$five}"
  elif [ -n "$seven" ]; then
    frag=",\"rate_limits\":{\"seven_day\":$seven}"
  fi
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"current_dir":"%s"}%s}' \
    "$TEST_TMP" "$frag"
}

_strip_sgr() { printf '%s' "$1" | LC_ALL=C sed -E $'s/\033\\[[0-9;]*m//g'; }

_run_rich() { # $1 = stdin
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor printf '%s' '$1' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich COLORTERM=truecolor '$RUNTIME'"
  [ "$status" -eq 0 ]
}

# ---------- format: two per-window segments with reset countdown -----------

@test "AC1: both windows render as 5h:<pct>% (<reset>)  7d:<pct>% (<reset>)" {
  _run_rich "$(_stdin_rl 23 $((2*3600+13*60)) 63 $((4*86400+2*3600)))"
  stripped="$(_strip_sgr "$output")"
  # Assert the percentage + that a parenthesised countdown of the right SHAPE is
  # present, not the exact minute. The countdown is computed as resets_at - now;
  # a single second ticking between the fixture stamping resets_at and the
  # runtime reading `date +%s` flips 2h13m -> 2h12m, which made an exact-string
  # match flake (even locally). The unit shape (Nh Nm / Nd Nh) is the stable
  # contract.
  echo "$stripped" | grep -qE "5h:23% \([0-9]+h[0-9]+m\)"
  echo "$stripped" | grep -qE "7d:63% \([0-9]+d[0-9]+h\)"
  # The legacy combined "RL: x%/y%" form is gone.
  ! echo "$stripped" | grep -q "RL:"
  ! echo "$stripped" | grep -q "23%/63%"
}

# ---------- per-window gradient color (NOT a shared max-band) --------------

@test "AC2: each window % is gradient-colored by its OWN value" {
  # 5h=23 (green-dominant) and 7d=63 (amber) produce DIFFERENT fg escapes —
  # proving per-window gradient, not one shared max-band color.
  _run_rich "$(_stdin_rl 23 7980 63 352800)"
  c5="$(printf '%s' "$output" | LC_ALL=C grep -oE $'\033\\[38;2;[0-9;]+m5h:' | head -1)"
  c7="$(printf '%s' "$output" | LC_ALL=C grep -oE $'\033\\[38;2;[0-9;]+m7d:' | head -1)"
  [ -n "$c5" ]
  [ -n "$c7" ]
  [ "$c5" != "$c7" ]
}

@test "AC2: a low-pct window is green-dominant; a high-pct window is red-dominant" {
  _run_rich "$(_stdin_rl 5 7980 95 352800)"
  # 5% -> near green endpoint (G channel in the 200s).
  printf '%s' "$output" | LC_ALL=C grep -qE $'\033\\[38;2;[0-9]+;20[0-9];[0-9]+m5h:'
  # 95% -> near red endpoint (R high ~230, G low ~70s).
  printf '%s' "$output" | LC_ALL=C grep -qE $'\033\\[38;2;2[0-9][0-9];[0-9]+;[0-9]+m7d:'
}

# ---------- adaptive reset countdown ---------------------------------------

@test "reset <1h renders whole minutes (e.g. 47m)" {
  _run_rich "$(_stdin_rl 30 $((47*60)) null '')"
  stripped="$(_strip_sgr "$output")"
  # 47m delta; live elapsed seconds may shave to 46m — accept 46m or 47m.
  echo "$stripped" | grep -qE "5h:30% \((46|47)m\)"
}

@test "reset 1-24h renders NhNm (e.g. 2h13m)" {
  _run_rich "$(_stdin_rl 30 $((2*3600+13*60+30)) null '')"
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "5h:30% (2h13m)"
}

@test "reset >24h renders NdNh (e.g. 4d2h)" {
  _run_rich "$(_stdin_rl null '' 63 $((4*86400+2*3600+30*60)))"
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "7d:63% (4d2h)"
}

@test "reset already past renders (now)" {
  _run_rich "$(_stdin_rl null '' 91 -100)"
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "7d:91% (now)"
}

@test "present pct but resets_at MISSING -> no parens" {
  _run_rich "$(_stdin_rl 23 '' null '')"
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "5h:23%"
  ! echo "$stripped" | grep -q "5h:23% ("
}

# ---------- single-window + absence ----------------------------------------

@test "only 5h present -> single 5h segment, no 7d" {
  _run_rich "$(_stdin_rl 23 7980 null '')"
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "5h:23%"
  ! echo "$stripped" | grep -q "7d:"
}

@test "only 7d present -> single 7d segment, no 5h" {
  _run_rich "$(_stdin_rl null '' 41 352800)"
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "7d:41%"
  ! echo "$stripped" | grep -q "5h:"
}

@test "rate_limits entirely absent -> no RL segment at all" {
  _run_rich "$(_stdin_rl null '' null '')"
  stripped="$(_strip_sgr "$output")"
  ! echo "$stripped" | grep -qE "5h:|7d:"
}

# ---------- float percentage truncation ------------------------------------

@test "float used_percentage truncates to int" {
  # used_percentage may arrive as a float; the runtime truncates before the
  # percent is rendered. Assert on the RENDERED segment specifically — a bare
  # "23.5" substring check is fragile (it can match unrelated harness text in
  # some CI environments), so verify the segment shows the truncated "5h:23%"
  # and that the float-form segment "5h:23.5%" is NOT emitted.
  _run_rich "$(_stdin_rl 23.5 7980 null '')"
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "5h:23%"
  ! echo "$stripped" | grep -q "5h:23\.5"
}

# ---------- theme + width gating (unchanged contract) ----------------------

@test "minimal theme does NOT emit the rate-limits segment" {
  stdin="$(_stdin_rl 23 7980 41 352800)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=minimal printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=minimal '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qE "5h:|7d:"
}

@test "default theme (rich) DOES emit the rate-limits segment" {
  stdin="$(_stdin_rl 23 7980 41 352800)"
  run bash -c "COLUMNS=200 printf '%s' '$stdin' | env -u GAIA_STATUSLINE_THEME COLUMNS=200 '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "5h:|7d:"
}

@test "narrow COLS (<80) drops the rate-limits segment" {
  stdin="$(_stdin_rl 23 7980 41 352800)"
  run bash -c "COLUMNS=79 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=79 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qE "5h:|7d:"
}

@test "COLS >= 80 keeps the rate-limits segment" {
  stdin="$(_stdin_rl 23 7980 41 352800)"
  run bash -c "COLUMNS=80 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=80 GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(_strip_sgr "$output")"
  echo "$stripped" | grep -q "5h:23%"
  echo "$stripped" | grep -q "7d:41%"
}

# ---------- NO_COLOR strips the gradient escapes ---------------------------

@test "NO_COLOR -> segment text present, no SGR escapes" {
  stdin="$(_stdin_rl 23 7980 41 352800)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_THEME=rich NO_COLOR=1 printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_THEME=rich NO_COLOR=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "5h:23%"
  ! echo "$output" | LC_ALL=C grep -q $'\033\[38;2;'
}
