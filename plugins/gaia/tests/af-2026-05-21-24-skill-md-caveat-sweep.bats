#!/usr/bin/env bats
# AF-21-24: surgical caveat-file cleanup. Final 14 files containing residual
# docs/ refs after AF-21-23 bulk sweep. Each file has a per-file cap allowing
# only intentional dual-layout caveats / JSON examples / Do-NOT-hardcode
# warnings to remain.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# Helper: assert SKILL.md has AT MOST $expected docs/ literal hits.
_assert_cap() {
  local file="$1" expected="$2"
  local actual=0
  if [ -f "$PLUGIN_ROOT/skills/$file" ]; then
    # grep -c exits 1 on zero matches; mask via || true
    actual=$(grep -cE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts|research-artifacts)' "$PLUGIN_ROOT/skills/$file" 2>/dev/null || true)
    actual=${actual:-0}
  fi
  [ "$actual" -le "$expected" ]
}

@test "AF-21-24: gaia-create-arch/SKILL.md cap 1 (Path-resolution caveat)" {
  _assert_cap gaia-create-arch/SKILL.md 1
}
@test "AF-21-24: gaia-create-prd/SKILL.md cap 1 (Path-resolution caveat)" {
  _assert_cap gaia-create-prd/SKILL.md 1
}
@test "AF-21-24: gaia-edit-arch/SKILL.md cap 1 (Path-resolution caveat)" {
  _assert_cap gaia-edit-arch/SKILL.md 1
}
@test "AF-21-24: gaia-edit-prd/SKILL.md cap 1 (Path-resolution caveat)" {
  _assert_cap gaia-edit-prd/SKILL.md 1
}
@test "AF-21-24: gaia-edit-ux/SKILL.md cap 1 (Path-resolution caveat)" {
  _assert_cap gaia-edit-ux/SKILL.md 1
}
@test "AF-21-24: gaia-help/SKILL.md cap 6 (intentional dual-layout detector + phase indicators)" {
  _assert_cap gaia-help/SKILL.md 6
}
@test "AF-21-24: gaia-meeting/SKILL.md cap 1 (Path-resolution caveat)" {
  _assert_cap gaia-meeting/SKILL.md 1
}
@test "AF-21-24: gaia-qa-tests/SKILL.md cap 3 (Do-NOT-hardcode caveats)" {
  _assert_cap gaia-qa-tests/SKILL.md 3
}
@test "AF-21-24: gaia-review-perf/SKILL.md cap 4 (Do-NOT-hardcode caveats)" {
  _assert_cap gaia-review-perf/SKILL.md 4
}
@test "AF-21-24: gaia-run-all-reviews/SKILL.md cap 3 (ADR-070 dual-layout caveats)" {
  _assert_cap gaia-run-all-reviews/SKILL.md 3
}
@test "AF-21-24: gaia-test-automate/SKILL.md cap 3 (Do-NOT-hardcode caveats)" {
  _assert_cap gaia-test-automate/SKILL.md 3
}
@test "AF-21-24: gaia-test-review/SKILL.md cap 3 (Do-NOT-hardcode caveats)" {
  _assert_cap gaia-test-review/SKILL.md 3
}
@test "AF-21-24: gaia-val-validate/SKILL.md cap 8 (JSON envelope example payloads — illustrative)" {
  _assert_cap gaia-val-validate/SKILL.md 8
}
@test "AF-21-24: gaia-add-stories/SKILL.md zero legacy hits (fully canonical)" {
  _assert_cap gaia-add-stories/SKILL.md 0
}
