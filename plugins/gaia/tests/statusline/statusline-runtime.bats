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
# CLAUDE_PLUGIN_ROOT takes precedence over PROJECT_PATH for version read.
# Catches the v1.140.0/v1.141.0 drift class from AF-2026-05-10 — when the
# in-tree repo plugin.json lags the actively-loaded marketplace plugin, the
# statusline must show the *active* version.
# ---------------------------------------------------------------------------

@test "CLAUDE_PLUGIN_ROOT overrides PROJECT_PATH for version" {
  [ -f "$RUNTIME" ]
  # Build a second fake plugin tree representing the marketplace-installed
  # active plugin with a DIFFERENT version than the in-tree PROJECT_PATH tree.
  ACTIVE_PLUGIN_ROOT="$TEST_TMP/active-plugin"
  mkdir -p "$ACTIVE_PLUGIN_ROOT/.claude-plugin"
  cat > "$ACTIVE_PLUGIN_ROOT/.claude-plugin/plugin.json" <<'PJ'
{ "name": "gaia", "version": "1.141.0-active" }
PJ
  cd "$TEST_TMP"
  run bash -c "CLAUDE_PLUGIN_ROOT='$ACTIVE_PLUGIN_ROOT' printf '%s' '$STDIN_JSON' | env CLAUDE_PLUGIN_ROOT='$ACTIVE_PLUGIN_ROOT' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Must show the active-plugin version, NOT the in-tree 9.9.9-test version.
  echo "$output" | grep -q "1.141.0-active"
  ! echo "$output" | grep -q "9.9.9-test"
}

@test "CLAUDE_PLUGIN_ROOT unset → falls back to PROJECT_PATH" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  # Explicitly unset CLAUDE_PLUGIN_ROOT to prove the fallback path.
  run bash -c "unset CLAUDE_PLUGIN_ROOT; printf '%s' '$STDIN_JSON' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "9.9.9-test"
}

@test "CLAUDE_PLUGIN_ROOT set but plugin.json missing → falls back to PROJECT_PATH" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  # Point CLAUDE_PLUGIN_ROOT at a directory without a .claude-plugin subdir.
  EMPTY_ROOT="$TEST_TMP/empty-plugin"
  mkdir -p "$EMPTY_ROOT"
  run bash -c "CLAUDE_PLUGIN_ROOT='$EMPTY_ROOT' printf '%s' '$STDIN_JSON' | env CLAUDE_PLUGIN_ROOT='$EMPTY_ROOT' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Should fall back to PROJECT_PATH and show the in-tree version.
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

# ===========================================================================
# E82-S5 — Statusline smart-hiding (FR-447).
#
# Suppresses empty-string segments AND their leading separator. Composes
# orthogonally with the FR-433 width ladder.
# ===========================================================================

# Helper: assert no orphan-separator artifacts in $1.
# An orphan is `" |  | "` (double-separator from an empty middle chunk) or
# a trailing ` | ` at the end of the line.
assert_no_orphans() {
  local out="$1"
  [[ "$out" != *" |  | "* ]] || {
    echo "orphan double-separator in: $out" >&2
    return 1
  }
  [[ "$out" != *' | ' ]] || {
    echo "orphan trailing-separator in: $out" >&2
    return 1
  }
}

@test "E82-S5 / AC1: non-empty MODEL + PROJECT chunks render with separators (status quo)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "printf '%s' '$STDIN_JSON' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Default render contains GAIA brand AND at least one separator.
  echo "$output" | grep -q "GAIA"
  echo "$output" | grep -q " | "
}

@test "E82-S5 / AC2: empty PROJECT chunk produces no orphan separator" {
  [ -f "$RUNTIME" ]
  # Force PROJECT chunk to render empty by pointing at a project tree with no
  # recognizable markers. We override PROJECT_PATH to a fresh empty tmp dir
  # that has only the plugin.json (no docs/, no .git, no package.json).
  EMPTY_PROJ="$TEST_TMP/empty-proj"
  mkdir -p "$EMPTY_PROJ/gaia-public/plugins/gaia/.claude-plugin"
  cp gaia-public/plugins/gaia/.claude-plugin/plugin.json "$EMPTY_PROJ/gaia-public/plugins/gaia/.claude-plugin/plugin.json"
  STDIN_EMPTY='{"model":{"id":"claude-opus-4-7","display_name":"Opus 4.7"},"workspace":{"current_dir":"'"$EMPTY_PROJ"'"}}'
  run bash -c "PROJECT_PATH='$EMPTY_PROJ' printf '%s' '$STDIN_EMPTY' | env PROJECT_PATH='$EMPTY_PROJ' '$RUNTIME'"
  [ "$status" -eq 0 ]
  assert_no_orphans "$output"
}

@test "E82-S5 / AC3: narrow COLS + minimal segments — no orphans" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "COLUMNS=40 printf '%s' '$STDIN_JSON' | env COLUMNS=40 '$RUNTIME'"
  [ "$status" -eq 0 ]
  assert_no_orphans "$output"
}

@test "E82-S5 / AC3: wide COLS + minimal segments — no orphans" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "COLUMNS=200 printf '%s' '$STDIN_JSON' | env COLUMNS=200 '$RUNTIME'"
  [ "$status" -eq 0 ]
  assert_no_orphans "$output"
}

@test "E82-S5 / AC4: cache-absent update-indicator does not emit orphan separator" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  # Ensure no cache file exists (we never created one in setup).
  run bash -c "printf '%s' '$STDIN_JSON' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  assert_no_orphans "$output"
}

@test "E82-S5 / AC5: chunk containing '|' renders as-is (smart-hiding checks emptiness, not content)" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  STDIN_PIPE='{"model":{"id":"a","display_name":"A | B"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run bash -c "printf '%s' '$STDIN_PIPE' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "A | B"
}

@test "E82-S5 / smoke: very narrow COLS (only BRAND survives) has zero separators" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "COLUMNS=20 printf '%s' '$STDIN_JSON' | env COLUMNS=20 '$RUNTIME'"
  [ "$status" -eq 0 ]
  # At COLS<32 only BRAND survives the width ladder → no separator anywhere.
  [[ "$output" != *' | '* ]]
}

# Structural assertions for the defensive guards (FR-447 generalization).
# These ensure MODEL and PROJECT chunk assembly uses the composite
# `(KEEP_X eq 1) AND (chunk non-empty)` pattern that BRANCH and SPRINT
# already use on lines 234 and 237. The behavioural tests above pass
# regardless because current MODEL_NAME / PROJECT_NAME defaults backstop
# emptiness; the structural test guards against future regressions.

@test "E82-S5 / structural: MODEL chunk assembly includes non-empty guard" {
  [ -f "$RUNTIME" ]
  # Extract the MODEL assembly stanza — must include an `-n "$MODEL_CHUNK"` check.
  # Looks for either `[ -n "$MODEL_CHUNK" ]` or `[ -n "${MODEL_CHUNK}" ]`.
  run grep -E '(KEEP_MODEL.*-n.*MODEL_CHUNK|-n.*MODEL_CHUNK.*KEEP_MODEL|-n[[:space:]]*"\$\{?MODEL_CHUNK\}?")' "$RUNTIME"
  [ "$status" -eq 0 ]
}

@test "E82-S5 / structural: PROJECT chunk assembly includes non-empty guard" {
  [ -f "$RUNTIME" ]
  run grep -E '(KEEP_PROJECT.*-n.*PROJECT_CHUNK|-n.*PROJECT_CHUNK.*KEEP_PROJECT|-n[[:space:]]*"\$\{?PROJECT_CHUNK\}?")' "$RUNTIME"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# E82-S6 — Staleness WARN segment (ADR-094 Component 4).
# ===========================================================================

@test "E82-S6 / WARN: ASCII theme renders [stale: rerun install-statusline] when installed_version_stale=true" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  # Seed cache with installed_version_stale=true.
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.141.0","update_available":false,"installed_version_stale":true}
JSON
  # No prior per-day marker.
  run bash -c "HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "stale: rerun install-statusline"
}

@test "E82-S6 / WARN: per-day suppression — second render same UTC day omits the warn segment" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.141.0","update_available":false,"installed_version_stale":true}
JSON
  # First render — should emit the warn.
  run bash -c "HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "stale: rerun install-statusline"
  # Second render same day — should NOT emit (per-day marker is now present).
  run bash -c "HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "stale: rerun install-statusline"
}

@test "E82-S6 / WARN: backward-compat — cache without installed_version_stale field does not emit warn" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  # Old-schema cache without the new field.
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.141.0","update_available":false}
JSON
  run bash -c "HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' GAIA_STATUSLINE_ASCII=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "stale:"
}

# ===========================================================================
# E82-S8 — Dirty glyph appended to BRANCH chunk when git_dirty=true.
# ===========================================================================

@test "E82-S8 / AC3: ASCII theme appends '*' to BRANCH when git_dirty=true" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.142.0","update_available":false,"installed_version_stale":false,"git_dirty":true}
JSON
  run bash -c "HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x '$RUNTIME'"
  [ "$status" -eq 0 ]
  # BRANCH chunk should be "@ feature/x*" with ASCII glyph + dirty marker.
  echo "$output" | grep -q "feature/x\*"
}

@test "E82-S8 / AC3: git_dirty=false leaves BRANCH chunk clean" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.142.0","update_available":false,"installed_version_stale":false,"git_dirty":false}
JSON
  run bash -c "HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Branch should be "feature/x" with NO trailing asterisk (other asterisks
  # may appear elsewhere, e.g., GLYPH_SPARK).
  echo "$output" | grep -q "feature/x"
  ! echo "$output" | grep -q "feature/x\*"
}

@test "E82-S8 / AC4: detached HEAD (BRANCH empty) -> no dirty marker leaks" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.142.0","update_available":false,"installed_version_stale":false,"git_dirty":true}
JSON
  # Empty branch override means BRANCH is empty -> smart-hiding suppresses chunk.
  run bash -c "HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE='' printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE='' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # No branch glyph anywhere — and no stray dirty marker leaking elsewhere.
  ! echo "$output" | grep -q "@ "
}

@test "E82-S8 / backward-compat: cache without git_dirty field -> no marker" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.142.0","update_available":false}
JSON
  run bash -c "HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "feature/x\*"
}
