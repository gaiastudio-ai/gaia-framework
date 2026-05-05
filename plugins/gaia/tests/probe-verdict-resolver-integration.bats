#!/usr/bin/env bats
# probe-verdict-resolver-integration.bats — integration tests for the probe-to-verdict-resolver
# handoff (E66-S2 Task 4, AC2, AC3, TC-RSV2-PROBE-02..03 + Test Scenarios #10, #11).
#
# Verifies:
#   - state=ran_and_errored produced by the probe -> when wired into an analysis-results.json
#     check.status=errored, the verdict resolver emits BLOCKED (rule 1 / EC-3).
#   - state=expected_and_missing -> when wired the same way, the verdict resolver emits BLOCKED.
#   - state=not_applicable -> contributes a check.status=skipped entry that does NOT trigger
#     BLOCKED; with no other failures the verdict is APPROVE.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PROBE="$SCRIPTS_DIR/tool-availability-probe.sh"
  RESOLVER="$SCRIPTS_DIR/verdict-resolver.sh"
}
teardown() { common_teardown; }

# Build an analysis-results.json from a single check object.
build_analysis() {
  local out="$1"; shift
  local check_json="$1"; shift
  cat > "$out" <<EOF
{
  "schema_version": "1.0",
  "story_key": "E66-S2",
  "skill": "gaia-code-review",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [$check_json]
}
EOF
}

empty_findings() {
  printf '{"findings": []}' > "$1"
}

# Run the probe, then convert its state to a check entry, and feed to the resolver.
probe_to_check() {
  local probe_out="$1"; shift
  local tool_name="$1"; shift
  # Map probe state -> check.status:
  #   expected_and_missing -> errored (with error_reason)
  #   ran_and_errored      -> errored (with error_reason)
  #   not_applicable       -> skipped (with skip_reason)
  #   available            -> passed
  jq -c --arg name "$tool_name" '
    if .state == "expected_and_missing" then
      {name: $name, status: "errored", error_reason: ("tool not installed: " + $name)}
    elif .state == "ran_and_errored" then
      {name: $name, status: "errored", error_reason: (.error_detail // "tool failed")}
    elif .state == "not_applicable" then
      {name: $name, status: "skipped", skip_reason: .skip_reason}
    else
      {name: $name, status: "passed"}
    end
  ' <<<"$probe_out"
}

@test "integration: expected_and_missing probe state -> verdict BLOCKED" {
  # Set up a probe scenario: tool not on PATH.
  local adapter_dir="$TEST_TMP/adapter"
  mkdir -p "$adapter_dir"
  cat > "$adapter_dir/adapter.json" <<EOF
{"provider":"definitely-not-real-xyz","category":"linter","runtime-profile":"subprocess",
 "default-timeout-seconds":30,"file-extensions":[".ts"]}
EOF
  echo '#!/usr/bin/env bash' > "$adapter_dir/run.sh"; chmod +x "$adapter_dir/run.sh"
  printf 'src/app.ts\n' > "$TEST_TMP/file-list.txt"

  run -1 --separate-stderr "$PROBE" --adapter-dir "$adapter_dir" --file-list "$TEST_TMP/file-list.txt"
  local probe_json="$output"

  local check; check="$(probe_to_check "$probe_json" definitely-not-real-xyz)"
  local analysis="$TEST_TMP/analysis.json"
  local findings="$TEST_TMP/findings.json"
  build_analysis "$analysis" "$check"
  empty_findings "$findings"

  run --separate-stderr "$RESOLVER" --skill gaia-code-review --analysis-results "$analysis" --llm-findings "$findings"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "integration: ran_and_errored probe state -> verdict BLOCKED" {
  local adapter_dir="$TEST_TMP/adapter"
  mkdir -p "$adapter_dir"
  # Provide a fake binary on PATH so availability passes.
  local fake_dir="$TEST_TMP/fake"
  mkdir -p "$fake_dir"
  cat > "$fake_dir/eslint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake_dir/eslint"

  cat > "$adapter_dir/adapter.json" <<EOF
{"provider":"eslint","category":"linter","runtime-profile":"subprocess",
 "default-timeout-seconds":30,"file-extensions":[".ts"]}
EOF
  cat > "$adapter_dir/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "internal crash" >&2
exit 1
EOF
  chmod +x "$adapter_dir/run.sh"
  printf 'src/app.ts\n' > "$TEST_TMP/file-list.txt"

  PATH="$fake_dir:$PATH" run -1 --separate-stderr "$PROBE" --adapter-dir "$adapter_dir" --file-list "$TEST_TMP/file-list.txt"
  local probe_json="$output"

  local check; check="$(probe_to_check "$probe_json" eslint)"
  local analysis="$TEST_TMP/analysis.json"
  local findings="$TEST_TMP/findings.json"
  build_analysis "$analysis" "$check"
  empty_findings "$findings"

  run --separate-stderr "$RESOLVER" --skill gaia-code-review --analysis-results "$analysis" --llm-findings "$findings"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "integration: not_applicable probe state -> verdict APPROVE (silent skip)" {
  local adapter_dir="$TEST_TMP/adapter"
  mkdir -p "$adapter_dir"
  cat > "$adapter_dir/adapter.json" <<EOF
{"provider":"eslint","category":"linter","runtime-profile":"subprocess",
 "default-timeout-seconds":30,"file-extensions":[".ts",".tsx"]}
EOF
  echo '#!/usr/bin/env bash' > "$adapter_dir/run.sh"; chmod +x "$adapter_dir/run.sh"
  # Python-only file list -> not applicable.
  printf 'src/main.py\n' > "$TEST_TMP/file-list.txt"

  run "$PROBE" --adapter-dir "$adapter_dir" --file-list "$TEST_TMP/file-list.txt"
  [ "$status" -eq 0 ]
  local probe_json="$output"

  local check; check="$(probe_to_check "$probe_json" eslint)"
  local analysis="$TEST_TMP/analysis.json"
  local findings="$TEST_TMP/findings.json"
  build_analysis "$analysis" "$check"
  empty_findings "$findings"

  run --separate-stderr "$RESOLVER" --skill gaia-code-review --analysis-results "$analysis" --llm-findings "$findings"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}
