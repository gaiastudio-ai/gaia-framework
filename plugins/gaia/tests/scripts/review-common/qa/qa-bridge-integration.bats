#!/usr/bin/env bats
# qa-bridge-integration.bats — E67-S4 bats coverage for Test Execution Bridge
# delegation (AC8).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  STORY_KEY="E67-S4"
  WORKDIR="${TEST_TMP}/.gaia/state/review/qa-tests/${STORY_KEY}"
  mkdir -p "$WORKDIR"
  # Fake bridge run-tests.sh records its invocation to a sentinel file.
  BRIDGE_DIR="${TEST_TMP}/bridge"
  mkdir -p "$BRIDGE_DIR"
  cat > "${BRIDGE_DIR}/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SENTINEL="${BRIDGE_SENTINEL:-/tmp/qa-bridge-sentinel}"
printf '%s\n' "$@" > "$SENTINEL"
# Emit a JSON payload that the runner can parse for evidence.
cat <<JSON
{"suites":[{"name":"bridge","exit_code":0,"pass_count":1,"fail_count":0,"duration_seconds":0.01}]}
JSON
exit 0
EOF
  chmod +x "${BRIDGE_DIR}/run-tests.sh"
  export BRIDGE_SENTINEL="${TEST_TMP}/bridge-sentinel.txt"
  rm -f "$BRIDGE_SENTINEL"
}
teardown() { common_teardown; }

write_bridge_enabled_config() {
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution_bridge:
  bridge_enabled: true
  run_tests_path: ${BRIDGE_DIR}/run-tests.sh
test_execution:
  tier_1:
    placement: local
    command: "false"
    timeout_seconds: 30
EOF
}

write_bridge_disabled_config() {
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution_bridge:
  bridge_enabled: false
test_execution:
  tier_1:
    placement: local
    command: "true"
    timeout_seconds: 30
EOF
}

# --- AC8: bridge enabled -> delegates to run-tests.sh ------------------

@test "AC8: bridge enabled -- runner delegates to run-tests.sh" {
  write_bridge_enabled_config "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local BRIDGE_SENTINEL="$BRIDGE_SENTINEL" \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  # Bridge run-tests.sh was invoked (sentinel file was written).
  [ -f "$BRIDGE_SENTINEL" ]
  # Despite tier_1.command="false" (which would fail), the bridge run
  # returned exit 0 — so the bridge handled execution.
  jq -e '.bridge_used == true' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC8: bridge disabled -> direct execution --------------------------

@test "AC8: bridge disabled -- runner executes commands directly" {
  write_bridge_disabled_config "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local BRIDGE_SENTINEL="$BRIDGE_SENTINEL" \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ ! -f "$BRIDGE_SENTINEL" ]
  jq -e '.bridge_used == false' "$WORKDIR/execution-evidence.json" >/dev/null
}
