#!/usr/bin/env bats
# statusline-runtime.bats — runtime behavioural coverage.
#
# Story: E82-S1 — Statusline runtime + glyph helper + color helper + install.
#
# Covers TC-STATUSLINE-1, -2, -3, -4, -5, -6, -15.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNTIME="$PLUGIN_ROOT/scripts/statusline.sh"
  cd "$TEST_TMP"
  # Build a minimal fake project layout so the runtime can read plugin.json
  # and (rich theme) sprint-status.yaml without touching the real repo.
  mkdir -p gaia-public/plugins/gaia/.claude-plugin
  cat > gaia-public/plugins/gaia/.claude-plugin/plugin.json <<'PJ'
{ "name": "gaia", "version": "9.9.9-test" }
PJ
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'SS'
sprint_id: sprint-99
status: active
SS
  export PROJECT_PATH="$TEST_TMP"
  # Default stdin JSON (Claude Code statusLine contract).
  STDIN_JSON='{"model":{"id":"claude-opus-4-7","display_name":"Opus 4.7"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  export STDIN_JSON
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-STATUSLINE-3 / AT-2 — no-network + no-cache + no-git renders minimal one-liner
# ---------------------------------------------------------------------------

@test "TC-3: no-cache + no-git renders minimal one-liner exit 0 (AT-2)" {
  [ -f "$RUNTIME" ]
  # No cache file, no git ref.
  cd "$TEST_TMP"
  run bash -c "printf '%s' '$STDIN_JSON' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Brand glyph + GAIA + version + model + project segment.
  echo "$output" | grep -q "GAIA"
  echo "$output" | grep -q "9.9.9-test"
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-5 / AT-3 — ASCII flag → zero non-ASCII bytes
# ---------------------------------------------------------------------------

@test "TC-5: GAIA_STATUSLINE_ASCII=1 produces zero non-ASCII bytes (AT-3)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # LC_ALL=C grep -P '[^\x00-\x7F]' must NOT match (exit 1 from grep).
  echo "$output" | LC_ALL=C grep -P '[^\x00-\x7F]' && return 1
  return 0
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-4 — width ladder at 49 cols drops branch BEFORE project
# ---------------------------------------------------------------------------

@test "TC-4: width ladder at 49 cols drops branch before project" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  # Initialize a fake git ref via env override (runtime accepts GAIA_STATUSLINE_BRANCH_OVERRIDE for testability).
  run bash -c "COLUMNS=49 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/test printf '%s' '$STDIN_JSON' | env COLUMNS=49 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/test '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Branch segment must NOT be in output.
  ! echo "$output" | grep -q "feature/test"
}

@test "TC-4: width ladder at 80 cols keeps branch segment" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "COLUMNS=80 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/test printf '%s' '$STDIN_JSON' | env COLUMNS=80 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/test '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "feature/test"
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-6 — rich theme reads sprint-status.yaml; default does NOT
# ---------------------------------------------------------------------------

@test "TC-6: rich theme reads sprint-status.yaml" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "GAIA_STATUSLINE_THEME=rich printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_THEME=rich '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sprint-99"
}

@test "TC-6: default theme does NOT read sprint-status.yaml" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "printf '%s' '$STDIN_JSON' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "sprint-99"
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-15 — OSC-8 hyperlink only for iTerm.app/Kitty/WezTerm
# ---------------------------------------------------------------------------

@test "TC-15: OSC-8 emitted for TERM_PROGRAM=iTerm.app" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "TERM_PROGRAM=iTerm.app printf '%s' '$STDIN_JSON' | env TERM_PROGRAM=iTerm.app '$RUNTIME'"
  [ "$status" -eq 0 ]
  # OSC-8 sequence: ESC ] 8 ; ; URL ESC \ TEXT ESC ] 8 ; ; ESC \
  # Detect the bell-form OSC-8: ESC ] 8 (octal \033]8) anywhere.
  echo "$output" | LC_ALL=C grep -q $'\033\]8'
}

@test "TC-15: OSC-8 NOT emitted for TERM_PROGRAM=xterm-256color" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "TERM_PROGRAM=xterm-256color printf '%s' '$STDIN_JSON' | env TERM_PROGRAM=xterm-256color '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | LC_ALL=C grep -q $'\033\]8'
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-2 — subprocess inventory bounded
# ---------------------------------------------------------------------------

@test "TC-2: runtime source contains only allowed subprocess primitives" {
  [ -f "$RUNTIME" ]
  # Allowed inventory: jq, git, cat, tput. Plus shell builtins and standard
  # text utils (printf, grep, sed, tr, awk, head, tail, wc) which are
  # builtin-ish for our purposes. We assert the FORBIDDEN set is absent.
  ! grep -E '\bcurl\b|\bwget\b|\bnc[[:space:]]|\bgh\b' "$RUNTIME"
}

# ---------------------------------------------------------------------------
# TC-STATUSLINE-1 / AT-1 — p95 latency < 100ms across 200 renders, 300ms ceiling
# ---------------------------------------------------------------------------

@test "TC-1: 200 renders p95 < 100ms, max < 300ms (AT-1)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  # Use a python helper to compute p95 from per-render timings.
  python3 - <<PY
import json, os, subprocess, time, sys
runtime = "$RUNTIME"
stdin = '$STDIN_JSON'
times = []
for _ in range(200):
    t0 = time.monotonic()
    subprocess.run([runtime], input=stdin.encode(), stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    t1 = time.monotonic()
    times.append((t1 - t0) * 1000.0)
times.sort()
p95 = times[int(0.95 * len(times)) - 1]
mx = max(times)
print(f"p95={p95:.1f}ms max={mx:.1f}ms", file=sys.stderr)
sys.exit(0 if (p95 < 100.0 and mx < 300.0) else 1)
PY
}
