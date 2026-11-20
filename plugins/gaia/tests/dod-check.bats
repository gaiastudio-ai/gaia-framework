#!/usr/bin/env bats
# dod-check.bats — coverage for skills/gaia-dev-story/scripts/dod-check.sh
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
  # Project-config explicit test_cmd that fails (highest non-bridge precedence).
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
# System /bin/test must not be treated as a project test runner.
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
  # Must emit SKIPPED (or PASSED with skipped reason), never FAILED
  [[ "$output" != *"item: tests, status: FAILED"* ]]
  # Check that the tests row is present
  [[ "$output" == *"item: tests"* ]]
}

# ---------------------------------------------------------------------------
# project-config.yaml test_cmd takes precedence over package.json and bats.
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
# package.json scripts.test fallback when no project-config test_cmd is set.
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
# bats discovery fallback when no higher-precedence test runner resolves.
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
# No test signals at all -> tests row SKIPPED.
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
# Subtask scan is scoped to the Tasks/Subtasks section only.
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
# /bin/test resolution must emit SKIPPED, never a masked PASSED.
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
# Subtask scan tolerates mixed-case heading and trailing whitespace.
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

# ---------------------------------------------------------------------------
# Clean child environment — a caller's project-root variables must not reach
# the project's own test / build / lint commands. A suite that resolves
# canonical paths otherwise sees the caller's ambient root instead of its own
# fixture root and reports failures a clean checkout would never produce.
# ---------------------------------------------------------------------------

@test "dod-check : resolved test command does not see the caller's project-root variables" {
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"
  # A runner that reports exactly what project-root variables it can see.
  cat > "$STUB_BIN/env-probe-runner" <<'STUB'
#!/usr/bin/env bash
printf 'PROJECT_ROOT=[%s] CLAUDE_PROJECT_ROOT=[%s] PROJECT_PATH=[%s] CLAUDE_PLUGIN_ROOT=[%s]\n' \
  "${PROJECT_ROOT:-}" "${CLAUDE_PROJECT_ROOT:-}" "${PROJECT_PATH:-}" "${CLAUDE_PLUGIN_ROOT:-}"
exit 0
STUB
  chmod +x "$STUB_BIN/env-probe-runner"
  mkdir -p config
  cat > config/project-config.yaml <<EOF
test_cmd: env-probe-runner
EOF

  PROJECT_PATH=/ambient/leaked-path \
  PROJECT_ROOT=/ambient/leaked-root \
  CLAUDE_PROJECT_ROOT=/ambient/leaked-claude-root \
  CLAUDE_PLUGIN_ROOT=/ambient/leaked-plugin-root \
    run "$DOD_CHECK"

  [[ "$output" == *"item: tests, status: PASSED"* ]]
  [[ "$output" != *"ambient"* ]]
  [[ "$output" == *"PROJECT_ROOT=[]"* ]]
  [[ "$output" == *"CLAUDE_PROJECT_ROOT=[]"* ]]
  [[ "$output" == *"PROJECT_PATH=[]"* ]]
  [[ "$output" == *"CLAUDE_PLUGIN_ROOT=[]"* ]]
}

@test "dod-check : resolved build and lint commands also run with a cleared project root" {
  rm -f "$STUB_BIN/test"
  cat > "$STUB_BIN/script-env-probe" <<'STUB'
#!/usr/bin/env bash
printf 'observed PROJECT_PATH=[%s]\n' "${PROJECT_PATH:-}"
exit 0
STUB
  chmod +x "$STUB_BIN/script-env-probe"
  mkdir -p config
  cat > config/project-config.yaml <<EOF
build_cmd: script-env-probe
lint_cmd: script-env-probe
EOF

  PROJECT_PATH=/ambient/leaked-path run "$DOD_CHECK"

  [[ "$output" == *"item: build, status: PASSED"* ]]
  [[ "$output" == *"item: lint, status: PASSED"* ]]
  [[ "$output" != *"ambient"* ]]
  [[ "$output" == *"observed PROJECT_PATH=[]"* ]]
}

# ---------------------------------------------------------------------------
# Bridge tier-1 runner — manifest path resolution.
#
# The bridge tier is the highest-precedence test-runner source (rung 0).
# When bridge_enabled is true in project-config.yaml, the script must
# resolve the test-environment manifest from the canonical config path
# first, with the legacy artifact path as fallback.
# ---------------------------------------------------------------------------

# Helper: write a yq stub that handles the two expressions dod-check.sh uses:
#   .test_execution_bridge.bridge_enabled  (from project-config.yaml)
#   [.runners[] | select(.tier == 1)] | .[0].command  (from the manifest)
# Any other expression returns empty string (safe fall-through).
_stub_yq() {
  local bridge_enabled_val="$1" runner_cmd_val="${2:-}"
  cat > "$STUB_BIN/yq" <<YQ_STUB
#!/usr/bin/env bash
expr="\$2"
case "\$expr" in
  *.bridge_enabled*)
    printf '%s\n' "$bridge_enabled_val"
    ;;
  *runners*tier*command*|*runners*select*command*)
    printf '%s\n' "$runner_cmd_val"
    ;;
  *)
    printf '\n'
    ;;
esac
exit 0
YQ_STUB
  chmod +x "$STUB_BIN/yq"
}

# Helper: file-aware yq stub that dispatches the tier-1 runner command
# based on which manifest file the script passes as the third argument.
# Used by the "both paths exist" test where canonical and legacy manifests
# carry different runners.
_stub_yq_by_file() {
  local canonical_runner="$1" legacy_runner="$2"
  cat > "$STUB_BIN/yq" <<YQ_STUB
#!/usr/bin/env bash
expr="\$2"
file="\$3"
case "\$expr" in
  *.bridge_enabled*)
    printf 'true\n'
    ;;
  *runners*tier*command*|*runners*select*command*)
    case "\$file" in
      *.gaia/config/test-environment.yaml)
        printf '%s\n' "$canonical_runner"
        ;;
      *.gaia/artifacts/test-artifacts/test-environment.yaml)
        printf '%s\n' "$legacy_runner"
        ;;
      *)
        printf '\n'
        ;;
    esac
    ;;
  *)
    printf '\n'
    ;;
esac
exit 0
YQ_STUB
  chmod +x "$STUB_BIN/yq"
}

# Common bridge-test scaffolding: build/lint stubs, no test stub, and a
# project-config.yaml with bridge_enabled: true under .gaia/config/.
_setup_bridge() {
  _stub "build" 0 "build ok"
  _stub "lint"  0 "lint ok"
  rm -f "$STUB_BIN/test"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'YAML'
test_execution_bridge:
  bridge_enabled: true
YAML
}

@test "dod-check: bridge tier-1 reads runner from canonical config path" {
  # When the manifest exists at the canonical .gaia/config/ location,
  # the script must read the tier-1 runner from that file.
  _setup_bridge

  cat > .gaia/config/test-environment.yaml <<'YAML'
runners:
  - tier: 1
    command: canonical-bridge-runner
YAML

  _stub "canonical-bridge-runner" 0 "canonical runner executed"
  _stub_yq "true" "canonical-bridge-runner"

  run "$DOD_CHECK"
  grep -qF 'item: tests, status: PASSED' <<<"$output"
  grep -qE 'canonical-bridge-runner|canonical runner executed' <<<"$output"
}

@test "dod-check: bridge tier-1 falls back to legacy artifact path" {
  # Regression guard: when only the legacy .gaia/artifacts/test-artifacts/
  # path exists, the script must still find the runner there.
  _setup_bridge

  mkdir -p .gaia/artifacts/test-artifacts
  cat > .gaia/artifacts/test-artifacts/test-environment.yaml <<'YAML'
runners:
  - tier: 1
    command: legacy-bridge-runner
YAML

  _stub "legacy-bridge-runner" 0 "legacy runner executed"
  _stub_yq "true" "legacy-bridge-runner"

  run "$DOD_CHECK"
  grep -qF 'item: tests, status: PASSED' <<<"$output"
  grep -qE 'legacy-bridge-runner|legacy runner executed' <<<"$output"
}

@test "dod-check: bridge enabled but no manifest reports unconfigured" {
  # When the bridge is enabled but no test-environment manifest exists
  # at any path, the tests row must be SKIPPED (not a hard error) and
  # the output must name the bridge as the reason.
  _setup_bridge
  _stub_yq "true" ""

  run "$DOD_CHECK"
  grep -qF 'item: tests, status: SKIPPED' <<<"$output"
  grep -qF 'bridge enabled but no test-environment manifest found' <<<"$output"
}

@test "dod-check: bridge tier-1 uses canonical path when both paths exist" {
  # When both the canonical (.gaia/config/) and legacy (.gaia/artifacts/)
  # manifests exist, the canonical path must win.
  _setup_bridge

  cat > .gaia/config/test-environment.yaml <<'YAML'
runners:
  - tier: 1
    command: canonical-bridge-runner
YAML

  mkdir -p .gaia/artifacts/test-artifacts
  cat > .gaia/artifacts/test-artifacts/test-environment.yaml <<'YAML'
runners:
  - tier: 1
    command: legacy-bridge-runner
YAML

  _stub "canonical-bridge-runner" 0 "canonical runner executed"
  _stub "legacy-bridge-runner" 0 "legacy runner executed"
  _stub_yq_by_file "canonical-bridge-runner" "legacy-bridge-runner"

  run "$DOD_CHECK"
  grep -qF 'item: tests, status: PASSED' <<<"$output"
  grep -qE 'canonical-bridge-runner|canonical runner executed' <<<"$output"
  ! grep -qF 'legacy-bridge-runner' <<<"$output" || false
  ! grep -qF 'legacy runner executed' <<<"$output" || false
}

@test "dod-check: bridge enabled, no manifest, lower tier resolves and runs" {
  # When the bridge is enabled but no manifest exists, the lower-tier
  # test-command resolution (project-config test_cmd, package.json, bats
  # discovery) must still run. The bridge-specific SKIPPED message should
  # only appear when nothing at all resolves.
  _setup_bridge
  _stub_yq "true" ""

  # A test_cmd in project-config that should still be found and executed.
  cat > "$STUB_BIN/fallback-test-runner" <<'STUB'
#!/usr/bin/env bash
echo "fallback-test-runner executed"
exit 0
STUB
  chmod +x "$STUB_BIN/fallback-test-runner"
  cat >> .gaia/config/project-config.yaml <<'YAML'
test_cmd: fallback-test-runner
YAML

  run "$DOD_CHECK"
  grep -qF 'item: tests, status: PASSED' <<<"$output"
  grep -qE 'fallback-test-runner|fallback-test-runner executed' <<<"$output"
}
