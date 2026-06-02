#!/usr/bin/env bats
# ATDD — E28-S134 Review Gate Test
# Each test maps 1:1 to one AC or EC in E28-S134.
# Red phase: run before runner/fixtures/trace emitter exist — all tests MUST fail.
# Green phase: once the runner, fixtures, trace, audit, and normalizer are in place, all tests pass.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  RUNNER="$REPO_ROOT/gaia-framework/plugins/gaia/test/runners/review-gate.sh"
  RESET="$REPO_ROOT/gaia-framework/plugins/gaia/test/runners/reset-fixtures.sh"
  FIXTURE_DIR="$REPO_ROOT/gaia-framework/plugins/gaia/test/fixtures/cluster-19/stories"
  CLEAN_DIR="$FIXTURE_DIR/clean"
  CR_DEFECT_DIR="$FIXTURE_DIR/code-review-defect"
  SEC_DEFECT_DIR="$FIXTURE_DIR/security-finding"
  BASELINE_TRACE="$REPO_ROOT/gaia-framework/plugins/gaia/test/fixtures/parity-baseline/traces/run-all-reviews.jsonl"
  NATIVE_TRACE="$REPO_ROOT/docs/test-artifacts/traces/native-run-all-reviews.jsonl"
  AUDIT="$REPO_ROOT/docs/test-artifacts/traces/native-review-gate-mtime-audit.log"
  NORM="$REPO_ROOT/gaia-framework/plugins/gaia/scripts/lib/verdict-normalizer.sh"
  # Reset fixtures to review state before each test so AC1, EC1, EC7 (which mutate state) are repeatable.
  [ -x "$RESET" ] && "$RESET" >/dev/null 2>&1 || true
}

skip_fail() { echo "FAIL(setup): $1"; return 1; }

# AC1 — 18 artifacts produced (3 × 6)
@test "AC1: run-all-reviews produces 18 artifacts across 3 fixture stories" {
  [ -x "$RUNNER" ] || skip_fail "runner missing: $RUNNER"
  [ -d "$CLEAN_DIR" ] && [ -d "$CR_DEFECT_DIR" ] && [ -d "$SEC_DEFECT_DIR" ] || skip_fail "fixtures missing"

  "$RUNNER" --fixtures "$FIXTURE_DIR" --trace-out "$NATIVE_TRACE" --audit-out "$AUDIT"

  local count=0
  for story_key in FIX-CLEAN-01 FIX-CRD-01 FIX-SEC-01; do
    for review in code-review qa-tests security-review test-automation test-review performance-review; do
      f="$REPO_ROOT/docs/implementation-artifacts/cluster-19-${story_key}-${review}.md"
      [ -f "$f" ] || { echo "missing: $f" >&2; return 1; }
      count=$((count+1))
    done
  done
  [ "$count" -eq 18 ]
}

# AC2 — native trace byte-equal to baseline on order + verdicts
@test "AC2: native trace matches parity-baseline byte-for-byte on order and verdicts" {
  [ -f "$NATIVE_TRACE" ] || skip_fail "native trace missing"
  [ -f "$BASELINE_TRACE" ] || skip_fail "baseline trace missing"

  diff -q <(jq -c '{story_key, review, verdict}' "$NATIVE_TRACE") \
          <(jq -c '{story_key, review, verdict}' "$BASELINE_TRACE")
}

# AC3 — Review Gate row transitions populate with Report link
@test "AC3: 18 Review Gate rows transition from UNVERIFIED to PASSED/FAILED with Report link" {
  "$RUNNER" --fixtures "$FIXTURE_DIR" --trace-out "$NATIVE_TRACE" --audit-out "$AUDIT"
  for story_dir in "$CLEAN_DIR" "$CR_DEFECT_DIR" "$SEC_DEFECT_DIR"; do
    story_file="$(ls "$story_dir"/*.md 2>/dev/null | head -1)"
    [ -f "$story_file" ] || skip_fail "story file missing: $story_dir"
    ! grep -q "| UNVERIFIED |" "$story_file"
    grep -qE "\| (PASSED|FAILED) \|" "$story_file"
    grep -qE "cluster-19-.*-(code-review|qa-tests|security-review|test-automation|test-review|performance-review)\.md" "$story_file"
  done
}

# AC4 — clean fixture transitions review → done atomically
@test "AC4: clean fixture transitions review→done atomically with sprint-status agreement" {
  "$RUNNER" --fixtures "$FIXTURE_DIR" --trace-out "$NATIVE_TRACE" --audit-out "$AUDIT"
  story_file="$(ls "$CLEAN_DIR"/*.md 2>/dev/null | head -1)"
  [ -f "$story_file" ] || skip_fail "clean story missing"
  grep -qE "^status: done$" "$story_file"
  grep -q '^> \*\*Status:\*\* done$' "$story_file"
}

# AC5 — planted-defect fixtures transition review → in-progress
@test "AC5: planted-defect fixtures transition review→in-progress with failed rows populated" {
  "$RUNNER" --fixtures "$FIXTURE_DIR" --trace-out "$NATIVE_TRACE" --audit-out "$AUDIT"
  for story_dir in "$CR_DEFECT_DIR" "$SEC_DEFECT_DIR"; do
    story_file="$(ls "$story_dir"/*.md 2>/dev/null | head -1)"
    [ -f "$story_file" ] || skip_fail "defect story missing: $story_dir"
    grep -qE "^status: in-progress$" "$story_file"
    grep -qE "\| FAILED \|" "$story_file"
  done
}

# EC1 — crash path
@test "EC1: injected code-review crash records FAILED and continues the other 5 reviews" {
  [ -x "$RUNNER" ] || skip_fail "runner missing"
  GAIA_TEST_CRASH_REVIEW=code-review NODE_ENV=test "$RUNNER" --fixture-story "$CLEAN_DIR" --trace-out /tmp/e28-s134-ec1.jsonl
  story_file="$(ls "$CLEAN_DIR"/*.md | head -1)"
  grep -qE "Code Review.*FAILED.*(crash|ERROR)" "$story_file"
}

# EC2 — strict monotonic mtime audit
@test "EC2: Review Gate writes are strictly monotonic (sequential per ADR-045)" {
  [ -f "$AUDIT" ] || skip_fail "mtime audit missing"

  local prev=""
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    if [ -n "$prev" ]; then
      [[ "$ts" > "$prev" ]] || return 1
    fi
    prev="$ts"
  done < <(awk '{print $1}' "$AUDIT")
}

# EC4 — normalizer
@test "EC4: verdict normalizer produces only canonical values" {
  [ -x "$NORM" ] || skip_fail "normalizer missing"
  [ "$("$NORM" APPROVE)" = "PASSED" ]
  [ "$("$NORM" REQUEST_CHANGES)" = "FAILED" ]
  [ "$("$NORM" PASSED)" = "PASSED" ]
  [ "$("$NORM" FAILED)" = "FAILED" ]
  out="$("$NORM" OK)"
  [[ "$out" == FAILED* ]]
}

# EC5 — wrong-state guard
@test "EC5: running the gate on an in-progress story refuses and produces no side effects" {
  tmp="$(mktemp -d)"
  cp "$CLEAN_DIR"/*.md "$tmp/story.md"
  # portable in-place sed (macOS + GNU compatibility)
  if sed --version >/dev/null 2>&1; then
    sed -i 's/^status: review$/status: in-progress/' "$tmp/story.md"
  else
    sed -i '' 's/^status: review$/status: in-progress/' "$tmp/story.md"
  fi
  before_md5="$(md5sum "$tmp/story.md" 2>/dev/null | awk '{print $1}' || md5 -q "$tmp/story.md")"
  run "$RUNNER" --fixture-story "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Story must be in"*"review"*"state"* ]]
  after_md5="$(md5sum "$tmp/story.md" 2>/dev/null | awk '{print $1}' || md5 -q "$tmp/story.md")"
  [ "$before_md5" = "$after_md5" ]
}

# EC7 — idempotency on unchanged fixture
@test "EC7: re-running the gate on an unchanged fixture yields byte-equal verdicts" {
  [ -x "$RUNNER" ] || skip_fail "runner missing"
  trace1="$(mktemp)"
  trace2="$(mktemp)"
  "$RUNNER" --fixture-story "$CLEAN_DIR" --trace-out "$trace1"
  "$RESET" >/dev/null
  "$RUNNER" --fixture-story "$CLEAN_DIR" --trace-out "$trace2"
  diff -q <(jq -c '{review, verdict}' "$trace1") <(jq -c '{review, verdict}' "$trace2")
}
