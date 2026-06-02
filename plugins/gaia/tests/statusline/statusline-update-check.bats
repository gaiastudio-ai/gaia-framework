#!/usr/bin/env bats
# statusline-update-check.bats — fetcher behavioural coverage.
#
# Story: E82-S2 — Background update-check fetcher.
#
# Covers TC-STATUSLINE-8, TC-STATUSLINE-10, and the AC suite for the fetcher.

load '../test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FETCHER="$PLUGIN_ROOT/scripts/statusline-update-check.sh"
  cd "$TEST_TMP"
  mkdir -p gaia-framework/plugins/gaia/.claude-plugin
  cat > gaia-framework/plugins/gaia/.claude-plugin/plugin.json <<'PJ'
{ "name": "gaia", "version": "1.0.0" }
PJ
  # Per-test HOME so we never touch the real ~/.claude.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude/gaia-statusline/cache"
  CACHE="$HOME/.claude/gaia-statusline/cache/latest-release.json"
  export CACHE
  export PROJECT_PATH="$TEST_TMP"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helper: install a stub `gh` and `curl` on PATH.
# Args: <gh-mode> <curl-mode>  where mode in {ok-equal, ok-newer, http-error,
# malformed-json, missing}. "missing" removes the binary from PATH (returns
# 127) so the script must fall through to the next option.
# ---------------------------------------------------------------------------
_make_stub() {
  local name="$1"; local mode="$2"; local stub_dir="$TEST_TMP/stubs"
  mkdir -p "$stub_dir"
  local stub="$stub_dir/$name"
  case "$mode" in
    ok-equal)
      cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"tag_name":"v1.0.0"}'
SH
      ;;
    ok-newer)
      cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"tag_name":"v2.0.0"}'
SH
      ;;
    http-error)
      cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '404 not found' >&2
exit 22
SH
      ;;
    malformed-json)
      cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s' '<<<not-json>>>'
SH
      ;;
    network-down)
      cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf 'could not resolve host' >&2
exit 6
SH
      ;;
    missing)
      rm -f "$stub"
      return 0
      ;;
  esac
  chmod +x "$stub"
}

_with_stubs() {
  # Build a sandboxed PATH: stubs first, then system bin for jq/sort/printf etc.
  STUBS_PATH="$TEST_TMP/stubs:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
  export STUBS_PATH
}

# ---------------------------------------------------------------------------
# AC: fetcher source exists and is executable
# ---------------------------------------------------------------------------

@test "fetcher: source file exists and is executable" {
  [ -f "$FETCHER" ]
  [ -x "$FETCHER" ]
}

# ---------------------------------------------------------------------------
# AC10 / NFR-STATUSLINE-3 — no /tmp/ paths in fetcher source
# ---------------------------------------------------------------------------

@test "fetcher: source contains zero /tmp/ write paths (NFR-STATUSLINE-3)" {
  [ -f "$FETCHER" ]
  # Allow the word `tmp` in comments, but NEVER `/tmp/` literal as a write path.
  run grep -E '/tmp/' "$FETCHER"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC1 — network unreachable: cache unchanged, exit 0, no stderr
# ---------------------------------------------------------------------------

@test "AC1: network unreachable -> cache absent stays absent, exit 0, silent" {
  _make_stub gh missing
  _make_stub curl network-down
  _with_stubs
  [ ! -e "$CACHE" ]
  # Use --separate-stderr to verify silence on stderr.
  run --separate-stderr env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ -z "${stderr:-}" ]
  [ ! -e "$CACHE" ]
}

@test "AC1: network unreachable + existing cache -> byte-identical pre/post" {
  _make_stub gh missing
  _make_stub curl network-down
  _with_stubs
  printf '%s\n' '{"checked_at_iso":"2026-04-01T00:00:00Z","latest_tag":"1.0.0","current_tag":"1.0.0","update_available":false}' > "$CACHE"
  before_sha="$(shasum "$CACHE" | awk '{print $1}')"
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  after_sha="$(shasum "$CACHE" | awk '{print $1}')"
  [ "$before_sha" = "$after_sha" ]
}

# ---------------------------------------------------------------------------
# AC2 — HTTP 4xx/5xx: cache unchanged, exit 0
# ---------------------------------------------------------------------------

@test "AC2: HTTP error from gh -> cache unchanged, exit 0 (TC-STATUSLINE-10)" {
  _make_stub gh http-error
  _make_stub curl http-error
  _with_stubs
  [ ! -e "$CACHE" ]
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ ! -e "$CACHE" ]
}

# ---------------------------------------------------------------------------
# AC3 — malformed JSON: cache unchanged, exit 0
# ---------------------------------------------------------------------------

@test "AC3: malformed JSON response -> cache unchanged, exit 0 (TC-STATUSLINE-10)" {
  _make_stub gh malformed-json
  _make_stub curl malformed-json
  _with_stubs
  [ ! -e "$CACHE" ]
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ ! -e "$CACHE" ]
}

# ---------------------------------------------------------------------------
# AC4 — plugin.json missing or unparseable: cache unchanged, exit 0
# ---------------------------------------------------------------------------

@test "AC4: plugin.json missing -> cache unchanged, exit 0" {
  _make_stub gh ok-newer
  _make_stub curl ok-newer
  _with_stubs
  rm -f gaia-framework/plugins/gaia/.claude-plugin/plugin.json
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ ! -e "$CACHE" ]
}

@test "AC4: plugin.json unparseable -> cache unchanged, exit 0" {
  _make_stub gh ok-newer
  _make_stub curl ok-newer
  _with_stubs
  printf 'not json' > gaia-framework/plugins/gaia/.claude-plugin/plugin.json
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ ! -e "$CACHE" ]
}

# ---------------------------------------------------------------------------
# AC5 — TTL guard (< 24h): no-op write
# ---------------------------------------------------------------------------

@test "AC5: TTL guard fresh cache -> checked_at_iso unchanged" {
  # sprint-43 update: TTL was 24h, now 30min. The seed must be fresher than
  # 30min for this test to still exercise the guard. Use 5 minutes ago.
  _make_stub gh ok-newer
  _make_stub curl ok-newer
  _with_stubs
  ts_recent="$(date -u -v-5M +%FT%TZ 2>/dev/null || date -u -d '5 minutes ago' +%FT%TZ)"
  printf '%s' '{"checked_at_iso":"'"$ts_recent"'","latest_tag":"1.0.0","current_tag":"1.0.0","update_available":false}' > "$CACHE"
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  after_ts="$(jq -r '.checked_at_iso' "$CACHE")"
  [ "$after_ts" = "$ts_recent" ]
}

@test "AC5: TTL guard stale cache (> 30min) -> writes new checked_at_iso" {
  _make_stub gh ok-newer
  _make_stub curl ok-newer
  _with_stubs
  # 48h ago -> stale.
  ts_old="$(date -u -v-48H +%FT%TZ 2>/dev/null || date -u -d '48 hours ago' +%FT%TZ)"
  printf '%s' '{"checked_at_iso":"'"$ts_old"'","latest_tag":"1.0.0","current_tag":"1.0.0","update_available":false}' > "$CACHE"
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  after_ts="$(jq -r '.checked_at_iso' "$CACHE")"
  [ "$after_ts" != "$ts_old" ]
  [ -n "$after_ts" ]
}

# ---------------------------------------------------------------------------
# AC6 — successful query: tags equal -> update_available=false
# ---------------------------------------------------------------------------

@test "AC6: successful fetch with equal tags -> update_available=false, latest_tag matches" {
  _make_stub gh ok-equal
  _make_stub curl ok-equal
  _with_stubs
  rm -f "$CACHE"
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  ua="$(jq -r '.update_available' "$CACHE")"
  lt="$(jq -r '.latest_tag' "$CACHE")"
  ct="$(jq -r '.current_tag' "$CACHE")"
  [ "$ua" = "false" ]
  [ "$lt" = "1.0.0" ]
  [ "$ct" = "1.0.0" ]
}

# ---------------------------------------------------------------------------
# AC7 — successful query: newer tag -> update_available=true
# ---------------------------------------------------------------------------

@test "AC7: successful fetch with newer remote tag -> update_available=true" {
  _make_stub gh ok-newer
  _make_stub curl ok-newer
  _with_stubs
  rm -f "$CACHE"
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  ua="$(jq -r '.update_available' "$CACHE")"
  lt="$(jq -r '.latest_tag' "$CACHE")"
  [ "$ua" = "true" ]
  [ "$lt" = "2.0.0" ]
}

# ---------------------------------------------------------------------------
# AC8 — atomic write under contention: well-formed JSON exactly one writer's payload
# ---------------------------------------------------------------------------

@test "AC8: concurrent invocation -> well-formed cache (TC-STATUSLINE-8)" {
  _make_stub gh ok-newer
  _make_stub curl ok-newer
  _with_stubs
  rm -f "$CACHE"
  # Run 5 concurrent invocations; wait for all.
  for i in 1 2 3 4 5; do
    env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER" &
  done
  wait
  # Cache must be well-formed JSON.
  [ -f "$CACHE" ]
  run jq -e '.' "$CACHE"
  [ "$status" -eq 0 ]
  # And contain the canonical schema keys.
  ua="$(jq -r '.update_available' "$CACHE")"
  lt="$(jq -r '.latest_tag' "$CACHE")"
  ts="$(jq -r '.checked_at_iso' "$CACHE")"
  [ "$ua" = "true" ]
  [ "$lt" = "2.0.0" ]
  [ -n "$ts" ]
  # No leftover sibling tempfiles in the cache dir.
  run bash -c "ls $HOME/.claude/gaia-statusline/cache/latest-release.json.* 2>/dev/null"
  [ -z "${output:-}" ]
}

# ---------------------------------------------------------------------------
# Fallback: gh missing -> curl path is exercised
# ---------------------------------------------------------------------------

@test "fallback: gh missing -> curl fallback writes cache successfully" {
  _make_stub gh missing
  _make_stub curl ok-newer
  _with_stubs
  rm -f "$CACHE"
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  lt="$(jq -r '.latest_tag' "$CACHE")"
  [ "$lt" = "2.0.0" ]
}

# ===========================================================================
# E82-S6 — installed_version_stale staleness detection (ADR-094).
#
# Tests a-g per Theo's compliance enumeration. All exercise the fetcher's
# new computation path (marker vs CLAUDE_PLUGIN_ROOT/plugin.json) and the
# additive cache field.
# ===========================================================================

# Helper: prepare a CLAUDE_PLUGIN_ROOT fixture with a given version.
_make_plugin_root() {
  local version="$1" dir="$TEST_TMP/active-plugin"
  mkdir -p "$dir/.claude-plugin"
  cat > "$dir/.claude-plugin/plugin.json" <<PJ
{ "name": "gaia", "version": "$version" }
PJ
  printf '%s' "$dir"
}

@test "E82-S6 / TC-a: fresh install marker matches active plugin version -> stale=false" {
  local proot
  proot="$(_make_plugin_root 1.142.0)"
  printf '1.142.0\n' > "$HOME/.claude/gaia-statusline/.installed-version"
  _make_stub gh ok-equal
  _make_stub curl ok-equal
  _with_stubs
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" CLAUDE_PLUGIN_ROOT="$proot" "$FETCHER"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  run jq -r '.installed_version_stale' "$CACHE"
  [ "$output" = "false" ]
}

@test "E82-S6 / TC-c: marker != active version -> stale=true" {
  local proot
  proot="$(_make_plugin_root 1.142.0)"
  printf '1.141.0\n' > "$HOME/.claude/gaia-statusline/.installed-version"
  _make_stub gh ok-equal
  _make_stub curl ok-equal
  _with_stubs
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" CLAUDE_PLUGIN_ROOT="$proot" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.installed_version_stale' "$CACHE"
  [ "$output" = "true" ]
}

@test "E82-S6 / TC-d: marker absent (first install bootstrap) -> stale=false" {
  local proot
  proot="$(_make_plugin_root 1.142.0)"
  rm -f "$HOME/.claude/gaia-statusline/.installed-version"
  _make_stub gh ok-equal
  _make_stub curl ok-equal
  _with_stubs
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" CLAUDE_PLUGIN_ROOT="$proot" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.installed_version_stale' "$CACHE"
  [ "$output" = "false" ]
}

@test "E82-S6 / TC-e: CLAUDE_PLUGIN_ROOT unset (dev/test mode) -> stale=false" {
  printf '1.141.0\n' > "$HOME/.claude/gaia-statusline/.installed-version"
  _make_stub gh ok-equal
  _make_stub curl ok-equal
  _with_stubs
  run env -u CLAUDE_PLUGIN_ROOT PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.installed_version_stale' "$CACHE"
  [ "$output" = "false" ]
}

@test "AF-27-7 / TC-d2: marker ABSENT but a real installed runtime exists -> stale=true" {
  # The reported bug class: a pre-marker install (runtime present, no
  # .installed-version) silently rotted across plugin updates because the old
  # rule read marker-absent as 'bootstrap -> false'. Now a real-but-unmarked
  # install reads as stale so the re-install nudge surfaces.
  local proot
  proot="$(_make_plugin_root 1.142.0)"
  rm -f "$HOME/.claude/gaia-statusline/.installed-version"
  # Distinguish from a true bootstrap: an installed runtime file IS present.
  mkdir -p "$HOME/.claude/gaia-statusline"
  printf '#!/usr/bin/env bash\n' > "$HOME/.claude/gaia-statusline/statusline.sh"
  _make_stub gh ok-equal
  _make_stub curl ok-equal
  _with_stubs
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" CLAUDE_PLUGIN_ROOT="$proot" "$FETCHER"
  [ "$status" -eq 0 ]
  run jq -r '.installed_version_stale' "$CACHE"
  [ "$output" = "true" ]
}

@test "E82-S6 / TC-g: cache field is always populated (writers contract)" {
  local proot
  proot="$(_make_plugin_root 1.142.0)"
  _make_stub gh ok-equal
  _make_stub curl ok-equal
  _with_stubs
  rm -f "$CACHE"
  run env PATH="$STUBS_PATH" HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" CLAUDE_PLUGIN_ROOT="$proot" "$FETCHER"
  [ "$status" -eq 0 ]
  # Field MUST exist (per ADR-091 amendment writers contract).
  run bash -c "jq -e 'has(\"installed_version_stale\")' '$CACHE'"
  [ "$status" -eq 0 ]
}
