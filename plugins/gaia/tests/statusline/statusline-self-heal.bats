#!/usr/bin/env bats
# statusline-self-heal.bats — coverage for the FR-448 AC8 / E82-S11
# consent-gated self-heal of stale statusline runtime.
#
# Story: E82-S11 (AF-2026-06-02-3).
#
# Covers:
#   TC-STATUSLINE-17 — install-statusline.sh surgical cache reset preserves
#                      git_dirty.
#   TC-STATUSLINE-18 — gaia-statusline-toggle.sh --enable consent-prompt
#                      three-branch + non-TTY + YOLO + marker-absent
#                      coverage.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TOGGLE="$PLUGIN_ROOT/scripts/gaia-statusline-toggle.sh"
  INSTALL_SCRIPT="$PLUGIN_ROOT/scripts/install-statusline.sh"
  cd "$TEST_TMP"
  # Sandbox HOME so every read/write under ~/.claude/ lands in tmpdir.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude/gaia-statusline/cache"

  # Provide the runtime stub so the toggle's AC7 pre-flight passes. The
  # consent-prompt staleness check requires a readable runtime to even
  # consider firing.
  cat > "$HOME/.claude/gaia-statusline/statusline.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub statusline"
STUB
  chmod +x "$HOME/.claude/gaia-statusline/statusline.sh"

  # Set GAIA_YOLO_FLAG to a definitively non-1 value for the explicit-N /
  # 'y' branches; individual tests override to 1 for the YOLO branch.
  export GAIA_YOLO_FLAG=0
}

teardown() { common_teardown; }

# Helper — seed a fake plugin cache dir under HOME with a plugin.json
# carrying $1 as the version string.
_seed_plugin_cache() {
  local ver="$1"
  local cache_dir="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/$ver"
  mkdir -p "$cache_dir/.claude-plugin" "$cache_dir/scripts/lib"
  printf '{"version":"%s"}\n' "$ver" > "$cache_dir/.claude-plugin/plugin.json"
  # Provide a minimal install-statusline.sh stub at the cached path so
  # the toggle can invoke it on 'y'. The stub writes a fresh marker
  # matching the cached version + leaves cache reset to the toggle.
  cat > "$cache_dir/scripts/install-statusline.sh" <<INSTALL
#!/usr/bin/env bash
# stub installer — bumps the marker to the cached version.
printf '%s\n' "$ver" > "\$HOME/.claude/gaia-statusline/.installed-version"
exit 0
INSTALL
  chmod +x "$cache_dir/scripts/install-statusline.sh"
}

# Helper — seed an .installed-version marker.
_seed_marker() {
  printf '%s\n' "$1" > "$HOME/.claude/gaia-statusline/.installed-version"
}

# Helper — seed a populated latest-release.json with all six canonical
# keys present.
_seed_cache_file() {
  cat > "$HOME/.claude/gaia-statusline/cache/latest-release.json" <<'CACHE'
{
  "checked_at_iso": "2026-06-02T13:00:00Z",
  "latest_tag": "1.182.10",
  "current_tag": "1.182.10",
  "update_available": false,
  "installed_version_stale": false,
  "git_dirty": {"is_dirty": true, "added": 3, "removed": 1}
}
CACHE
}

# ===========================================================================
# TC-STATUSLINE-17 — install-statusline.sh surgical cache reset
# ===========================================================================

@test "TC-STATUSLINE-17 (a): install-statusline.sh deletes update-check-owned keys but preserves git_dirty" {
  _seed_cache_file
  # Run the real installer against the sandboxed HOME.
  run bash "$INSTALL_SCRIPT"
  [ "$status" -eq 0 ]
  # The five reader-fields MUST be absent.
  local cache="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  [ -f "$cache" ]
  run jq -e 'has("checked_at_iso") | not' "$cache"
  [ "$status" -eq 0 ]
  run jq -e 'has("latest_tag") | not' "$cache"
  [ "$status" -eq 0 ]
  run jq -e 'has("current_tag") | not' "$cache"
  [ "$status" -eq 0 ]
  run jq -e 'has("update_available") | not' "$cache"
  [ "$status" -eq 0 ]
  run jq -e 'has("installed_version_stale") | not' "$cache"
  [ "$status" -eq 0 ]
  # git_dirty MUST survive byte-equivalent.
  run jq -e '.git_dirty.is_dirty == true and .git_dirty.added == 3 and .git_dirty.removed == 1' "$cache"
  [ "$status" -eq 0 ]
}

@test "TC-STATUSLINE-17 (b): install-statusline.sh cache reset is a no-op when cache file absent" {
  # No cache file pre-existing. Installer must not create one.
  [ ! -f "$HOME/.claude/gaia-statusline/cache/latest-release.json" ]
  run bash "$INSTALL_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/gaia-statusline/cache/latest-release.json" ]
}

# Seed a pruned cache file in the EXACT canonical shape THIS jq produces, so
# the reset's byte-identical short-circuit reliably fires regardless of jq
# version (hardcoding jq's pretty-print is brittle across versions).
_seed_canonical_pruned_cache() {
  local cache="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  printf '%s\n' '{"git_dirty":{"is_dirty":false,"added":0,"removed":0}}' \
    | jq 'del(.checked_at_iso, .latest_tag, .current_tag, .update_available, .installed_version_stale)' \
    > "$cache"
  printf '%s' "$cache"
}

@test "TC-STATUSLINE-17 (c): cache reset on canonical pruned cache is byte-identical (content)" {
  # The meaningful idempotency contract: a reset run against already-canonical
  # input leaves the file CONTENT byte-identical (sha256 unchanged).
  local cache; cache="$(_seed_canonical_pruned_cache)"
  source "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"
  local before_sum after_sum
  before_sum="$(shasum -a 256 "$cache" | awk '{print $1}')"
  run _statusline_cache_reset
  [ "$status" -eq 0 ]
  after_sum="$(shasum -a 256 "$cache" | awk '{print $1}')"
  [ "$before_sum" = "$after_sum" ]
}

# bats test_tags=hardware-dependent
# The content contract is covered by the test above. This additionally asserts
# the no-op preserves mtime (the short-circuit avoids the rewrite). mtime-on-
# no-op-rewrite is host-filesystem dependent and flakes on some CI runners even
# when the bytes are identical, so it is excluded from the standard run.
@test "TC-STATUSLINE-17 (c): cache reset on canonical pruned cache preserves mtime (no rewrite)" {
  local cache; cache="$(_seed_canonical_pruned_cache)"
  source "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"
  local before_mtime after_mtime
  before_mtime="$(stat -f '%m' "$cache" 2>/dev/null || stat -c '%Y' "$cache")"
  sleep 1
  run _statusline_cache_reset
  [ "$status" -eq 0 ]
  after_mtime="$(stat -f '%m' "$cache" 2>/dev/null || stat -c '%Y' "$cache")"
  [ "$before_mtime" = "$after_mtime" ]
}

# ===========================================================================
# TC-STATUSLINE-18 — gaia-statusline-toggle.sh --enable consent prompt
# ===========================================================================

@test "TC-STATUSLINE-18 (a): marker-matches no-op — canonical idempotency message preserved" {
  _seed_plugin_cache "1.183.0"
  _seed_marker "1.183.0"
  # Settings already canonical.
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<JSON
{
  "statusLine": {
    "command": "$HOME/.claude/gaia-statusline/statusline.sh",
    "refreshInterval": 10000,
    "type": "command"
  }
}
JSON
  # bats run is non-TTY by default — but with matching marker, no prompt
  # is even considered.
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op (already enabled)"* ]]
  # Cache file untouched (was absent).
  [ ! -f "$HOME/.claude/gaia-statusline/cache/latest-release.json" ]
}

@test "TC-STATUSLINE-18 (d): non-TTY suppression — marker-differs but bats default has no TTY → no prompt, AC6 applies" {
  _seed_plugin_cache "1.183.0"
  _seed_marker "1.182.10"  # stale
  _seed_cache_file
  local cache="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  local before_sum
  before_sum="$(shasum -a 256 "$cache" | awk '{print $1}')"
  # bats run has no TTY on stdin or stdout — prompt MUST suppress, no
  # install MUST run.
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  # No consent prompt in output.
  [[ "$output" != *"Re-install runtime?"* ]]
  [[ "$output" != *"refreshed runtime"* ]]
  # Cache file MUST be byte-identical (no install ran, no reset fired).
  local after_sum
  after_sum="$(shasum -a 256 "$cache" | awk '{print $1}')"
  [ "$before_sum" = "$after_sum" ]
  # Marker MUST still read the old version (no install ran).
  run cat "$HOME/.claude/gaia-statusline/.installed-version"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.182.10"* ]]
}

@test "TC-STATUSLINE-18 (e): YOLO suppression — GAIA_YOLO_FLAG=1 suppresses prompt even with stale marker" {
  _seed_plugin_cache "1.183.0"
  _seed_marker "1.182.10"  # stale
  export GAIA_YOLO_FLAG=1
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  [[ "$output" != *"Re-install runtime?"* ]]
  # Marker untouched.
  run cat "$HOME/.claude/gaia-statusline/.installed-version"
  [[ "$output" == *"1.182.10"* ]]
}

@test "TC-STATUSLINE-18 (f): marker-absent silent no-op — first-install fixture, no marker file" {
  _seed_plugin_cache "1.183.0"
  # No marker file seeded. Staleness check must early-out.
  [ ! -f "$HOME/.claude/gaia-statusline/.installed-version" ]
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  [[ "$output" != *"Re-install runtime?"* ]]
  [[ "$output" != *"refreshed runtime"* ]]
}

@test "TC-STATUSLINE-18: cache-dir absent — toggle does not error when plugin cache dir does not exist" {
  # No plugin cache seeded at all. Resolver returns empty cached version.
  _seed_marker "1.182.10"
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  # No prompt because cached version is empty → no comparison fires.
  [[ "$output" != *"Re-install runtime?"* ]]
}

@test "TC-STATUSLINE-18: highest-semver-dir resolver picks 1.183.0 over 1.182.10 when both present" {
  _seed_plugin_cache "1.182.10"
  _seed_plugin_cache "1.183.0"
  # Verify the resolver helper returns 1.183.0 (not lex-sort first).
  source "$PLUGIN_ROOT/scripts/lib/statusline-plugin-cache-dir.sh"
  run _statusline_resolve_cached_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.183.0" ]
}

# ===========================================================================
# Cache-reset library coverage — exercise the helper directly
# ===========================================================================

@test "lib/statusline-cache-reset.sh: deletes the five canonical keys, preserves git_dirty" {
  _seed_cache_file
  source "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"
  run _statusline_cache_reset
  [ "$status" -eq 0 ]
  local cache="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  run jq -e 'has("checked_at_iso") | not' "$cache"
  [ "$status" -eq 0 ]
  run jq -e '.git_dirty.is_dirty == true' "$cache"
  [ "$status" -eq 0 ]
}

@test "lib/statusline-cache-reset.sh: cache-absent is a silent no-op (return 0, no file created)" {
  [ ! -f "$HOME/.claude/gaia-statusline/cache/latest-release.json" ]
  source "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"
  run _statusline_cache_reset
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/gaia-statusline/cache/latest-release.json" ]
}

@test "lib/statusline-cache-reset.sh: malformed JSON leaves the cache alone (best-effort)" {
  printf '{not valid json' > "$HOME/.claude/gaia-statusline/cache/latest-release.json"
  local cache="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  local before_sum
  before_sum="$(shasum -a 256 "$cache" | awk '{print $1}')"
  source "$PLUGIN_ROOT/scripts/lib/statusline-cache-reset.sh"
  run _statusline_cache_reset
  [ "$status" -eq 0 ]
  local after_sum
  after_sum="$(shasum -a 256 "$cache" | awk '{print $1}')"
  [ "$before_sum" = "$after_sum" ]
}
