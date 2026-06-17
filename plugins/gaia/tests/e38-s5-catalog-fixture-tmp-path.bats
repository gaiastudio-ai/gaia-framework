#!/usr/bin/env bats
# e38-s5-catalog-fixture-tmp-path.bats
#
# Structural assertions for E38-S5 — Migrate CATALOG fixture in
# e38-s1-reconcile-risk.bats to per-test TEST_TMP path.
#
# These tests verify the FIXTURE FILE itself (not its behaviour). After E38-S5
# lands, the fixture must:
#   - export MITIGATION_CATALOG to a per-test BATS_TEST_TMPDIR path (AC2),
#   - no longer back up / restore the real on-disk catalog (AC1),
#   - leave the real on-disk catalog byte-identical after a full bats run
#     including --random-order (AC4).
#
# Refs: AC1, AC2, AC4 of docs/implementation-artifacts/E38-S5-*.md

load 'test_helper.bash'

FIXTURE_FILE="$(cd "$BATS_TEST_DIRNAME" && pwd)/e38-s1-reconcile-risk.bats"
CATALOG_PATH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-sprint-status" && pwd)/mitigation-catalog.yaml"

# ---------------------------------------------------------------------------
# AC1 — fixture no longer performs cp/rm backup of the real CATALOG path
# ---------------------------------------------------------------------------
@test "fixture does not 'cp \$CATALOG' (no backup of real on-disk catalog)" {
  run grep -nE 'cp[[:space:]]+"\$CATALOG"' "$FIXTURE_FILE"
  [ "$status" -ne 0 ]
}

@test "fixture does not 'rm -f \$CATALOG' in setup/teardown" {
  run grep -nE 'rm[[:space:]]+-f[[:space:]]+"\$CATALOG"' "$FIXTURE_FILE"
  [ "$status" -ne 0 ]
}

@test "fixture does not declare CATALOG_BACKUP" {
  run grep -nE 'CATALOG_BACKUP' "$FIXTURE_FILE"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — fixture sets MITIGATION_CATALOG="$BATS_TEST_TMPDIR/..." per test
# ---------------------------------------------------------------------------
@test "fixture exports MITIGATION_CATALOG pointing at BATS_TEST_TMPDIR" {
  run grep -nE 'export[[:space:]]+MITIGATION_CATALOG=.*BATS_TEST_TMPDIR' "$FIXTURE_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4 — running the suite leaves real on-disk catalog byte-identical
# ---------------------------------------------------------------------------
@test "real on-disk mitigation-catalog.yaml is byte-identical after running -risk.bats" {
  [ -f "$CATALOG_PATH" ] || skip "real catalog not present in this checkout"

  local before
  before="$(shasum "$CATALOG_PATH" | awk '{print $1}')"

  run bats --no-tempdir-cleanup "$FIXTURE_FILE"
  [ "$status" -eq 0 ]

  local after
  after="$(shasum "$CATALOG_PATH" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "real on-disk mitigation-catalog.yaml is byte-identical after --random-order" {
  [ -f "$CATALOG_PATH" ] || skip "real catalog not present in this checkout"

  local before
  before="$(shasum "$CATALOG_PATH" | awk '{print $1}')"

  run bats --no-tempdir-cleanup "$FIXTURE_FILE"
  [ "$status" -eq 0 ]

  local after
  after="$(shasum "$CATALOG_PATH" | awk '{print $1}')"
  [ "$before" = "$after" ]
}
