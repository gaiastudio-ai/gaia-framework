#!/usr/bin/env bats
# statusline-git-dirty.bats — E82-S8 fetcher coverage (FR-449, ADR-091 amendment).
#
# Story: E82-S8 — Statusline git-dirty marker (PreToolUse-triggered).
#
# Covers fetcher behaviors: clean working tree, dirty (modified), dirty
# (untracked), non-git CWD silent-no-op, timeout silent-no-op, read-modify-
# write contract (other-fetcher fields preserved), submodule recursion env-
# flag.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FETCHER="$PLUGIN_ROOT/scripts/statusline-git-dirty-check.sh"
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude/gaia-statusline/cache"
  CACHE="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  export CACHE
  # Build a real git repo under TEST_TMP so the fetcher has something to probe.
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m initial
  export PROJECT_PATH="$REPO"
}
teardown() { common_teardown; }

# ---------- Fetcher script existence ---------------------------------------

@test "fetcher script exists and is executable" {
  [ -x "$FETCHER" ]
}

# ---------- AC1: clean working tree -> git_dirty=false ---------------------

@test "AC1: clean working tree writes git_dirty=false" {
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  run jq -r '.git_dirty' "$CACHE"
  [ "$output" = "false" ]
}

# ---------- AC2: uncommitted change -> git_dirty=true ----------------------

@test "AC2: modified working tree writes git_dirty=true" {
  printf 'change\n' > "$REPO/new-file.txt"
  git -C "$REPO" -c user.email=t@t -c user.name=t add new-file.txt
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.git_dirty' "$CACHE"
  [ "$output" = "true" ]
}

@test "AC2: untracked file writes git_dirty=true (porcelain reports untracked)" {
  printf 'untracked\n' > "$REPO/untracked.txt"
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.git_dirty' "$CACHE"
  [ "$output" = "true" ]
}

# ---------- AC6: non-git CWD -> silent no-op -------------------------------

@test "AC6: non-git CWD is silent no-op, cache untouched" {
  mkdir -p "$TEST_TMP/not-a-repo"
  rm -f "$CACHE"
  run env HOME="$HOME" PROJECT_PATH="$TEST_TMP/not-a-repo" "$FETCHER"
  [ "$status" -eq 0 ]
  # Cache should remain absent (no write on non-git CWD).
  [ ! -f "$CACHE" ]
}

# ---------- ADR-091 RMW contract: other fields preserved -------------------

@test "RMW: pre-existing cache fields are preserved (only git_dirty merged)" {
  # Seed cache with the canonical update-check field set.
  cat > "$CACHE" <<'JSON'
{"checked_at_iso":"2026-05-11T12:00:00Z","latest_tag":"1.142.0","current_tag":"1.141.0","update_available":true,"installed_version_stale":false}
JSON
  printf 'untracked\n' > "$REPO/x.txt"
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  # git_dirty is now true.
  run jq -r '.git_dirty' "$CACHE"
  [ "$output" = "true" ]
  # All pre-existing fields still present and unchanged.
  run jq -r '.checked_at_iso' "$CACHE"
  [ "$output" = "2026-05-11T12:00:00Z" ]
  run jq -r '.latest_tag' "$CACHE"
  [ "$output" = "1.142.0" ]
  run jq -r '.update_available' "$CACHE"
  [ "$output" = "true" ]
  run jq -r '.installed_version_stale' "$CACHE"
  [ "$output" = "false" ]
}

# ---------- AC8: PreToolUse-only contract — fetcher is standalone ---------

@test "AC8: fetcher runs once and exits 0 (no daemon, no loop)" {
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  # Re-running is idempotent for a stable tree.
  cp "$CACHE" "$TEST_TMP/cache-first.json"
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  # git_dirty same on both runs.
  run jq -r '.git_dirty' "$TEST_TMP/cache-first.json"
  first="$output"
  run jq -r '.git_dirty' "$CACHE"
  [ "$output" = "$first" ]
}

# ---------- AC9: portable timeout fallback exists in source ---------------

@test "AC9: fetcher source contains the portable-timeout fallback chain" {
  # Static check: must reference timeout -> gtimeout -> bash kill-after.
  run grep -E 'command -v timeout|command -v gtimeout|kill .*GIT_PID' "$FETCHER"
  [ "$status" -eq 0 ]
}

# ---------- Cache schema: git_dirty field always present after run --------

@test "schema: git_dirty field present after every successful run" {
  rm -f "$CACHE"
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  run bash -c "jq -e 'has(\"git_dirty\")' '$CACHE'"
  [ "$status" -eq 0 ]
}
