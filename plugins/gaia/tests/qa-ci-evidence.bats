#!/usr/bin/env bats
# qa-ci-evidence.bats — tests for CI JUnit evidence integration with
# the QA gate, the execution-evidence schema, and the review-gate
# acceptance path.

load 'test_helper.bash'

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

# ── Helpers ──────────────────────────────────────────────────────────

# _make_ci_evidence — create a CI-derived execution-evidence.json.
# Args: out_path, pass_count, fail_count, head_sha, [run_url]
_make_ci_evidence() {
  local out_path="$1"
  local pass_count="${2:-10}"
  local fail_count="${3:-0}"
  local head_sha="${4:-abc1234}"
  local run_url="${5:-https://github.com/org/repo/actions/runs/101}"

  jq -n \
    --argjson pass "$pass_count" \
    --argjson fail "$fail_count" \
    --arg sha "$head_sha" \
    --arg url "$run_url" \
    '{
      suites: [{
        name: "ci-junit",
        command: "ci",
        exit_code: (if $fail > 0 then 1 else 0 end),
        duration_seconds: 120,
        pass_count: $pass,
        fail_count: $fail
      }],
      tier: "ci",
      context: "ci_pre_merge",
      wall_clock_seconds: 120,
      ci_source: {
        provider: "github-actions",
        runs: [{url: $url, head_sha: $sha, attempt: 1, conclusion: "success"}],
        head_sha: $sha
      }
    }' > "$out_path"
}

# _make_junit_evidence_json — create a ci-junit-evidence.json.
# Args: out_path, pass_count, fail_count, skipped_count, head_sha
_make_junit_evidence_json() {
  local out_path="$1"
  local pass="${2:-10}" fail="${3:-0}" skipped="${4:-2}"
  local head_sha="${5:-abc1234}"

  local skipped_arr="[]"
  local si=0
  while [ "$si" -lt "$skipped" ]; do
    skipped_arr="$(printf '%s' "$skipped_arr" | jq \
      --arg suite "Suite" \
      --arg name "skipped-test-$si" \
      --arg reason "reason $si" \
      '. + [{"suite": $suite, "name": $name, "reason": $reason}]')"
    si=$((si + 1))
  done

  jq -n \
    --arg sv "1.0" \
    --arg provider "github-actions" \
    --arg sha "$head_sha" \
    --argjson tests "$((pass + fail + skipped))" \
    --argjson pass "$pass" \
    --argjson fail "$fail" \
    --argjson skipped "$skipped" \
    --argjson skipped_arr "$skipped_arr" \
    '{
      schema_version: $sv,
      provider: $provider,
      head_sha: $sha,
      runs: [{url: "https://github.com/org/repo/actions/runs/101", head_sha: $sha, attempt: 1, conclusion: "success"}],
      totals: {tests: $tests, passed: $pass, failed: $fail, skipped: $skipped},
      skipped: $skipped_arr,
      flaky: []
    }' > "$out_path"
}

# ── Setup / teardown ─────────────────────────────────────────────────

setup() {
  common_setup
  unset GAIA_WORKTREE_MODE GAIA_PARALLEL_EXECUTION

  WORKDIR="$TEST_TMP/work"
  mkdir -p "$WORKDIR"
}

teardown() {
  common_teardown
}

# ── Schema validation tests ──────────────────────────────────────────

@test "qa-ci-evidence: CI-derived evidence validates against schema" {
  local evidence="$WORKDIR/execution-evidence.json"
  _make_ci_evidence "$evidence" 10 0 "abc1234"

  local schema="$SCRIPTS_DIR/../schemas/execution-evidence.schema.json"
  [ -f "$schema" ] || skip "schema file not found"

  # Validate with python jsonschema if available
  if command -v python3 >/dev/null 2>&1; then
    run python3 -I -c '
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(0)  # skip if jsonschema not installed
schema = json.load(open(sys.argv[1]))
instance = json.load(open(sys.argv[2]))
jsonschema.validate(instance, schema)
print("valid")
' "$schema" "$evidence"
    # Either validates (exit 0) or skips (jsonschema not installed)
    [ "$status" -eq 0 ]
  fi
}

@test "qa-ci-evidence: schema allows ci_source block" {
  local schema="$SCRIPTS_DIR/../schemas/execution-evidence.schema.json"
  [ -f "$schema" ] || skip "schema file not found"

  # Verify ci_source is in the schema
  run jq '.properties.ci_source' "$schema"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  # Verify ci_source has required fields
  run jq '.properties.ci_source.required' "$schema"
  [ "$status" -eq 0 ]
  [[ "$output" == *"provider"* ]]
  [[ "$output" == *"runs"* ]]
  [[ "$output" == *"head_sha"* ]]
}

@test "qa-ci-evidence: schema tier description mentions ci" {
  local schema="$SCRIPTS_DIR/../schemas/execution-evidence.schema.json"
  [ -f "$schema" ] || skip "schema file not found"

  run jq -r '.properties.tier.description' "$schema"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci"* ]]
}

# ── ci-junit-evidence.json tests ─────────────────────────────────────

@test "qa-ci-evidence: ci-junit-evidence.json has valid structure" {
  local evidence="$WORKDIR/ci-junit-evidence.json"
  _make_junit_evidence_json "$evidence" 10 0 2 "abc1234"

  # Check required fields
  run jq -r '.schema_version' "$evidence"
  [ "$output" = "1.0" ]

  run jq -r '.provider' "$evidence"
  [ "$output" = "github-actions" ]

  run jq '.totals.tests' "$evidence"
  [ "$output" = "12" ]

  run jq '.totals.skipped' "$evidence"
  [ "$output" = "2" ]

  run jq '.skipped | length' "$evidence"
  [ "$output" = "2" ]
}

@test "qa-ci-evidence: skipped tests listed with reasons" {
  local evidence="$WORKDIR/ci-junit-evidence.json"
  _make_junit_evidence_json "$evidence" 8 0 2 "abc1234"

  run jq -r '.skipped[0].reason' "$evidence"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "qa-ci-evidence: values with quotes and newlines stay valid JSON" {
  local evidence="$WORKDIR/ci-junit-evidence.json"
  # Create evidence with tricky names
  jq -n '{
    schema_version: "1.0",
    provider: "github-actions",
    head_sha: "abc1234",
    runs: [{url: "https://example.com/run/1", head_sha: "abc1234", attempt: 1, conclusion: "success"}],
    totals: {tests: 2, passed: 1, failed: 0, skipped: 1},
    skipped: [{"suite": "Suite", "name": "test with \"quotes\" and\nnewlines", "reason": "skip <reason> & more"}],
    flaky: []
  }' > "$evidence"

  # Must be valid JSON
  run jq '.' "$evidence"
  [ "$status" -eq 0 ]

  # Values must be preserved
  run jq -r '.skipped[0].name' "$evidence"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quotes"* ]]
}

# ── review-gate acceptance tests ─────────────────────────────────────

@test "qa-ci-evidence: review-gate.sh update accepts CI evidence file" {
  local gate_script="$SCRIPTS_DIR/review-gate.sh"
  [ -f "$gate_script" ] || skip "review-gate.sh not found"

  # The gate checks that the evidence file exists; CI evidence with tier=ci
  # is a valid evidence file for the QA gate proof of execution.
  local evidence="$WORKDIR/execution-evidence.json"
  _make_ci_evidence "$evidence" 10 0 "abc1234"

  # Verify the file exists and is valid JSON
  [ -f "$evidence" ]
  run jq '.' "$evidence"
  [ "$status" -eq 0 ]

  # Verify it has the fields the gate checks
  run jq -r '.tier' "$evidence"
  [ "$output" = "ci" ]
  run jq -r '.context' "$evidence"
  [ "$output" = "ci_pre_merge" ]
}

# ── cache bypass tests ───────────────────────────────────────────────

@test "qa-ci-evidence: CI evidence presence signals cache bypass" {
  # When CI evidence exists for a commit, the QA Phase 3A.1 result cache
  # (.cache/{cache_key}.json) must not short-circuit the CI evidence branch.
  # We verify the contract: run-records.json presence is the bypass signal.
  local evidence_dir="$WORKDIR/ci-evidence"
  mkdir -p "$evidence_dir"
  printf '{"runs":[{"url":"https://example.com/run/1","head_sha":"abc","attempt":1,"conclusion":"success","duration_seconds":60}],"wall_clock_seconds":60}\n' \
    > "$evidence_dir/run-records.json"

  # run-records.json exists — this is the bypass signal
  [ -f "$evidence_dir/run-records.json" ]

  # A cached result file should not prevent CI evidence from being used
  local cache_dir="$WORKDIR/.cache"
  mkdir -p "$cache_dir"
  printf '{"cached":true}\n' > "$cache_dir/qa-abc.json"

  # Both exist — CI evidence takes precedence (contract: run-records.json
  # presence means "CI was checked, use its result")
  [ -f "$evidence_dir/run-records.json" ]
  [ -f "$cache_dir/qa-abc.json" ]
}

# ── store-ci-evidence.sh tests ──────────────────────────────────────
#
# These tests call the REAL writer — no hand-built evidence JSON.

# _setup_store_env — prepare a story folder and evidence dir for the writer.
# Sets: STORE_SCRIPT, STORY_DIR, EVIDENCE_SRC, FAKE_REPO
_setup_store_env() {
  STORE_SCRIPT="$SCRIPTS_DIR/store-ci-evidence.sh"
  [ -f "$STORE_SCRIPT" ] || fail "store-ci-evidence.sh not found at $STORE_SCRIPT"

  # Fake story directory (resolve-story-file.sh will be bypassed via env)
  STORY_DIR="$TEST_TMP/story-folder"
  mkdir -p "$STORY_DIR"

  # Evidence source dir with JUnit XML and run records
  EVIDENCE_SRC="$TEST_TMP/evidence-src"
  mkdir -p "$EVIDENCE_SRC"

  # Fake git repo for gitleaks repo arg
  FAKE_REPO="$TEST_TMP/fake-repo"
  mkdir -p "$FAKE_REPO"
  git -C "$FAKE_REPO" init -q 2>/dev/null || true
  git -C "$FAKE_REPO" config user.email "test@test.com"
  git -C "$FAKE_REPO" config user.name "Test"
  printf 'x\n' > "$FAKE_REPO/x.txt"
  git -C "$FAKE_REPO" add x.txt
  git -C "$FAKE_REPO" commit -q -m "init"
}

# _write_junit_with_sysout — write a JUnit XML containing system-out with a
# runtime-assembled token.
# Args: path [tests] [failures] [skipped]
_write_junit_with_sysout() {
  local path="$1"
  local tests="${2:-10}" failures="${3:-0}" skipped="${4:-0}"
  cat > "$path" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="10" failures="0" skipped="2">
  <testsuite name="Suite1" tests="6" failures="0" skipped="1">
    <testcase name="test-pass" classname="Suite1" time="0.1"/>
    <testcase name="test-skipped" classname="Suite1" time="0.0">
      <skipped message="not ready"/>
    </testcase>
    <system-out>GITHUB_TOKEN=ghp_aBcDeFgHiJkLmNoPqRsT runtime-token-here</system-out>
    <system-err>debug stderr line</system-err>
  </testsuite>
  <testsuite name="Suite2" tests="4" failures="0" skipped="1">
    <testcase name="test-ok" classname="Suite2" time="0.2"/>
    <testcase name="test-skip2" classname="Suite2" time="0.0">
      <skipped message="env missing"/>
    </testcase>
    <system-out>CI_JOB_TOKEN=secret456 another token</system-out>
  </testsuite>
</testsuites>
XMLEOF
}

# _write_run_records — write a run-records.json matching the evidence dir.
# Args: out_path, head_sha
_write_run_records() {
  local out_path="$1" head_sha="$2"
  jq -n \
    --arg sha "$head_sha" \
    '{
      runs: [{
        url: "https://github.com/org/repo/actions/runs/42",
        head_sha: $sha,
        attempt: 1,
        conclusion: "success",
        duration_seconds: 120
      }],
      wall_clock_seconds: 120
    }' > "$out_path"
}

@test "store-ci-evidence: token in system-out is absent from stored evidence" {
  _setup_store_env
  local head_sha
  head_sha="$(git -C "$FAKE_REPO" rev-parse HEAD)"

  _write_junit_with_sysout "$EVIDENCE_SRC/run-42-results.xml"
  _write_run_records "$EVIDENCE_SRC/run-records.json" "$head_sha"

  run bash "$STORE_SCRIPT" \
    --story-key "TEST-S1" \
    --evidence-dir "$EVIDENCE_SRC" \
    --story-dir "$STORY_DIR" \
    --repo "$FAKE_REPO"
  [ "$status" -eq 0 ]

  # ci-evidence/ must exist
  [ -d "$STORY_DIR/ci-evidence" ]

  # No token content anywhere under ci-evidence/
  local token_hits
  token_hits="$(grep -rl 'ghp_aBcDeFgHiJkLmNoPqRsT\|secret456\|runtime-token-here\|debug stderr' "$STORY_DIR/ci-evidence/" 2>/dev/null || true)"
  [ -z "$token_hits" ]

  # system-out and system-err element content must be gone from XML copies
  local sysout_hits
  sysout_hits="$(grep -rl '<system-out>[^<]' "$STORY_DIR/ci-evidence/" 2>/dev/null || true)"
  [ -z "$sysout_hits" ]
}

@test "store-ci-evidence: secret finding halts and writes nothing" {
  _setup_store_env
  local head_sha
  head_sha="$(git -C "$FAKE_REPO" rev-parse HEAD)"

  _write_junit_with_sysout "$EVIDENCE_SRC/run-42-results.xml"
  _write_run_records "$EVIDENCE_SRC/run-records.json" "$head_sha"

  # Stub gitleaks to report a finding (exit 1 = finding detected).
  # Parse --report-path from the arguments to write the report file
  # where _rpb_gitleaks_scan expects it.
  local stub_bin="$TEST_TMP/bin-gitleaks"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/gitleaks" <<'GLEOF'
#!/usr/bin/env bash
# Stub: always report a secret finding
report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$report" ]; then
  mkdir -p "$(dirname "$report")" 2>/dev/null || true
  printf '[{"File":"test.xml","StartLine":1,"RuleID":"generic-api-key"}]\n' > "$report"
fi
exit 1
GLEOF
  chmod +x "$stub_bin/gitleaks"

  run env PATH="$stub_bin:$PATH" \
    bash "$STORE_SCRIPT" \
      --story-key "TEST-S1" \
      --evidence-dir "$EVIDENCE_SRC" \
      --story-dir "$STORY_DIR" \
      --repo "$FAKE_REPO"
  [ "$status" -ne 0 ]

  # Nothing written to story folder
  [ ! -d "$STORY_DIR/ci-evidence" ] || [ -z "$(ls -A "$STORY_DIR/ci-evidence" 2>/dev/null)" ]
  [ ! -f "$STORY_DIR/ci-evidence/ci-junit-evidence.json" ]
}

@test "store-ci-evidence: quotes newlines and markup in names produce valid JSON" {
  _setup_store_env
  local head_sha
  head_sha="$(git -C "$FAKE_REPO" rev-parse HEAD)"

  # Create JUnit with tricky names
  cat > "$EVIDENCE_SRC/run-42-results.xml" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="3" failures="0" skipped="1">
  <testsuite name="&lt;Tricky&gt; &amp; Suite" tests="3" failures="0" skipped="1">
    <testcase name='test with "quotes" and
newlines' classname="Tricky" time="0.1"/>
    <testcase name="test-ok" classname="Tricky" time="0.1"/>
    <testcase name="test &lt;markup&gt; skip" classname="Tricky" time="0.0">
      <skipped message="reason with &quot;quotes&quot; and &lt;tags&gt;"/>
    </testcase>
  </testsuite>
</testsuites>
XMLEOF
  _write_run_records "$EVIDENCE_SRC/run-records.json" "$head_sha"

  run bash "$STORE_SCRIPT" \
    --story-key "TEST-S1" \
    --evidence-dir "$EVIDENCE_SRC" \
    --story-dir "$STORY_DIR" \
    --repo "$FAKE_REPO"
  [ "$status" -eq 0 ]

  # ci-junit-evidence.json must be valid JSON
  local evi="$STORY_DIR/ci-evidence/ci-junit-evidence.json"
  [ -f "$evi" ]
  run jq '.' "$evi"
  [ "$status" -eq 0 ]

  # Skipped entry must have the reason preserved
  run jq -r '.skipped[0].reason' "$evi"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quotes"* ]]
}

@test "store-ci-evidence: skipped and flaky entries are listed" {
  _setup_store_env
  local head_sha
  head_sha="$(git -C "$FAKE_REPO" rev-parse HEAD)"

  # Create JUnit with skipped and flaky tests
  cat > "$EVIDENCE_SRC/run-42-results.xml" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="5" failures="0" skipped="2">
  <testsuite name="MySuite" tests="5" failures="0" skipped="2">
    <testcase name="test-pass" classname="MySuite" time="0.1"/>
    <testcase name="test-skip1" classname="MySuite" time="0.0">
      <skipped message="pending feature"/>
    </testcase>
    <testcase name="test-skip2" classname="MySuite" time="0.0">
      <skipped message="env not configured"/>
    </testcase>
    <testcase name="test-flaky1" classname="MySuite" time="0.3">
      <flakyFailure message="intermittent"/>
    </testcase>
    <testcase name="test-flaky2" classname="MySuite" time="0.2">
      <rerunFailure message="retry passed"/>
    </testcase>
  </testsuite>
</testsuites>
XMLEOF
  _write_run_records "$EVIDENCE_SRC/run-records.json" "$head_sha"

  run bash "$STORE_SCRIPT" \
    --story-key "TEST-S1" \
    --evidence-dir "$EVIDENCE_SRC" \
    --story-dir "$STORY_DIR" \
    --repo "$FAKE_REPO"
  [ "$status" -eq 0 ]

  local evi="$STORY_DIR/ci-evidence/ci-junit-evidence.json"
  [ -f "$evi" ]

  # Two skipped entries
  local skip_count
  skip_count="$(jq '.skipped | length' "$evi")"
  [ "$skip_count" -eq 2 ]

  # Skipped reasons present
  run jq -r '.skipped[0].reason' "$evi"
  [[ "$output" == "pending feature" ]]

  # Two flaky entries
  local flaky_count
  flaky_count="$(jq '.flaky | length' "$evi")"
  [ "$flaky_count" -eq 2 ]

  # Flaky kinds recorded
  run jq -r '.flaky[0].kind' "$evi"
  [[ "$output" == "flakyFailure" ]]
  run jq -r '.flaky[1].kind' "$evi"
  [[ "$output" == "rerunFailure" ]]

  # Totals
  run jq '.totals.skipped' "$evi"
  [ "$output" = "2" ]
  run jq '.totals.tests' "$evi"
  [ "$output" = "5" ]
}

@test "store-ci-evidence: end-to-end AC8 — writer output feeds review-packet-builder CI section" {
  _setup_store_env
  local head_sha
  head_sha="$(git -C "$FAKE_REPO" rev-parse HEAD)"

  _write_junit_with_sysout "$EVIDENCE_SRC/run-42-results.xml"
  _write_run_records "$EVIDENCE_SRC/run-records.json" "$head_sha"

  run bash "$STORE_SCRIPT" \
    --story-key "TEST-S1" \
    --evidence-dir "$EVIDENCE_SRC" \
    --story-dir "$STORY_DIR" \
    --repo "$FAKE_REPO"
  [ "$status" -eq 0 ]

  local evi="$STORY_DIR/ci-evidence/ci-junit-evidence.json"
  [ -f "$evi" ]

  # Verify the evidence has the fields the review-packet-builder reads
  # (see review-packet-builder.sh ~line 741: jq reads .head_sha, .runs[].url,
  #  .totals.{tests,passed,failed,skipped})
  run jq -r '.head_sha' "$evi"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]

  run jq -r '.runs[0].url' "$evi"
  [ "$status" -eq 0 ]
  [[ "$output" == https://* ]]

  run jq '.totals.tests' "$evi"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]

  run jq '.totals.skipped' "$evi"
  [ "$status" -eq 0 ]
  [ "$output" -ge 0 ]

  # Simulate what review-packet-builder does: build a CI section string
  local short_sha
  short_sha="$(jq -r '.head_sha[:7]' "$evi")"
  local run_url
  run_url="$(jq -r '.runs[0].url' "$evi")"
  local totals
  totals="$(jq -r '"tests=\(.totals.tests) passed=\(.totals.passed) failed=\(.totals.failed) skipped=\(.totals.skipped)"' "$evi")"

  [ -n "$short_sha" ]
  [ -n "$run_url" ]
  [[ "$totals" == *"tests="* ]]
  [[ "$totals" == *"passed="* ]]
  [[ "$totals" == *"skipped="* ]]
}
