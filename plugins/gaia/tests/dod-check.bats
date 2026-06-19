#!/usr/bin/env bats
# dod-check.bats — coverage for skills/gaia-dev-story/scripts/dod-check.sh
#
# Story: E55-S8 — Auto-reviews YOLO-only (Step 16) + 4 helper scripts + bats coverage
#
# Coverage matrix:
#   - happy path: all checks PASSED, exit 0, six YAML rows
#   - failure path: tests FAILED, exit non-zero, row marked FAILED
#   - idempotency: re-running yields the same final outcome
#   - secrets gate: a staged .env-like file flips secrets row to FAILED
#
# The script is dumb and deterministic — it shells out to project-local
# build/test/lint commands and emits YAML. Tests stub those commands by
# putting fake binaries on PATH inside an isolated TEST_TMP working dir.

load 'test_helper.bash'

setup() {
  common_setup
  DOD_CHECK="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/dod-check.sh"
  cd "$TEST_TMP"
  # Stub git repo so any git invocation in the script is well-defined.
  git init -q -b feat/dummy
  git config user.email "dev@example.com"
  git config user.name "Dev"
  git commit -q --allow-empty -m "init"
  # Per-test stub bin dir prepended to PATH.
  STUB_BIN="$TEST_TMP/stub-bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers — write a tiny shell stub that exits with the requested code.
# ---------------------------------------------------------------------------
_stub() {
  local name="$1" exit_code="${2:-0}" stdout="${3:-}"
  cat > "$STUB_BIN/$name" <<STUB
#!/usr/bin/env bash
[ -n "$stdout" ] && printf '%s\n' "$stdout"
exit $exit_code
STUB
  chmod +x "$STUB_BIN/$name"
}

# ---------------------------------------------------------------------------
# Happy path — all gates pass.
# ---------------------------------------------------------------------------

@test "dod-check: happy path emits all PASSED rows and exits 0" {
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  run "$DOD_CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status: PASSED"* ]]
  # Must have at least the canonical rows.
  for row in build tests lint secrets subtasks; do
    [[ "$output" == *"item: $row"* ]] || {
      echo "missing item row: $row" >&2
      echo "actual: $output" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Failure — tests fail.
# ---------------------------------------------------------------------------

@test "dod-check: tests fail -> tests row FAILED, exit non-zero" {
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"
  # Project-config explicit test_cmd that fails; precedence (a) per AC-EC1.
  cat > "$STUB_BIN/failing-test-runner" <<'STUB'
#!/usr/bin/env bash
echo "tests broke"
exit 1
STUB
  chmod +x "$STUB_BIN/failing-test-runner"
  mkdir -p config
  cat > config/project-config.yaml <<EOF
test_cmd: failing-test-runner
EOF
  run "$DOD_CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"item: tests"* ]]
  [[ "$output" == *"item: tests, status: FAILED"* ]]
}

# ---------------------------------------------------------------------------
# Secrets — staging a .env-like file flips secrets row.
# ---------------------------------------------------------------------------

@test "dod-check: staged .env trips secrets row to FAILED" {
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  printf 'API_KEY=foo\n' > .env
  git add -f .env
  run "$DOD_CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"item: secrets"* ]]
  [[ "$output" == *"status: FAILED"* ]]
}

# ---------------------------------------------------------------------------
# Idempotency — running twice yields the same overall verdict.
# ---------------------------------------------------------------------------

@test "dod-check: idempotent — two consecutive runs match" {
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  run "$DOD_CHECK"
  first_status="$status"
  first_output="$output"
  run "$DOD_CHECK"
  [ "$status" -eq "$first_status" ]
  [ "$output" = "$first_output" ]
}

# ---------------------------------------------------------------------------
# E64-S1 / AC1 / TC-E64-1 — skip /bin/test on macOS
# ---------------------------------------------------------------------------

@test "dod-check: tests row skips system /bin/test (no project test_cmd)" {
  # No project signals — no test_cmd in project-config, no package.json,
  # no tests/*.bats, no project-local test wrapper. The script must NOT
  # resolve to /bin/test or /usr/bin/test and must not emit FAILED for tests.
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  # Make sure no `test` stub is in our STUB_BIN, so PATH falls back to system.
  rm -f "$STUB_BIN/test"
  run "$DOD_CHECK"
  # AC-EC2 — must emit SKIPPED (or PASSED with skipped reason), never FAILED
  [[ "$output" != *"item: tests, status: FAILED"* ]]
  # Check that the tests row is present
  [[ "$output" == *"item: tests"* ]]
}

# ---------------------------------------------------------------------------
# E64-S1 / AC1 / TC-E64-2 — honor project-config.yaml test_cmd
# ---------------------------------------------------------------------------

@test "dod-check: tests row honors project-config.yaml test_cmd: when set" {
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"
  # Put a custom test runner stub
  cat > "$STUB_BIN/my-test-runner" <<'STUB'
#!/usr/bin/env bash
echo "my-test-runner ran"
exit 0
STUB
  chmod +x "$STUB_BIN/my-test-runner"
  mkdir -p config
  cat > config/project-config.yaml <<EOF
test_cmd: my-test-runner
EOF
  run "$DOD_CHECK"
  [[ "$output" == *"item: tests, status: PASSED"* ]]
  # Output must reflect that my-test-runner was invoked, not the system test.
  [[ "$output" == *"my-test-runner"* ]]
}

# ---------------------------------------------------------------------------
# E64-S1 / AC1 / TC-E64-3 — honor package.json scripts.test
# ---------------------------------------------------------------------------

@test "dod-check: tests row falls back to package.json scripts.test" {
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"
  # Provide a `npm` stub that recognizes `npm test` and exits 0
  cat > "$STUB_BIN/npm" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "test" ]; then
  echo "npm test ran"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_BIN/npm"
  cat > package.json <<'JSON'
{
  "name": "stub",
  "scripts": {
    "test": "echo 'pkg test ran' && true"
  }
}
JSON
  run "$DOD_CHECK"
  [[ "$output" == *"item: tests, status: PASSED"* ]]
  [[ "$output" == *"npm test"* ]] || [[ "$output" == *"pkg test"* ]]
}

# ---------------------------------------------------------------------------
# E64-S1 / AC1 / TC-E64-4 — honor bats discovery
# ---------------------------------------------------------------------------

@test "dod-check: tests row falls back to bats discovery on tests/*.bats" {
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"
  # Add a bats stub on PATH that exits 0
  cat > "$STUB_BIN/bats" <<'STUB'
#!/usr/bin/env bash
echo "bats discovery ran with: $*"
exit 0
STUB
  chmod +x "$STUB_BIN/bats"
  mkdir -p tests
  printf '@test "x" { :; }\n' > tests/sample.bats
  run "$DOD_CHECK"
  [[ "$output" == *"item: tests, status: PASSED"* ]]
  [[ "$output" == *"bats discovery ran"* ]]
}

# ---------------------------------------------------------------------------
# E64-S1 / AC-EC2 — no test signals at all → SKIPPED
# ---------------------------------------------------------------------------

@test "dod-check: tests row marked SKIPPED when no test signal exists" {
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"
  run "$DOD_CHECK"
  [[ "$output" == *"item: tests, status: SKIPPED"* ]]
  [[ "$output" == *"no test runner detected"* ]]
}

# ---------------------------------------------------------------------------
# E64-S1 / AC2 / TC-E64-5 — subtask scan ignores DoD-section unchecked items
# ---------------------------------------------------------------------------

@test "dod-check: subtask scan ignores unchecked items outside Tasks/Subtasks" {
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  cat > story.md <<'EOF'
---
key: "E64-S1"
status: in-progress
---

## Tasks / Subtasks

- [x] Task 1
- [x] Task 2

## Acceptance Criteria

- [ ] AC1 (still unchecked at dev time — that's fine)

## Definition of Done

- [ ] PR merged to staging
- [ ] CI green on all required checks
EOF
  STORY_FILE="$TEST_TMP/story.md" run "$DOD_CHECK"
  # Subtask row must be PASSED — Tasks/Subtasks is fully checked, the
  # unchecked items in DoD and AC sections are intentionally excluded.
  [[ "$output" == *"item: subtasks, status: PASSED"* ]]
}

@test "dod-check: subtask scan FAILS when Tasks/Subtasks has unchecked items" {
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  cat > story.md <<'EOF'
---
key: "E64-S1"
status: in-progress
---

## Tasks / Subtasks

- [x] Task 1
- [ ] Task 2 unfinished

## Definition of Done

- [x] All tests pass
EOF
  STORY_FILE="$TEST_TMP/story.md" run "$DOD_CHECK"
  [[ "$output" == *"item: subtasks, status: FAILED"* ]]
}

# ---------------------------------------------------------------------------
# E64-S2 / AC1 — `/bin/test` resolution must emit SKIPPED, never PASSED-skipped
# ---------------------------------------------------------------------------

@test "dod-check : tests row emits SKIPPED when only system /bin/test is on PATH" {
  # Story-file scenario 2: host where `/bin/test` is on PATH but no project
  # signal exists. The row MUST be SKIPPED with the canonical reason — never
  # FAILED, and not silently masked as PASSED with a "skipped" output blurb.
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"  # ensure no project-local `test` wrapper
  # Belt-and-braces: drop config / package.json / tests if a previous run leaked
  rm -rf config package.json tests
  run "$DOD_CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"item: tests, status: SKIPPED"* ]]
  [[ "$output" == *"no test runner detected"* ]]
  [[ "$output" != *"item: tests, status: FAILED"* ]]
  [[ "$output" != *"item: tests, status: PASSED"* ]]
}

# ---------------------------------------------------------------------------
# E64-S2 / AC3 — subtask scan tolerates mixed-case heading + trailing whitespace
# ---------------------------------------------------------------------------

@test "dod-check : subtask scan detects mixed-case '## tasks / subtasks' heading" {
  # Story scenario 4: heading uses lowercase. Without case-insensitive
  # matching the section is missed entirely and unchecked items inside it
  # are silently ignored, producing a false PASSED. To prove the section is
  # actually detected, the fixture has an UNCHECKED box inside the lowercase
  # section — the scan must therefore report FAILED.
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  cat > story.md <<'EOF'
---
key: "E64-S2"
status: in-progress
---

## tasks / subtasks

- [x] Task 1
- [ ] Task 2 unfinished

## Definition of Done

- [x] All tests pass
EOF
  STORY_FILE="$TEST_TMP/story.md" run "$DOD_CHECK"
  [[ "$output" == *"item: subtasks, status: FAILED"* ]]
  [[ "$output" != *"item: subtasks, status: PASSED"* ]]
}

@test "dod-check : subtask scan tolerates trailing whitespace on heading" {
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  # Heading has trailing spaces. Same trick as the mixed-case test: place an
  # UNCHECKED box inside the section so a "section missed entirely" bug
  # would manifest as a false PASSED.
  printf -- '---\nkey: "E64-S2"\nstatus: in-progress\n---\n\n## Tasks / Subtasks   \n\n- [x] Task 1\n- [ ] Task 2 unfinished\n\n## Definition of Done\n\n- [x] All tests pass\n' > story.md
  STORY_FILE="$TEST_TMP/story.md" run "$DOD_CHECK"
  [[ "$output" == *"item: subtasks, status: FAILED"* ]]
  [[ "$output" != *"item: subtasks, status: PASSED"* ]]
}

@test "dod-check : mixed-case heading + unchecked DoD remains scoped to Tasks/Subtasks" {
  # Mixed-case heading + only-checked Tasks/Subtasks + unchecked DoD items.
  # Even with the case-insensitive heading match in place, DoD unchecked
  # boxes must still be excluded — guards against an over-broad fix.
  _stub "build" 0 "build ok"
  _stub "test"  0 "tests ok"
  _stub "lint"  0 "lint ok"
  cat > story.md <<'EOF'
---
key: "E64-S2"
status: in-progress
---

## Tasks / SUBTASKS

- [x] Task 1
- [x] Task 2

## Definition of Done

- [ ] PR merged to staging
- [ ] CI green
EOF
  STORY_FILE="$TEST_TMP/story.md" run "$DOD_CHECK"
  [[ "$output" == *"item: subtasks, status: PASSED"* ]]
}
