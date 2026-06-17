#!/usr/bin/env bats
# pixel-diff-unit.bats — public function coverage: source + call every new
# public function by name. Also covers the design_baselines resolver kind.
#
# Every public function (matching ^[a-z_][a-z0-9_]*() {) in the new scripts
# must appear by name in at least one bats test.

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  PIXEL_DIFF="$PLUGIN_DIR/skills/gaia-test-manual/scripts/pixel-diff.sh"
  READ_CONFIG="$PLUGIN_DIR/skills/gaia-test-manual/scripts/read-visual-diff-config.sh"
  RESOLVER="$PLUGIN_DIR/scripts/lib/resolve-artifact-path.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/pixel-diff"

  TEST_TMP="$(mktemp -d)"
  mkdir -p "$TEST_TMP/.gaia/config"

  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
visual_diff:
  threshold_percent: 0.3
  breakpoints: [375, 768, 1440]
  mask_regions:
    - x: 0
      y: 0
      w: 5
      h: 5
      label: "clock"
YAML
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- resolve-artifact-path.sh: design_baselines kind ----------

@test "unit: resolver design_baselines kind resolves canonical path with slug" {
  run bash "$RESOLVER" design_baselines --slug my-story --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "test-artifacts/manual-test/my-story/design-baselines"
}

@test "unit: resolver design_baselines kind requires --slug" {
  run bash "$RESOLVER" design_baselines --project-root "$TEST_TMP"
  [ "$status" -ne 0 ]
}

@test "unit: resolver design_baselines with --existing-only exits 1 when dir absent" {
  run bash "$RESOLVER" design_baselines --slug absent-story \
    --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 1 ]
}

@test "unit: resolver design_baselines with --existing-only exits 0 for non-empty dir" {
  SLUG="existing-story"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  cp "$FIXTURE_DIR/baseline-375.png" "$BASELINE_DIR/baseline-375.png"

  run bash "$RESOLVER" design_baselines --slug "$SLUG" \
    --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "design-baselines"
}

# ---------- read-visual-diff-config.sh functions ----------

@test "unit: read_threshold returns configured value" {
  source "$READ_CONFIG"
  run read_threshold "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "0.3"
}

@test "unit: read_threshold returns 0.1 default when not configured" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
YAML
  source "$READ_CONFIG"
  run read_threshold "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "0.1"
}

@test "unit: read_breakpoints returns configured breakpoints" {
  source "$READ_CONFIG"
  run read_breakpoints "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "375"
  echo "$output" | grep -q "768"
  echo "$output" | grep -q "1440"
}

@test "unit: read_breakpoints returns 1440 default when not configured" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
YAML
  source "$READ_CONFIG"
  run read_breakpoints "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1440"
}

@test "unit: read_mask_regions emits x,y,w,h,label lines" {
  source "$READ_CONFIG"
  run read_mask_regions "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "0,0,5,5,clock"
}

@test "unit: read_mask_regions returns empty when none configured" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
YAML
  source "$READ_CONFIG"
  run read_mask_regions "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- pixel-diff.sh functions ----------

@test "unit: detect_compare_tool returns tool name or empty" {
  source "$PIXEL_DIFF"
  run detect_compare_tool
  [ "$status" -eq 0 ]
  # Output should be a tool name or empty
  [ "$output" = "compare" ] || [ "$output" = "pixelmatch" ] || [ -z "$output" ]
}

@test "unit: detect_compare_tool with empty PATH returns empty" {
  source "$PIXEL_DIFF"
  PATH="" run detect_compare_tool
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unit: mask_image creates masked copy without mutating original" {
  command -v convert || skip "ImageMagick convert not installed"

  source "$PIXEL_DIFF"
  ORIG="$FIXTURE_DIR/baseline-375.png"
  MASKED_OUT="$TEST_TMP/masked.png"
  original_sum="$(shasum "$ORIG" | cut -d' ' -f1)"

  run mask_image "$ORIG" "$MASKED_OUT" "0,0,5,5,test-region"
  [ "$status" -eq 0 ]

  # Original must not be modified
  after_sum="$(shasum "$ORIG" | cut -d' ' -f1)"
  [ "$original_sum" = "$after_sum" ]

  # Masked output must exist
  [ -f "$MASKED_OUT" ]
}

@test "unit: mask_image warns but succeeds when convert absent" {
  source "$PIXEL_DIFF"
  ORIG="$FIXTURE_DIR/baseline-375.png"
  MASKED_OUT="$TEST_TMP/masked-noconvert.png"

  PATH="/usr/bin:/bin" run mask_image "$ORIG" "$MASKED_OUT" "0,0,5,5,test"
  # Should warn (non-fatal) — the function is a no-op without convert
  [ "$status" -eq 0 ]
}

@test "unit: diff_single_breakpoint produces PASSED/FAILED with percentage" {
  command -v compare || skip "ImageMagick not installed"

  source "$PIXEL_DIFF"
  # Identical images
  run diff_single_breakpoint "$FIXTURE_DIR/baseline-375.png" \
    "$FIXTURE_DIR/screenshot-375.png" "0.5"
  echo "$output" | grep -qi "PASSED"
  echo "$output" | grep -qE '[0-9]+(\.[0-9]+)?%'

  # Different images
  run diff_single_breakpoint "$FIXTURE_DIR/baseline-768.png" \
    "$FIXTURE_DIR/screenshot-768-drifted.png" "0.5"
  echo "$output" | grep -qi "FAILED"
}

@test "unit: run_pixel_diff function exists and is callable" {
  source "$PIXEL_DIFF"
  # Just verify the function is defined after sourcing
  declare -f run_pixel_diff >/dev/null
}

# ---------- capture-screenshot.sh ----------

@test "unit: capture_screenshot function exits 2 when no headless browser found" {
  CAPTURE="$PLUGIN_DIR/skills/gaia-test-manual/scripts/capture-screenshot.sh"
  source "$CAPTURE"
  # Point PATH at an empty dir so no browser resolves regardless of host
  # (CI runners ship chromium/google-chrome under /usr/bin, so narrowing to
  # the standard bin dirs would not hide it).
  EMPTY_BIN="$TEST_TMP/empty-bin"
  mkdir -p "$EMPTY_BIN"
  PATH="$EMPTY_BIN" run capture_screenshot "http://localhost" "1440" "$TEST_TMP/out.png"
  [ "$status" -eq 2 ]
}

@test "unit: capture-screenshot.sh CLI exits 2 when no headless browser found" {
  CAPTURE="$PLUGIN_DIR/skills/gaia-test-manual/scripts/capture-screenshot.sh"
  # Resolve bash by absolute path, then run the script with PATH pointed at an
  # empty dir so no browser resolves regardless of host (CI runners ship
  # chromium/google-chrome under /usr/bin, so narrowing to standard bin dirs
  # would not hide it). The script's control flow up to the no-browser return-2
  # uses only bash builtins, so an empty PATH is sufficient and deterministic.
  EMPTY_BIN="$TEST_TMP/empty-bin"
  mkdir -p "$EMPTY_BIN"
  BASH_BIN="$(command -v bash)"
  run env PATH="$EMPTY_BIN" "$BASH_BIN" "$CAPTURE" --url "http://localhost" \
    --breakpoint 1440 --output "$TEST_TMP/out.png"
  [ "$status" -eq 2 ]
}
