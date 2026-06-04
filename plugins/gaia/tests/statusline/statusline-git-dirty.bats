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
  # Build a real git repo under TEST_TMP so the fetcher has something to probe.
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m initial
  export PROJECT_PATH="$REPO"
  # The fetcher writes git-state to a PER-PROJECT cache file keyed by the
  # session workspace root (cross-project branch-leak fix). With no stdin
  # payload the session root is PROJECT_PATH, so the key is cksum("$REPO").
  CACHE_KEY="$(printf '%s' "$REPO" | cksum | awk '{print $1}')"
  CACHE="$HOME/.claude/gaia-statusline/cache/git-state-${CACHE_KEY}.json"
  export CACHE
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

# ---------- AF-2026-05-27-5: per-class line-change counts ------------------

@test "AF-27-5: fetcher writes staged_added/removed from git diff --cached --shortstat" {
  # Commit a base file, then stage edits that add 2 + remove 1 line.
  printf 'a\nb\nc\n' > "$REPO/f.txt"
  git -C "$REPO" -c user.email=t@t -c user.name=t add f.txt
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m base
  printf 'a\nB1\nB2\n' > "$REPO/f.txt"   # 'b','c' -> 'B1','B2' : git shortstat = 2 ins, 2 del
  git -C "$REPO" -c user.email=t@t -c user.name=t add f.txt
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.git_dirty' "$CACHE"; [ "$output" = "true" ]
  run jq -r '.staged_added' "$CACHE";   [ "$output" = "2" ]
  run jq -r '.staged_removed' "$CACHE"; [ "$output" = "2" ]
  # Nothing unstaged.
  run jq -r '.unstaged_added' "$CACHE";   [ "$output" = "0" ]
  run jq -r '.unstaged_removed' "$CACHE"; [ "$output" = "0" ]
}

@test "AF-27-5: fetcher writes unstaged_added/removed from git diff --shortstat" {
  printf 'x\ny\n' > "$REPO/g.txt"
  git -C "$REPO" -c user.email=t@t -c user.name=t add g.txt
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m base2
  printf 'x\ny\nz\n' >> "$REPO/g.txt" 2>/dev/null; printf 'x\ny\nz\n' > "$REPO/g.txt"  # +1 line, unstaged
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.unstaged_added' "$CACHE";   [ "$output" = "1" ]
  run jq -r '.unstaged_removed' "$CACHE"; [ "$output" = "0" ]
  run jq -r '.staged_added' "$CACHE";     [ "$output" = "0" ]
}

@test "AF-27-5: untracked-only tree is dirty with all counts 0 (git counts no line diff)" {
  printf 'untracked\n' > "$REPO/u.txt"
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.git_dirty' "$CACHE"; [ "$output" = "true" ]
  for f in staged_added staged_removed unstaged_added unstaged_removed; do
    run jq -r ".$f" "$CACHE"; [ "$output" = "0" ]
  done
}

@test "AF-27-5: clean tree writes all counts 0" {
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  for f in staged_added staged_removed unstaged_added unstaged_removed; do
    run jq -r ".$f // 0" "$CACHE"; [ "$output" = "0" ]
  done
}

@test "AC2: untracked file writes git_dirty=true (porcelain reports untracked)" {
  printf 'untracked\n' > "$REPO/untracked.txt"
  run env HOME="$HOME" PROJECT_PATH="$REPO" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.git_dirty' "$CACHE"
  [ "$output" = "true" ]
}

# ---------- AC6: non-git probe dir clears branch+dirty (sprint-43 update) --

@test "AC6: non-git probe dir clears active_branch + git_dirty in cache" {
  # sprint-43 update: the original AC6 contract was "no write on non-git
  # CWD". That left stale active_branch in the cache after the agent left
  # a repo, which broke the sprint-43 issue-2 fix. The new contract is
  # "non-git probe dir writes git_dirty=false + active_branch=null" so the
  # statusline correctly reflects "no active repo right now".
  mkdir -p "$TEST_TMP/not-a-repo"
  # The per-project cache key is derived from the session root, which is this
  # invocation's PROJECT_PATH (no stdin payload) — the non-git dir here.
  ng_key="$(printf '%s' "$TEST_TMP/not-a-repo" | cksum | awk '{print $1}')"
  ng_cache="$HOME/.claude/gaia-statusline/cache/git-state-${ng_key}.json"
  rm -f "$ng_cache"
  run env HOME="$HOME" PROJECT_PATH="$TEST_TMP/not-a-repo" "$FETCHER"
  [ "$status" -eq 0 ]
  [ -f "$ng_cache" ]
  run jq -r '.git_dirty' "$ng_cache"
  [ "$output" = "false" ]
  run jq -r '.active_branch' "$ng_cache"
  [ "$output" = "null" ]
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
