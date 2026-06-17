#!/usr/bin/env bats
# pixel-diff-ac2-thresholds-and-masking.bats — AC2: configurable diff
# thresholds and dynamic-region masking before comparison.
#
# Scenarios: S2.1 -- S2.5

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  PIXEL_DIFF="$PLUGIN_DIR/skills/gaia-test-manual/scripts/pixel-diff.sh"
  READ_CONFIG="$PLUGIN_DIR/skills/gaia-test-manual/scripts/read-visual-diff-config.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/pixel-diff"

  TEST_TMP="$(mktemp -d)"
  mkdir -p "$TEST_TMP/.gaia/config"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- S2.1: Threshold configured, diff within tolerance ----------

@test "S2.1: diff below threshold produces PASSED" {
  command -v compare || skip "ImageMagick not installed"

  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
visual_diff:
  threshold_percent: 0.5
  breakpoints: [375]
YAML

  STORY_SLUG="test-story-s2-1"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  cp "$FIXTURE_DIR/baseline-375.png" "$BASELINE_DIR/baseline-375.png"
  cp "$FIXTURE_DIR/screenshot-375.png" "$SCREENSHOT_DIR/screenshot-375.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "PASSED"
}

# ---------- S2.2: Threshold boundary — diff exactly at threshold ----------

@test "S2.2: diff exactly at threshold produces PASSED (non-degenerate)" {
  command -v compare || skip "ImageMagick not installed"

  # screenshot-375-1pct.png has 1 pixel changed out of 100 (10x10) = 1.00%
  # Set threshold to 1.0 so measured == threshold => PASSED via the <= operator
  source "$PIXEL_DIFF"

  BASELINE="$FIXTURE_DIR/baseline-375.png"
  SCREENSHOT="$FIXTURE_DIR/screenshot-375-1pct.png"
  run diff_single_breakpoint "$BASELINE" "$SCREENSHOT" "1.0"
  echo "$output" | grep -qi "PASSED"
}

# ---------- S2.3: Threshold boundary — diff above threshold ----------

@test "S2.3: diff above threshold produces FAILED with measured pct" {
  command -v compare || skip "ImageMagick not installed"

  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
visual_diff:
  threshold_percent: 0.5
  breakpoints: [768]
YAML

  STORY_SLUG="test-story-s2-3"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  cp "$FIXTURE_DIR/baseline-768.png" "$BASELINE_DIR/baseline-768.png"
  cp "$FIXTURE_DIR/screenshot-768-drifted.png" "$SCREENSHOT_DIR/screenshot-768.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"

  echo "$output" | grep -qi "FAILED"
  # Must include both measured diff and threshold for diagnostics
  echo "$output" | grep -qE '[0-9]+(\.[0-9]+)?%'
}

# ---------- S2.4: Dynamic-region masking ----------

@test "S2.4: masked regions are excluded from diff comparison" {
  command -v compare || skip "ImageMagick not installed"
  command -v convert || skip "ImageMagick convert not installed"

  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
visual_diff:
  threshold_percent: 0.1
  breakpoints: [375]
  mask_regions:
    - x: 0
      y: 0
      w: 5
      h: 5
      label: "dynamic-region"
YAML

  STORY_SLUG="test-story-s2-4"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  # Baseline is all white; screenshot has a red region in top-left 5x5
  # that SHOULD be masked, making the diff within threshold
  cp "$FIXTURE_DIR/baseline-375.png" "$BASELINE_DIR/baseline-375.png"
  cp "$FIXTURE_DIR/screenshot-masked-changed.png" "$SCREENSHOT_DIR/screenshot-375.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"

  echo "$output" | grep -qi "PASSED"
  echo "$output" | grep -qi "masked"
}

# ---------- S2.5: No threshold configured — falls back to default ----------

@test "S2.5: missing threshold falls back to 0.1 percent default" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
YAML

  source "$READ_CONFIG"
  run read_threshold "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  # Default threshold is 0.1
  echo "$output" | grep -q "0.1"
}

@test "S2.5: read_breakpoints defaults to 1440 when not configured" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
YAML

  source "$READ_CONFIG"
  run read_breakpoints "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1440"
}
