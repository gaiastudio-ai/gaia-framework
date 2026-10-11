#!/usr/bin/env bats
# create-story-token-savings.bats — E63-S11 / Work Item 6 (AC6)
#
# Token-savings benchmark for the /gaia-create-story script-tier wiring.
# Asserts that the post-migration LLM token cost is at least 30% lower than
# the pre-migration baseline, with an absolute target of ~2K tokens saved
# per run (1500-token floor for the absolute check, allowing 25% wiggle room
# against the design intent).
#
# Methodology
# -----------
# The benchmark is a *recorded* measurement, not a live measurement. The
# baseline_total and post_total figures are captured manually from a
# byte-identical fixture (the synthetic E99-S1 story used by the sibling
# create-story-e2e.bats fixture) under two SKILL.md revisions:
#
#   baseline_commit — the last commit before E63 began landing prose-to-
#     script replacements. The baseline exercises the V1 prose pipeline.
#
#   post_commit — the commit that landed E63-S11's SKILL.md rewrite. The
#     post run exercises the thin-orchestrator pipeline.
#
# Token counts include the full /gaia-create-story invocation overhead:
# subagent dispatches (PM Derek, Architect Theo, optional UX Designer
# Christy), Val (ADR-074 contract C2, opus-pinned), and any fix-loop
# attempts. Variance comes from ideation-phase content (AC authoring,
# edge-case ideation) which is unchanged across the two revisions; pinning
# the fixture inputs keeps that variance bounded.
#
# Re-capture trigger
# ------------------
# Refresh the JSON fixture whenever a SKILL.md change exceeds 50 LOC. The
# 50-LOC threshold is the design heuristic from the story Technical Notes
# (significant prose-shape change ⇒ benchmark refresh). Smaller edits do
# not require re-capture; the existing fixture continues to gate the floor.
#
# Models
# ------
# Per ADR-074 contract C2, Val runs on `claude-opus-4-7`; the user-facing
# /gaia-create-story dispatch defaults to Sonnet. Both models are recorded
# in the `model_pin` field of the fixture for audit traceability.
#
# Non-determinism caveats
# -----------------------
# Live token measurements vary slightly across runs due to nucleus sampling
# in the dispatched subagents and cache-hit variance in Val. The benchmark
# is recorded (the bats reads a JSON fixture) precisely to keep CI green
# without paying live LLM costs on every PR. The floor (>= 30%, >= 1500
# absolute saved) carries enough margin to absorb the captured variance.
#
# Spec references
# ---------------
#   - docs/planning-artifacts/feature-create-story-hardening.md (Work Item 6)
#   - docs/planning-artifacts/architecture.md §Decision Log — ADR-074
#   - docs/implementation-artifacts/E63-S11-*.md — this story

load 'test_helper.bash'

setup() {
  common_setup
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/create-story-token-baseline.json"
  export FIXTURE
}
teardown() { common_teardown; }

@test "AC6: token-savings JSON fixture exists" {
  [ -f "$FIXTURE" ]
}

@test "AC6: post-migration tokens are >= 30% lower than baseline" {
  [ -f "$FIXTURE" ]

  # Read baseline_total and post_total from the JSON fixture. Use a small
  # POSIX-y reader (jq if available, fallback grep+awk) so the bats does
  # not hard-depend on jq for environments that haven't installed it.
  local baseline post
  if command -v jq >/dev/null 2>&1; then
    baseline=$(jq -r '.baseline_total' "$FIXTURE")
    post=$(jq -r '.post_total' "$FIXTURE")
  else
    baseline=$(grep -E '"baseline_total"' "$FIXTURE" | head -n1 | grep -oE '[0-9]+')
    post=$(grep -E '"post_total"' "$FIXTURE" | head -n1 | grep -oE '[0-9]+')
  fi

  [ -n "$baseline" ]
  [ -n "$post" ]

  # Compute the savings ratio as an integer percentage to avoid bash float
  # arithmetic issues.
  local ratio_x100
  ratio_x100=$(awk -v b="$baseline" -v p="$post" 'BEGIN { printf "%d", ((b - p) * 100) / b }')

  # Floor: >= 30%
  [ "$ratio_x100" -ge 30 ]
}

@test "AC6: absolute savings >= 1500 tokens (margin against ~2K design target)" {
  [ -f "$FIXTURE" ]

  local baseline post
  if command -v jq >/dev/null 2>&1; then
    baseline=$(jq -r '.baseline_total' "$FIXTURE")
    post=$(jq -r '.post_total' "$FIXTURE")
  else
    baseline=$(grep -E '"baseline_total"' "$FIXTURE" | head -n1 | grep -oE '[0-9]+')
    post=$(grep -E '"post_total"' "$FIXTURE" | head -n1 | grep -oE '[0-9]+')
  fi

  local saved=$((baseline - post))
  [ "$saved" -ge 1500 ]
}

@test "AC6: fixture records both baseline_commit and post_commit for audit" {
  [ -f "$FIXTURE" ]

  # Both commit fields must be present (non-empty strings). Don't assert the
  # exact SHA — re-captures are expected when SKILL.md changes substantially.
  if command -v jq >/dev/null 2>&1; then
    run jq -r '.baseline_commit' "$FIXTURE"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$output" != "null" ]
    run jq -r '.post_commit' "$FIXTURE"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$output" != "null" ]
  else
    grep -E '"baseline_commit"' "$FIXTURE" | head -n1 | grep -q '"[^"]\+"'
    grep -E '"post_commit"' "$FIXTURE" | head -n1 | grep -q '"[^"]\+"'
  fi
}

@test "AC6: fixture records captured_at ISO8601 timestamp" {
  [ -f "$FIXTURE" ]

  if command -v jq >/dev/null 2>&1; then
    run jq -r '.captured_at' "$FIXTURE"
    [ "$status" -eq 0 ]
    # Loose ISO8601 shape: YYYY-MM-DD with optional T-time
    grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' <<<"$output"
  else
    grep -E '"captured_at"' "$FIXTURE" | head -n1 | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'
  fi
}
