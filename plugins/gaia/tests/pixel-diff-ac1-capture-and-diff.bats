#!/usr/bin/env bats
# pixel-diff-ac1-capture-and-diff.bats — AC1: browser surface captures
# per-breakpoint screenshots and pixel-diffs against per-story baselines
# via the paths helper (not hard-coded).
#
# Scenarios: S1.1 -- S1.5

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  PIXEL_DIFF="$PLUGIN_DIR/skills/gaia-test-manual/scripts/pixel-diff.sh"
  RESOLVER="$PLUGIN_DIR/scripts/lib/resolve-artifact-path.sh"
  CAPTURE="$PLUGIN_DIR/skills/gaia-test-manual/scripts/capture-screenshot.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/pixel-diff"

  TEST_TMP="$(mktemp -d)"

  # Minimal project config with breakpoints
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
visual_diff:
  threshold_percent: 0.5
  breakpoints: [375, 768, 1440]
YAML
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- S1.1: Happy path — baselines exist, all pass ----------

@test "S1.1: all breakpoints pass when screenshots match baselines" {
  command -v compare || skip "ImageMagick not installed"

  # Set up baselines via the resolver path
  STORY_SLUG="test-story-s1-1"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  for bp in 375 768 1440; do
    cp "$FIXTURE_DIR/baseline-${bp}.png" "$BASELINE_DIR/baseline-${bp}.png"
  done

  # Set up screenshots (identical to baselines = PASS)
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"
  for bp in 375 768 1440; do
    cp "$FIXTURE_DIR/screenshot-${bp}.png" "$SCREENSHOT_DIR/screenshot-${bp}.png"
  done

  # Source and call
  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASSED"
}

# ---------- S1.2: Paths helper routing — no hard-coded baseline dir ----------

@test "S1.2: pixel-diff.sh does not hard-code baseline directory literals" {
  [ -f "$PIXEL_DIFF" ] || skip "pixel-diff.sh not yet created"

  # Grep for hard-coded baseline paths in the script body (excluding comments)
  # The script should route through resolve-artifact-path.sh, not contain
  # literal .gaia/artifacts/ or design-baselines/ paths.
  run bash -c "grep -n 'design-baselines/' '$PIXEL_DIFF' | grep -v '^[[:space:]]*#' | grep -v 'resolve-artifact-path' || true"
  [ -z "$output" ]
}

@test "S1.2: pixel-diff.sh calls the paths helper for baseline resolution" {
  [ -f "$PIXEL_DIFF" ] || skip "pixel-diff.sh not yet created"

  # Must reference resolve-artifact-path somewhere (by name or by sourcing)
  run grep -c 'resolve-artifact-path\|design_baselines' "$PIXEL_DIFF"
  [ "$output" -ge 1 ]
}

# ---------- S1.3: Multiple breakpoints — diff runs once per breakpoint ----------

@test "S1.3: three breakpoints produce three independent diff results" {
  command -v compare || skip "ImageMagick not installed"

  STORY_SLUG="test-story-s1-3"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  for bp in 375 768 1440; do
    cp "$FIXTURE_DIR/baseline-${bp}.png" "$BASELINE_DIR/baseline-${bp}.png"
    cp "$FIXTURE_DIR/screenshot-${bp}.png" "$SCREENSHOT_DIR/screenshot-${bp}.png"
  done

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  # Each breakpoint should be mentioned independently
  echo "$output" | grep -q "375"
  echo "$output" | grep -q "768"
  echo "$output" | grep -q "1440"
}

# ---------- S1.4: Partial failure — one breakpoint exceeds threshold ----------

@test "S1.4: one drifted breakpoint produces FAILED with measured diff" {
  command -v compare || skip "ImageMagick not installed"

  STORY_SLUG="test-story-s1-4"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  for bp in 375 1440; do
    cp "$FIXTURE_DIR/baseline-${bp}.png" "$BASELINE_DIR/baseline-${bp}.png"
    cp "$FIXTURE_DIR/screenshot-${bp}.png" "$SCREENSHOT_DIR/screenshot-${bp}.png"
  done
  cp "$FIXTURE_DIR/baseline-768.png" "$BASELINE_DIR/baseline-768.png"
  cp "$FIXTURE_DIR/screenshot-768-drifted.png" "$SCREENSHOT_DIR/screenshot-768.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"

  # Overall must be FAILED
  echo "$output" | grep -qi "FAILED"
  # 375 and 1440 should pass
  echo "$output" | grep "375" | grep -qi "PASSED"
  echo "$output" | grep "1440" | grep -qi "PASSED"
  # 768 should fail with a percentage
  echo "$output" | grep "768" | grep -qi "FAILED"
  echo "$output" | grep "768" | grep -qE '[0-9]+(\.[0-9]+)?%'
}

# ---------- S1.5: Degradation — image-compare tool not installed ----------

@test "S1.5: missing compare tool resolves UNVERIFIED not FAILED" {
  STORY_SLUG="test-story-s1-5"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  cp "$FIXTURE_DIR/baseline-375.png" "$BASELINE_DIR/baseline-375.png"

  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"
  cp "$FIXTURE_DIR/screenshot-375.png" "$SCREENSHOT_DIR/screenshot-375.png"

  # Override PATH so compare/pixelmatch are not found
  source "$PIXEL_DIFF"
  PATH="/usr/bin:/bin" run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"

  echo "$output" | grep -qi "UNVERIFIED"
  # Must NOT be FAILED or SKIPPED
  ! echo "$output" | grep -qi "^FAILED"
  ! echo "$output" | grep -qi "SKIPPED"
}
