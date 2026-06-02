#!/usr/bin/env bats
# ATDD — E28-S133 Full Lifecycle Test (red phase)
# Each test maps 1:1 to a single acceptance criterion in E28-S133.
# These tests MUST fail on first run — the runner and evidence artifacts do not yet exist.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # In the repo layout, tests live under gaia-framework/plugins/gaia/test/ and the
  # repo root is the gaia-framework/ directory itself.
  RUNNER="$REPO_ROOT/plugins/gaia/test/runners/full-lifecycle.sh"
  FIXTURE_DIR="$REPO_ROOT/plugins/gaia/test/fixtures/cluster-19"
  RUNS_ROOT="$REPO_ROOT/plugins/gaia/test/runs"
  BASELINE_TAG="v-parity-baseline"
  TODAY="$(date -u +%Y-%m-%d)"
  DOCS_ROOT="$REPO_ROOT/../docs"
  RESULTS_FILE="$DOCS_ROOT/test-artifacts/cluster-19-full-lifecycle-results-${TODAY}.md"
  DEFECTS_FILE="$DOCS_ROOT/implementation-artifacts/e28-s133-defects.yaml"
  RUN_ID="atdd-$(date -u +%Y-%m-%dT%H-%M-%S)-$$-$BATS_TEST_NUMBER"
  RUN_DIR="$RUNS_ROOT/$RUN_ID"
  export GAIA_MEMORY_ROOT="$RUN_DIR/memory"
  export GAIA_ATDD=1
}

teardown() {
  # Keep run dir for diagnostics only if explicitly requested.
  if [ -z "${GAIA_KEEP_RUNS:-}" ] && [ -d "$RUN_DIR" ]; then
    rm -rf "$RUN_DIR"
  fi
}

# ---------------------------------------------------------------------------
# AC1 — All 10 stages complete with exit 0, zero non-native fallback.
# ---------------------------------------------------------------------------
@test "AC1: full lifecycle runs all 10 stages natively with zero workflow.xml/.resolved reads" {
  [ -x "$RUNNER" ] || skip_fail "runner missing: $RUNNER"
  [ -d "$FIXTURE_DIR" ] || skip_fail "fixture missing: $FIXTURE_DIR"

  run "$RUNNER" --run-id "$RUN_ID" --fixture "$FIXTURE_DIR" --baseline-tag "$BASELINE_TAG"
  [ "$status" -eq 0 ]

  # Exactly 10 stages in canonical order.
  local expected_stages=(brainstorm product-brief prd ux architecture epics-stories sprint-plan dev-story all-reviews deploy-checklist)
  for stage in "${expected_stages[@]}"; do
    grep -qE "stage=${stage}\b.*exit=0" "$RUN_DIR/trace.log"
  done
  [ "$(grep -cE '^stage=' "$RUN_DIR/trace.log")" -eq 10 ]

  # Native-only guard: zero workflow.xml loads and zero .resolved/ reads across the entire run.
  run grep -cE 'load=.*workflow\.xml|read=.*\.resolved/' "$RUN_DIR/trace.log"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — Parity oracle: zero schema diff, tolerated content drift only.
# ---------------------------------------------------------------------------
@test "AC2: each produced artifact parity-diffs clean against v-parity-baseline" {
  [ -x "$RUNNER" ] || skip_fail "runner missing"
  run "$RUNNER" --run-id "$RUN_ID" --fixture "$FIXTURE_DIR" --baseline-tag "$BASELINE_TAG"
  [ "$status" -eq 0 ]

  [ -f "$RESULTS_FILE" ]

  # Every stage row carries a parity_verdict column and is PASS or TOLERATED_DRIFT — never FAIL.
  run awk -F'|' '/^\| (brainstorm|product-brief|prd|ux|architecture|epics-stories|sprint-plan|dev-story|all-reviews|deploy-checklist) /{print $7}' "$RESULTS_FILE"
  [ "$status" -eq 0 ]
  while IFS= read -r verdict; do
    verdict="$(echo "$verdict" | xargs)"
    [ "$verdict" = "PASS" ] || [ "$verdict" = "TOLERATED_DRIFT" ]
  done <<< "$output"

  # Schematized artifacts (PRD, architecture, sprint-status, story frontmatter, review gate) MUST be schema-exact.
  run grep -E 'schema_diff=0' "$RUN_DIR/parity/prd.diff.meta"
  [ "$status" -eq 0 ]
  run grep -E 'schema_diff=0' "$RUN_DIR/parity/architecture.diff.meta"
  [ "$status" -eq 0 ]

  # Reordering of any list inside epics / sprint waves / review gate is a CRITICAL regression — not tolerated.
  run grep -E 'ordering_regression=true' "$RUN_DIR/parity/epics-stories.diff.meta"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — Every stage handoff: file exists, non-empty, cross-referenced downstream,
# silent skip is a FAIL.
# ---------------------------------------------------------------------------
@test "AC3: every stage handoff verifies artifact exists, is non-empty, and is cross-referenced downstream" {
  [ -x "$RUNNER" ] || skip_fail "runner missing"
  run "$RUNNER" --run-id "$RUN_ID" --fixture "$FIXTURE_DIR" --baseline-tag "$BASELINE_TAG"
  [ "$status" -eq 0 ]

  # For every non-terminal stage, the handoff trace must record existence + size>0 + downstream-reference.
  run grep -cE 'handoff=.* exists=true size_gt_0=true downstream_ref=true' "$RUN_DIR/trace.log"
  [ "$output" -eq 9 ]  # 10 stages => 9 handoffs

  # A silent skip is a hard FAIL: trace must not contain any "stage=*.* status=skipped" lines.
  run grep -cE 'status=skipped' "$RUN_DIR/trace.log"
  [ "$output" -eq 0 ]

  # Negative-path signal: if a stage cannot locate its input, the runner halts with an error naming the missing artifact.
  # Under a green run, no such line exists.
  run grep -cE 'FATAL: missing input for stage=' "$RUN_DIR/trace.log"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4 — Durable results artifact with required sections, SHAs, and table shape.
# ---------------------------------------------------------------------------
@test "AC4: runner emits cluster-19-full-lifecycle-results-{YYYY-MM-DD}.md with required sections" {
  [ -x "$RUNNER" ] || skip_fail "runner missing"
  run "$RUNNER" --run-id "$RUN_ID" --fixture "$FIXTURE_DIR" --baseline-tag "$BASELINE_TAG"
  [ "$status" -eq 0 ]

  [ -f "$RESULTS_FILE" ]

  # Required headings.
  grep -q '^## Stages' "$RESULTS_FILE"
  grep -q '^## Summary' "$RESULTS_FILE"
  grep -q '^## Regressions' "$RESULTS_FILE"

  # Required table header: stage | skill | exit | artifact_path | sha256 | parity_verdict
  grep -qE '^\| stage \| skill \| exit \| artifact_path \| sha256 \| parity_verdict \|' "$RESULTS_FILE"

  # Exactly 10 stage rows (one per lifecycle stage).
  run grep -cE '^\| (brainstorm|product-brief|prd|ux|architecture|epics-stories|sprint-plan|dev-story|all-reviews|deploy-checklist) \|' "$RESULTS_FILE"
  [ "$output" -eq 10 ]

  # gaia-framework HEAD SHA and baseline tag SHA both recorded.
  grep -qE 'gaia_public_head_sha: [0-9a-f]{40}' "$RESULTS_FILE"
  grep -qE 'parity_baseline_sha: [0-9a-f]{40}' "$RESULTS_FILE"
  grep -qE 'baseline_tag: v-parity-baseline' "$RESULTS_FILE"
}

# ---------------------------------------------------------------------------
# AC5 — Parity deltas append to defects YAML, story status is gated.
# ---------------------------------------------------------------------------
@test "AC5: parity deltas append to e28-s133-defects.yaml and hold story in-progress" {
  [ -x "$RUNNER" ] || skip_fail "runner missing"

  # Seed a known regression fixture (runner supports --seed-regression for ATDD only).
  run "$RUNNER" --run-id "$RUN_ID" --fixture "$FIXTURE_DIR" --baseline-tag "$BASELINE_TAG" --seed-regression ordering
  # Expected non-zero exit because AC5 is failing the gate.
  [ "$status" -ne 0 ]

  [ -f "$DEFECTS_FILE" ]

  # Defect entry carries every required field.
  grep -qE '^- stage: (brainstorm|product-brief|prd|ux|architecture|epics-stories|sprint-plan|dev-story|all-reviews|deploy-checklist)$' "$DEFECTS_FILE"
  grep -qE '^  artifact: .+$' "$DEFECTS_FILE"
  grep -qE '^  expected: .+$' "$DEFECTS_FILE"
  grep -qE '^  actual: .+$' "$DEFECTS_FILE"
  grep -qE '^  severity: (critical|high|medium|low)$' "$DEFECTS_FILE"
  grep -qE '^  delta_type: (schema|content|ordering|missing)$' "$DEFECTS_FILE"

  # Story status gate: on any unresolved delta, the runner must transition the story back to in-progress.
  grep -qE 'story_status_next=in-progress' "$RUN_DIR/trace.log"

  # Deferred-delta path requires both signatures; absent them, the defect must NOT be marked closed.
  run grep -cE 'closed_by: .+\(Sable\).*\(Derek\)' "$DEFECTS_FILE"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Helper — fail loudly when a precondition is missing.
# ---------------------------------------------------------------------------
skip_fail() {
  echo "# precondition missing: $*" >&2
  return 1
}
