#!/usr/bin/env bats
# statusline-refresh.bats — coverage for the FR-448 AC9 / E82-S12
# `/gaia-statusline-refresh` slash command.
#
# Story: E82-S12 (AF-2026-06-02-4).
#
# Covers TC-STATUSLINE-19 — three sub-branches:
#   (a) non-TTY refresh — install runs, marker bumps, stdout matches
#       canonical "refreshed runtime to <version>".
#   (b) cache-absent pre-flight — non-zero exit, canonical stderr.
#   (c) marker-matches idempotency — stdout matches "no-op (already at
#       <version>)" + cmp-only-if-different short-circuits.
#   (d) YOLO-independence — GAIA_YOLO_FLAG=1 produces byte-equivalent
#       behaviour to the non-YOLO case (explicit slash-command IS the
#       consent regardless of mode).
#
# The skill body lives inline in the SKILL.md `!`-block — to exercise it
# the test invokes the same bash code via the same ${CLAUDE_PLUGIN_ROOT}
# resolution path, so the production code path is what's exercised.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_DIR="$PLUGIN_ROOT/skills/gaia-statusline-refresh"
  cd "$TEST_TMP"
  # Sandbox HOME so every read/write under ~/.claude/ lands in tmpdir.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude/gaia-statusline/cache"
  # Set ${CLAUDE_PLUGIN_ROOT} to point at the in-tree plugin tree so the
  # SKILL.md !-block's `. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/..."` source
  # resolves correctly during the test.
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export GAIA_YOLO_FLAG=0
}

teardown() { common_teardown; }

# Helper — seed a fake plugin cache dir under HOME with a plugin.json
# carrying $1 as the version string AND a stub install-statusline.sh that
# bumps the marker + performs the cache reset.
_seed_plugin_cache() {
  local ver="$1"
  local cache_dir="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/$ver"
  mkdir -p "$cache_dir/.claude-plugin" "$cache_dir/scripts/lib"
  printf '{"version":"%s"}\n' "$ver" > "$cache_dir/.claude-plugin/plugin.json"
  # Stub installer: copies one fixed-content runtime file (so cmp-only-if-
  # different idempotency can be asserted), writes the marker, and exits 0.
  cat > "$cache_dir/scripts/install-statusline.sh" <<INSTALL
#!/usr/bin/env bash
mkdir -p "\$HOME/.claude/gaia-statusline"
runtime="\$HOME/.claude/gaia-statusline/statusline.sh"
if [ ! -e "\$runtime" ] || ! cmp -s <(printf '#!/usr/bin/env bash\necho stub %s\n' "$ver") "\$runtime"; then
  printf '#!/usr/bin/env bash\necho stub %s\n' "$ver" > "\$runtime"
  chmod +x "\$runtime"
fi
printf '%s\n' "$ver" > "\$HOME/.claude/gaia-statusline/.installed-version"
exit 0
INSTALL
  chmod +x "$cache_dir/scripts/install-statusline.sh"
}

_seed_marker() {
  printf '%s\n' "$1" > "$HOME/.claude/gaia-statusline/.installed-version"
}

# Helper — execute the SKILL.md !-block body. The body is reproduced here
# verbatim so the test exercises the same code the substrate runs from
# the skill bash block.
_run_refresh_skill() {
  bash -c '
    set -euo pipefail
    . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/statusline-plugin-cache-dir.sh"
    installer="$(_statusline_resolve_cached_install_script)"
    if [ -z "$installer" ]; then
      printf "gaia-statusline-refresh: no cached install-statusline.sh found under %s/<version>/scripts/ — install the marketplace plugin first via /plugin marketplace add gaiastudio-ai/gaia-framework\n" "$(_statusline_plugin_cache_dir)" >&2
      exit 1
    fi
    marker="$HOME/.claude/gaia-statusline/.installed-version"
    before=""
    if [ -r "$marker" ]; then
      before="$(head -n1 "$marker" 2>/dev/null | tr -d "[:space:]" || printf "")"
    fi
    bash "$installer" >/dev/null
    after=""
    if [ -r "$marker" ]; then
      after="$(head -n1 "$marker" 2>/dev/null | tr -d "[:space:]" || printf "")"
    fi
    if [ -n "$after" ] && [ "$before" = "$after" ]; then
      printf "gaia-statusline-refresh: no-op (already at %s)\n" "$after"
    elif [ -n "$after" ]; then
      printf "gaia-statusline-refresh: refreshed runtime to %s\n" "$after"
    else
      printf "gaia-statusline-refresh: refresh completed (marker unavailable — install-statusline.sh may have run from a checkout without plugin.json)\n"
    fi
  '
}

# ===========================================================================
# TC-STATUSLINE-19 (a): non-TTY refresh — install runs + marker bumps
# ===========================================================================

@test "TC-STATUSLINE-19 (a): non-TTY refresh runs install-statusline.sh + bumps marker + emits canonical message" {
  _seed_plugin_cache "1.184.0"
  _seed_marker "1.180.7"  # stale
  # bats `run` has no TTY by default — same context as Claude Code Bash tool.
  run _run_refresh_skill
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed runtime to 1.184.0"* ]]
  # Marker bumped to cached version.
  run cat "$HOME/.claude/gaia-statusline/.installed-version"
  [[ "$output" == *"1.184.0"* ]]
}

# ===========================================================================
# TC-STATUSLINE-19 (b): cache-absent pre-flight refusal
# ===========================================================================

@test "TC-STATUSLINE-19 (b): cache-absent exits non-zero with canonical stderr naming the missing path" {
  # No plugin cache seeded.
  _seed_marker "1.180.7"
  run _run_refresh_skill
  [ "$status" -ne 0 ]
  [[ "$output" == *"no cached install-statusline.sh found"* ]]
  [[ "$output" == *"gaiastudio-ai-gaia-framework/gaia"* ]]
  [[ "$output" == *"/plugin marketplace add gaiastudio-ai/gaia-framework"* ]]
}

@test "TC-STATUSLINE-19 (b): cache-dir-present-but-empty also exits non-zero (no semver subdir)" {
  # Cache dir exists but is empty — no semver-named subdirectories.
  mkdir -p "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia"
  _seed_marker "1.180.7"
  run _run_refresh_skill
  [ "$status" -ne 0 ]
  [[ "$output" == *"no cached install-statusline.sh found"* ]]
}

# ===========================================================================
# TC-STATUSLINE-19 (c): marker-matches idempotency
# ===========================================================================

@test "TC-STATUSLINE-19 (c): marker-matches → 'no-op (already at <version>)' message" {
  _seed_plugin_cache "1.184.0"
  _seed_marker "1.184.0"  # already at cached version
  run _run_refresh_skill
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op (already at 1.184.0)"* ]]
  # Marker unchanged.
  run cat "$HOME/.claude/gaia-statusline/.installed-version"
  [[ "$output" == *"1.184.0"* ]]
}

@test "TC-STATUSLINE-19 (c): marker-matches → runtime file mtime is not bumped (cmp-only-if-different)" {
  _seed_plugin_cache "1.184.0"
  _seed_marker "1.184.0"
  # Pre-seed the runtime to byte-match what the stub installer writes so
  # the cmp-only-if-different path triggers.
  printf '#!/usr/bin/env bash\necho stub %s\n' "1.184.0" > "$HOME/.claude/gaia-statusline/statusline.sh"
  chmod +x "$HOME/.claude/gaia-statusline/statusline.sh"
  local runtime="$HOME/.claude/gaia-statusline/statusline.sh"
  local before_mtime
  before_mtime="$(stat -f '%m' "$runtime" 2>/dev/null || stat -c '%Y' "$runtime")"
  sleep 1
  run _run_refresh_skill
  [ "$status" -eq 0 ]
  local after_mtime
  after_mtime="$(stat -f '%m' "$runtime" 2>/dev/null || stat -c '%Y' "$runtime")"
  [ "$before_mtime" = "$after_mtime" ]
}

# ===========================================================================
# TC-STATUSLINE-19 (d): YOLO-independence
# ===========================================================================

@test "TC-STATUSLINE-19 (d): GAIA_YOLO_FLAG=1 produces byte-equivalent behaviour (explicit slash IS consent)" {
  _seed_plugin_cache "1.184.0"
  _seed_marker "1.180.7"  # stale
  export GAIA_YOLO_FLAG=1
  run _run_refresh_skill
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed runtime to 1.184.0"* ]]
  run cat "$HOME/.claude/gaia-statusline/.installed-version"
  [[ "$output" == *"1.184.0"* ]]
}

# ===========================================================================
# SKILL.md authoring sanity checks (static)
# ===========================================================================

@test "SKILL.md exists at the canonical path and has required frontmatter" {
  [ -f "$SKILL_DIR/SKILL.md" ]
  grep -qE '^name: gaia-statusline-refresh$' "$SKILL_DIR/SKILL.md"
  grep -qE '^allowed-tools: \[Bash\]$' "$SKILL_DIR/SKILL.md"
}

@test "SKILL.md uses CLAUDE_PLUGIN_ROOT (not PLUGIN_DIR) per feedback_plugin_root_var_not_plugin_dir" {
  # The !-block MUST source the lib helper via CLAUDE_PLUGIN_ROOT.
  grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/lib/statusline-plugin-cache-dir.sh' "$SKILL_DIR/SKILL.md"
  # PLUGIN_DIR is NOT a substrate variable — it would silently expand
  # empty (memory rule feedback_plugin_root_var_not_plugin_dir). Forbid it.
  run grep -F '${PLUGIN_DIR}' "$SKILL_DIR/SKILL.md"
  [ "$status" -ne 0 ]
}

@test "SKILL.md documents the AC6 reconciliation explicitly (per Val F-01)" {
  grep -qF 'AC6 reconciliation' "$SKILL_DIR/SKILL.md"
  grep -qF 'MUST NOT invoke' "$SKILL_DIR/SKILL.md"
}

@test "SKILL.md documents the rejection of softer-confirm interpretation (per Val F-02)" {
  grep -qiE 'softer.*proceed|softer.*confirm|softer.*\[y/N\]|softer .this will overwrite' "$SKILL_DIR/SKILL.md"
}
