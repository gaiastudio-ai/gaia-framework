#!/usr/bin/env bats
# vcp-chk-26-readiness-check-negative.bats — E42-S13 negative test for
# the V1 65-item /gaia-readiness-check checklist ported to V2.
#
# Covers VCP-CHK-26 (negative) per docs/test-artifacts/test-plan.md and
# story AC2: given a readiness-report.md artifact missing 3 items
# across different categories (cascade resolution / traceability /
# gate verdict), finalize.sh exits non-zero and all 3 violations are
# named with category context on stderr.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s13-readiness-check"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-readiness-check"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
  # Seed a self-contained PROJECT_ROOT with the upstream artifacts
  # the fixtures reference — so the PRD/arch/test-plan presence checks
  # pass on the positive path and the 3-missing fixture fails ONLY on
  # the 3 intended anchors (not on incidental "upstream file missing"
  # noise).
  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/docs/planning-artifacts" "$PROJECT_ROOT/docs/test-artifacts"
  : > "$PROJECT_ROOT/docs/planning-artifacts/prd.md"
  : > "$PROJECT_ROOT/docs/planning-artifacts/architecture.md"
  : > "$PROJECT_ROOT/docs/test-artifacts/test-plan.md"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-26 — Negative: artifact missing 3 items across categories.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when 3 items are missing" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the status field anchor in failure output" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"status field present in YAML frontmatter"* ]]
}

@test "finalize.sh names the traceability_complete anchor in failure output" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Traceability complete field present in YAML frontmatter"* ]]
}

@test "finalize.sh names the Pending Cascades anchor in failure output" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pending Cascades section present if cascades tracked"* ]]
}

@test "every violation carries [category: ...] context" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"[category: cascade resolution]"* ]]
  [[ "$output" == *"[category: traceability]"* ]]
  [[ "$output" == *"[category: gate verdict]"* ]]
}

@test "violations span three distinct categories" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  # Count FAIL lines in violations section — expected exactly 3.
  violations="$(printf '%s\n' "$output" \
    | awk '/^Checklist violations:/ { in_sec = 1; next } in_sec && /^  - / { print } in_sec && !/^  - / && !/^Checklist violations:/ { in_sec = 0 }')"
  count="$(printf '%s\n' "$violations" | grep -c '^  - ')"
  [ "$count" = "3" ]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-readiness-check" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"readiness-check"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export READINESS_ARTIFACT="$FIXTURES/readiness-report-missing-3-across-categories.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/implementation-readiness.yaml" ] \
    || [ -f "$CHECKPOINT_PATH/gaia-readiness-check.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 / AC-EC3 — READINESS_ARTIFACT points at a missing file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no readiness report to validate' when READINESS_ARTIFACT points at a missing file" {
  export READINESS_ARTIFACT="$BATS_TMPDIR/does-not-exist-readiness-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no readiness report to validate"* ]]
}

# -------------------------------------------------------------------------
# AC-EC1 / AC-EC2 — 0/65 and 65/65 boundary fixtures.
# The 65/65 case lives in vcp-chk-25 (positive). The 0/65 case is
# exercised by the missing-file variant (AC4) and the empty-file
# variant below (AC-EC3 / empty artifact).
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no readiness report to validate' when the artifact is 0 bytes" {
  local empty
  empty="$TEST_TMP/empty-readiness-report.md"
  : > "$empty"
  [ -f "$empty" ]
  [ ! -s "$empty" ]
  export READINESS_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no readiness report to validate"* ]]
}

# -------------------------------------------------------------------------
# AC-EC8 — Shell metacharacter safety. Pass an artifact path containing
# ; and $(), confirm finalize.sh treats it as a literal file path (no
# injection; no command execution) and emits the AC4 "no artifact to
# validate" violation when the file does not exist.
# -------------------------------------------------------------------------

@test "shell metacharacters in READINESS_ARTIFACT do not cause command injection" {
  local crafted
  crafted="$TEST_TMP/weird; name \$(touch $TEST_TMP/injected).md"
  export READINESS_ARTIFACT="$crafted"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  # Critical: the side-effect file MUST NOT exist — proof that $() did
  # not execute. AC-EC8 / ShellCheck SC2086 coverage.
  [ ! -f "$TEST_TMP/injected" ]
}
