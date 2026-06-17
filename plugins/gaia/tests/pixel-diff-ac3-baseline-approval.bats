#!/usr/bin/env bats
# pixel-diff-ac3-baseline-approval.bats — AC3: human-in-the-loop baseline
# approval; baselines are NEVER auto-accepted.
#
# Scenarios: S3.1 -- S3.4

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  APPROVE="$PLUGIN_DIR/skills/gaia-test-manual/scripts/approve-baseline.sh"
  PIXEL_DIFF="$PLUGIN_DIR/skills/gaia-test-manual/scripts/pixel-diff.sh"
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

# ---------- S3.1: Happy path — human approves new baseline ----------

@test "S3.1: approve_single_breakpoint with y input updates baseline" {
  STORY_SLUG="test-story-s3-1"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  cp "$FIXTURE_DIR/baseline-1440.png" "$BASELINE_DIR/baseline-1440.png"
  cp "$FIXTURE_DIR/screenshot-768-drifted.png" "$SCREENSHOT_DIR/screenshot-1440.png"

  original_sum="$(shasum "$BASELINE_DIR/baseline-1440.png" | cut -d' ' -f1)"

  # Source the script (bypasses _main guard and its tty check)
  # Call the public function with piped 'y' answer
  source "$APPROVE"
  echo "y" | approve_single_breakpoint "$STORY_SLUG" "1440" "$BASELINE_DIR" "$SCREENSHOT_DIR"

  # Baseline should be updated (different from original)
  after_sum="$(shasum "$BASELINE_DIR/baseline-1440.png" | cut -d' ' -f1)"
  [ "$original_sum" != "$after_sum" ]

  # Old baseline should be archived under previous/
  [ -d "$BASELINE_DIR/previous" ]

  # Audit log should exist
  [ -f "$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/baseline-approvals.log" ]
}

# ---------- S3.2: Hard guarantee — no auto-accept ----------

@test "S3.2: pixel-diff.sh has no cp/mv that targets a baseline destination" {
  [ -f "$PIXEL_DIFF" ] || skip "pixel-diff.sh not yet created"

  # Static analysis: the ATDD S3.2 requires no unconditional cp/mv of
  # screenshot TO baseline path. The script may use cp for masking (to temp)
  # but never writes to a baseline directory.
  # Check: no cp/mv lines with "baseline" as the DESTINATION (last argument).
  run bash -c "
    grep -nE '\\bcp\\b.*baseline-[0-9]+\\.png\"?\$|\\bmv\\b.*baseline-[0-9]+\\.png\"?\$' '$PIXEL_DIFF' \
      | grep -v '^[[:space:]]*#' \
      || true
  "
  [ -z "$output" ]
}

@test "S3.2: pixel-diff.sh structural guarantee comment is present" {
  [ -f "$PIXEL_DIFF" ] || skip "pixel-diff.sh not yet created"

  # The script must contain the structural guarantee comment
  grep -q "STRUCTURAL GUARANTEE" "$PIXEL_DIFF"
  grep -qi "NO cp/mv" "$PIXEL_DIFF"
}

# ---------- S3.3: Human declines — baseline unchanged ----------

@test "S3.3: declining approval preserves existing baseline unchanged" {
  STORY_SLUG="test-story-s3-3"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  cp "$FIXTURE_DIR/baseline-1440.png" "$BASELINE_DIR/baseline-1440.png"
  cp "$FIXTURE_DIR/screenshot-768-drifted.png" "$SCREENSHOT_DIR/screenshot-1440.png"

  original_sum="$(shasum "$BASELINE_DIR/baseline-1440.png" | cut -d' ' -f1)"

  # Source and call the function with 'n' answer
  source "$APPROVE"
  echo "n" | approve_single_breakpoint "$STORY_SLUG" "1440" "$BASELINE_DIR" "$SCREENSHOT_DIR" || true

  after_sum="$(shasum "$BASELINE_DIR/baseline-1440.png" | cut -d' ' -f1)"
  [ "$original_sum" = "$after_sum" ]
}

# ---------- S3.4: Batch approval — per-breakpoint consent ----------

@test "S3.4: batch approval with selective accept/reject per breakpoint" {
  STORY_SLUG="test-story-s3-4"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  for bp in 375 768 1440; do
    cp "$FIXTURE_DIR/baseline-${bp}.png" "$BASELINE_DIR/baseline-${bp}.png"
    cp "$FIXTURE_DIR/screenshot-768-drifted.png" "$SCREENSHOT_DIR/screenshot-${bp}.png"
  done

  sum_375_before="$(shasum "$BASELINE_DIR/baseline-375.png" | cut -d' ' -f1)"
  sum_768_before="$(shasum "$BASELINE_DIR/baseline-768.png" | cut -d' ' -f1)"

  # Source the script and call approve_single_breakpoint per breakpoint
  # simulating the --all flow: accept 375, reject 768, accept 1440
  source "$APPROVE"
  echo "y" | approve_single_breakpoint "$STORY_SLUG" "375" "$BASELINE_DIR" "$SCREENSHOT_DIR"
  echo "n" | approve_single_breakpoint "$STORY_SLUG" "768" "$BASELINE_DIR" "$SCREENSHOT_DIR" || true
  echo "y" | approve_single_breakpoint "$STORY_SLUG" "1440" "$BASELINE_DIR" "$SCREENSHOT_DIR"

  # 375 should be updated (different checksum)
  sum_375_after="$(shasum "$BASELINE_DIR/baseline-375.png" | cut -d' ' -f1)"
  [ "$sum_375_before" != "$sum_375_after" ]

  # 768 should be preserved (same checksum as the original baseline fixture)
  sum_768_after="$(shasum "$BASELINE_DIR/baseline-768.png" | cut -d' ' -f1)"
  [ "$sum_768_before" = "$sum_768_after" ]
}

# ---------- S3: approve-baseline.sh refuses in non-tty ----------

@test "S3: approve-baseline.sh CLI refuses when stdin is not a tty" {
  STORY_SLUG="test-story-s3-notty"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  cp "$FIXTURE_DIR/baseline-375.png" "$BASELINE_DIR/baseline-375.png"
  cp "$FIXTURE_DIR/screenshot-768-drifted.png" "$SCREENSHOT_DIR/screenshot-375.png"

  # Pipe stdin from /dev/null (not a tty)
  run bash "$APPROVE" --story "$STORY_SLUG" --breakpoint 375 \
    --project-root "$TEST_TMP" \
    --screenshot-dir "$SCREENSHOT_DIR" </dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "tty\|interactive\|terminal"
}

# ---------- S3: sourced function non-tty refusal ----------

@test "S3: approve_single_breakpoint refuses when sourced in non-tty with no confirmation" {
  STORY_SLUG="test-story-s3-source-notty"
  BASELINE_DIR="$TEST_TMP/.gaia/artifacts/test-artifacts/manual-test/${STORY_SLUG}/design-baselines"
  mkdir -p "$BASELINE_DIR"
  SCREENSHOT_DIR="$TEST_TMP/screenshots"
  mkdir -p "$SCREENSHOT_DIR"

  cp "$FIXTURE_DIR/baseline-375.png" "$BASELINE_DIR/baseline-375.png"
  cp "$FIXTURE_DIR/screenshot-768-drifted.png" "$SCREENSHOT_DIR/screenshot-375.png"

  original_sum="$(shasum "$BASELINE_DIR/baseline-375.png" | cut -d' ' -f1)"

  # Source the script and call the function with /dev/null (non-tty, no input)
  # The function must refuse and leave the baseline untouched.
  run bash -c "
    source '$APPROVE'
    approve_single_breakpoint '$STORY_SLUG' '375' '$BASELINE_DIR' '$SCREENSHOT_DIR'
  " </dev/null

  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "non-interactive\|refused"

  # Baseline must be unchanged (checksum identical)
  after_sum="$(shasum "$BASELINE_DIR/baseline-375.png" | cut -d' ' -f1)"
  [ "$original_sum" = "$after_sum" ]
}
