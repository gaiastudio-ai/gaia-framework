#!/usr/bin/env bats
# derive-design-scope-diff.bats — per-project diff wrapper for scope derivation.
#
# Tests the derive-design-scope-diff.sh script that wraps the per-project
# manifest diff and the path classifier into one testable unit.
#
# Public functions covered: (script entry point, not a library)

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------

fail() { printf '%s\n' "$1" >&2; return 1; }

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _seed_last_published — write a design-last-published.json with both projects.
# Args: $1 = token_hash, $2 = component_hash, $3 = screen_hash
_seed_last_published() {
  local token_hash="${1:-aaa111}"
  local component_hash="${2:-bbb222}"
  local screen_hash="${3:-ccc333}"

  cat > "$TEST_TMP/design-last-published.json" <<EOF
{
  "design_system": {
    "last_published_at": "2026-01-01T00:00:00Z",
    "files": [
      {"path": "tokens/colors.html", "hash": "$token_hash"},
      {"path": "components/button.spec.html", "hash": "$component_hash"}
    ]
  },
  "product_design": {
    "last_published_at": "2026-01-01T00:00:00Z",
    "files": [
      {"path": "project/login.dc.html", "hash": "$screen_hash"}
    ]
  }
}
EOF
}

# _seed_local_manifest — write a local-manifest.json with spec paths and hashes.
# Args: key=value pairs like tokens/colors.html=abc123
_seed_local_manifest() {
  local first=1
  printf '{' > "$TEST_TMP/local-manifest.json"
  for pair in "$@"; do
    local key="${pair%%=*}"
    local val="${pair#*=}"
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ',' >> "$TEST_TMP/local-manifest.json"
    fi
    printf '"%s":"%s"' "$key" "$val" >> "$TEST_TMP/local-manifest.json"
  done
  printf '}' >> "$TEST_TMP/local-manifest.json"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DIFF_SCRIPT="$PLUGIN_ROOT/scripts/derive-design-scope-diff.sh"
  SCOPE_SCRIPT="$PLUGIN_ROOT/scripts/derive-design-scope.sh"
}

teardown() { common_teardown; }

# ===========================================================================
# Diff wrapper classification tests
# ===========================================================================

@test "token-only edit yields scope both at the driver call" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Seed last-published with known token hash
  _seed_last_published "old-token-hash" "bbb222" "ccc333"

  # Local manifest: token hash changed, everything else same
  _seed_local_manifest \
    "tokens/colors.html=new-token-hash" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444"

  # No screens were edited (no --edited), but rule (c) should trigger
  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (token rule (c)), got: $output"
}

@test "screen-only edit yields scope product-design" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Seed with matching hashes for design-system; screen exists in product_design
  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444"

  # Screen was edited
  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] || fail "expected product-design, got: $output"
}

@test "added screen yields scope product-design" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Last-published has no product_design entries for this screen
  _seed_last_published "aaa111" "bbb222" "ccc333"

  # Local manifest has a new screen not in product_design.files[]
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444" \
    "screens/signup.spec.html=eee555"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] || fail "expected product-design (added screen), got: $output"
}

@test "removed screen yields scope product-design" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Last-published has a screen that is NOT in the local manifest
  _seed_last_published "aaa111" "bbb222" "ccc333"

  # Local manifest omits screens/login.spec.html (it was removed)
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] || fail "expected product-design (removed screen), got: $output"
}

@test "components-only edit yields scope design-system" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Tokens unchanged, component hash changed, screen unchanged
  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-component-hash" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "design-system" ] || fail "expected design-system, got: $output"
}

@test "absent last-published file treated as empty" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "screens/login.spec.html=ddd444"

  # Pass /dev/null as the last-published baseline (everything is new)
  run bash "$DIFF_SCRIPT" \
    --last-published /dev/null \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (all specs are new), got: $output"
}

@test "output to classifier never contains a project/ path" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Set up a shim for derive-design-scope.sh that logs all arguments
  local shim_dir="$TEST_TMP/shim-bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/derive-design-scope.sh" <<'SHIMEOF'
#!/usr/bin/env bash
# Log all args to a file, then output "both" to satisfy the caller
for arg in "$@"; do
  printf '%s\n' "$arg"
done > "${SHIM_LOG_FILE}"
printf 'both\n'
SHIMEOF
  chmod +x "$shim_dir/derive-design-scope.sh"

  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=new-hash" \
    "screens/login.spec.html=ddd444"

  local shim_log="$TEST_TMP/shim-args.log"
  SHIM_LOG_FILE="$shim_log" \
    run env PATH="$shim_dir:$PATH" \
    bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ -f "$shim_log" ] || fail "shim log not created — the diff script did not call derive-design-scope.sh"

  # Assert no argument starts with "project/"
  local project_lines
  project_lines="$(grep -c '^project/' "$shim_log" || true)"
  [ "$project_lines" -eq 0 ] \
    || fail "classifier received $project_lines path(s) starting with project/ — must use spec-side paths"
}

@test "no changes yields scope both" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Everything matches — no changes
  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444"

  # No --edited, no hash changes for design-system, no added/removed screens
  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (no changes = no args to classifier), got: $output"
}
