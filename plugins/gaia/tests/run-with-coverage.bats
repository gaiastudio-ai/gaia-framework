#!/usr/bin/env bats
# run-with-coverage.bats — regression tests for run-with-coverage.sh.
# Story: E28-S184
# Coverage:
#   AC1, AC2  — wrapper runs all 4 steps; guarded grep pipelines do not abort
#   AC5       — bats fixture assertions for zero-func, uncovered-func, JSON shape
#   AC6       — distinct "0 public functions — skipping" log line
#   AC-EC1    — script with exactly 1 public function (boundary vs zero)
#   AC-EC4    — private-only `_foo()` functions are skipped (not false-uncovered)
#   AC-EC8    — new script with no matching .bats file surfaces uncovered by name
#   AC-EC10   — LC_ALL=C invariant pinned in wrapper header
#   AC-EC12   — public-functions.json is valid JSON even when all scripts skipped

load 'test_helper.bash'

setup() {
  common_setup
  WRAPPER="$BATS_TEST_DIRNAME/run-with-coverage.sh"

  # Strip BATS_RETRY_SCRIPT so the wrapper does not enter the retry-script
  # code path when these tests exercise it. In CI, the outer wrapper unsets
  # the var before spawning bats; but a developer may export it in their
  # shell, and each bats subprocess would inherit it. Unsetting here keeps
  # the fake-bats-based coverage tests deterministic.
  unset BATS_RETRY_SCRIPT

  # Fixture layout mirrors the real plugins/gaia/ layout so the wrapper's
  # REPO_ROOT derivation still works, but env-var overrides for SCRIPTS_DIR
  # and TESTS_DIR let us point at a fresh tmpdir per test.
  export FIXTURE_ROOT="$TEST_TMP/fixture"
  export FIXTURE_SCRIPTS="$FIXTURE_ROOT/scripts"
  export FIXTURE_TESTS="$FIXTURE_ROOT/tests"
  export FIXTURE_COVERAGE="$FIXTURE_ROOT/coverage"
  mkdir -p "$FIXTURE_SCRIPTS" "$FIXTURE_TESTS" "$FIXTURE_COVERAGE"

  # Env vars the wrapper honours under test (added in E28-S184).
  export SCRIPTS_DIR_OVERRIDE="$FIXTURE_SCRIPTS"
  export TESTS_DIR_OVERRIDE="$FIXTURE_TESTS"
  export COVERAGE_DIR="$FIXTURE_COVERAGE"
  # Fake bats so Step 2 always passes quickly in tests — avoids recursive
  # invocation of the real bats binary against our fixture tests dir.
  export FAKE_BATS_BIN="$TEST_TMP/fake-bats"
  cat > "$FAKE_BATS_BIN" <<'FAKEBATS'
#!/usr/bin/env bash
# Fake bats used in E28-S184 regression tests — always exits 0.
exit 0
FAKEBATS
  chmod +x "$FAKE_BATS_BIN"
  export PATH="$TEST_TMP:$PATH"
  ln -sf "$FAKE_BATS_BIN" "$TEST_TMP/bats"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC2, AC6, AC-EC1, AC-EC4 — wrapper does not abort on zero-public-function
# script; emits the skip log line; proceeds through all four steps.
# ---------------------------------------------------------------------------
@test "AC2/EC2 wrapper continues past script with zero public functions" {
  # Script with only a private helper — should be treated as zero public.
  cat > "$FIXTURE_SCRIPTS/empty-script.sh" <<'EOF'
#!/usr/bin/env bash
_private_helper() { :; }
EOF

  # A second script with one public function that IS covered by the bats fixture.
  cat > "$FIXTURE_SCRIPTS/one-func.sh" <<'EOF'
#!/usr/bin/env bash
do_something() { echo "hi"; }
EOF
  # IMPORTANT: do NOT write `@test "..."` inside heredocs in this file.
  # The parent bats parser scans for `^\s*@test` across every file in the
  # tests directory during its static pre-count phase, including content
  # embedded in heredocs. Any `@test` line in these fixtures — even
  # indented — inflates the parent suite's expected test count and fails
  # the job with "Executed N instead of expected M tests".
  # The wrapper's Step 3 coverage check is a plain `grep` for the function
  # name across every *.bats file, so a comment-only fixture containing
  # the function name is sufficient to mark the function as covered.
  cat > "$FIXTURE_TESTS/one-func.bats" <<'EOF'
#!/usr/bin/env bats
# Fixture references do_something so the wrapper's grep-based coverage
# check sees the public function as covered.
EOF

  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty-script.sh: 0 public functions"* ]]
  [[ "$output" == *"skipping"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — public-functions.json is valid JSON; coverage-summary.json contains
# the uncovered_total field.
# ---------------------------------------------------------------------------
@test "AC5 public-functions.json and coverage-summary.json are valid JSON" {
  cat > "$FIXTURE_SCRIPTS/mixed.sh" <<'EOF'
#!/usr/bin/env bash
public_one() { :; }
_private_two() { :; }
EOF
  cat > "$FIXTURE_TESTS/mixed.bats" <<'EOF'
#!/usr/bin/env bats
# Fixture references public_one so the wrapper's coverage check passes.
EOF

  run bash "$WRAPPER"
  [ "$status" -eq 0 ]

  # jq is required in CI and local setups per plugin-ci.yml; skip if absent.
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi

  run jq -e '.' "$FIXTURE_COVERAGE/public-functions.json"
  [ "$status" -eq 0 ]

  run jq -e '.uncovered_total | type == "number"' "$FIXTURE_COVERAGE/coverage-summary.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5, AC-EC8 — wrapper exits 1 when an uncovered public function exists.
# ---------------------------------------------------------------------------
@test "AC5 wrapper exits 1 when an uncovered public function exists" {
  cat > "$FIXTURE_SCRIPTS/needs-coverage.sh" <<'EOF'
#!/usr/bin/env bash
uniquely_named_uncovered_fn_abc123() { :; }
EOF
  # No bats file references the function — it must land in uncovered.

  run bash "$WRAPPER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uniquely_named_uncovered_fn_abc123"* ]]

  if command -v jq >/dev/null 2>&1; then
    run jq -e '.uncovered_total >= 1' "$FIXTURE_COVERAGE/coverage-summary.json"
    [ "$status" -eq 0 ]
  fi
}

# ---------------------------------------------------------------------------
# AC-EC1 — script with exactly 1 public function is enumerated and covered.
# ---------------------------------------------------------------------------
@test "AC-EC1 script with exactly one public function is enumerated correctly" {
  cat > "$FIXTURE_SCRIPTS/single.sh" <<'EOF'
#!/usr/bin/env bash
only_public_fn() { :; }
EOF
  cat > "$FIXTURE_TESTS/single.bats" <<'EOF'
#!/usr/bin/env bats
# Fixture references only_public_fn so the wrapper's coverage check passes.
EOF

  run bash "$WRAPPER"
  [ "$status" -eq 0 ]

  if command -v jq >/dev/null 2>&1; then
    run jq -e '.["single.sh"] | length == 1' "$FIXTURE_COVERAGE/public-functions.json"
    [ "$status" -eq 0 ]
  fi
}

# ---------------------------------------------------------------------------
# AC-EC4 — private-only script (all underscore prefixes) is skipped without
# generating a false uncovered entry.
# ---------------------------------------------------------------------------
@test "AC-EC4 private-only script produces no uncovered entries" {
  cat > "$FIXTURE_SCRIPTS/privates.sh" <<'EOF'
#!/usr/bin/env bash
_helper_one() { :; }
_helper_two() { :; }
EOF

  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"privates.sh: 0 public functions"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC12 — all scripts skipped → public-functions.json still valid JSON.
# ---------------------------------------------------------------------------
@test "AC-EC12 all-empty scripts produce valid JSON output" {
  cat > "$FIXTURE_SCRIPTS/zero-a.sh" <<'EOF'
#!/usr/bin/env bash
_only_private() { :; }
EOF
  cat > "$FIXTURE_SCRIPTS/zero-b.sh" <<'EOF'
#!/usr/bin/env bash
# no functions at all
EOF

  run bash "$WRAPPER"
  [ "$status" -eq 0 ]

  if command -v jq >/dev/null 2>&1; then
    run jq -e '.' "$FIXTURE_COVERAGE/public-functions.json"
    [ "$status" -eq 0 ]
    run jq -e '.uncovered_total == 0' "$FIXTURE_COVERAGE/coverage-summary.json"
    [ "$status" -eq 0 ]
  fi
}

# ---------------------------------------------------------------------------
# AC-EC10 — LC_ALL=C invariant pinned at the top of the wrapper.
# ---------------------------------------------------------------------------
@test "AC-EC10 wrapper pins LC_ALL=C in its header" {
  run grep -n '^LC_ALL=C' "$WRAPPER"
  [ "$status" -eq 0 ]
  # Ensure the pin appears in the wrapper header (first 60 lines, before any
  # functional logic) — a drift guard against future refactors that move it
  # into a conditional branch or after Step 1.
  line_num="${output%%:*}"
  [ "$line_num" -le 60 ]
}

# ---------------------------------------------------------------------------
# Regression: BATS_RETRY_SCRIPT must not leak into the wrapper when tests run.
# When the variable is inherited from the outer environment, the wrapper must
# capture it and unset it so nested bats processes (and their tests) do not
# see it. This test explicitly re-exports the variable to prove the wrapper
# still passes — the setup() unset prevents the other tests from tripping
# on the retry-script code path; this test verifies the wrapper's own
# sanitisation.
# ---------------------------------------------------------------------------
@test "wrapper unsets BATS_RETRY_SCRIPT so nested bats processes do not inherit it" {
  cat > "$FIXTURE_SCRIPTS/simple.sh" <<'EOF'
#!/usr/bin/env bash
do_thing() { :; }
EOF
  cat > "$FIXTURE_TESTS/simple.bats" <<'EOF'
#!/usr/bin/env bats
# Fixture references do_thing for coverage.
EOF

  # Point BATS_RETRY_SCRIPT at a script that captures the variable and fails
  # if it is still set when bats runs.
  local probe="$TEST_TMP/retry-probe.sh"
  cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
# This script is invoked in place of bats-shard-retry.sh. It checks whether
# the wrapper leaked BATS_RETRY_SCRIPT into its environment.
if [ -n "${BATS_RETRY_SCRIPT:-}" ]; then
  printf 'LEAK: BATS_RETRY_SCRIPT is still set: %s\n' "$BATS_RETRY_SCRIPT" >&2
  exit 99
fi
# Skip the actual retry logic — we only needed the env check.
exit 0
PROBE
  chmod +x "$probe"

  # Re-export BATS_RETRY_SCRIPT for this one test only.
  BATS_RETRY_SCRIPT="$probe" run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  # The probe must not have printed a LEAK line.
  [[ "$output" != *"LEAK:"* ]]
}

# ---------------------------------------------------------------------------
# AC1 / AC2 drift guard — wrapper source still contains a guarded grep form
# (pipefail-safe). If a future refactor drops `|| true`, this fails loudly.
# ---------------------------------------------------------------------------
@test "AC2 wrapper source uses pipefail-safe grep guard" {
  run grep -c '|| true' "$WRAPPER"
  [ "$status" -eq 0 ]
  # At least two guards — Step 1 (enumerate) and Step 3 (coverage check).
  [ "$output" -ge 2 ]
}
