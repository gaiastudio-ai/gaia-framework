#!/usr/bin/env bats
# review-summary-gen.bats — Cluster 9 unit test (E58-S2)
#
# Verifies the deterministic V1-locked summary writer:
#   review-summary-gen.sh --story <key> [--output <path>] [--synopsis-file <path>]
#
# Output contract (TC-RAR-04..06, TC-RAR-17, ECI-667, ECI-671):
#   exit 0 — summary file written; absolute path on stdout
#   exit 1 — story not found
#   exit 2 — gate table empty / malformed / write failure
#
# Refs: FR-RAR-2, AF-2026-04-28-7, NFR-RAR-1
# Schema source: V1 V1 reference schema lines 80-135 (immutable).

load 'test_helper.bash'

# ---------- Paths ----------

CLUSTER9_DIR="${BATS_TEST_DIRNAME}"
FIXTURES_DIR="${CLUSTER9_DIR}/fixtures"
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"

SUMMARY_GEN="$SCRIPTS_DIR/review-summary-gen.sh"
GATE="$SCRIPTS_DIR/review-gate.sh"

# Canonical reviewer slugs in V1 schema order.
CANONICAL_REVIEWERS_JSON='["code-review","qa-tests","security-review","test-automate","test-review","review-perf"]'

# ---------- Helpers ----------

setup() {
  common_setup
  TEST_PROJECT="$TEST_TMP"
  ART="$TEST_PROJECT/docs/implementation-artifacts"
  mkdir -p "$ART"
  export PROJECT_PATH="$TEST_PROJECT"
  # AF-2026-05-20-1: this suite seeds gate verdicts via review-gate.sh
  # update with no report files. Disable the proof-of-execution gate so
  # the summary-gen mechanics can be exercised. Proof-of-execution has
  # its own dedicated suite at tests/review-gate-proof-of-execution.bats.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  STORY_KEY="E58-S2-FIXTURE"
  STORY_FILE="$ART/${STORY_KEY}-fake.md"

  cp "$FIXTURES_DIR/C9-FIXTURE-fake.md" "$STORY_FILE"
  sed -i.bak "s/key: \"C9-FIXTURE\"/key: \"${STORY_KEY}\"/" "$STORY_FILE"
  rm -f "${STORY_FILE}.bak"

  BATS_PRESERVE_TMPDIR_ON_FAILURE=1
}

teardown() {
  if [ "$BATS_TEST_COMPLETED" = 1 ]; then
    common_teardown
  else
    echo "# POST-MORTEM: temp dir preserved at $TEST_TMP" >&3
  fi
}

seed_gate() {
  local gate="$1" verdict="$2"
  "$GATE" update --story "$STORY_KEY" --gate "$gate" --verdict "$verdict" >/dev/null
}

seed_all_passed() {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" PASSED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" PASSED
}

# ---------- AC1: Happy path — V1 schema match (TC-RAR-04, TC-RAR-05) ----------

@test "happy path: all 6 PASSED writes V1-schema summary, stdout = abs path" {
  seed_all_passed

  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  # stdout is exactly one line — the absolute path
  local line_count
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$line_count" -eq 1 ]

  local out_path
  out_path="$output"
  case "$out_path" in
    /*) : ;;
    *) echo "stdout not absolute: $out_path" >&2; return 1 ;;
  esac
  [ -f "$out_path" ]

  # Default location matches the canonical contract.
  [ "$out_path" = "$ART/${STORY_KEY}-review-summary.md" ]

  # Frontmatter has the four required fields, in V1 order.
  grep -q "^story_key: ${STORY_KEY}\$" "$out_path"
  grep -q "^date: " "$out_path"
  grep -q "^overall_status: PASSED\$" "$out_path"
  grep -q "^reviewers: \[code-review, qa-tests, security-review, test-automate, test-review, review-perf\]\$" "$out_path"

  # 6 reviewer H2 sections in canonical order.
  local sections
  sections=$(grep -E '^## (Code Review|QA Tests|Security Review|Test Automation|Test Review|Performance Review|Aggregate Gate Status)$' "$out_path")
  [ "$(printf '%s' "$sections" | sed -n '1p')" = "## Code Review" ]
  [ "$(printf '%s' "$sections" | sed -n '2p')" = "## QA Tests" ]
  [ "$(printf '%s' "$sections" | sed -n '3p')" = "## Security Review" ]
  [ "$(printf '%s' "$sections" | sed -n '4p')" = "## Test Automation" ]
  [ "$(printf '%s' "$sections" | sed -n '5p')" = "## Test Review" ]
  [ "$(printf '%s' "$sections" | sed -n '6p')" = "## Performance Review" ]
  [ "$(printf '%s' "$sections" | sed -n '7p')" = "## Aggregate Gate Status" ]

  # Aggregate Gate Status table present.
  grep -q '^| Review | Verdict | Report |' "$out_path"
  grep -q '^\*\*Overall Status:\*\* PASSED$' "$out_path"
}

# ---------- AC2: Synopsis injection (TC-RAR-06) ----------

@test "synopsis-file: 4 of 6 supplied, 2 fall back to 'See report'" {
  seed_all_passed

  local synopsis="$TEST_TMP/synopses.txt"
  cat > "$synopsis" <<'SYN'
code-review=All checks pass.
qa-tests=All happy-path scenarios green.
security-review=No CVEs detected.
test-automate=4 new tests added.
SYN

  run "$SUMMARY_GEN" --story "$STORY_KEY" --synopsis-file "$synopsis"
  [ "$status" -eq 0 ]

  local out_path="$output"
  [ -f "$out_path" ]

  # 4 supplied synopses appear verbatim.
  grep -q '^\*\*Synopsis:\*\* All checks pass\.$' "$out_path"
  grep -q '^\*\*Synopsis:\*\* All happy-path scenarios green\.$' "$out_path"
  grep -q '^\*\*Synopsis:\*\* No CVEs detected\.$' "$out_path"
  grep -q '^\*\*Synopsis:\*\* 4 new tests added\.$' "$out_path"

  # 2 omitted reviewers (test-review, review-perf) fall back to "See report".
  local fallback_count
  fallback_count=$(grep -c '^\*\*Synopsis:\*\* See report$' "$out_path" || true)
  [ "$fallback_count" -eq 2 ]
}

# ---------- AC3: Determinism (TC-RAR-17, ECI-671) ----------

@test "determinism: re-run with unchanged gate state is byte-identical" {
  seed_all_passed

  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local first="$TEST_TMP/first-summary.md"
  cp "$output" "$first"

  # Re-run; gate state unchanged.
  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local second="$output"

  # cmp confirms byte-identical (no diff false negatives on line endings).
  cmp "$first" "$second"
}

# ---------- ECI-671: Overwrite, never append ----------

@test "overwrite: pre-existing summary is replaced (not appended)" {
  seed_all_passed

  local out_default="$ART/${STORY_KEY}-review-summary.md"
  printf 'PRE-EXISTING GARBAGE\n%.0s' {1..50} > "$out_default"
  local pre_size
  pre_size=$(wc -c < "$out_default" | tr -d ' ')

  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  ! grep -q 'PRE-EXISTING GARBAGE' "$out_default"
  grep -q "^story_key: ${STORY_KEY}\$" "$out_default"
}

# ---------- AC4: Story not found → exit 1 (TC-RAR-04) ----------

@test "missing story: exit 1 with stderr 'story not found'" {
  run "$SUMMARY_GEN" --story "NONEXISTENT-S99"
  [ "$status" -eq 1 ]
  [[ "$output" == *"story not found"* ]]
}

# ---------- AC5: Zero-row gate table → exit 2 (ECI-667) ----------

@test "zero-row gate table: exit 2 with stderr 'gate table empty'" {
  local empty_story="$ART/E58-S2-EMPTYGATE-fake.md"
  cat > "$empty_story" <<'STORY'
---
template: 'story'
key: "E58-S2-EMPTYGATE"
status: review
---

# Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|

> Story moves to done only when ALL reviews show PASSED.
STORY

  run "$SUMMARY_GEN" --story "E58-S2-EMPTYGATE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"row"* ]]
}

# ---------- AC-EC1: Malformed gate row → exit 2 ----------

@test "malformed gate row: missing pipe columns → exit 2" {
  # Wreck the Code Review row by stripping a pipe.
  sed -i.bak 's/| Code Review | UNVERIFIED | — |/| Code Review UNVERIFIED — |/' "$STORY_FILE"
  rm -f "${STORY_FILE}.bak"

  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed"* ]] || [[ "$output" == *"missing"* ]] || [[ "$output" == *"empty"* ]]
}

# ---------- AC-EC2: Duplicate synopsis keys → last-wins + warning ----------

@test "duplicate synopsis keys: last-wins; warning to stderr" {
  seed_all_passed

  local synopsis="$TEST_TMP/synopses.txt"
  cat > "$synopsis" <<'SYN'
code-review=First take.
code-review=Second take wins.
SYN

  run "$SUMMARY_GEN" --story "$STORY_KEY" --synopsis-file "$synopsis"
  [ "$status" -eq 0 ]

  # Warning lives on stderr (merged into $output by bats); the actual file
  # path is the LAST line of stdout (script contract).
  local out_path
  out_path="$(printf '%s\n' "$output" | tail -1)"
  [ -f "$out_path" ]
  grep -q '^\*\*Synopsis:\*\* Second take wins\.$' "$out_path"
  ! grep -q '^\*\*Synopsis:\*\* First take\.$' "$out_path"

  # Warning text surfaces somewhere in the combined output.
  [[ "$output" == *"duplicate"* ]] || [[ "$output" == *"warning"* ]]
}

# ---------- AC-EC3: Concurrent invocation → atomic write ----------

@test "concurrent invocation: atomic temp+rename, no partial file" {
  seed_all_passed

  # Fire two writers in parallel; both should produce a valid summary file.
  "$SUMMARY_GEN" --story "$STORY_KEY" >/dev/null 2>&1 &
  local pid1=$!
  "$SUMMARY_GEN" --story "$STORY_KEY" >/dev/null 2>&1 &
  local pid2=$!
  wait $pid1
  wait $pid2

  local out_default="$ART/${STORY_KEY}-review-summary.md"
  [ -f "$out_default" ]
  # No tempfile crumb left behind.
  ! ls "$ART"/*.tmp.* 2>/dev/null | grep -q .
  # Frontmatter is intact (not half-written).
  head -1 "$out_default" | grep -q '^---$'
  grep -q "^story_key: ${STORY_KEY}\$" "$out_default"
}

# ---------- AC-EC4: LC_ALL drift → identical output ----------

@test "LC_ALL drift: caller LC_ALL=fr_FR.UTF-8 produces identical output to LC_ALL=C" {
  seed_all_passed

  LC_ALL=C run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local first="$TEST_TMP/locale-c.md"
  cp "$output" "$first"

  LC_ALL=fr_FR.UTF-8 run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  cmp "$first" "$output"
}

# ---------- AC-EC5: Non-writable output dir → exit 2 ----------

@test "non-writable output dir: exit 2 with 'write failure'" {
  seed_all_passed

  local readonly_dir="$TEST_TMP/readonly"
  mkdir -p "$readonly_dir"
  chmod 0500 "$readonly_dir"

  run "$SUMMARY_GEN" --story "$STORY_KEY" --output "$readonly_dir/x.md"
  # Restore so teardown can rm.
  chmod 0700 "$readonly_dir"

  [ "$status" -eq 2 ]
  [[ "$output" == *"write failure"* ]]
  # No partial file.
  [ ! -e "$readonly_dir/x.md" ]
}

# ---------- Determinism: date stamped from gate-state mtime, not wall-clock ----------

@test "determinism: date is derived from gate-state mtime, not date +%s" {
  seed_all_passed

  # Pin the story file mtime to a known timestamp.
  touch -t 202604010000.00 "$STORY_FILE"

  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  local out_path="$output"
  grep -q '^date: 2026-04-01$' "$out_path"
}

# ---------- Aggregate table: mixed verdicts + overall_status enum ----------

@test "mixed verdicts: overall_status is INCOMPLETE when any UNVERIFIED, no FAILED" {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" PASSED
  # Security Review stays UNVERIFIED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" PASSED

  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  grep -q '^overall_status: INCOMPLETE$' "$output"
  grep -q '^\*\*Overall Status:\*\* INCOMPLETE$' "$output"
}

@test "mixed verdicts: overall_status is FAILED when any FAILED (dominates UNVERIFIED)" {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" FAILED
  # Security Review stays UNVERIFIED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" PASSED

  run "$SUMMARY_GEN" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  grep -q '^overall_status: FAILED$' "$output"
}

# ---------- Custom output path ----------

@test "--output flag: writes to caller-specified path" {
  seed_all_passed

  local custom="$TEST_TMP/custom-summary.md"

  run "$SUMMARY_GEN" --story "$STORY_KEY" --output "$custom"
  [ "$status" -eq 0 ]
  [ "$output" = "$custom" ]
  [ -f "$custom" ]
  grep -q "^story_key: ${STORY_KEY}\$" "$custom"
}
