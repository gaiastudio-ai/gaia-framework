#!/usr/bin/env bats
# statusline-version-resolution.bats — three-tier version resolution.
#
# Replaces the broken CLAUDE_PLUGIN_ROOT-keyed lookup that produced "GAIA dev"
# in production. The new resolution chain is: (1) plugin cache scan,
# (2) in-tree repo, (3) literal "dev".

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNTIME="$PLUGIN_ROOT/scripts/statusline.sh"
  cd "$TEST_TMP"
  # Override $HOME so the tier-1 cache scan looks at our fixture, not the
  # developer's real ~/.claude/plugins/cache/.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
  export PROJECT_PATH="$TEST_TMP"
}
teardown() { common_teardown; }

_make_cache_version() {
  local version="$1"
  local dir="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/$version/.claude-plugin"
  mkdir -p "$dir"
  cat > "$dir/plugin.json" <<EOF
{ "name": "gaia", "version": "$version" }
EOF
}

_make_in_tree_repo() {
  local version="$1"
  local dir="$PROJECT_PATH/gaia-public/plugins/gaia/.claude-plugin"
  mkdir -p "$dir"
  cat > "$dir/plugin.json" <<EOF
{ "name": "gaia", "version": "$version" }
EOF
}

_stdin() {
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"current_dir":"%s"}}' \
    "$TEST_TMP"
}

# ---- Tier 1: plugin cache scan -------------------------------------------

@test "tier 1: single cached version is rendered" {
  _make_cache_version "1.145.0"
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA 1.145.0"* ]]
  [[ "$output" != *"GAIA dev"* ]]
}

@test "tier 1: highest semver wins when multiple versions are cached" {
  _make_cache_version "1.140.0"
  _make_cache_version "1.144.0"
  _make_cache_version "1.145.0"
  _make_cache_version "1.142.0"
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA 1.145.0"* ]]
  [[ "$output" != *"1.144.0"* ]]
  [[ "$output" != *"1.142.0"* ]]
  [[ "$output" != *"1.140.0"* ]]
}

@test "tier 1: non-semver subdirectories are ignored" {
  # A stray non-semver dir (e.g., a backup, a .DS_Store, a partially-
  # extracted archive) MUST NOT confuse version selection.
  _make_cache_version "1.145.0"
  mkdir -p "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/.tmp-extract"
  mkdir -p "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/backup-2026-05-12"
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA 1.145.0"* ]]
}

# ---- Tier 2: in-tree repo fallback ---------------------------------------

@test "tier 2: in-tree repo wins when cache is empty" {
  _make_in_tree_repo "9.9.9-dev"
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA 9.9.9-dev"* ]]
}

@test "tier 1 takes precedence over tier 2 when both exist" {
  _make_cache_version "1.145.0"
  _make_in_tree_repo "9.9.9-dev"
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA 1.145.0"* ]]
  [[ "$output" != *"9.9.9-dev"* ]]
}

# ---- Tier 3: last-resort "dev" literal -----------------------------------

@test "tier 3: empty cache and no in-tree repo renders dev" {
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA dev"* ]]
}

# ---- CLAUDE_PLUGIN_ROOT must NOT influence resolution --------------------

@test "CLAUDE_PLUGIN_ROOT is intentionally ignored — must not poison resolution" {
  # The original bug: CLAUDE_PLUGIN_ROOT was the tier-1 key, but Claude Code
  # never sets it for the statusLine command. The new resolution chain MUST
  # NOT regress to consulting it. Setting a bogus value MUST NOT change the
  # outcome.
  _make_cache_version "1.145.0"
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' CLAUDE_PLUGIN_ROOT='/nonexistent/bogus/path' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$PROJECT_PATH' CLAUDE_PLUGIN_ROOT='/nonexistent/bogus/path' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA 1.145.0"* ]]
  [[ "$output" != *"GAIA dev"* ]]
}
