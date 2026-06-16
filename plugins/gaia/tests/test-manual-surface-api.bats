#!/usr/bin/env bats
# test-manual-surface-api.bats — AC3: api surface runs real commands
#
# Validates that dispatch-surface.sh for the api surface executes the
# target command, captures transcript + exit code via write-evidence.sh,
# and produces PASSED/FAILED verdicts based on exit code. No pixel
# comparison or screenshot references.
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  DISPATCH="$PLUGIN_DIR/skills/gaia-test-manual/scripts/dispatch-surface.sh"
  WRITE_EVIDENCE="$PLUGIN_DIR/skills/gaia-test-manual/scripts/write-evidence.sh"

  TEST_TMP="$(mktemp -d)"
  EVIDENCE_DIR="$TEST_TMP/evidence"
  mkdir -p "$EVIDENCE_DIR"

  # Config with server platform for api surface
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [server]
YAML
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- AC3: api surface captures transcript ----------

@test "AC3: api dispatch with passing command produces PASSED verdict" {
  run bash "$DISPATCH" --surface api --target "echo hello-api" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "PASSED"
}

@test "AC3: api dispatch writes run-record.md with transcript" {
  bash "$DISPATCH" --surface api --target "echo hello-api" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ -s "$EVIDENCE_DIR/run-record.md" ]
  grep -q "hello-api" "$EVIDENCE_DIR/run-record.md"
}

@test "AC3: api dispatch writes exit-code.log" {
  bash "$DISPATCH" --surface api --target "echo hello-api" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ -s "$EVIDENCE_DIR/exit-code.log" ]
}

@test "AC3: api dispatch with failing command produces FAILED verdict" {
  run bash "$DISPATCH" --surface api --target "exit 1" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  # dispatch itself exits 0 (it completed its job), but verdict is FAILED
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "FAILED"
}

@test "AC3: api dispatch captures exit code in evidence for failing command" {
  bash "$DISPATCH" --surface api --target "exit 42" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" || true
  [ -s "$EVIDENCE_DIR/exit-code.log" ]
  # The actual exit code value must appear in the run-record evidence
  grep -q "42" "$EVIDENCE_DIR/run-record.md"
  # The exit-code.log must also contain the actual exit code value
  grep -q "42" "$EVIDENCE_DIR/exit-code.log"
}

@test "AC3: api dispatch does not reference pixel or screenshot" {
  run bash "$DISPATCH" --surface api --target "echo test" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  ! echo "$output" | grep -qi "pixel"
  ! echo "$output" | grep -qi "screenshot"
}

# ---------- AC3: non-api surfaces emit PENDING ----------

@test "AC3: browser dispatch emits PENDING when configured" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
YAML
  run bash "$DISPATCH" --surface browser --target "some-url" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "PENDING"
}

@test "AC3: mobile dispatch emits PENDING when configured" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [ios]
YAML
  run bash "$DISPATCH" --surface mobile --target "app-flow" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "PENDING"
}

@test "AC3: desktop dispatch emits PENDING when configured" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
sprint_review:
  desktop_commands:
    electron:
      command: "echo test"
YAML
  run bash "$DISPATCH" --surface desktop --target "window-check" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "PENDING"
}

# ---------- AC3: SKIPPED surface passes through ----------

@test "AC3: dispatch for unconfigured surface emits SKIPPED JSON" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [server]
YAML
  run bash "$DISPATCH" --surface browser --target "some-url" \
    --evidence-dir "$EVIDENCE_DIR" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "SKIPPED"
}
