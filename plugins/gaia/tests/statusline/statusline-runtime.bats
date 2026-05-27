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
  # Override HOME so the tier-1 plugin-cache scan defaults to empty unless a
  # fixture creates one. Without this, the runtime would resolve the
  # developer's real ~/.claude/plugins/cache/.../gaia/<latest>/ and shadow
  # the in-tree 9.9.9-test fixture used by these tests.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
  # Default stdin JSON (Claude Code statusLine contract).
  STDIN_JSON='{"model":{"id":"claude-opus-4-7","display_name":"Opus 4.7"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  export STDIN_JSON
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AF-2026-05-21-5 — fresh-install render path (fetcher present, cache absent)
#
# Regression coverage for the live repro on 2026-05-21: a second machine
# had the runtime + fetcher installed (statusline-update-check.sh present
# and executable) but no cache file yet (statusline-update-check.sh had
# never been invoked, so cache/latest-release.json did not exist). Under
# `set -u` the runtime aborted at line 191 dereferencing CACHE_TS before
# emitting any stdout, leaving Claude Code with nothing to render.
#
# The existing TC-3 above did not catch this because its fixture has no
# statusline-update-check.sh under $HOME, so the `[ -x "$_FETCHER" ]`
# gate at line 189 was false and execution skipped the buggy block. This
# new test installs a fetcher stub, leaves the cache absent, and asserts
# the runtime still renders cleanly.
# ---------------------------------------------------------------------------

@test "AF-2026-05-21-5: fresh install (fetcher present, cache absent) renders exit 0 with empty stderr" {
  [ -f "$RUNTIME" ]
  # Install a fetcher stub at the canonical path so the runtime's
  # `[ -x "$_FETCHER" ]` gate is true and control reaches the
  # CACHE_TS/AGE dereferences.
  mkdir -p "$HOME/.claude/gaia-statusline"
  cat > "$HOME/.claude/gaia-statusline/statusline-update-check.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$HOME/.claude/gaia-statusline/statusline-update-check.sh"
  # Cache file intentionally absent — this is the fresh-install state.
  [ ! -e "$HOME/.claude/gaia-statusline/cache/latest-release.json" ]
  cd "$TEST_TMP"
  run bash -c "printf '%s' '$STDIN_JSON' | '$RUNTIME' 2>/tmp/af-2026-05-21-5-stderr"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Runtime contract: NEVER emit to stderr (statusline.sh:9).
  [ ! -s /tmp/af-2026-05-21-5-stderr ]
  rm -f /tmp/af-2026-05-21-5-stderr
}

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
# Version-resolution chain (replaces the legacy CLAUDE_PLUGIN_ROOT-keyed
# lookup that produced the "GAIA dev" production bug). The full tier-by-tier
# matrix lives in statusline-version-resolution.bats; this file keeps a
# single drift-class assertion: the runtime MUST prefer the plugin cache's
# highest semver over the in-tree repo's plugin.json (the AF-2026-05-10
# v1.140.0/v1.141.0 drift class — when the in-tree repo lags the actively-
# loaded marketplace plugin, the statusline shows the active version).
# ---------------------------------------------------------------------------

@test "version: plugin cache (tier 1) overrides in-tree repo (tier 2) when both exist" {
  [ -f "$RUNTIME" ]
  # Setup put a tier-2 in-tree repo at 9.9.9-test. Add a tier-1 cache entry
  # with a different version under the test-overridden $HOME. The cache MUST
  # win. CLAUDE_PLUGIN_ROOT is left unset — the runtime no longer consults
  # it (Claude Code does not set it for the statusLine command, which was
  # the original "GAIA dev" production bug).
  CACHE_DIR="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/1.141.0-active/.claude-plugin"
  mkdir -p "$CACHE_DIR"
  cat > "$CACHE_DIR/plugin.json" <<'PJ'
{ "name": "gaia", "version": "1.141.0-active" }
PJ
  cd "$TEST_TMP"
  run bash -c "printf '%s' '$STDIN_JSON' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Must show the tier-1 cache version, NOT the tier-2 in-tree 9.9.9-test.
  echo "$output" | grep -q "1.141.0-active"
  ! echo "$output" | grep -q "9.9.9-test"
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

@test "TC-6: minimal theme does NOT read sprint-status.yaml (sprint-43 update)" {
  # sprint-43 update: rich is the runtime default; minimal is opt-OUT.
  # The original TC-6 contract ("default theme suppresses sprint") is now
  # served by the minimal-theme branch.
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "GAIA_STATUSLINE_THEME=minimal printf '%s' '$STDIN_JSON' | env GAIA_STATUSLINE_THEME=minimal '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "sprint-99"
}

@test "TC-6 (sprint-43): default theme NOW reads sprint-status.yaml (rich is default)" {
  # Companion to the TC-6 update — proves the new default behaviour.
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  run bash -c "printf '%s' '$STDIN_JSON' | '$RUNTIME'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sprint-99"
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

@test "E82-S8 / AC3 (AF-27-5): dirty chunk shows S/U +added/-removed line counts on line 2" {
  # AF-2026-05-27-5: the dirty marker is no longer a bare "*" — it shows per-class
  # line-change counts "S +<staged_add> -<staged_rem>  U +<unstaged_add> -<unstaged_rem>"
  # read from the cache fields written by statusline-git-dirty-check.sh.
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.142.0","update_available":false,"installed_version_stale":false,"git_dirty":true,"staged_added":30,"staged_removed":4,"unstaged_added":12,"unstaged_removed":3}
JSON
  run bash -c "HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x '$RUNTIME'"
  [ "$status" -eq 0 ]
  line2="$(echo "$output" | tail -1)"
  echo "$line2" | grep -q "feature/x"
  # branch | dirty-counts | project = two separators.
  sep_count=$(echo "$line2" | grep -o " | " | wc -l | tr -d ' ')
  [ "$sep_count" -ge 2 ]
  stripped="$(echo "$line2" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\\]*\\//g')"
  echo "$stripped" | grep -q "S +30 -4"
  echo "$stripped" | grep -q "U +12 -3"
  # The legacy standalone "*" chunk is gone.
  ! echo "$stripped" | grep -qE '\| \* \|'
}

@test "AF-27-5: dirty tree with no line diff (untracked-only) still shows +0 -0" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.142.0","update_available":false,"installed_version_stale":false,"git_dirty":true,"staged_added":0,"staged_removed":0,"unstaged_added":0,"unstaged_removed":0}
JSON
  run bash -c "HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(echo "$output" | tail -1 | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\\]*\\//g')"
  echo "$stripped" | grep -q "S +0 -0"
  echo "$stripped" | grep -q "U +0 -0"
}

@test "AF-27-5: counts absent from cache (legacy dirty=true) default to +0 -0" {
  [ -f "$RUNTIME" ]
  cd "$TEST_TMP"
  mkdir -p "$TEST_TMP/.claude/gaia-statusline/cache"
  # No staged_*/unstaged_* keys — backward-compat with an old cache.
  cat > "$TEST_TMP/.claude/gaia-statusline/cache/latest-release.json" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.142.0","update_available":false,"installed_version_stale":false,"git_dirty":true}
JSON
  run bash -c "HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x printf '%s' '$STDIN_JSON' | env HOME='$TEST_TMP' COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_BRANCH_OVERRIDE=feature/x '$RUNTIME'"
  [ "$status" -eq 0 ]
  stripped="$(echo "$output" | tail -1 | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\\]*\\//g')"
  echo "$stripped" | grep -q "S +0 -0"
  echo "$stripped" | grep -q "U +0 -0"
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

# ---------- model display-name: strip trailing context-window parenthetical ----
# The statusline shows just the model, not its context-window suffix (user req).
# "Opus 4.7 (1M context)" -> "Opus 4.7"; non-context parentheticals are kept.

_model_line() { # $1 = display_name ; prints stripped line 1 (no color)
  local dn="$1"
  local stdin
  stdin='{"model":{"id":"x","display_name":"'"$dn"'"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":20,"current_usage":100}}'
  run bash -c "COLUMNS=200 NO_COLOR=1 printf '%s' '$stdin' | env COLUMNS=200 NO_COLOR=1 '$RUNTIME'"
  [ "$status" -eq 0 ]
}

@test "model: strips '(1M context)' suffix -> shows bare model" {
  _model_line "Opus 4.7 (1M context)"
  echo "$output" | grep -q "Opus 4.7"
  ! echo "$output" | grep -q "1M context"
  ! echo "$output" | grep -qF "(1M"
}

@test "model: strips '(1M)' suffix" {
  _model_line "Opus 4.7 (1M)"
  echo "$output" | grep -q "Opus 4.7"
  ! echo "$output" | grep -qF "(1M)"
}

@test "model: strips '(200K context)' suffix" {
  _model_line "Sonnet 4.6 (200K context)"
  echo "$output" | grep -q "Sonnet 4.6"
  ! echo "$output" | grep -q "200K context"
}

@test "model: leaves a plain model name unchanged" {
  _model_line "Claude Opus 4.7"
  echo "$output" | grep -q "Claude Opus 4.7"
}

@test "model: leaves a NON-context parenthetical intact (e.g. '(preview)')" {
  _model_line "Opus 4.7 (preview)"
  echo "$output" | grep -qF "Opus 4.7 (preview)"
}

# ---------- AF-27-7: installed runtime self-heals from the plugin cache -----
# /plugin update refreshes only the plugin CACHE, never ~/.claude/gaia-statusline/.
# The runtime now self-heals: when run AS the installed copy and the cached
# runtime differs, it re-copies the runtime + helpers in place and stamps the
# .installed-version marker — so users get shipped fixes on the next render.

@test "AF-27-7: installed runtime re-copies a newer cache runtime + stamps marker" {
  [ -f "$RUNTIME" ]
  local install_dir="$HOME/.claude/gaia-statusline"
  local cache_scripts="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/1.180.3/scripts"
  mkdir -p "$install_dir/lib" "$cache_scripts/lib" \
           "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/1.180.3/.claude-plugin"
  printf '{ "name":"gaia","version":"1.180.3" }' > "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/1.180.3/.claude-plugin/plugin.json"
  # CACHE = real current runtime + helpers, with a trailing byte so it DIFFERS
  # from the installed copy (forces the self-heal trigger).
  cp "$RUNTIME" "$cache_scripts/statusline.sh"; printf '\n# newer\n' >> "$cache_scripts/statusline.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-colors.sh" "$cache_scripts/lib/statusline-colors.sh"
  cp "$PLUGIN_ROOT/scripts/lib/statusline-glyphs.sh" "$cache_scripts/lib/statusline-glyphs.sh" 2>/dev/null || true
  cp "$PLUGIN_ROOT/scripts/statusline-update-check.sh" "$PLUGIN_ROOT/scripts/statusline-git-dirty-check.sh" "$cache_scripts/" 2>/dev/null || true
  # INSTALLED = the current runtime (so it carries the self-heal logic) but a
  # STALE colors lib + NO marker.
  cp "$RUNTIME" "$install_dir/statusline.sh"; chmod +x "$install_dir/statusline.sh"
  printf 'STALE COLORS\n' > "$install_dir/lib/statusline-colors.sh"
  rm -f "$install_dir/.installed-version"
  # Run the INSTALLED runtime.
  run bash -c "printf '%s' '$STDIN_JSON' | env HOME='$HOME' COLUMNS=200 NO_COLOR=1 PROJECT_PATH='$PROJECT_PATH' '$install_dir/statusline.sh'"
  [ "$status" -eq 0 ]
  # Installed statusline now matches the cache copy.
  cmp -s "$install_dir/statusline.sh" "$cache_scripts/statusline.sh"
  # Stale lib was replaced with the real one.
  ! grep -q 'STALE COLORS' "$install_dir/lib/statusline-colors.sh"
  grep -q 'gradient_color' "$install_dir/lib/statusline-colors.sh"
  # Marker stamped with the active version.
  [ "$(cat "$install_dir/.installed-version" 2>/dev/null)" = "1.180.3" ]
}

@test "AF-27-7: dev/in-tree run (NOT the install dir) does NOT self-heal" {
  [ -f "$RUNTIME" ]
  local install_dir="$HOME/.claude/gaia-statusline"
  mkdir -p "$install_dir"
  rm -f "$install_dir/.installed-version" "$install_dir/statusline.sh"
  # Run the repo runtime directly (path is NOT under the install dir).
  run bash -c "printf '%s' '$STDIN_JSON' | env HOME='$HOME' COLUMNS=200 NO_COLOR=1 PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # No marker written, no install-dir runtime created by the dev run.
  [ ! -f "$install_dir/.installed-version" ]
  [ ! -f "$install_dir/statusline.sh" ]
}
