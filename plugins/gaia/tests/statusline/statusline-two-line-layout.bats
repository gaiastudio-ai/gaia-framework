#!/usr/bin/env bats
# statusline-two-line-layout.bats — sprint-43 two-line layout coverage.
#
# Layout:
#   Line 1: brand [update] [stale] | context-bar pct% [size] | model |
#           rate-limits | sprint
#   Line 2: branch | dirty | project   (suppressed when all three empty)
#
# Plus: gradient bar (green->yellow->red), inline percentage colored by band,
# grey size hint (200K / 1M), separate dirty chunk (not embedded in branch).

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
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
}
teardown() { common_teardown; }

_seed_cache() {
  # Seed the PER-PROJECT git-state cache with the given active_branch +
  # git_dirty. branch/dirty moved out of the shared latest-release.json into a
  # per-project git-state-<key>.json (keyed by the workspace root) to fix the
  # cross-project branch leak, so the fixture must write to the same per-project
  # file the runtime reads — keyed via the shared project-cache-key helper.
  local branch="$1" dirty="$2"
  local cache_dir="$HOME/.claude/gaia-statusline/cache"
  mkdir -p "$cache_dir"
  # shellcheck source=/dev/null
  . "$PLUGIN_ROOT/scripts/lib/statusline-project-cache-key.sh"
  local cache_file
  cache_file="$(_statusline_git_state_cache_file "$cache_dir" "$PROJECT_PATH")"
  if [ "$branch" = "null" ]; then
    cat > "$cache_file" <<EOF
{"active_branch": null, "git_dirty": $dirty}
EOF
  else
    cat > "$cache_file" <<EOF
{"active_branch": "$branch", "git_dirty": $dirty}
EOF
  fi
}

_render() {
  local stdin="$1"
  bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
}

# ---- 2-line emission -----------------------------------------------------

@test "two-line: line 1 brand, line 2 branch+dirty+project when cache has active_branch" {
  _seed_cache "feat/x" "true"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  # 2 lines (header + body)
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  [ "$line_count" = "2" ]
  # Line 1 has GAIA brand; line 2 has branch + dirty
  echo "$output" | head -1 | grep -q "GAIA"
  echo "$output" | tail -1 | grep -q "feat/x"
}

@test "two-line: line 2 suppressed entirely when branch+project empty (extreme degraded)" {
  # No branch in cache + project name is empty. Use PROJECT_PATH=/ so basename
  # gives just the empty-equivalent "/" — but actually basename / returns "/".
  # To make project truly empty we'd need to override; instead, narrow COLS so
  # KEEP_PROJECT=0 AND KEEP_BRANCH=0 (the <32 col tier).
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run bash -c "COLUMNS=30 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=30 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # Only one line (the brand-only tier at <32 cols).
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  [ "$line_count" = "1" ]
}

# ---- Active-branch cache wins over local git probe -----------------------

@test "branch: cache.active_branch wins over local git -C probe" {
  # Cache says "feat/from-cache"; PROJECT_PATH has no git repo so the local
  # probe would return empty. Cache takes precedence either way; this proves
  # the read happens.
  _seed_cache "feat/from-cache" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "feat/from-cache"
}

@test "branch: cache.active_branch=null falls back to local git probe (empty here)" {
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  # No branch should appear (TEST_TMP is not a git repo and cache is null).
  ! echo "$output" | grep -q "@ "
}

# ---- Dirty marker is its own chunk ---------------------------------------

@test "dirty: marker rendered as separate chunk between branch and project" {
  _seed_cache "main" "true"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  # Line 2 should have at least two " | " separators: branch | dirty | project.
  line2="$(echo "$output" | tail -1)"
  sep_count=$(echo "$line2" | grep -o " | " | wc -l | tr -d ' ')
  [ "$sep_count" -ge 2 ]
  # AF-2026-05-27-5: dirty chunk shows per-class line counts (the cache here has
  # no count fields, so they default to +0 -0). Marker is the S/U counts, not "*".
  stripped="$(echo "$line2" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\\]*\\//g')"
  echo "$stripped" | grep -q "S +0 -0"
  echo "$stripped" | grep -q "U +0 -0"
  ! echo "$stripped" | grep -qE '\| \* \|'
}

@test "dirty: marker suppressed when git_dirty=false" {
  _seed_cache "main" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  line2="$(echo "$output" | tail -1)"
  stripped="$(echo "$line2" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\\]*\\//g')"
  # No dirty chunk at all on a clean tree — no S/U counts.
  ! echo "$stripped" | grep -qE 'S \+|U \+'
}

# ---- Context-bar gradient + percentage + size hint ----------------------

@test "context-bar: inline percentage rendered" {
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":42,"current_usage":420000,"context_size":"1M"}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "42%"
}

@test "context-bar: size hint shows [1M] when context_window_size > 500000" {
  # sprint-43 schema update: Claude Code sends context_window_size as int.
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":50,"context_window_size":1000000,"current_usage":{"input_tokens":1,"output_tokens":2}}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[1M\]"
}

@test "context-bar: size hint shows [200K] when context_window_size <= 500000" {
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":50,"context_window_size":200000,"current_usage":{"input_tokens":1,"output_tokens":2}}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[200K\]"
}

@test "context-bar: 90% renders 9 filled cells in gradient" {
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":90,"current_usage":900000}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  # ASCII mode: 9 filled "#" and 1 empty "-"
  filled_count=$(echo "$output" | head -1 | grep -o "#" | wc -l | tr -d ' ')
  [ "$filled_count" -eq 9 ]
  empty_count=$(echo "$output" | head -1 | grep -o -- "-" | wc -l | tr -d ' ')
  # At least 1 empty cell; bash regex doesn't anchor so '-' inside "Opus" etc. wouldn't trigger here.
  [ "$empty_count" -ge 1 ]
}

@test "context-bar: 0% with current_usage non-null renders all-empty bar + 0%" {
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":0,"current_usage":0,"context_size":"200K"}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "0%"
  # No filled "#" cells in line 1.
  ! echo "$output" | head -1 | grep -q "#"
}

@test "context-bar: null used_percentage suppresses entire chunk" {
  # sprint-43 schema update: gate is now used_percentage (scalar 0..100) not
  # current_usage (which Claude Code sends as an object — would crash bash
  # arithmetic).
  _seed_cache "null" "false"
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"context_window":{"used_percentage":null}}'
  run _render "$stdin"
  [ "$status" -eq 0 ]
  ! echo "$output" | head -1 | grep -q "%"
}
