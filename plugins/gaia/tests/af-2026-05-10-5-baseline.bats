#!/usr/bin/env bats
# af-2026-05-10-5-baseline.bats — TC-MSS-SUBSHARD-10 (E53-S251).
#
# Verifies the WARNING-count convergence across the E53-S249 + E53-S250 fix:
# pre-fix baseline = 12 WARNINGs; post-fix expected = 9 WARNINGs.
#
# The 3 cleared lines are the structural sub-shard false-positives that
# E53-S249 (check-monolith-shard-sync.sh sub-shard awareness) eliminated.
# The 9 unchanged lines are real per-section content drift between PRD
# §5/§11/§12/§13/§14 monolith vs shards, and architecture §2/§12/§13/
# Version-History monolith vs shards — out of scope for AF-2026-05-10-5.

setup() {
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/af-2026-05-10-5-baseline"
  PRE_FIX_FILE="$FIXTURE_DIR/pre-fix-warnings.txt"
  POST_FIX_FILE="$FIXTURE_DIR/post-fix-warnings.txt"
}

@test "TC-MSS-SUBSHARD-10: pre-fix fixture is 12 WARNINGs (historical baseline)" {
  [ -f "$PRE_FIX_FILE" ]
  count=$(grep -c '^WARNING' "$PRE_FIX_FILE")
  [ "$count" -eq 12 ]
}

@test "TC-MSS-SUBSHARD-10: post-fix fixture is 9 WARNINGs (expected after E53-S249 + E53-S250)" {
  [ -f "$POST_FIX_FILE" ]
  count=$(grep -c '^WARNING' "$POST_FIX_FILE")
  [ "$count" -eq 9 ]
}

@test "TC-MSS-SUBSHARD-10: count delta is 12 -> 9 (3 cleared)" {
  pre=$(grep -c '^WARNING' "$PRE_FIX_FILE")
  post=$(grep -c '^WARNING' "$POST_FIX_FILE")
  delta=$((pre - post))
  [ "$delta" -eq 3 ]
}

@test "TC-MSS-SUBSHARD-10: 3 cleared lines are the structural sub-shard false-positives" {
  # The lines in pre-fix but NOT in post-fix MUST be the 3 structural
  # false-positives (PRD §4 missing-shard + PRD §4 Sub-Sharded absent +
  # architecture §10 Sub-Sharded absent).
  cleared=$(comm -23 <(sort "$PRE_FIX_FILE") <(sort "$POST_FIX_FILE"))
  cleared_count=$(printf '%s\n' "$cleared" | grep -c '^WARNING' || true)
  [ "$cleared_count" -eq 3 ]
  # Sanity: each cleared line should mention either "no matching shard" or
  # "Sub-Sharded".
  printf '%s\n' "$cleared" | grep -q 'no matching shard'
  printf '%s\n' "$cleared" | grep -q 'Sub-Sharded'
}

@test "TC-MSS-SUBSHARD-10: 9 unchanged lines are real per-section drift (out of scope for this AF)" {
  unchanged=$(comm -12 <(sort "$PRE_FIX_FILE") <(sort "$POST_FIX_FILE"))
  unchanged_count=$(printf '%s\n' "$unchanged" | grep -c '^WARNING' || true)
  [ "$unchanged_count" -eq 9 ]
  # Sanity: each unchanged line should mention "diverges between" (the
  # real-drift signature, vs structural absence).
  unchanged_diverges=$(printf '%s\n' "$unchanged" | grep -c 'diverges between' || true)
  [ "$unchanged_diverges" -eq 9 ]
}

@test "TC-MSS-SUBSHARD-10: live drift-report output matches post-fix fixture" {
  # AC1 — the live `check-monolith-shard-sync.sh` from project root must
  # emit exactly the 9 WARNINGs captured in the post-fix fixture.
  # Skip cleanly when running outside the live project-root checkout
  # (CI runs against gaia-framework/ alone, where the docs/planning-artifacts/
  # monolith+shard tree doesn't exist; in that environment the script
  # emits 0 WARNINGs and the AC1 assertion does not apply).
  cd "$BATS_TEST_DIRNAME/../../../.."  # land at gaia-framework/ in CI, project-root locally
  if [ ! -f "docs/planning-artifacts/prd/prd.md" ] || [ ! -f "gaia-framework/plugins/gaia/scripts/check-monolith-shard-sync.sh" ]; then
    skip "not running from project root (no docs/planning-artifacts tree) — fixture-only mode"
  fi
  live=$(bash gaia-framework/plugins/gaia/scripts/check-monolith-shard-sync.sh 2>&1 | grep '^WARNING' || true)
  live_count=$(printf '%s\n' "$live" | grep -c '^WARNING' || true)
  [ "$live_count" -eq 9 ]
}
