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

  # Set up a logging shim that records the args passed to the classifier.
  # The diff script honours _DERIVE_SCOPE_HELPER_OVERRIDE for testing.
  local shim_path="$TEST_TMP/scope-shim.sh"
  local shim_log="$TEST_TMP/shim-args.log"
  cat > "$shim_path" <<'SHIMEOF'
#!/usr/bin/env bash
for arg in "$@"; do
  printf '%s\n' "$arg"
done > "${SHIM_LOG_FILE}"
printf 'both\n'
SHIMEOF
  chmod +x "$shim_path"

  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=new-hash" \
    "screens/login.spec.html=ddd444"

  run env SHIM_LOG_FILE="$shim_log" \
    _DERIVE_SCOPE_HELPER_OVERRIDE="$shim_path" \
    bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ -f "$shim_log" ] || fail "shim log not created — the diff script did not call the classifier"

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

@test "screen name with space classifies correctly" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222" \
    "screens/Sign In.spec.html=fff666"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "screens/Sign In.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] || fail "expected product-design for screen with space, got: $output"
}

# ===========================================================================
# Hijack resistance: a decoy in CWD must not be executed
# ===========================================================================

@test "decoy derive-design-scope.sh in working directory is not executed" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found at $DIFF_SCRIPT"

  # Create a temp working directory with a decoy script
  local decoy_dir="$TEST_TMP/decoy-cwd"
  mkdir -p "$decoy_dir"
  cat > "$decoy_dir/derive-design-scope.sh" <<'DECOYEOF'
#!/usr/bin/env bash
printf 'HIJACKED\n'
DECOYEOF
  chmod +x "$decoy_dir/derive-design-scope.sh"

  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=new-hash" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444"

  # Run the diff script from the decoy directory
  run bash -c "cd '$decoy_dir' && bash '$DIFF_SCRIPT' \
    --last-published '$TEST_TMP/design-last-published.json' \
    --local-manifest '$TEST_TMP/local-manifest.json' \
    --edited 'screens/login.spec.html'"

  [ "$status" -eq 0 ]
  # The real classifier should run, not the decoy
  [ "$output" != "HIJACKED" ] \
    || fail "decoy script in CWD was executed — the helper must be called by absolute path"
  # The output should be a valid scope, not HIJACKED
  case "$output" in
    design-system|product-design|both) ;;
    *) fail "unexpected output: $output (expected a valid scope)" ;;
  esac
}

# ===========================================================================
# Path normalisation: ./ prefix and --spec-root on edited paths
# ===========================================================================

@test "dotslash edited screen with component change yields both" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp-hash" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "./screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (component + ./screen), got: $output"
}

@test "absolute edited screen under spec-root with component change yields both" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  local sr="$TEST_TMP/specroot"
  mkdir -p "$sr"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp-hash" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --spec-root "$sr" \
    --edited "$sr/screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (component + absolute screen), got: $output"
}

# ===========================================================================
# Flows handling
# ===========================================================================

@test "edited flow yields scope product-design" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444" \
    "flows/checkout.spec.html=eee555"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "flows/checkout.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] || fail "expected product-design for edited flow, got: $output"
}

@test "components-only edit with a flow spec in local yields design-system" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  # Flow exists in local manifest but was NOT edited. Flows have no
  # artboard mapping in the published record, so the diff script only
  # detects flow changes via --edited. A component-only edit with an
  # unedited flow must derive design-system, not both.
  _seed_last_published "aaa111" "bbb222" "ccc333"

  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp" \
    "screens/login.spec.html=ddd444" \
    "flows/checkout.spec.html=eee555"

  # Only component changed, flow exists but was NOT edited
  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "design-system" ] || fail "expected design-system (component-only, flow not edited), got: $output"
}

@test "removed design-system file yields design-system" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  # Local manifest is missing tokens/colors.html (it was removed)
  _seed_local_manifest \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (removed token triggers token rule), got: $output"
}

@test "removed component file yields design-system" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "design-system" ] || fail "expected design-system (removed component), got: $output"
}

# ===========================================================================
# Mutant resistance: ignoring edited flows or removed design-system files
# ===========================================================================

@test "mutant: ignoring edited flows changes the scope" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  # Setup: a flow is edited, no other changes. Should yield product-design.
  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444" \
    "flows/checkout.spec.html=eee555"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "flows/checkout.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "product-design" ] \
    || fail "original: edited flow should yield product-design, got: $output"

  # Mutant: same run without --edited. The flow is not tracked by artboard
  # mapping, so dropping --edited makes the diff script miss it. The scope
  # should change to 'both' (no changes = no args to classifier).
  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" != "product-design" ] \
    || fail "mutant: without --edited, flow should NOT yield product-design"
}

@test "mutant: ignoring removed design-system files changes the scope" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  # Setup: a component file is removed (in published but not in local)
  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "screens/login.spec.html=ddd444"
  # components/button.spec.html is absent from local

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" = "design-system" ] \
    || fail "original: removed component should yield design-system, got: $output"

  # Mutant: if we restore the component in the local manifest at the same
  # hash, no removal is detected, so the scope should change.
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=bbb222" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" != "design-system" ] \
    || fail "mutant: with component restored, scope should not be design-system"
}

# ===========================================================================
# Robustness: error handling
# ===========================================================================

@test "missing --local-manifest flag exits 2" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  run bash "$DIFF_SCRIPT" --last-published /dev/null
  [ "$status" -eq 2 ] || fail "expected exit 2 for missing --local-manifest, got: $status"
}

@test "nonexistent local-manifest file exits 2" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  run bash "$DIFF_SCRIPT" \
    --last-published /dev/null \
    --local-manifest "$TEST_TMP/nonexistent.json"
  [ "$status" -eq 2 ] || fail "expected exit 2 for nonexistent file, got: $status"
}

@test "malformed local-manifest exits 2" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  printf 'not json' > "$TEST_TMP/bad.json"
  run bash "$DIFF_SCRIPT" \
    --last-published /dev/null \
    --local-manifest "$TEST_TMP/bad.json"
  [ "$status" -eq 2 ] || fail "expected exit 2 for malformed manifest, got: $status"
}

@test "unknown flag exits 2" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_local_manifest "tokens/colors.html=aaa111"
  run bash "$DIFF_SCRIPT" \
    --last-published /dev/null \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --bogus-flag
  [ "$status" -eq 2 ] || fail "expected exit 2 for unknown flag, got: $status"
}

@test "flag with no value exits 2" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  run bash "$DIFF_SCRIPT" --spec-root
  [ "$status" -eq 2 ] || fail "expected exit 2 for flag with no value, got: $status"
}

@test "production ignores helper override without bats" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  # Create a malicious override
  local bad_helper="$TEST_TMP/bad-helper.sh"
  printf '#!/usr/bin/env bash\nprintf HIJACKED\n' > "$bad_helper"
  chmod +x "$bad_helper"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=new-hash" \
    "screens/login.spec.html=ddd444"

  # Run WITHOUT BATS_TEST_FILENAME — production mode
  run env -u BATS_TEST_FILENAME \
    _DERIVE_SCOPE_HELPER_OVERRIDE="$bad_helper" \
    bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  [ "$output" != "HIJACKED" ] \
    || fail "production honoured the helper override — must ignore it without BATS_TEST_FILENAME"
  # The real scope should be computed, not the override
  case "$output" in
    design-system|product-design|both) ;;
    *) fail "production mode should produce a real scope, got: $output" ;;
  esac
}

@test "test seam override is honoured inside bats" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  # Create a deterministic override that returns a known answer
  local test_helper="$TEST_TMP/test-helper.sh"
  cat > "$test_helper" <<'HELPEOF'
#!/usr/bin/env bash
printf 'design-system\n'
HELPEOF
  chmod +x "$test_helper"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  # Token change + screen edit would normally yield both via token rule
  _seed_local_manifest \
    "tokens/colors.html=new-hash" \
    "screens/login.spec.html=ddd444"

  # Run WITH BATS_TEST_FILENAME set (as bats sets it)
  run env BATS_TEST_FILENAME="$BATS_TEST_FILENAME" \
    _DERIVE_SCOPE_HELPER_OVERRIDE="$test_helper" \
    bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json"

  [ "$status" -eq 0 ]
  # The override helper always returns design-system
  [ "$output" = "design-system" ] \
    || fail "test seam should be honoured inside bats, got: $output"
}

# ===========================================================================
# Scaling: single-pass jq must not spawn per-entry processes
# ===========================================================================

@test "diff at 100 entries completes in under 5 seconds" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  # Generate a 100-entry manifest
  local manifest="$TEST_TMP/large-manifest.json"
  local lp="$TEST_TMP/large-lp.json"

  # Build local manifest with 50 tokens + 50 screens
  printf '{' > "$manifest"
  local i=0 sep=""
  while [ "$i" -lt 50 ]; do
    printf '%s"tokens/t%d.html":"hash%d"' "$sep" "$i" "$i" >> "$manifest"
    sep=","
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 50 ]; do
    printf ',"screens/s%d.spec.html":"shash%d"' "$i" "$i" >> "$manifest"
    i=$((i + 1))
  done
  printf '}' >> "$manifest"

  # Build last-published with the same entries but different hashes for half
  printf '{"design_system":{"files":[' > "$lp"
  i=0; sep=""
  while [ "$i" -lt 50 ]; do
    local h="hash$i"
    if [ $((i % 2)) -eq 0 ]; then h="old$i"; fi
    printf '%s{"path":"tokens/t%d.html","hash":"%s"}' "$sep" "$i" "$h" >> "$lp"
    sep=","
    i=$((i + 1))
  done
  printf ']},"product_design":{"files":[' >> "$lp"
  i=0; sep=""
  while [ "$i" -lt 50 ]; do
    local sh="shash$i"
    if [ $((i % 2)) -eq 0 ]; then sh="old$i"; fi
    printf '%s{"path":"project/s%d.dc.html","hash":"%s"}' "$sep" "$i" "$sh" >> "$lp"
    sep=","
    i=$((i + 1))
  done
  printf ']}}' >> "$lp"

  local start_s
  start_s="$(date +%s)"

  run bash "$DIFF_SCRIPT" \
    --last-published "$lp" \
    --local-manifest "$manifest"

  local end_s
  end_s="$(date +%s)"
  local elapsed=$(( end_s - start_s ))

  [ "$status" -eq 0 ] || fail "diff script failed at 100 entries: $output"
  [ "$elapsed" -lt 5 ] || fail "diff at 100 entries took ${elapsed}s (limit 5s)"
}

# ===========================================================================
# Path normalisation: flag order, repeated slashes, artboard mapping, dotdot
# ===========================================================================

@test "spec-root placed after edited still normalises absolute path" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  local sr="$TEST_TMP/specroot"
  mkdir -p "$sr"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp-hash" \
    "screens/login.spec.html=ddd444"

  # --edited comes BEFORE --spec-root
  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "$sr/screens/login.spec.html" \
    --spec-root "$sr"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (component + absolute screen after spec-root), got: $output"
}

@test "repeated slashes in edited path are collapsed" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp-hash" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited ".//screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (component + .//screen), got: $output"
}

@test "artboard path project/name.dc.html maps to screens/name.spec.html" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp-hash" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "project/login.dc.html"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (component + artboard path), got: $output"
}

@test "dotdot segment in edited path yields both via unclassified" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp-hash" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "tokens/../screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (component + dotdot path), got: $output"
}

@test "absolute path with no spec-root yields both via unclassified" {
  [ -f "$DIFF_SCRIPT" ] || fail "derive-design-scope-diff.sh not found"

  _seed_last_published "aaa111" "bbb222" "ccc333"
  _seed_local_manifest \
    "tokens/colors.html=aaa111" \
    "components/button.spec.html=new-comp-hash" \
    "screens/login.spec.html=ddd444"

  run bash "$DIFF_SCRIPT" \
    --last-published "$TEST_TMP/design-last-published.json" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --edited "/some/absolute/screens/login.spec.html"

  [ "$status" -eq 0 ]
  [ "$output" = "both" ] || fail "expected both (component + unclassified absolute), got: $output"
}

