#!/usr/bin/env bats
# pixel-diff-ac4-no-baseline-unverified.bats — AC4: no reference baseline
# resolves UNVERIFIED (non-blocking), distinct from SKIPPED (not configured).
#
# Scenarios: S4.1 -- S4.4

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  PIXEL_DIFF="$PLUGIN_DIR/skills/gaia-test-manual/scripts/pixel-diff.sh"
  DISPATCH="$PLUGIN_DIR/skills/gaia-test-manual/scripts/dispatch-surface.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/pixel-diff"

  TEST_TMP="$(mktemp -d)"
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

# ---------- S4.1: No baseline directory exists ----------

@test "S4.1: missing baseline directory resolves UNVERIFIED" {
  STORY_SLUG="test-story-s4-1"
  # No baseline dir created — design-baselines/ does not exist
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"
  cp "$FIXTURE_DIR/screenshot-375.png" "$SCREENSHOT_DIR/screenshot-375.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"

  grep -qi "UNVERIFIED" <<<"$output"
  ! grep -qi "^FAILED" <<<"$output"
  ! grep -qi "SKIPPED" <<<"$output"
}

# ---------- S4.2: Baseline directory exists but is empty ----------

@test "S4.2: empty baseline directory resolves UNVERIFIED" {
  STORY_SLUG="test-story-s4-2"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  # Directory exists but no PNG files inside

  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"
  cp "$FIXTURE_DIR/screenshot-375.png" "$SCREENSHOT_DIR/screenshot-375.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"

  grep -qi "UNVERIFIED" <<<"$output"
  # Should name the empty baseline directory in diagnostics
  grep -qi "baseline\|empty" <<<"$output"
}

# ---------- S4.3: Partial baselines — some exist, some missing ----------

@test "S4.3: partial baselines — present breakpoints diffed, missing UNVERIFIED" {
  command -v compare || skip "ImageMagick not installed"

  STORY_SLUG="test-story-s4-3"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  # Only 375 and 768 have baselines, not 1440
  for bp in 375 768; do
    cp "$FIXTURE_DIR/baseline-${bp}.png" "$BASELINE_DIR/baseline-${bp}.png"
    cp "$FIXTURE_DIR/screenshot-${bp}.png" "$SCREENSHOT_DIR/screenshot-${bp}.png"
  done
  cp "$FIXTURE_DIR/screenshot-1440.png" "$SCREENSHOT_DIR/screenshot-1440.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"

  # 375 and 768 should report PASSED
  grep "375" <<<"$output" | grep -qi "PASSED"
  grep "768" <<<"$output" | grep -qi "PASSED"
  # 1440 should report UNVERIFIED
  grep "1440" <<<"$output" | grep -qi "UNVERIFIED"
  # Overall should be PASSED (worst non-UNVERIFIED result; UNVERIFIED is advisory)
  echo "$output" | tail -1 | grep -qi "PASSED"
}

# ---------- S4.4: UNVERIFIED is distinct from SKIPPED ----------

@test "S4.4: UNVERIFIED (no baseline) is different from SKIPPED (not configured)" {
  # UNVERIFIED: browser surface is configured but baseline is missing
  STORY_SLUG="test-story-s4-4u"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"
  cp "$FIXTURE_DIR/screenshot-375.png" "$SCREENSHOT_DIR/screenshot-375.png"

  source "$PIXEL_DIFF"
  run run_pixel_diff "$STORY_SLUG" "$SCREENSHOT_DIR" \
    --project-root "$TEST_TMP" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  unverified_output="$output"
  grep -qi "UNVERIFIED" <<<"$unverified_output"

  # SKIPPED: browser surface is NOT configured (no web in platforms)
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [server]
YAML

  EVIDENCE_DIR="$TEST_TMP/evidence"
  mkdir -p "$EVIDENCE_DIR"

  run bash "$DISPATCH" --surface browser --target "echo test" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  skipped_output="$output"
  grep -qi "SKIPPED" <<<"$skipped_output"

  # The two verdicts must be distinct strings
  [ "$unverified_output" != "$skipped_output" ]
}
