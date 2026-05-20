#!/usr/bin/env bats
# run-all-reviews.bats — Cluster 9 integration test (E28-S73)
#
# End-to-end test for gaia-run-all-reviews: verifies all 6 Review Gate rows
# are updated correctly using the canonical PASSED / FAILED / UNVERIFIED
# vocabulary, in the canonical ADR-045 order.
#
# Refs: FR-323, FR-325, FR-330, NFR-048, NFR-052, NFR-053, ADR-041, ADR-045
# Brief: P9-S8

load 'test_helper.bash'

# ---------- Paths ----------

CLUSTER9_DIR="${BATS_TEST_DIRNAME}"
FIXTURES_DIR="${CLUSTER9_DIR}/fixtures"
EXPECTED_DIR="${FIXTURES_DIR}/expected"
# Override SCRIPTS_DIR from test_helper (which resolves relative to tests/)
# Cluster 9 tests need the scripts dir two levels up from cluster-9/
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"

# ---------- Helpers ----------

setup() {
  common_setup
  TEST_PROJECT="$TEST_TMP"
  # Post-E28-S99, review-gate.sh::locate_story_file resolves story files
  # directly under IMPLEMENTATION_ARTIFACTS (flat directory), matching
  # sprint-state.sh. The fixture must be installed at that flat location,
  # not under a stories/ subdirectory — otherwise reviewers run but the
  # writeback target resolves to "no story file found" and Review Gate
  # rows stay UNVERIFIED. See E28-S174.
  ART="$TEST_PROJECT/docs/implementation-artifacts"
  mkdir -p "$ART"

  export PROJECT_PATH="$TEST_PROJECT"
  export REVIEW_GATE_SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  # AF-2026-05-20-1: this suite exercises the orchestration mechanics with
  # MOCK_VERDICTS — the mock-orchestrator invokes review-gate.sh update
  # without --report. Disable the proof-of-execution gate so the suite can
  # focus on orchestration order / canonical sequence / parity tracing.
  # The proof-of-execution contract has its own dedicated suite at
  # tests/review-gate-proof-of-execution.bats.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  # Preserve temp dir path on failure for post-mortem (AC fixture doc)
  BATS_PRESERVE_TMPDIR_ON_FAILURE=1
}

teardown() {
  if [ "$BATS_TEST_COMPLETED" = 1 ]; then
    common_teardown
  else
    # Preserve temp path in TAP log for post-mortem
    echo "# POST-MORTEM: temp dir preserved at $TEST_TMP" >&3
  fi
}

# Copy fixture story to the test temp dir
install_fixture() {
  cp "$FIXTURES_DIR/C9-FIXTURE-fake.md" "$ART/C9-FIXTURE-fake.md"
}

# Create mock reviewers that all return PASSED
seed_all_pass_reviewers() {
  local mock_dir="$TEST_TMP/mock-reviewers"
  mkdir -p "$mock_dir"
  for reviewer in code-review security-review qa-generate-tests test-automation test-review performance-review; do
    cat > "$mock_dir/$reviewer" <<'MOCK'
#!/usr/bin/env bash
echo "PASSED"
exit 0
MOCK
    chmod +x "$mock_dir/$reviewer"
  done
  export REVIEWER_MOCK_DIR="$mock_dir"
}

# Create mock reviewers where security-review returns FAILED, rest PASSED
seed_security_failed_reviewers() {
  local mock_dir="$TEST_TMP/mock-reviewers"
  mkdir -p "$mock_dir"
  for reviewer in code-review qa-generate-tests test-automation test-review performance-review; do
    cat > "$mock_dir/$reviewer" <<'MOCK'
#!/usr/bin/env bash
echo "PASSED"
exit 0
MOCK
    chmod +x "$mock_dir/$reviewer"
  done
  cat > "$mock_dir/security-review" <<'MOCK'
#!/usr/bin/env bash
echo "FAILED"
exit 0
MOCK
  chmod +x "$mock_dir/security-review"
  export REVIEWER_MOCK_DIR="$mock_dir"
}

# Extract the Review Gate table from the story file and normalize it.
# Returns one line per gate row: "| <gate_name> | <status> | — |"
extract_review_gate_table() {
  local file="$1"
  awk '
    /^## Review Gate/ { in_gate = 1; next }
    in_gate && /^## / { in_gate = 0 }
    in_gate && /^\|/ && !/^\|[-]+/ && !/^\| Review/ {
      n = split($0, cells, "|")
      if (n >= 4) {
        gate = cells[2]; status = cells[3]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
        if (gate != "") printf "| %s | %s | — |\n", gate, status
      }
    }
  ' "$file"
}

# Parse the review-runner.sh stderr output to extract the invocation sequence
extract_reviewer_sequence() {
  local stderr_file="$1"
  grep 'running reviewer' "$stderr_file" | sed 's/.*running reviewer [0-9]\/6: //' | sed 's/ (.*//'
}

# Validate all Review Gate Status cells are in canonical vocabulary
validate_canonical_vocabulary() {
  local file="$1"
  local non_canonical=0
  local status_values
  status_values=$(awk '
    /^## Review Gate/ { in_gate = 1; next }
    in_gate && /^## / { in_gate = 0 }
    in_gate && /^\|/ && !/^\|[-]+/ && !/^\| Review/ {
      split($0, cells, "|")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[3])
      if (cells[3] != "") print cells[3]
    }
  ' "$file")

  while IFS= read -r val; do
    case "$val" in
      PASSED|FAILED|UNVERIFIED) ;;
      *) non_canonical=1; echo "NON-CANONICAL: '$val'" ;;
    esac
  done <<< "$status_values"
  return $non_canonical
}

# ---------- Test 1: Happy path — all six reviewers pass (AC1, AC2) ----------

@test "happy path: all 6 reviewers run and produce all-PASSED gate table" {
  install_fixture
  seed_all_pass_reviewers

  run "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE"
  [ "$status" -eq 0 ]

  # Verify all 6 gate rows updated to PASSED
  run "$SCRIPTS_DIR/review-gate.sh" check --story "C9-FIXTURE"
  [ "$status" -eq 0 ]
}

# ---------- Test 2: Vocabulary invariant — only canonical values (AC2) ----------

@test "vocabulary invariant: all gate values are canonical after all-pass run" {
  install_fixture
  seed_all_pass_reviewers

  "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE" 2>/dev/null

  run validate_canonical_vocabulary "$ART/C9-FIXTURE-fake.md"
  [ "$status" -eq 0 ]
}

# ---------- Test 3: Snapshot diff — all-pass matches expected (AC2) ----------

@test "all-pass snapshot: Review Gate table matches expected/review-gate-all-pass.md" {
  install_fixture
  seed_all_pass_reviewers

  "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE" 2>/dev/null

  # Extract actual Review Gate section
  local actual expected
  actual=$(extract_review_gate_table "$ART/C9-FIXTURE-fake.md")
  expected=$(extract_review_gate_table "$EXPECTED_DIR/review-gate-all-pass.md")

  [ "$actual" = "$expected" ]
}

# ---------- Test 4: Negative path — one reviewer FAILED (AC3) ----------

@test "negative path: security-review FAILED, remaining 5 still run" {
  install_fixture
  seed_security_failed_reviewers

  run "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE"
  # Should exit non-zero because at least one FAILED
  [ "$status" -ne 0 ]

  # All 6 gate writes should have happened
  run "$SCRIPTS_DIR/review-gate.sh" status --story "C9-FIXTURE"
  [ "$status" -eq 0 ]
  # Parse JSON: Security Review should be FAILED, rest PASSED
  echo "$output" | jq -e '.gates["Security Review"] == "FAILED"'
  echo "$output" | jq -e '.gates["Code Review"] == "PASSED"'
  echo "$output" | jq -e '.gates["QA Tests"] == "PASSED"'
  echo "$output" | jq -e '.gates["Test Automation"] == "PASSED"'
  echo "$output" | jq -e '.gates["Test Review"] == "PASSED"'
  echo "$output" | jq -e '.gates["Performance Review"] == "PASSED"'
}

# ---------- Test 5: Negative path — story status stays review (not done) (AC3b) ----------

@test "negative path: story frontmatter status remains review (not auto-transitioned)" {
  install_fixture
  seed_security_failed_reviewers

  "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE" 2>/dev/null || true

  # Story status should still be review (review-runner.sh does NOT transition state)
  grep -q 'status: review' "$ART/C9-FIXTURE-fake.md"
}

# ---------- Test 6: Negative snapshot diff (AC3) ----------

@test "negative-path snapshot: Review Gate table matches expected/review-gate-security-failed.md" {
  install_fixture
  seed_security_failed_reviewers

  "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE" 2>/dev/null || true

  local actual expected
  actual=$(extract_review_gate_table "$ART/C9-FIXTURE-fake.md")
  expected=$(extract_review_gate_table "$EXPECTED_DIR/review-gate-security-failed.md")

  if [ "$actual" != "$expected" ]; then
    echo "EXPECTED:"
    echo "$expected"
    echo "ACTUAL:"
    echo "$actual"
    diff -u <(echo "$expected") <(echo "$actual") || true
    return 1
  fi
}

# ---------- Test 7: Canonical order — ADR-045 sequence (AC1) ----------

@test "canonical order: reviewers invoked in ADR-045 sequence" {
  install_fixture
  seed_all_pass_reviewers

  local stderr_file="$TEST_TMP/runner-stderr.txt"
  "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE" 2>"$stderr_file"

  local sequence
  sequence=$(extract_reviewer_sequence "$stderr_file")

  local expected_sequence="code-review
security-review
qa-generate-tests
test-automation
test-review
performance-review"

  [ "$sequence" = "$expected_sequence" ]
}

# ---------- Test 8: Each reviewer invoked exactly once (AC1) ----------

@test "each reviewer invoked exactly once" {
  install_fixture
  seed_all_pass_reviewers

  local stderr_file="$TEST_TMP/runner-stderr.txt"
  "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE" 2>"$stderr_file"

  local count
  count=$(grep -c 'running reviewer' "$stderr_file")
  [ "$count" -eq 6 ]
}

# ---------- Test 9: Vocabulary breach detection — non-canonical value (AC2) ----------

@test "vocabulary invariant: parser detects non-canonical value" {
  install_fixture

  # Manually inject a non-canonical value
  sed -i.bak 's/Code Review | UNVERIFIED/Code Review | PASS/' "$ART/C9-FIXTURE-fake.md"
  rm -f "$ART/C9-FIXTURE-fake.md.bak"

  run validate_canonical_vocabulary "$ART/C9-FIXTURE-fake.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NON-CANONICAL"* ]]
  [[ "$output" == *"PASS"* ]]
}

# ---------- Test 10: Temp-dir isolation — no writes outside temp dir ----------

@test "isolation: no writes to repo state outside test temp dir" {
  install_fixture
  seed_all_pass_reviewers

  # Record state of the fixtures dir before the run
  local fixtures_hash_before fixtures_hash_after
  fixtures_hash_before=$(find "$FIXTURES_DIR" -type f -exec shasum {} \; | sort)

  "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE" 2>/dev/null

  fixtures_hash_after=$(find "$FIXTURES_DIR" -type f -exec shasum {} \; | sort)
  [ "$fixtures_hash_before" = "$fixtures_hash_after" ]
}

# ---------- E58-S5: dead-code regression + true orchestration harness ----------

# AC1 (TC-RAR-13): the dead `echo "PASSED"` path at lines 172-176 is gone.
# The only literal `echo "PASSED"` left in the file MUST be inside the
# mock-mode branch of run_reviewer().
@test "E58-S5 AC1: dead PASSED echo removed; only one mock-branch occurrence remains" {
  local count
  count=$(grep -cE '^[[:space:]]*echo "PASSED"$' "$SCRIPTS_DIR/review-runner.sh")
  [ "$count" -eq 1 ]
}

# Helper: stub a sibling script ("$1") to append a tag ("$2") to a trace file.
# The stub overrides the real script via env-var override (REVIEW_*_SCRIPT).
seed_orchestration_trace_stubs() {
  local stub_dir="$TEST_TMP/orch-stubs"
  mkdir -p "$stub_dir"

  # Skip-check stub: emits all-run JSON and traces "skip-check"
  cat > "$stub_dir/review-skip-check.sh" <<MOCK
#!/usr/bin/env bash
echo "skip-check" >> "$TEST_TMP/orch-trace.txt"
echo '{"skip":[],"run":["code-review","qa-tests","security-review","test-automate","test-review","review-perf"]}'
exit 0
MOCK
  chmod +x "$stub_dir/review-skip-check.sh"

  # Summary-gen stub
  cat > "$stub_dir/review-summary-gen.sh" <<MOCK
#!/usr/bin/env bash
echo "summary-gen" >> "$TEST_TMP/orch-trace.txt"
echo "/tmp/fake-summary.md"
exit 0
MOCK
  chmod +x "$stub_dir/review-summary-gen.sh"

  # Nudge stub
  cat > "$stub_dir/review-nudge.sh" <<MOCK
#!/usr/bin/env bash
echo "nudge" >> "$TEST_TMP/orch-trace.txt"
exit 0
MOCK
  chmod +x "$stub_dir/review-nudge.sh"

  export REVIEW_SKIP_CHECK_SCRIPT="$stub_dir/review-skip-check.sh"
  export REVIEW_SUMMARY_GEN_SCRIPT="$stub_dir/review-summary-gen.sh"
  export REVIEW_NUDGE_SCRIPT="$stub_dir/review-nudge.sh"
}

# AC2 (TC-RAR-14): mock-mode orchestration order must be:
#   skip-check -> 6x (judgment + gate-write) -> summary-gen -> nudge.
@test "E58-S5 AC2: MOCK_VERDICTS orchestration order matches contract" {
  install_fixture
  seed_orchestration_trace_stubs

  : > "$TEST_TMP/orch-trace.txt"
  export MOCK_MODE=true
  export MOCK_VERDICTS="PASS,PASS,PASS,PASS,PASS,PASS"

  run "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE"
  [ "$status" -eq 0 ]

  # Trace must record skip-check first, summary-gen second-to-last, nudge last.
  local trace
  trace=$(cat "$TEST_TMP/orch-trace.txt")
  [ "$(echo "$trace" | head -1)" = "skip-check" ]
  [ "$(echo "$trace" | tail -2 | head -1)" = "summary-gen" ]
  [ "$(echo "$trace" | tail -1)" = "nudge" ]
}

# AC4 / AC-EC3 (ECI-668): a CRASH sentinel in MOCK_VERDICTS must produce a
# FAILED gate row for the crashing slot AND let the run continue to the
# remaining reviewers, each recording their own verdict.
@test "E58-S5 AC4: CRASH sentinel writes FAILED row and run continues" {
  install_fixture
  seed_orchestration_trace_stubs

  : > "$TEST_TMP/orch-trace.txt"
  export MOCK_MODE=true
  export MOCK_VERDICTS="PASS,CRASH,PASS,PASS,PASS,PASS"

  run "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE"
  # Exit non-zero because at least one reviewer FAILED.
  [ "$status" -ne 0 ]

  # Reviewer #2 in canonical order is security-review (the run order matches
  # REVIEWER_SKILLS in review-runner.sh: code-review, security-review, ...).
  run "$SCRIPTS_DIR/review-gate.sh" status --story "C9-FIXTURE"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.gates["Code Review"] == "PASSED"'
  echo "$output" | jq -e '.gates["Security Review"] == "FAILED"'
  echo "$output" | jq -e '.gates["QA Tests"] == "PASSED"'
  echo "$output" | jq -e '.gates["Test Automation"] == "PASSED"'
  echo "$output" | jq -e '.gates["Test Review"] == "PASSED"'
  echo "$output" | jq -e '.gates["Performance Review"] == "PASSED"'
}

# AC-EC1: MOCK_MODE=true with MOCK_VERDICTS unset must error clearly with a
# non-zero exit AND a stderr message naming MOCK_VERDICTS as required. The
# guard runs before any per-reviewer iteration begins.
@test "E58-S5 AC-EC1: MOCK_MODE without MOCK_VERDICTS errors with actionable stderr" {
  install_fixture
  seed_orchestration_trace_stubs

  unset MOCK_VERDICTS
  export MOCK_MODE=true

  run "$SCRIPTS_DIR/review-runner.sh" "C9-FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MOCK_VERDICTS"* ]]
  [[ "$output" == *"required"* ]]
}

# ---------- E58-S6: SKILL.md thin-orchestrator + parity trace ----------

# Path to the skill file (resolved once per test from SCRIPTS_DIR layout).
SKILL_FILE="$(cd "${BATS_TEST_DIRNAME}/../../skills/gaia-run-all-reviews" && pwd)/SKILL.md"
# Path to the parity trace.
PARITY_TRACE="$(cd "${BATS_TEST_DIRNAME}/../../test/fixtures/parity-baseline/traces" && pwd)/run-all-reviews.jsonl"

# AC1 (TC-RAR-15, ECI-670): SKILL.md frontmatter must declare the new
# argument-hint with [--force] and keep allowed-tools at [Read, Grep, Glob, Bash].
@test "E58-S6 AC1: SKILL.md argument-hint includes [--force] and allowed-tools unchanged" {
  [ -f "$SKILL_FILE" ]

  # Extract frontmatter (between leading --- and the next ---)
  local fm
  fm=$(awk '/^---$/{c++; next} c==1' "$SKILL_FILE")

  # argument-hint check (exact string match)
  echo "$fm" | grep -Fq 'argument-hint: "[story-key] [--force]"'
  # allowed-tools unchanged
  echo "$fm" | grep -Fq 'allowed-tools: [Read, Grep, Glob, Bash]'
}

# AC2 (TC-RAR-15): SKILL.md Step 2 must reference review-skip-check.sh and
# scope per-reviewer LLM judgment to the `run` slice of its JSON output.
@test "E58-S6 AC2: SKILL.md Step 2 invokes review-skip-check.sh and iterates the run slice" {
  grep -Fq 'review-skip-check.sh' "$SKILL_FILE"
  # Must mention the JSON {skip,run} partition contract
  grep -Eq '\{skip[^}]*run' "$SKILL_FILE"
}

# AC3 (TC-RAR-15, ECI-670): SKILL.md must document that --force is forwarded
# to review-skip-check.sh so all 6 LLM judgments fire.
@test "E58-S6 AC3: SKILL.md documents --force passthrough to review-skip-check.sh" {
  # The --force flag must be referenced in Step 2 / orchestrator wiring.
  grep -Fq -- '--force' "$SKILL_FILE"
}

# AC4 (TC-RAR-16): SKILL.md must document SKIPPED reporting for already-PASSED
# reviewers in the final summary block.
@test "E58-S6 AC4: SKILL.md documents SKIPPED (already PASSED) summary entries" {
  grep -Fq 'SKIPPED (already PASSED)' "$SKILL_FILE"
}

# AC4/AC5 (TC-RAR-16, NFR-RAR-1, TC-RAR-17): Step 3 must call the three
# deterministic scripts in order: review-summary-gen.sh, review-gate.sh
# review-gate-check, review-nudge.sh.
@test "E58-S6 AC4+AC5: SKILL.md Step 3 calls summary-gen, review-gate-check, and nudge" {
  grep -Fq 'review-summary-gen.sh' "$SKILL_FILE"
  grep -Fq 'review-gate-check' "$SKILL_FILE"
  grep -Fq 'review-nudge.sh' "$SKILL_FILE"

  # Order check: in Step 3, the three deterministic helper scripts must
  # be invoked in canonical order. Anchor on `bash scripts/...` invocation
  # lines (the imperative call sites) rather than prose mentions, since
  # the Mission/Critical-Rules prose may list multiple scripts on a single
  # line. The Step-3 procedure must call summary-gen first, then
  # review-gate-check, then review-nudge.
  local ln_summary ln_check ln_nudge
  ln_summary=$(grep -nE 'bash scripts/review-summary-gen\.sh' "$SKILL_FILE" | head -1 | cut -d: -f1)
  ln_check=$(grep -nE 'bash scripts/review-gate\.sh review-gate-check' "$SKILL_FILE" | head -1 | cut -d: -f1)
  ln_nudge=$(grep -nE 'bash scripts/review-nudge\.sh' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$ln_summary" ] && [ -n "$ln_check" ] && [ -n "$ln_nudge" ]
  [ "$ln_summary" -lt "$ln_check" ]
  [ "$ln_check" -lt "$ln_nudge" ]
}

# AC6: Parity trace must reflect the new step boundaries:
# validate-input -> skip-check -> per-reviewer -> summary-gen ->
# review-gate-check -> nudge.
@test "E58-S6 AC6: parity trace reflects new step-boundary phases" {
  [ -f "$PARITY_TRACE" ]

  # Each phase name must appear at least once in the trace.
  grep -Fq 'validate-input' "$PARITY_TRACE"
  grep -Fq 'skip-check' "$PARITY_TRACE"
  grep -Fq 'per-reviewer' "$PARITY_TRACE"
  grep -Fq 'summary-gen' "$PARITY_TRACE"
  grep -Fq 'review-gate-check' "$PARITY_TRACE"
  grep -Fq 'nudge' "$PARITY_TRACE"
}

# AC-EC11: Parity-trace JSONL must be well-formed — every line must parse
# as a single JSON object. The bats test fails fast with the offending line
# number if any line is malformed.
@test "E58-S6 AC-EC11: parity trace JSONL is well-formed (one JSON object per line)" {
  [ -f "$PARITY_TRACE" ]

  local lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    # Skip empty lines (allowed at EOF)
    [ -z "$line" ] && continue
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      echo "malformed JSON on line $lineno: $line" >&2
      return 1
    fi
  done < "$PARITY_TRACE"
}
