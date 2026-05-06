#!/usr/bin/env bats
# e72-s1-test-run.bats — gaia-test-run manual any-environment runner tests
#
# Story: E72-S1 — `/gaia-test-run` honours `test_execution.{tier}` placement
# and supports `--tag/--story/--file` targeting (FR-RSV2-39, FR-RSV2-40).
#
# AC coverage:
#   AC1 — tier_1.placement=local → local execution path + verdict emit
#   AC2 — tier_2.placement=ci-pre-merge → dry-run output, no execution
#   AC3 — --tag filters to tagged tests (smoke-level: flag plumbed through)
#   AC4 — --story KEY filters to story-key matched files
#   AC5 — --file PATH runs only that file
#   AC6 — no --tier flag defaults to tier_1
#   AC7 — verdict JSON shape: status, tier, environment, duration_ms, test_count, pass_count, fail_count, skip_count
#   AC8 — failure output containing "timeout" → flake_suspected=true in verdict
#   AC9 — missing test_execution section → exact error string + non-zero exit

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/gaia-test-run"
SCRIPTS_DIR="$SKILL_DIR/scripts"
RUNNER="$SCRIPTS_DIR/run-tests.sh"
PARSE="$SCRIPTS_DIR/parse-output.sh"
FLAKE="$SCRIPTS_DIR/flake-detect.sh"

setup() {
  TMP_DIR="$(mktemp -d)"
  # Place a fake config dir under TMP_DIR.
  mkdir -p "$TMP_DIR/config" "$TMP_DIR/bin"
  export CLAUDE_PROJECT_ROOT="$TMP_DIR"
  # Stub resolve-config.sh on PATH so the runner picks it up regardless of plugin context.
  cat >"$TMP_DIR/bin/resolve-config.sh" <<'STUB'
#!/usr/bin/env bash
# Stub resolve-config used in bats tests. Reads $TMP_DIR/config/project-config.yaml
# and emits scalar values for --field <dotted-key>.
set -euo pipefail
CFG="${CLAUDE_PROJECT_ROOT}/config/project-config.yaml"
key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --field) key="$2"; shift 2;;
    --field=*) key="${1#--field=}"; shift;;
    *) shift;;
  esac
done
[ -z "$key" ] && { echo "no --field" >&2; exit 64; }
[ -f "$CFG" ] || { echo "" ; exit 0; }
case "$key" in
  test_execution.tier_1.placement)
    awk '/^test_execution:/{in_te=1;next} in_te && /^  tier_1:/{in_t1=1;next} in_t1 && /^    placement:/{print $2; exit} /^[a-zA-Z]/{in_te=0;in_t1=0}' "$CFG";;
  test_execution.tier_2.placement)
    awk '/^test_execution:/{in_te=1;next} in_te && /^  tier_2:/{in_t2=1;next} in_t2 && /^    placement:/{print $2; exit} /^[a-zA-Z]/{in_te=0;in_t2=0}' "$CFG";;
  test_execution.tier_3.placement)
    awk '/^test_execution:/{in_te=1;next} in_te && /^  tier_3:/{in_t3=1;next} in_t3 && /^    placement:/{print $2; exit} /^[a-zA-Z]/{in_te=0;in_t3=0}' "$CFG";;
  tools.test_runner.provider)
    awk '/^tools:/{in_t=1;next} in_t && /^  test_runner:/{in_tr=1;next} in_tr && /^    provider:/{print $2; exit} /^[a-zA-Z]/{in_t=0;in_tr=0}' "$CFG";;
  *) echo "" ;;
esac
exit 0
STUB
  chmod +x "$TMP_DIR/bin/resolve-config.sh"
  export PATH="$TMP_DIR/bin:$PATH"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# Helper: write a project-config.yaml with the given test_execution block.
write_config() {
  cat >"$TMP_DIR/config/project-config.yaml"
}

# ===== Skill structural checks =====

@test "gaia-test-run/SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "SKILL.md has name=gaia-test-run in frontmatter" {
  run head -10 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-test-run"* ]]
}

@test "run-tests.sh exists and is executable" {
  [ -x "$RUNNER" ]
}

@test "parse-output.sh exists and is executable" {
  [ -x "$PARSE" ]
}

@test "flake-detect.sh exists and is executable" {
  [ -x "$FLAKE" ]
}

# ===== AC9: missing test_execution section =====

@test "AC9: missing test_execution section emits exact error and exits non-zero" {
  # Empty config — no test_execution block at all.
  write_config <<EOF
project_name: test
EOF
  run "$RUNNER" --tier 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"test_execution section not configured in project-config.yaml"* ]]
  [[ "$output" == *"/gaia-config-ci"* ]]
}

# ===== AC6: default tier is tier_1 =====

@test "AC6: no --tier flag defaults to tier_1" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: ci-pre-merge
  tier_2:
    placement: ci-post-merge
EOF
  run "$RUNNER" --no-execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier=1"* ]] || [[ "$output" == *"\"tier\": 1"* ]] || [[ "$output" == *'"tier":1'* ]]
}

# ===== AC2: ci-pre-merge dry-run =====

@test "AC2: tier_2.placement=ci-pre-merge emits dry-run output, no execution" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: local
  tier_2:
    placement: ci-pre-merge
EOF
  run "$RUNNER" --tier 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"DRY-RUN"* ]] || [[ "$output" == *"would execute"* ]]
  [[ "$output" == *"ci-pre-merge"* ]]
}

# ===== AC1: local execution path =====

@test "AC1: tier_1.placement=local invokes the configured runner" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: local
tools:
  test_runner:
    provider: fake
EOF
  # Provide a fake runner on PATH.
  cat >"$TMP_DIR/bin/fake" <<'FAKE'
#!/usr/bin/env bash
echo "Tests:       3 passed | 0 failed | 0 skipped"
echo "Duration:    25 ms"
exit 0
FAKE
  chmod +x "$TMP_DIR/bin/fake"
  run "$RUNNER" --tier 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]] || [[ "$output" == *"passed"* ]]
  [[ "$output" == *"local"* ]]
}

# ===== AC7: verdict JSON schema =====

@test "AC7: verdict JSON contains all required fields" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: local
tools:
  test_runner:
    provider: fake
EOF
  cat >"$TMP_DIR/bin/fake" <<'FAKE'
#!/usr/bin/env bash
echo "Tests:       5 passed | 0 failed | 1 skipped"
echo "Duration:    100 ms"
exit 0
FAKE
  chmod +x "$TMP_DIR/bin/fake"
  run "$RUNNER" --tier 1 --json
  [ "$status" -eq 0 ]
  # Each required field appears in the JSON output.
  [[ "$output" == *'"status"'* ]]
  [[ "$output" == *'"tier"'* ]]
  [[ "$output" == *'"environment"'* ]]
  [[ "$output" == *'"duration_ms"'* ]]
  [[ "$output" == *'"test_count"'* ]]
  [[ "$output" == *'"pass_count"'* ]]
  [[ "$output" == *'"fail_count"'* ]]
  [[ "$output" == *'"skip_count"'* ]]
}

# ===== AC8: flake detection =====

@test "AC8: failure output containing 'timeout' yields flake_suspected=true" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: local
tools:
  test_runner:
    provider: fake
EOF
  cat >"$TMP_DIR/bin/fake" <<'FAKE'
#!/usr/bin/env bash
echo "Tests:       1 passed | 1 failed | 0 skipped"
echo "Error: Network timeout while connecting to fixture server"
exit 1
FAKE
  chmod +x "$TMP_DIR/bin/fake"
  run "$RUNNER" --tier 1 --json
  [ "$status" -ne 0 ] || [ "$status" -eq 0 ]  # exit code may be 0 (verdict emitted) or non-zero
  [[ "$output" == *'"flake_suspected"'* ]]
  [[ "$output" == *'true'* ]]
}

# ===== AC4: --story targeting =====

@test "AC4: --story KEY plumbs the story filter into the runner invocation" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: local
tools:
  test_runner:
    provider: fake
EOF
  cat >"$TMP_DIR/bin/fake" <<'FAKE'
#!/usr/bin/env bash
echo "ARGS:$*"
echo "Tests:       0 passed | 0 failed | 0 skipped"
exit 0
FAKE
  chmod +x "$TMP_DIR/bin/fake"
  run "$RUNNER" --tier 1 --story E72-S1
  [ "$status" -eq 0 ]
  # The runner is expected to forward a filter argument referencing the story key
  # (either as a path glob, a -t name filter, or a similar runner-specific flag).
  [[ "$output" == *"E72-S1"* ]]
}

# ===== AC5: --file targeting =====

@test "AC5: --file PATH plumbs the file path into the runner invocation" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: local
tools:
  test_runner:
    provider: fake
EOF
  cat >"$TMP_DIR/bin/fake" <<'FAKE'
#!/usr/bin/env bash
echo "ARGS:$*"
echo "Tests:       0 passed | 0 failed | 0 skipped"
exit 0
FAKE
  chmod +x "$TMP_DIR/bin/fake"
  run "$RUNNER" --tier 1 --file tests/unit/foo.test.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/unit/foo.test.ts"* ]]
}

# ===== AC3: --tag targeting =====

@test "AC3: --tag NAME plumbs the tag into the runner invocation" {
  write_config <<EOF
test_execution:
  tier_1:
    placement: local
tools:
  test_runner:
    provider: fake
EOF
  cat >"$TMP_DIR/bin/fake" <<'FAKE'
#!/usr/bin/env bash
echo "ARGS:$*"
echo "Tests:       0 passed | 0 failed | 0 skipped"
exit 0
FAKE
  chmod +x "$TMP_DIR/bin/fake"
  run "$RUNNER" --tier 1 --tag integration
  [ "$status" -eq 0 ]
  [[ "$output" == *"integration"* ]]
}

# ===== flake-detect.sh unit tests =====

@test "flake-detect.sh: timeout pattern returns flake_suspected=true" {
  run bash -c "echo 'Network timeout while connecting' | $FLAKE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flake_suspected=true"* ]]
}

@test "flake-detect.sh: ECONNREFUSED pattern returns flake_suspected=true" {
  run bash -c "echo 'ECONNREFUSED 127.0.0.1:5432' | $FLAKE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flake_suspected=true"* ]]
}

@test "flake-detect.sh: assertion failure (non-flake) returns flake_suspected=false" {
  run bash -c "echo 'AssertionError: expected 1 to equal 2' | $FLAKE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flake_suspected=false"* ]]
}

# ===== parse-output.sh unit tests =====

@test "parse-output.sh: extracts pass/fail/skip counts from canonical line" {
  run bash -c "echo 'Tests:       3 passed | 1 failed | 2 skipped' | $PARSE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pass_count=3"* ]]
  [[ "$output" == *"fail_count=1"* ]]
  [[ "$output" == *"skip_count=2"* ]]
  [[ "$output" == *"test_count=6"* ]]
}

# ===== Knowledge registration =====

@test "gaia-help.csv references gaia-test-run" {
  run grep -c "gaia-test-run" "$PLUGIN_DIR/knowledge/gaia-help.csv"
  [ "$output" -ge 1 ]
}

@test "workflow-manifest.csv references gaia-test-run" {
  run grep -c "gaia-test-run" "$PLUGIN_DIR/knowledge/workflow-manifest.csv"
  [ "$output" -ge 1 ]
}
