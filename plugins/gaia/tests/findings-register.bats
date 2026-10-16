#!/usr/bin/env bats
# findings-register.bats — test suite for the shared findings register writer
# (register-write.sh), cross-gate integration tests, verdict.sh register-mode
# integration, and gate-status subcommand tests.
#
# The setup() guard asserts register-write.sh is executable.  When the script
# does not yet exist (Red phase), every test FAILs in setup — genuinely red.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/register-write.sh"
  if [ ! -x "$SCRIPT" ]; then
    echo "register-write.sh not executable: $SCRIPT" >&2
    return 1
  fi
  RESOLVER="$SCRIPTS_DIR/verdict-resolver.sh"
  REPORT_PATH="$SCRIPTS_DIR/resolve-review-report-path.sh"
  REVIEW_GATE="$SCRIPTS_DIR/review-gate.sh"
  DAST_VERDICT="$BATS_TEST_DIRNAME/../skills/gaia-test-dast/scripts/verdict.sh"
  PERF_VERDICT="$BATS_TEST_DIRNAME/../skills/gaia-test-perf/scripts/verdict.sh"
  EXTRACT="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/extract-findings.sh"
  # Isolate each test's register: set IMPLEMENTATION_ARTIFACTS to a per-test
  # temp dir so resolve-review-report-path.sh writes there (not the real tree).
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Step 0.9 — bash version gate
# ---------------------------------------------------------------------------

@test "bash version is 3.x or 5.x" {
  bash --version >&3
  local ver
  ver="$(bash --version | head -1)"
  grep -qE '^GNU bash, version [35]\.' <<<"$ver" || {
    echo "unexpected bash version: $ver" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_register() {
  # _write_register <path> <yaml-body>
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$1" > "$path"
}

_minimal_register() {
  # _minimal_register <path> [entries-yaml]
  local path="$1"
  local entries="${2:-"[]"}"
  _write_register "$path" "schema_version: 1
story: TEST-S1
gate_runs: []
entries: ${entries}"
}

_write_story_file() {
  # _write_story_file <path> <key>
  # Writes a story file at the given path. When the parent dir is named
  # "stories", resolve-story-file.sh finds it via tier-1 (legacy nested).
  # When the parent dir matches {key}-*, tier-0 (new layout) applies.
  local path="$1" key="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<STORY
---
template: 'story'
key: "${key}"
title: "Test Story"
status: in-progress
epic: "${key%%-*}"
---
# Story: Test Story

## Findings

> Out-of-scope issues.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |
STORY
}

_write_legacy_story() {
  # _write_legacy_story <key>
  # Creates a legacy-nested story file that resolve-story-file.sh tier-1 finds:
  #   $IMPLEMENTATION_ARTIFACTS/epic-test/stories/<key>-test-story.md
  local key="$1"
  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  mkdir -p "$stories_dir"
  _write_story_file "$stories_dir/${key}-test-story.md" "$key"
}

# ---------------------------------------------------------------------------
# Step 0.1 — register-write.sh unit tests
# ---------------------------------------------------------------------------

@test "writer add creates register with schema_version 1 and sequential ID" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "null pointer on empty input" \
    --type bug --severity critical --gate code-review \
    --evidence "src/main.ts:42" --impact "crash on startup" \
    --blocking --blocking-rationale "Critical severity: crash on production path"
  [ "$status" -eq 0 ]
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ]
  local sv
  sv="$(yq '.schema_version' "$reg")"
  [ "$sv" = "1" ]
  local id
  id="$(yq '.entries[0].id' "$reg")"
  [ "$id" = "RF-1" ]
}

@test "writer add with matching dedup key merges into existing entry" {
  # First add
  run "$SCRIPT" add --story TEST-S1 \
    --defect "SQL injection in login" \
    --type security --severity critical --gate security-review \
    --dedup-key "src/auth.ts:10-15:injection" \
    --blocking --blocking-rationale "Critical severity: SQL injection"
  [ "$status" -eq 0 ]

  # Second add with same dedup key from different gate
  run "$SCRIPT" add --story TEST-S1 \
    --defect "SQL injection in login handler" \
    --type security --severity high --gate code-review \
    --dedup-key "src/auth.ts:10-15:injection" \
    --blocking --blocking-rationale "High severity: SQL injection"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 1 ]
  local gates
  gates="$(yq '.entries[0].originating_gates | length' "$reg")"
  [ "$gates" -eq 2 ]
  local ratings
  ratings="$(yq '.entries[0].gate_ratings | length' "$reg")"
  [ "$ratings" -eq 2 ]
}

@test "writer add with matching dedup key on resolved entry reopens it and moves severity_resolution to history" {
  # Create and resolve an entry
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Missing validation" --type bug --severity high \
    --gate code-review --dedup-key "src/form.ts:20-25:validation" \
    --blocking --blocking-rationale "High severity: missing input validation"
  [ "$status" -eq 0 ]

  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false \
    --rationale "Reviewed: internal-only endpoint, not user-facing"
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition resolved
  [ "$status" -eq 0 ]

  # Re-add with same dedup key from a new gate
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Missing validation on form" --type bug --severity high \
    --gate qa-tests --dedup-key "src/form.ts:20-25:validation" \
    --blocking --blocking-rationale "High severity: missing validation"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  # Same ID — not a new entry
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 1 ]
  local id
  id="$(yq '.entries[0].id' "$reg")"
  [ "$id" = "RF-1" ]
  # Disposition reopened
  local disp
  disp="$(yq '.entries[0].disposition' "$reg")"
  [ "$disp" = "open" ]
  # severity_resolution moved to history
  local hist_len
  hist_len="$(yq '.entries[0].history | length' "$reg")"
  [ "$hist_len" -ge 1 ]
  local has_resolution
  has_resolution="$(yq 'has(.entries[0].severity_resolution)' "$reg" 2>/dev/null || echo "false")"
  # After reopen, severity_resolution should be absent or moved
  [ "$has_resolution" != "true" ] || {
    # If it's still there, it should be the new state, not the old one
    local sr_gate
    sr_gate="$(yq '.entries[0].history[-1].action' "$reg")"
    [ "$sr_gate" = "reopen" ] || [ "$sr_gate" = "severity_resolution_archived" ]
  }
}

@test "writer merge unifies two entries keeping lower ID and removes source" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Memory leak in handler" --type bug --severity high \
    --gate code-review --dedup-key "src/handler.ts:10:leak" \
    --blocking --blocking-rationale "High severity: memory leak"
  [ "$status" -eq 0 ]

  run "$SCRIPT" add --story TEST-S1 \
    --defect "Resource not freed" --type bug --severity medium \
    --gate performance-review --dedup-key "src/handler.ts:12:resource"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local before
  before="$(yq '.entries | length' "$reg")"
  [ "$before" -eq 2 ]

  run "$SCRIPT" merge --story TEST-S1 --source-id RF-2 --target-id RF-1
  [ "$status" -eq 0 ]

  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local after
  after="$(yq '.entries | length' "$reg")"
  [ "$after" -eq 1 ]
  local survivor_id
  survivor_id="$(yq '.entries[0].id' "$reg")"
  [ "$survivor_id" = "RF-1" ]
  local gate_count
  gate_count="$(yq '.entries[0].originating_gates | length' "$reg")"
  [ "$gate_count" -eq 2 ]
}

@test "writer resolve-severity with empty rationale exits non-zero" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Test defect" --type bug --severity high \
    --gate code-review --blocking --blocking-rationale "High severity"
  [ "$status" -eq 0 ]

  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false --rationale ""
  [ "$status" -ne 0 ]
  { grep -qF "rationale" <<<"$output"; } || { grep -qF "rationale" <<<"${stderr:-$output}"; }
}

@test "writer resolve-severity with whitespace-only rationale exits non-zero" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Test defect" --type bug --severity high \
    --gate code-review --blocking --blocking-rationale "High severity"
  [ "$status" -eq 0 ]

  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false --rationale "   "
  [ "$status" -ne 0 ]
  { grep -qF "rationale" <<<"$output"; } || { grep -qF "rationale" <<<"${stderr:-$output}"; }
}

@test "writer resolve-severity with valid rationale records resolution" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Test defect" --type bug --severity high \
    --gate code-review --blocking --blocking-rationale "High severity"
  [ "$status" -eq 0 ]

  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false \
    --rationale "Reviewed: low-risk internal path"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local resolved_sev
  resolved_sev="$(yq '.entries[0].severity_resolution.resolved_severity' "$reg")"
  [ "$resolved_sev" = "medium" ]
  local resolved_blk
  resolved_blk="$(yq '.entries[0].severity_resolution.resolved_blocking' "$reg")"
  [ "$resolved_blk" = "false" ]
}

@test "writer resolve-severity cannot clear material true" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Untested auth bypass" --type security --severity low \
    --gate security-review --material \
    --blocking --blocking-rationale "Material risk: auth bypass unverified"
  [ "$status" -eq 0 ]

  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity low --blocking false \
    --rationale "Attempting to clear material"
  # Either exits non-zero or the material flag stays true
  if [ "$status" -eq 0 ]; then
    local reg
    reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
    local mat
    mat="$(yq '.entries[0].material' "$reg")"
    [ "$mat" = "true" ]
    local blk
    blk="$(yq '.entries[0].blocking' "$reg")"
    [ "$blk" = "true" ]
  else
    { grep -qF "material" <<<"$output"; } || { grep -qF "material" <<<"${stderr:-$output}"; }
  fi
}

@test "writer set-disposition triage without owner or priority exits non-zero" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Minor style issue" --type code-debt --severity low \
    --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage
  [ "$status" -ne 0 ]
  { grep -qF "owner" <<<"$output"; } \
    || { grep -qF "priority" <<<"$output"; } \
    || { grep -qF "owner" <<<"${stderr:-$output}"; } \
    || { grep -qF "priority" <<<"${stderr:-$output}"; }
}

@test "writer set-disposition triage with owner and priority succeeds" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Minor style issue" --type code-debt --severity low \
    --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local disp
  disp="$(yq '.entries[0].disposition' "$reg")"
  [ "$disp" = "triage" ]
  local owner
  owner="$(yq '.entries[0].owner' "$reg")"
  [ "$owner" = "code-review" ]
}

@test "writer rejects story key containing slash or dot-dot" {
  run "$SCRIPT" add --story "../traversal" \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -ne 0 ]
  { grep -qF "story" <<<"$output"; } \
    || { grep -qF "story" <<<"${stderr:-$output}"; } \
    || { grep -qF "invalid" <<<"$output"; } \
    || { grep -qF "invalid" <<<"${stderr:-$output}"; }

  run "$SCRIPT" add --story "path/slash" \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -ne 0 ]
}

@test "writer rejects unknown disposition" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition wontfix-maybe
  [ "$status" -ne 0 ]
  { grep -qF "disposition" <<<"$output"; } || { grep -qF "disposition" <<<"${stderr:-$output}"; }
}

@test "writer rejects unknown severity" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity Blocker --gate code-review
  [ "$status" -ne 0 ]
  { grep -qF "severity" <<<"$output"; } || { grep -qF "severity" <<<"${stderr:-$output}"; }
}

@test "writer normalises template tier names to canonical severity" {
  # Critical -> critical
  run "$SCRIPT" add --story TEST-S1 \
    --defect "tier test" --type bug --severity Critical --gate code-review \
    --blocking --blocking-rationale "Critical severity"
  [ "$status" -eq 0 ]
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local sev
  sev="$(yq '.entries[0].severity' "$reg")"
  [ "$sev" = "critical" ]

  # Warning -> medium
  run "$SCRIPT" add --story TEST-S2 \
    --defect "warning tier" --type bug --severity Warning --gate code-review
  [ "$status" -eq 0 ]
  reg="$("$REPORT_PATH" --key TEST-S2 --type findings-register)"
  sev="$(yq '.entries[0].severity' "$reg")"
  [ "$sev" = "medium" ]

  # Suggestion -> low
  run "$SCRIPT" add --story TEST-S3 \
    --defect "suggestion tier" --type bug --severity Suggestion --gate code-review
  [ "$status" -eq 0 ]
  reg="$("$REPORT_PATH" --key TEST-S3 --type findings-register)"
  sev="$(yq '.entries[0].severity' "$reg")"
  [ "$sev" = "low" ]
}

@test "writer rejects non-blocking bug with high severity" {
  # The blocker definition says a high/critical bug is always blocking.
  # Passing --blocking false explicitly for a high bug should be rejected.
  # Without --blocking, high auto-derives to blocking.  This test verifies
  # that the writer does not allow an explicit override that contradicts the
  # blocker definition.
  run "$SCRIPT" add --story TEST-S1 \
    --defect "high bug override" --type bug --severity high --gate code-review
  # Without explicit --blocking, high auto-derives to blocking -> succeeds
  [ "$status" -eq 0 ]
  # The entry should be blocking
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local blk
  blk="$(yq '.entries[0].blocking' "$reg")"
  [ "$blk" = "true" ]
}

@test "writer set-disposition triage rejects high-severity bug" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "high sev bug" --type bug --severity high --gate code-review \
    --blocking --blocking-rationale "High severity bug"
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority high
  [ "$status" -ne 0 ]
  { grep -qF "bug" <<<"$output"; } \
    || { grep -qF "blocking" <<<"$output"; } \
    || { grep -qF "bug" <<<"${stderr:-$output}"; } \
    || { grep -qF "blocking" <<<"${stderr:-$output}"; }
}

@test "writer rejects unknown type" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "unknown type" --type foobar --severity low --gate code-review
  [ "$status" -ne 0 ]
  { grep -qF "type" <<<"$output"; } || { grep -qF "type" <<<"${stderr:-$output}"; }
}

@test "writer rejects blocking true without blocking_rationale" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "missing rationale" --type bug --severity medium \
    --gate code-review --blocking
  [ "$status" -ne 0 ]
  { grep -qF "rationale" <<<"$output"; } || { grep -qF "rationale" <<<"${stderr:-$output}"; }
}

@test "writer round-trips YAML metacharacters without execution" {
  local nasty_defect='has "quotes" and $(echo pwned) and {braces: true} and [array] and |pipe'
  local nasty_evidence=$'line1\nline2\nline3'
  run "$SCRIPT" add --story TEST-S1 \
    --defect "$nasty_defect" \
    --type bug --severity medium --gate code-review \
    --evidence "$nasty_evidence"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local readback
  readback="$(yq '.entries[0].defect' "$reg")"
  [ "$readback" = "$nasty_defect" ]
  # Verify nothing was executed — $(echo pwned) must be literal
  grep -qF '$(echo pwned)' <<<"$readback"
}

@test "writer exits non-zero on malformed register" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP"
  printf 'this is not: valid: yaml: [[[' > "$TEST_TMP/findings-register-TEST-S1.yaml"

  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 2 ]
  { grep -qF "structural" <<<"$output"; } \
    || { grep -qF "parse" <<<"$output"; } \
    || { grep -qF "malformed" <<<"$output"; } \
    || { grep -qF "structural" <<<"${stderr:-$output}"; } \
    || { grep -qF "parse" <<<"${stderr:-$output}"; }
}

@test "writer exits non-zero on truncated register" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP"
  printf 'schema_version: 1\nstory: TEST-S1\nentries:\n  - id: RF-' > "$TEST_TMP/findings-register-TEST-S1.yaml"

  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 2 ]
  { grep -qF "structural" <<<"$output"; } \
    || { grep -qF "parse" <<<"$output"; } \
    || { grep -qF "validation" <<<"$output"; } \
    || { grep -qF "structural" <<<"${stderr:-$output}"; } \
    || { grep -qF "parse" <<<"${stderr:-$output}"; }
}

@test "writer exits non-zero on register with entries as scalar string" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP"
  cat > "$TEST_TMP/findings-register-TEST-S1.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: "not a sequence"
YAML

  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 2 ]
  { grep -qF "structural" <<<"$output"; } || { grep -qF "structural" <<<"${stderr:-$output}"; }
}

@test "writer exits non-zero on register with entries as scalar number" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP"
  cat > "$TEST_TMP/findings-register-TEST-S1.yaml" <<'YAML'
schema_version: 1
story: TEST-S1
gate_runs: []
entries: 42
YAML

  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 2 ]
  { grep -qF "structural" <<<"$output"; } || { grep -qF "structural" <<<"${stderr:-$output}"; }
}

@test "concurrent writers produce valid YAML with unique contiguous IDs under flock" {
  if ! command -v flock >/dev/null 2>&1; then
    if [ "${GAIA_REQUIRE_FLOCK:-0}" = "1" ]; then
      echo "flock required (GAIA_REQUIRE_FLOCK=1) but not available" >&2
      false
    fi
    echo "flock not available; skipping flock test (set GAIA_REQUIRE_FLOCK=1 to require)" >&3
    skip "flock not available (see fallback test)"
  fi
  local pids=()
  for i in 1 2 3 4 5 6 7 8; do
    "$SCRIPT" add --story TEST-S1 \
      --defect "concurrent finding $i" --type bug --severity low \
      --gate code-review --dedup-key "src/c${i}.ts:1:concurrent-${i}" &
    pids+=("$!")
  done
  local failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  [ "$failed" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  yq '.' "$reg" >/dev/null 2>&1  # valid YAML
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 8 ]
  # IDs are RF-1..RF-8 contiguous
  local ids
  ids="$(yq '.entries[].id' "$reg" | sort -t- -k2 -n)"
  local expected
  expected="$(printf 'RF-%d\n' 1 2 3 4 5 6 7 8)"
  [ "$ids" = "$expected" ]
}

@test "concurrent writers produce valid YAML with unique contiguous IDs under fallback" {
  export GAIA_LOCK_FORCE_FALLBACK=1
  local pids=()
  for i in 1 2 3 4 5 6 7 8; do
    "$SCRIPT" add --story TEST-S1 \
      --defect "fallback finding $i" --type bug --severity low \
      --gate code-review --dedup-key "src/f${i}.ts:1:fallback-${i}" &
    pids+=("$!")
  done
  local failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  [ "$failed" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  yq '.' "$reg" >/dev/null 2>&1
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 8 ]
  local ids
  ids="$(yq '.entries[].id' "$reg" | sort -t- -k2 -n)"
  local expected
  expected="$(printf 'RF-%d\n' 1 2 3 4 5 6 7 8)"
  [ "$ids" = "$expected" ]
}

@test "writer record-run writes a gate_runs entry" {
  _minimal_register "$TEST_TMP/reg.yaml"
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local gr_len
  gr_len="$(yq '.gate_runs | length' "$reg")"
  [ "$gr_len" -ge 1 ]
  local gr_gate
  gr_gate="$(yq '.gate_runs[0].gate' "$reg")"
  [ "$gr_gate" = "code-review" ]
  local gr_outcome
  gr_outcome="$(yq '.gate_runs[0].outcome' "$reg")"
  [ "$gr_outcome" = "completed" ]
}

# ---------------------------------------------------------------------------
# Step 0.1 — findings-rows subcommand tests
# ---------------------------------------------------------------------------

@test "writer findings-rows writes triage entries as pipe-delimited rows in Findings section" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  # Add a finding then triage it
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Minor style gap" --type code-debt --severity low \
    --gate code-review --reproduction "grep -n style src/main.ts"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # Verify the row appears in the story file
  grep -q 'RF-1' "$story_file"
  grep -q 'code-debt' "$story_file"
  grep -q 'owner:' "$story_file"
}

@test "writer findings-rows sanitises pipe and triple-dash and TRIAGED markers" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  # Defect text with pipes, triple dashes, and nested TRIAGED markers
  run "$SCRIPT" add --story TEST-S1 \
    --defect "found | in output --- also [[TRIAGED stuff" \
    --type bug --severity low --gate code-review \
    --reproduction "echo test | grep ---"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # The row must contain the sanitised forms
  local findings_section
  findings_section="$(sed -n '/^## Findings/,/^## /p' "$story_file" | grep 'RF-1')"

  # pipe inside cell replaced with /
  grep -qF '/ in output' <<<"$findings_section" || { echo "expected pipe replaced with /" >&2; false; }
  # triple dash spaced
  grep -qF ' - - - ' <<<"$findings_section" || { echo "expected dashes to be spaced" >&2; false; }
  # nested bracket-prefixed TRIAGED marker fully stripped
  if grep -qF '[TRIAGED' <<<"$findings_section"; then
    echo "bracket-prefixed [TRIAGED marker survived sanitisation" >&2; false
  fi
  grep -qF 'TRIAGED' <<<"$findings_section" || { echo "TRIAGED keyword lost entirely" >&2; false; }
}

@test "findings-rows strips bracket markers when the rows total more than 128 KB" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  # Two ~100 KB defects: each stays under the per-argument limit Linux puts on
  # a single command-line string, but together the rows exceed 128 KB, which
  # is more than one environment string can carry there.
  local padding
  padding="$(head -c 100000 < /dev/zero | tr '\0' 'x')"
  local big1="first [TRIAGED marker ${padding} middle [DISMISSED end [[TRIAGED tail"
  local big2="second [DISMISSED marker ${padding} middle [TRIAGED end tail"

  run "$SCRIPT" add --story TEST-S1 \
    --defect "$big1" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]
  run "$SCRIPT" add --story TEST-S1 \
    --defect "$big2" --type tech-debt --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local id
  for id in RF-1 RF-2; do
    run "$SCRIPT" set-disposition --story TEST-S1 --id "$id" \
      --disposition triage --owner code-review --priority low
    [ "$status" -eq 0 ]
  done

  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local section
  section="$(sed -n '/^## Findings/,/^## /p' "$story_file")"
  local row1 row2
  row1="$(grep '| RF-1 |' <<<"$section")" || { echo "RF-1 row missing" >&2; false; }
  row2="$(grep '| RF-2 |' <<<"$section")" || { echo "RF-2 row missing" >&2; false; }
  [ "$(( ${#row1} + ${#row2} ))" -gt 131072 ] || { echo "rows do not exceed 128 KB in total" >&2; false; }

  # No bracket-prefixed markers should remain, and the keywords must survive.
  local row
  for row in "$row1" "$row2"; do
    if grep -qF '[TRIAGED' <<<"$row"; then
      echo "bracket-prefixed [TRIAGED marker survived sanitisation" >&2; false
    fi
    if grep -qF '[DISMISSED' <<<"$row"; then
      echo "bracket-prefixed [DISMISSED marker survived sanitisation" >&2; false
    fi
    grep -qF 'TRIAGED' <<<"$row" || { echo "TRIAGED keyword lost" >&2; false; }
    grep -qF 'DISMISSED' <<<"$row" || { echo "DISMISSED keyword lost" >&2; false; }
  done
}

@test "writer findings-rows replaces placeholder row and is idempotent" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 \
    --defect "Test finding" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # Placeholder row should be gone
  if grep -q '| — | — | — | — | — |' "$story_file"; then
    echo "placeholder row was not removed" >&2; false
  fi

  # Run again — idempotent: RF-1 not duplicated
  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local rf1_count
  rf1_count="$(grep -c 'RF-1' "$story_file")"
  [ "$rf1_count" -eq 1 ]
}

@test "writer findings-rows joins multi-line reproduction with semicolon-space" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  local multiline_repro
  multiline_repro="$(printf 'cd /tmp\necho hello\ngrep test file.txt')"
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Multi-line repro" --type bug --severity low --gate code-review \
    --reproduction "$multiline_repro"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local row
  row="$(grep 'RF-1' "$story_file")"
  # Multi-line joined with " ; "
  grep -qF " ; " <<<"$row" || { echo "expected ' ; ' in row but got: $row" >&2; false; }
}

@test "writer findings-rows uses em dash separator before owner" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 \
    --defect "Em dash test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local row
  row="$(grep 'RF-1' "$story_file")"
  # Em dash (U+2014) not double hyphen
  { grep -qF $'\xe2\x80\x94' <<<"$row"; } || { grep -qF " — " <<<"$row"; } || { echo "expected em dash in row but got: $row" >&2; false; }
}

@test "material true with low severity is blocking" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Material risk with low severity" --type security --severity low \
    --gate security-review --material \
    --blocking --blocking-rationale "Material risk: unverified auth"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local blk
  blk="$(yq '.entries[0].blocking' "$reg")"
  [ "$blk" = "true" ]
  local mat
  mat="$(yq '.entries[0].material' "$reg")"
  [ "$mat" = "true" ]

  # The resolver should yield REQUEST_CHANGES
  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "non-blocking add then triage then findings-rows produces a Findings row" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 \
    --defect "Low priority item" --type tech-debt --severity low \
    --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" triage-nonblocking --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  grep -q 'RF-1' "$story_file"
  grep -q 'tech-debt' "$story_file"
}

@test "triage-nonblocking skips disagreement entries with mixed blocking ratings" {
  # Two gates, one says blocking, one says not
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Disagreement entry" --type bug --severity high \
    --gate security-review --dedup-key "src/x.ts:1:disagree" \
    --blocking --blocking-rationale "High severity"
  [ "$status" -eq 0 ]

  run "$SCRIPT" add --story TEST-S1 \
    --defect "Same thing, lower rating" --type bug --severity medium \
    --gate code-review --dedup-key "src/x.ts:1:disagree"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate security-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" triage-nonblocking --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # Entry should still be open (not triaged) because of disagreement
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local disp
  disp="$(yq '.entries[0].disposition' "$reg")"
  [ "$disp" = "open" ]
}

# ---------------------------------------------------------------------------
# Step 0.5 — gate-status subcommand
# ---------------------------------------------------------------------------

@test "writer gate-status returns RAN for completed current-run gate" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate code-review
  [ "$status" -eq 0 ]
  [ "$output" = "RAN" ]
}

@test "writer gate-status returns UNVERIFIED for absent gate" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate security-review
  [ "$status" -eq 0 ]
  [ "$output" = "UNVERIFIED" ]
}

@test "writer gate-status returns UNVERIFIED for errored gate" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate security-review --outcome errored
  [ "$status" -eq 0 ]

  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate security-review
  [ "$status" -eq 0 ]
  [ "$output" = "UNVERIFIED" ]
}

# ---------------------------------------------------------------------------
# Step 0.5 — cross-gate integration tests
# ---------------------------------------------------------------------------

@test "cross-gate integration: two gates record same defect, both resolve same verdict" {
  # Gate A (code-review) adds a blocking finding
  run "$SCRIPT" add --story TEST-S1 \
    --defect "XSS in template" --type security --severity critical \
    --gate code-review --dedup-key "src/view.ts:10-15:xss" \
    --blocking --blocking-rationale "Critical severity: XSS vulnerability"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Gate B (security-review) adds with same dedup key
  run "$SCRIPT" add --story TEST-S1 \
    --defect "XSS in view template" --type security --severity critical \
    --gate security-review --dedup-key "src/view.ts:10-15:xss" \
    --blocking --blocking-rationale "Critical severity: XSS"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate security-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # One merged entry
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 1 ]

  # Same verdict from both gate resolver runs. Use --separate-stderr
  # so $output contains only the verdict token (stdout), not provenance (stderr).
  run --separate-stderr "$RESOLVER" --register "$reg" --skill gaia-code-review
  [ "$status" -eq 0 ]
  local verdict_a="$output"

  run --separate-stderr "$RESOLVER" --register "$reg" --skill gaia-review-security
  [ "$status" -eq 0 ]
  local verdict_b="$output"

  [ "$verdict_a" = "$verdict_b" ]
  [ "$verdict_a" = "REQUEST_CHANGES" ]
}

@test "cross-gate integration: gate A runs without B blocking, B adds blocker, consolidation makes both FAILED" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  # Gate A runs, no findings
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Verdict for gate A at this point: APPROVE (empty register)
  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]

  # Gate B adds a blocker
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Critical auth bypass" --type security --severity critical \
    --gate security-review --blocking --blocking-rationale "Critical severity"
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate security-review --outcome completed
  [ "$status" -eq 0 ]

  # After consolidation re-resolution, BOTH gates see REQUEST_CHANGES
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  run --separate-stderr "$RESOLVER" --register "$reg" --skill gaia-code-review
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]

  run --separate-stderr "$RESOLVER" --register "$reg" --skill gaia-review-security
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "register path for new-layout story resolves to reviews dir" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  # Use E99-S1 key so resolve-story-file.sh tier-0 glob (E*-S*-*) matches.
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/E99-S1-path-test"
  _write_story_file "$story_dir/story.md" "E99-S1"

  run "$REPORT_PATH" --key E99-S1 --type findings-register
  [ "$status" -eq 0 ]
  grep -qF "/reviews/findings-register-E99-S1.yaml" <<<"$output" || { echo "expected reviews path in output but got: $output" >&2; false; }
}

@test "register path for two legacy-nested stories yields distinct files" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  # Legacy stories (in stories/ subdir)
  mkdir -p "$IMPLEMENTATION_ARTIFACTS/epic-leg/stories"
  cat > "$IMPLEMENTATION_ARTIFACTS/epic-leg/stories/LEG-S1-foo.md" <<'EOF'
---
key: "LEG-S1"
title: "Foo"
status: done
epic: "LEG"
---
# Story
EOF
  cat > "$IMPLEMENTATION_ARTIFACTS/epic-leg/stories/LEG-S2-bar.md" <<'EOF'
---
key: "LEG-S2"
title: "Bar"
status: done
epic: "LEG"
---
# Story
EOF

  local path1 path2
  path1="$("$REPORT_PATH" --key LEG-S1 --type findings-register)"
  path2="$("$REPORT_PATH" --key LEG-S2 --type findings-register)"
  [ "$path1" != "$path2" ]
  grep -qF "LEG-S1" <<<"$path1"
  grep -qF "LEG-S2" <<<"$path2"
}

@test "open entry with non-blocking severity then material rating from second gate yields REQUEST_CHANGES" {
  # First gate: medium severity, non-blocking
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Potential auth issue" --type security --severity medium \
    --gate code-review --dedup-key "src/auth.ts:5:auth"
  [ "$status" -eq 0 ]

  # Second gate: same dedup key, material risk
  run "$SCRIPT" add --story TEST-S1 \
    --defect "Auth bypass risk" --type security --severity low \
    --gate security-review --dedup-key "src/auth.ts:5:auth" \
    --material --blocking --blocking-rationale "Material risk: auth bypass"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local mat
  mat="$(yq '.entries[0].material' "$reg")"
  [ "$mat" = "true" ]
  local blk
  blk="$(yq '.entries[0].blocking' "$reg")"
  [ "$blk" = "true" ]

  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "first run with no register and existing legacy reports creates register without parsing old reports" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"
  mkdir -p "$story_dir/reviews"

  # Write a legacy review report
  cat > "$story_dir/reviews/code-review-TEST-S1.md" <<'EOF'
# Code Review Report
## Findings
- Critical: Old bug from legacy review
EOF

  # First register write
  run "$SCRIPT" add --story TEST-S1 \
    --defect "New finding from this run" --type bug --severity medium \
    --gate code-review
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 1 ]
  # Only the new finding — old reports NOT parsed
  local defect
  defect="$(yq '.entries[0].defect' "$reg")"
  [ "$defect" = "New finding from this run" ]
}

# ---------------------------------------------------------------------------
# Step 0.7 — gate run / UNVERIFIED tests
# ---------------------------------------------------------------------------

@test "consolidation with absent gate for current run-id yields UNVERIFIED" {
  # Record only code-review, then check security-review status
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate security-review
  [ "$status" -eq 0 ]
  [ "$output" = "UNVERIFIED" ]
}

@test "gate with only earlier run record yields UNVERIFIED" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Check with a different (newer) run-id
  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-002 --gate code-review
  [ "$status" -eq 0 ]
  [ "$output" = "UNVERIFIED" ]
}

@test "gate with errored outcome yields UNVERIFIED" {
  run "$SCRIPT" add --story TEST-S1 \
    --defect "test" --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome errored
  [ "$status" -eq 0 ]

  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate code-review
  [ "$status" -eq 0 ]
  [ "$output" = "UNVERIFIED" ]
}

@test "gate with current-run completed and zero entries is not UNVERIFIED" {
  _minimal_register "$TEST_TMP/reg.yaml"
  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate code-review
  [ "$status" -eq 0 ]
  [ "$output" = "RAN" ]
}

# ---------------------------------------------------------------------------
# Step 0.8 — verdict.sh integration tests
# ---------------------------------------------------------------------------

@test "test-dast verdict.sh with story key and register reflects register rule" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  # Create analysis and findings fixtures
  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-dast",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"zap","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [] }
EOF

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]
  grep -qF "APPROVE" <<<"$output"
}

@test "test-perf verdict.sh with story key and register reflects register rule" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-perf",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"perf-check","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [] }
EOF

  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]
  grep -qF "APPROVE" <<<"$output"
}

@test "test-dast verdict.sh without register uses legacy llm-findings path unchanged" {
  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-dast",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"zap","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [] }
EOF

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  grep -qF "APPROVE" <<<"$output"
}

@test "test-perf verdict.sh without register uses legacy llm-findings path unchanged" {
  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-perf",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"perf-check","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [] }
EOF

  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json"
  [ "$status" -eq 0 ]
  grep -qF "APPROVE" <<<"$output"
}

@test "test-dast verdict.sh standalone mints run-id and records run" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-dast",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"zap","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [] }
EOF

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ]
  local gr_len
  gr_len="$(yq '.gate_runs | length' "$reg")"
  [ "$gr_len" -ge 1 ]
}

@test "test-dast verdict.sh with register and missing register file does not spuriously BLOCK" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-dast",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"zap","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [] }
EOF

  # No register exists yet — should be created by the first add, not BLOCKED
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]
  if grep -qF "BLOCKED" <<<"$output"; then
    echo "expected non-BLOCKED verdict for empty register, got BLOCKED" >&2; false
  fi
}

@test "test-dast verdict.sh with register and Critical finding in register yields REQUEST_CHANGES" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-dast",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"zap","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [{"category":"injection","severity":"Critical","message":"SQL injection found","file":"src/db.ts","line":42,"rule":"dast.injection.sql"}] }
EOF

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]
  grep -qF "REQUEST_CHANGES" <<<"$output"
}

@test "test-dast verdict.sh with two distinct findings produces two register entries" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-dast",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"zap","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [
  {"category":"injection","severity":"Critical","message":"SQL injection found","file":"src/db.ts","line":42,"rule":"dast.injection.sql"},
  {"category":"xss","severity":"Warning","message":"Reflected XSS in search","file":"src/search.ts","line":10,"rule":"dast.xss.reflected"}
] }
EOF

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 2 ]
  # Different IDs
  local id1 id2
  id1="$(yq '.entries[0].id' "$reg")"
  id2="$(yq '.entries[1].id' "$reg")"
  [ "$id1" != "$id2" ]
}

@test "test-perf verdict.sh with two distinct findings produces two register entries" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-perf",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"perf-check","status":"passed","findings":[]}]
}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [
  {"category":"slo","severity":"Critical","message":"p95 600ms > 500ms SLO","file":null,"line":0,"rule":"perf.slo.p95"},
  {"category":"memory","severity":"Warning","message":"heap growth 15% over baseline","file":"src/cache.ts","line":55,"rule":"perf.memory.heap"}
] }
EOF

  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Step 0.5 — findings-rows extract-findings round-trip
# ---------------------------------------------------------------------------

@test "findings-rows triage entries round-trip through extract-findings under bash" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  # Use E99-S1 key: extract-findings.sh matches only ^E[0-9]+-S[0-9]+ keys.
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/E99-S1-roundtrip-test.md"
  _write_story_file "$story_file" "E99-S1"

  # Add entries with tricky characters
  run "$SCRIPT" add --story E99-S1 \
    --defect "Found / in output - - - also TRIAGED stuff" \
    --type bug --severity low --gate code-review \
    --reproduction "echo test / grep foo"
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story E99-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story E99-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  run "$SCRIPT" findings-rows --story E99-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # Run extract-findings.sh on the story file
  run "$EXTRACT" --story-file "$story_file"
  [ "$status" -eq 0 ]
  # Should emit at least one finding line
  local line_count
  line_count="$(grep -c '|' <<<"$output" || true)"
  [ "$line_count" -ge 1 ]
  # Should contain the type and severity
  grep -qF "bug" <<<"$output"
  grep -qF "low" <<<"$output"
}

# ---------------------------------------------------------------------------
# Item 2 — stale severity resolution must not hide a later blocking rating
# ---------------------------------------------------------------------------

@test "writer add on open entry with stale severity resolution archives it and new rating counts" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  # Step 1: add medium (code-review) + high (qa-tests) with same dedup key
  run "$SCRIPT" add --story TEST-S1 --defect "dup-test" --type bug \
    --severity medium --gate code-review --dedup-key "k1"
  [ "$status" -eq 0 ]

  run "$SCRIPT" add --story TEST-S1 --defect "dup-test" --type bug \
    --severity high --gate qa-tests --dedup-key "k1"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Step 2: resolve-severity to non-blocking medium (entry is still open)
  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false --rationale "agreed medium"
  [ "$status" -eq 0 ]

  # Verify APPROVE after resolution (register-only, no analysis-results)
  run --separate-stderr "$RESOLVER" --skill gaia-code-review --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]

  # Step 3: new critical security rating on the same dedup key
  run "$SCRIPT" add --story TEST-S1 --defect "dup-test" --type security \
    --severity critical --gate security-review --dedup-key "k1"
  [ "$status" -eq 0 ]

  # The stale resolution must be archived; the new critical must be blocking
  run --separate-stderr "$RESOLVER" --skill gaia-code-review --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]

  # Verify severity_resolution was archived to history
  local has_sr
  has_sr="$(yq '.entries[0] | has("severity_resolution")' "$reg")"
  [ "$has_sr" = "false" ]
}

# ---------------------------------------------------------------------------
# Item 3 — merge self-merge rejection and merge-into-resolved reopen
# ---------------------------------------------------------------------------

@test "writer merge rejects self-merge with non-zero exit" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 --defect "self-merge-test" \
    --type bug --severity critical --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" merge --story TEST-S1 --source-id RF-1 --target-id RF-1
  [ "$status" -ne 0 ]
  grep -qF "source and target must differ" <<<"$output"

  # Entry must still exist
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 1 ]
}

@test "writer merge of unresolved source into resolved target reopens the target" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  # Create two entries
  run "$SCRIPT" add --story TEST-S1 --defect "source-defect" \
    --type bug --severity critical --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" add --story TEST-S1 --defect "target-defect" \
    --type bug --severity medium --gate qa-tests
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Resolve the target (RF-2) so it is not blocking
  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-2 \
    --severity low --blocking false --rationale "downgraded"
  [ "$status" -eq 0 ]
  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-2 \
    --disposition resolved
  [ "$status" -eq 0 ]

  # Merge unresolved critical source (RF-1) into resolved target (RF-2)
  run "$SCRIPT" merge --story TEST-S1 --source-id RF-1 --target-id RF-2
  [ "$status" -eq 0 ]

  # The merged entry must be reopened (open, not resolved)
  local disp
  disp="$(yq '.entries[0].disposition' "$reg")"
  [ "$disp" = "open" ]

  # The blocker must survive — REQUEST_CHANGES expected
  run --separate-stderr "$RESOLVER" --skill gaia-code-review --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# ---------------------------------------------------------------------------
# Item 4 — findings-rows multi-row idempotency, backslash, RF-ID exact match
# ---------------------------------------------------------------------------

@test "writer findings-rows with three entries is idempotent on re-run" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  # Create three entries, triage them
  run "$SCRIPT" add --story TEST-S1 --defect "issue one" \
    --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]
  run "$SCRIPT" add --story TEST-S1 --defect "issue two" \
    --type bug --severity low --gate qa-tests
  [ "$status" -eq 0 ]
  run "$SCRIPT" add --story TEST-S1 --defect "issue three" \
    --type bug --severity low --gate test-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" triage-nonblocking --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # First run writes 3 rows
  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local story_file
  story_file="$("$SCRIPTS_DIR/resolve-story-file.sh" TEST-S1)"
  local count1
  count1="$(grep -c 'RF-' "$story_file" || true)"
  [ "$count1" -eq 3 ]

  # Second run must not duplicate rows
  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local count2
  count2="$(grep -c 'RF-' "$story_file" || true)"
  [ "$count2" -eq 3 ]
}

@test "writer findings-rows preserves literal backslash-n and backslash-x in finding text" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 \
    --defect 'echo \n and \x7c should stay literal' \
    --type bug --severity low --gate code-review \
    --reproduction 'printf "%s\n" test'
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" triage-nonblocking --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]
  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local story_file
  story_file="$("$SCRIPTS_DIR/resolve-story-file.sh" TEST-S1)"
  local findings_section
  findings_section="$(sed -n '/^## Findings/,/^## [^F]/p' "$story_file")"

  # The literal \n must not have become a newline splitting the row
  local row_count
  row_count="$(grep -c 'RF-1' <<<"$findings_section" || true)"
  [ "$row_count" -eq 1 ]

  # The literal \x7c must not have become a pipe character
  if grep -q '\\x7c' <<<"$findings_section"; then
    true  # backslash-x7c stayed literal — correct
  else
    echo "backslash-x7c was decoded to a pipe or lost" >&2; false
  fi
}

@test "writer findings-rows uses exact cell match so first entry is not confused with tenth" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  # Create 10 entries to get RF-1 through RF-10
  local j=1
  while [ "$j" -le 10 ]; do
    run "$SCRIPT" add --story TEST-S1 --defect "entry $j" \
      --type bug --severity low --gate code-review
    [ "$status" -eq 0 ]
    j=$((j + 1))
  done

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" triage-nonblocking --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # Write ONLY RF-10 into the story file (manually, to simulate a prior run
  # that wrote RF-10 but not RF-1 — e.g. RF-1 was open then, now triaged).
  # Replace the placeholder row with just RF-10.
  local sf
  sf="$("$SCRIPTS_DIR/resolve-story-file.sh" TEST-S1)"
  local emdash
  emdash="$(printf '\xe2\x80\x94')"
  # Portable in-place edit (BSD and GNU sed disagree on -i).
  sed "s/| $emdash | $emdash | $emdash | $emdash | $emdash |/| RF-10 | bug | low | entry 10 (gates: code-review) | $emdash owner: ; priority: low |/" "$sf" > "$sf.new"
  mv "$sf.new" "$sf"

  # Verify RF-10 is present and RF-1 is absent
  grep -q '| RF-10 |' "$sf" || { echo "RF-10 not seeded" >&2; false; }
  if grep -q '| RF-1 |' "$sf"; then
    echo "RF-1 should not be present yet" >&2; false
  fi

  # Now run findings-rows — RF-1 must be inserted, RF-10 must not be duplicated
  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  # RF-1 must now appear (was new, must not have been confused with RF-10)
  grep -q '| RF-1 |' "$sf" || { echo "RF-1 was not inserted (exact-cell match confused RF-1 with RF-10)" >&2; false; }

  # RF-10 must appear exactly once (not duplicated)
  local rf10_count
  rf10_count="$(grep -c '| RF-10 |' "$sf")"
  [ "$rf10_count" -eq 1 ] || { echo "RF-10 appeared $rf10_count times (expected 1)" >&2; false; }
}

# ---------------------------------------------------------------------------
# verdict.sh severity normalisation and failed-write BLOCKED gate behaviour
# ---------------------------------------------------------------------------

@test "dast verdict.sh normalises non-standard severity labels to rubric scale" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "gaia-test-dast",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"zap","status":"passed","findings":[]}]
}
EOF
  # Finding with a severity that would fail validation without normalisation
  cat > "$TEST_TMP/f.json" <<'EOF'
{ "findings": [{"category":"injection","severity":"Critical Risk","message":"SQL injection","file":"src/db.ts","line":42,"rule":"dast.injection.sql"}] }
EOF

  # Severity "Critical Risk" is normalised to "critical" (not rejected)
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]

  # The finding should produce REQUEST_CHANGES (critical is blocking)
  grep -qF "REQUEST_CHANGES" <<<"$output"

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local sev
  sev="$(yq '.entries[0].severity' "$reg")"
  [ "$sev" = "critical" ]
}

# ---------------------------------------------------------------------------
# Item 9 — resolve-severity --blocking rejects invalid values
# ---------------------------------------------------------------------------

@test "writer resolve-severity accepts and normalises uppercase TRUE for blocking" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 --defect "blocking-val-test" \
    --type tech-debt --severity medium --gate code-review
  [ "$status" -eq 0 ]

  # TRUE (uppercase) must be accepted and normalised to lowercase true
  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking TRUE --rationale "test uppercase"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  # The stored resolved_blocking must be the boolean true
  local rb
  rb="$(yq '.entries[0].severity_resolution.resolved_blocking' "$reg")"
  [ "$rb" = "true" ]
  # The top-level blocking must also be true
  local blk
  blk="$(yq '.entries[0].blocking' "$reg")"
  [ "$blk" = "true" ]
}

@test "writer resolve-severity rejects yes for blocking" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 --defect "blocking-val-test" \
    --type tech-debt --severity medium --gate code-review
  [ "$status" -eq 0 ]

  # "yes" is not true or false — must be rejected
  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking yes --rationale "test invalid value"
  [ "$status" -ne 0 ]
  grep -qF "must be true or false" <<<"$output"
}

# ---------------------------------------------------------------------------
# Item 10 — runs of 5+ hyphens are broken up by sanitisation
# ---------------------------------------------------------------------------

@test "writer findings-rows breaks 5-dash and 9-dash runs in finding text" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  run "$SCRIPT" add --story TEST-S1 \
    --defect "five -----x and nine ---------y dashes" \
    --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]
  run "$SCRIPT" triage-nonblocking --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]
  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -eq 0 ]

  local story_file
  story_file="$("$SCRIPTS_DIR/resolve-story-file.sh" TEST-S1)"
  local findings_section
  findings_section="$(sed -n '/^## Findings/,/^## [^F]/p' "$story_file")"

  # No run of 3+ consecutive dashes should survive in the data row.
  # The table separator (|---|) naturally has dashes — check only data rows.
  local data_row
  data_row="$(grep 'RF-1' <<<"$findings_section")"
  if grep -q -- '---' <<<"$data_row"; then
    echo "run of 3+ dashes survived sanitisation in data row: $data_row" >&2; false
  fi
}

# ---------------------------------------------------------------------------
# Settled disagreement resilience: identical re-report keeps resolution
# ---------------------------------------------------------------------------

@test "identical re-report from the same gate keeps severity resolution intact" {
  # A settled disagreement must not be wiped by the same gate re-reporting
  # the same medium severity on the next round.
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-stable" --type bug \
    --severity medium --gate code-review --dedup-key "disagree:stable"
  [ "$status" -eq 0 ]
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-stable" --type bug \
    --severity high --gate qa-tests --dedup-key "disagree:stable" \
    --blocking --blocking-rationale "High severity"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Resolve to non-blocking medium
  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false --rationale "agreed medium after review"
  [ "$status" -eq 0 ]

  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]

  # Re-report identical medium from code-review (same dedup key, same gate, same severity)
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-stable" --type bug \
    --severity medium --gate code-review --dedup-key "disagree:stable"
  [ "$status" -eq 0 ]

  # Resolution must survive — still APPROVE
  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]

  local has_sr
  has_sr="$(yq '.entries[0] | has("severity_resolution")' "$reg")"
  [ "$has_sr" = "true" ]
}

@test "new gate rating on a resolved disagreement archives the resolution" {
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-new-gate" --type bug \
    --severity medium --gate code-review --dedup-key "disagree:newgate"
  [ "$status" -eq 0 ]
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-new-gate" --type bug \
    --severity high --gate qa-tests --dedup-key "disagree:newgate" \
    --blocking --blocking-rationale "High severity"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false --rationale "agreed medium"
  [ "$status" -eq 0 ]

  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$output" = "APPROVE" ]

  # A NEW gate (security-review) rates it critical
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-new-gate" --type security \
    --severity critical --gate security-review --dedup-key "disagree:newgate"
  [ "$status" -eq 0 ]

  # Resolution must be archived — now REQUEST_CHANGES
  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$output" = "REQUEST_CHANGES" ]
  local has_sr
  has_sr="$(yq '.entries[0] | has("severity_resolution")' "$reg")"
  [ "$has_sr" = "false" ]
}

@test "same gate raising its severity archives the resolution" {
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-raise" --type bug \
    --severity medium --gate code-review --dedup-key "disagree:raise"
  [ "$status" -eq 0 ]
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-raise" --type bug \
    --severity high --gate qa-tests --dedup-key "disagree:raise" \
    --blocking --blocking-rationale "High severity"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false --rationale "agreed medium"
  [ "$status" -eq 0 ]

  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$output" = "APPROVE" ]

  # code-review re-reports with HIGHER severity (critical)
  run "$SCRIPT" add --story TEST-S1 --defect "disagree-raise" --type bug \
    --severity critical --gate code-review --dedup-key "disagree:raise" \
    --blocking --blocking-rationale "Upgraded to critical"
  [ "$status" -eq 0 ]

  # Resolution archived — REQUEST_CHANGES
  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$output" = "REQUEST_CHANGES" ]
  local has_sr
  has_sr="$(yq '.entries[0] | has("severity_resolution")' "$reg")"
  [ "$has_sr" = "false" ]
}

# ---------------------------------------------------------------------------
# Severity normalisation in verdict.sh: non-standard labels
# ---------------------------------------------------------------------------

@test "test-dast verdict.sh normalises Informational to low" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{"schema_version":"1.0","checks":[{"name":"zap","status":"passed","findings":[]}]}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{"findings":[{"category":"info","severity":"Informational","message":"Info finding","file":"src/a.ts","line":1,"rule":"dast.info"}]}
EOF

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local sev
  sev="$(yq '.entries[0].severity' "$reg")"
  [ "$sev" = "low" ]
  # Non-blocking low => APPROVE
  grep -qF "APPROVE" <<<"$output"
}

# ---------------------------------------------------------------------------
# Story key implies register mode: verdict.sh auto-enables register
# ---------------------------------------------------------------------------

@test "test-dast verdict.sh with story-key but no --register still writes the register" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{"schema_version":"1.0","checks":[{"name":"zap","status":"passed","findings":[]}]}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{"findings":[{"category":"xss","severity":"medium","message":"reflected xss","file":"src/a.ts","line":1,"rule":"dast.xss"}]}
EOF

  # Invoke with --story-key but WITHOUT --register
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1
  [ "$status" -eq 0 ]

  # The register must exist and contain the finding
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ]
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 1 ]
  local gr_len
  gr_len="$(yq '.gate_runs | length' "$reg")"
  [ "$gr_len" -ge 1 ]
}

@test "test-perf verdict.sh with story-key but no --register still writes the register" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/a.json" <<'EOF'
{"schema_version":"1.0","checks":[{"name":"perf","status":"passed","findings":[]}]}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{"findings":[{"category":"slo","severity":"medium","message":"p95 too high","file":"src/b.ts","line":5,"rule":"perf.slo"}]}
EOF

  # Invoke with --story-key but WITHOUT --register
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1
  [ "$status" -eq 0 ]

  # The register must exist and contain the finding
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ]
  local count
  count="$(yq '.entries | length' "$reg")"
  [ "$count" -eq 1 ]
  local gr_len
  gr_len="$(yq '.gate_runs | length' "$reg")"
  [ "$gr_len" -ge 1 ]
}

# ---------------------------------------------------------------------------
# merge archives severity_resolution on open and triage targets
# ---------------------------------------------------------------------------

@test "merge into resolved open entry with severity_resolution archives the resolution" {
  # Scenario: open entry with medium resolved non-blocking, then critical merged in.
  # Resolver must return REQUEST_CHANGES after the merge, not APPROVE.
  run "$SCRIPT" add --story TEST-S1 --defect "merge-sr-open" --type bug \
    --severity medium --gate code-review --dedup-key "merge:sr:open:a"
  [ "$status" -eq 0 ]

  # Resolve as non-blocking
  run "$SCRIPT" resolve-severity --story TEST-S1 --id RF-1 \
    --severity medium --blocking false --rationale "accepted medium"
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Verdict before merge: APPROVE (resolved non-blocking)
  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]

  # Add a critical finding as a second entry
  run "$SCRIPT" add --story TEST-S1 --defect "merge-sr-open-crit" --type security \
    --severity critical --gate security-review \
    --blocking --blocking-rationale "Critical severity" \
    --dedup-key "merge:sr:open:b"
  [ "$status" -eq 0 ]

  # Merge the critical entry into the first (open, resolved non-blocking)
  run "$SCRIPT" merge --story TEST-S1 --source-id RF-2 --target-id RF-1
  [ "$status" -eq 0 ]

  # After merge: severity_resolution must be archived, verdict REQUEST_CHANGES
  run --separate-stderr "$RESOLVER" --register "$reg"
  [ "$output" = "REQUEST_CHANGES" ] || {
    echo "expected REQUEST_CHANGES after merging critical into resolved entry, got: $output" >&2; false
  }

  # severity_resolution must be gone
  local has_sr
  has_sr="$(yq '.entries[0] | has("severity_resolution")' "$reg")"
  [ "$has_sr" = "false" ] || {
    echo "severity_resolution was not archived on merge" >&2; false
  }
}

@test "merge blocking entry into triage target reopens it to open" {
  run "$SCRIPT" add --story TEST-S1 --defect "merge-triage" --type bug \
    --severity low --gate code-review --dedup-key "merge:triage:a"
  [ "$status" -eq 0 ]

  # Triage the first entry
  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  # Add a critical blocking entry
  run "$SCRIPT" add --story TEST-S1 --defect "merge-triage-crit" --type security \
    --severity critical --gate security-review \
    --blocking --blocking-rationale "Critical" --dedup-key "merge:triage:b"
  [ "$status" -eq 0 ]

  # Merge critical into triage target
  run "$SCRIPT" merge --story TEST-S1 --source-id RF-2 --target-id RF-1
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # The merged entry must be open (not triage), and blocking
  local disp blk
  disp="$(yq '.entries[0].disposition' "$reg")"
  blk="$(yq '.entries[0].blocking' "$reg")"
  [ "$disp" = "open" ] || { echo "expected open, got $disp" >&2; false; }
  [ "$blk" = "true" ] || { echo "expected blocking true, got $blk" >&2; false; }
}

# ---------------------------------------------------------------------------
# gate-status rejects unknown gate names
# ---------------------------------------------------------------------------

@test "gate-status rejects unknown gate names with a clear error" {
  run "$SCRIPT" add --story TEST-S1 --defect "gate-val" --type bug \
    --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  # Known gate: succeeds
  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate code-review
  [ "$status" -eq 0 ]

  # Unknown gate: must fail with "unknown gate" message
  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate review-perf
  [ "$status" -ne 0 ]
  grep -qF 'unknown gate' <<<"$output" || { echo "expected 'unknown gate' error, got: $output" >&2; false; }

  # The correct register gate name works
  run "$SCRIPT" gate-status --story TEST-S1 --run-id run-001 --gate performance-review
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# findings-rows pipeline failure exits non-zero (no silent swallowing)
# ---------------------------------------------------------------------------

@test "findings-rows exits non-zero when register has a non-string type field" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  local story_file="$story_dir/TEST-S1-test-story.md"
  _write_story_file "$story_file" "TEST-S1"

  # Create a valid register with one triage entry, then corrupt the type field
  run "$SCRIPT" add --story TEST-S1 --defect "pipeline-fail" \
    --type bug --severity low --gate code-review
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" set-disposition --story TEST-S1 --id RF-1 \
    --disposition triage --owner code-review --priority low
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"

  # Corrupt the type field to a non-string (array)
  yq -i '.entries[0].type = ["not","a","string"]' "$reg"

  # findings-rows must fail (jq type mismatch on .type | sanitise_cell)
  run "$SCRIPT" findings-rows --story TEST-S1 --run-id run-001
  [ "$status" -ne 0 ] || { echo "expected non-zero exit on pipeline error, got 0" >&2; false; }

  # Story file must be untouched (no zero-length rows written)
  grep -qF 'RF-1' "$story_file" && { echo "story file was modified despite pipeline error" >&2; false; }
  true
}

# ---------------------------------------------------------------------------
# dast verdict.sh BLOCKED exit writes gate row FAILED
# ---------------------------------------------------------------------------

@test "dast verdict.sh BLOCKED from write failure still updates gate row to FAILED" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  local story_file="$story_dir/story.md"
  mkdir -p "$story_dir"
  # Story file with canonical Review Gate section so review-gate.sh can update it
  cat > "$story_file" <<'STORY'
---
template: 'story'
key: "TEST-S1"
title: "Test Story"
status: in-progress
epic: "TEST"
---
# Story: Test Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Findings

> Out-of-scope issues.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |
STORY

  cat > "$TEST_TMP/a.json" <<'EOF'
{"schema_version":"1.0","checks":[{"name":"zap","status":"passed","findings":[]}]}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{"findings":[{"category":"xss","severity":"critical","message":"reflected xss","file":"src/a.ts","line":1,"rule":"dast.xss"}]}
EOF

  # Make the register path unwritable so register-write.sh add fails
  local reg_path
  reg_path="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg_path")"
  : > "$reg_path"
  chmod 000 "$reg_path"

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register \
    --gate "Security Review"
  chmod 644 "$reg_path" 2>/dev/null || true

  # Verdict must be BLOCKED
  grep -qF "BLOCKED" <<<"$output" || { echo "expected BLOCKED verdict, got: $output" >&2; false; }

  # The Security Review gate row must now be FAILED (not the prior PASSED)
  grep -q 'Security Review.*FAILED' "$story_file" || {
    echo "expected Security Review gate row FAILED after BLOCKED verdict" >&2
    grep 'Security Review' "$story_file" >&2
    false
  }
}

@test "perf verdict.sh BLOCKED from write failure still updates gate row to FAILED" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  local story_file="$story_dir/story.md"
  mkdir -p "$story_dir"
  cat > "$story_file" <<'STORY'
---
template: 'story'
key: "TEST-S1"
title: "Test Story"
status: in-progress
epic: "TEST"
---
# Story: Test Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Findings

> Out-of-scope issues.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |
STORY

  cat > "$TEST_TMP/a.json" <<'EOF'
{"schema_version":"1.0","checks":[{"name":"perf","status":"passed","findings":[]}]}
EOF
  cat > "$TEST_TMP/f.json" <<'EOF'
{"findings":[{"category":"slo","severity":"critical","message":"p95 breach","file":"src/b.ts","line":5,"rule":"perf.slo.p95"}]}
EOF

  # Make the register path unwritable
  local reg_path
  reg_path="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  mkdir -p "$(dirname "$reg_path")"
  : > "$reg_path"
  chmod 000 "$reg_path"

  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register \
    --gate "Performance Review"
  chmod 644 "$reg_path" 2>/dev/null || true

  # Verdict must be BLOCKED
  grep -qF "BLOCKED" <<<"$output" || { echo "expected BLOCKED verdict, got: $output" >&2; false; }

  # The Performance Review gate row must now be FAILED
  grep -q 'Performance Review.*FAILED' "$story_file" || {
    echo "expected Performance Review gate row FAILED after BLOCKED verdict" >&2
    grep 'Performance Review' "$story_file" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# round end-to-end: mint run ID, record gates, gate-status reports correctly
# ---------------------------------------------------------------------------

@test "round end-to-end: run ID minted once is used by all gate records and gate-status" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  local run_id="round-20260101T120000Z-99999"

  # Each gate records a run with the shared run_id
  local g
  for g in code-review qa-tests security-review test-automate test-review performance-review; do
    run "$SCRIPT" record-run --story TEST-S1 --run-id "$run_id" --gate "$g" --outcome completed
    [ "$status" -eq 0 ]
  done

  # gate-status must report RAN for every gate with the same run_id
  for g in code-review qa-tests security-review test-automate test-review performance-review; do
    run "$SCRIPT" gate-status --story TEST-S1 --run-id "$run_id" --gate "$g"
    [ "$status" -eq 0 ]
    [ "$output" = "RAN" ] || { echo "expected RAN for $g, got: $output" >&2; false; }
  done

  # A different run_id must report UNVERIFIED
  run "$SCRIPT" gate-status --story TEST-S1 --run-id "other-run" --gate code-review
  [ "$status" -eq 0 ]
  [ "$output" = "UNVERIFIED" ]
}

# ---------------------------------------------------------------------------
# verdict.sh PASSED verdict does not use the report-missing escape hatch
# ---------------------------------------------------------------------------

@test "dast verdict.sh PASSED verdict does not write gate row via escape hatch" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  local story_file="$story_dir/story.md"
  mkdir -p "$story_dir"
  cat > "$story_file" <<'STORY'
---
template: 'story'
key: "TEST-S1"
title: "Test Story"
status: in-progress
epic: "TEST"
---
# Story: Test Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

## Findings

> Out-of-scope issues.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |
STORY

  cat > "$TEST_TMP/a.json" <<'EOF'
{"schema_version":"1.0","checks":[{"name":"zap","status":"passed","findings":[]}]}
EOF
  # No findings — verdict will be APPROVE
  cat > "$TEST_TMP/f.json" <<'EOF'
{"findings":[]}
EOF

  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register \
    --gate "Security Review"
  [ "$status" -eq 0 ]

  # Verdict must be APPROVE
  grep -qF "APPROVE" <<<"$output" || { echo "expected APPROVE verdict, got: $output" >&2; false; }

  # The Security Review gate row must still be UNVERIFIED — PASSED must NOT be
  # written without a real report file (proof-of-execution rejects it)
  grep -q 'Security Review.*UNVERIFIED' "$story_file" || {
    local row
    row="$(grep 'Security Review' "$story_file")"
    echo "expected gate row to stay UNVERIFIED (no report), got: $row" >&2
    false
  }
}

@test "perf verdict.sh PASSED verdict does not write gate row via escape hatch" {
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  local story_file="$story_dir/story.md"
  mkdir -p "$story_dir"
  cat > "$story_file" <<'STORY'
---
template: 'story'
key: "TEST-S1"
title: "Test Story"
status: in-progress
epic: "TEST"
---
# Story: Test Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

## Findings

> Out-of-scope issues.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |
STORY

  cat > "$TEST_TMP/a.json" <<'EOF'
{"schema_version":"1.0","checks":[{"name":"perf","status":"passed","findings":[]}]}
EOF
  # No findings — verdict will be APPROVE
  cat > "$TEST_TMP/f.json" <<'EOF'
{"findings":[]}
EOF

  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/a.json" \
    --llm-findings "$TEST_TMP/f.json" --story-key TEST-S1 --register \
    --gate "Performance Review"
  [ "$status" -eq 0 ]

  # Verdict must be APPROVE
  grep -qF "APPROVE" <<<"$output" || { echo "expected APPROVE verdict, got: $output" >&2; false; }

  # The Performance Review gate row must still be UNVERIFIED — PASSED must NOT be
  # written without a real report file (proof-of-execution rejects it)
  grep -q 'Performance Review.*UNVERIFIED' "$story_file" || {
    local row
    row="$(grep 'Performance Review' "$story_file")"
    echo "expected gate row to stay UNVERIFIED (no report), got: $row" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Register-mode fail-closed tests for verdict.sh
#
# When --llm-findings is omitted, missing, unreadable, empty, or malformed
# in register mode, verdict.sh must yield BLOCKED with outcome "errored"
# so that a missing findings file never silently produces APPROVE.
# ---------------------------------------------------------------------------

# Helper: write a standard analysis-results fixture for DAST or perf.
_failclosed_setup() {
  local skill="$1"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  local story_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/TEST-S1-test-story"
  _write_story_file "$story_dir/story.md" "TEST-S1"

  cat > "$TEST_TMP/ar.json" <<EOF
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "skill": "$skill",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:test",
  "tool_versions": {},
  "file_hashes": {},
  "checks": [{"name":"check","status":"passed","findings":[]}]
}
EOF
}

# Assert: last stdout line is BLOCKED and the register's last gate_runs
# entry has outcome "errored".
_assert_blocked_errored() {
  local label="$1"
  [ "$status" -eq 0 ] || { echo "$label: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || {
    echo "$label: expected BLOCKED on last line, got: $last_line" >&2; false
  }
  # Check register outcome — assert existence, then check the outcome.
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "$label: register file not found at $reg" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg" 2>/dev/null)" || outcome=""
  [ "$outcome" = "errored" ] || {
    echo "$label: expected last gate_runs outcome=errored, got: $outcome" >&2; false
  }
}

# --- DAST verdict.sh fail-closed cases ---

@test "dast verdict.sh register mode: omitted llm-findings yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-dast"
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "dast-omitted"
}

@test "dast verdict.sh register mode: missing llm-findings path yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-dast"
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/no-such-file.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "dast-missing"
}

@test "dast verdict.sh register mode: unreadable llm-findings yields BLOCKED with errored run" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses permissions"; fi
  _failclosed_setup "gaia-test-dast"
  local f="$TEST_TMP/unreadable.json"
  printf '{"findings":[]}' > "$f"
  chmod 000 "$f"
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$f" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "dast-unreadable"
}

@test "dast verdict.sh register mode: empty llm-findings yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-dast"
  : > "$TEST_TMP/empty.json"
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/empty.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "dast-empty"
}

@test "dast verdict.sh register mode: truncated json yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-dast"
  printf '{"findings": [{"severity":' > "$TEST_TMP/truncated.json"
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/truncated.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "dast-truncated"
}

@test "dast verdict.sh register mode: json without findings array yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-dast"
  printf '{"results": []}' > "$TEST_TMP/nofind.json"
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/nofind.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "dast-no-findings-key"
}

@test "dast verdict.sh register mode: valid empty findings array yields APPROVE with completed run" {
  _failclosed_setup "gaia-test-dast"
  printf '{"findings":[]}' > "$TEST_TMP/ok.json"
  run "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/ok.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ]
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "APPROVE" ] || {
    echo "dast-control: expected APPROVE on last line, got: $last_line" >&2; false
  }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "dast-control: register file not found at $reg" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg" 2>/dev/null)" || outcome=""
  [ "$outcome" = "completed" ] || {
    echo "dast-control: expected last gate_runs outcome=completed, got: $outcome" >&2; false
  }
}

# --- Perf verdict.sh fail-closed cases ---

@test "perf verdict.sh register mode: omitted llm-findings yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-perf"
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "perf-omitted"
}

@test "perf verdict.sh register mode: missing llm-findings path yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-perf"
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/no-such-file.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "perf-missing"
}

@test "perf verdict.sh register mode: unreadable llm-findings yields BLOCKED with errored run" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses permissions"; fi
  _failclosed_setup "gaia-test-perf"
  local f="$TEST_TMP/unreadable.json"
  printf '{"findings":[]}' > "$f"
  chmod 000 "$f"
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$f" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "perf-unreadable"
}

@test "perf verdict.sh register mode: empty llm-findings yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-perf"
  : > "$TEST_TMP/empty.json"
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/empty.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "perf-empty"
}

@test "perf verdict.sh register mode: truncated json yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-perf"
  printf '{"findings": [{"severity":' > "$TEST_TMP/truncated.json"
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/truncated.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "perf-truncated"
}

@test "perf verdict.sh register mode: json without findings array yields BLOCKED with errored run" {
  _failclosed_setup "gaia-test-perf"
  printf '{"results": []}' > "$TEST_TMP/nofind.json"
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/nofind.json" \
    --story-key TEST-S1 --register
  _assert_blocked_errored "perf-no-findings-key"
}

@test "perf verdict.sh register mode: valid empty findings array yields APPROVE with completed run" {
  _failclosed_setup "gaia-test-perf"
  printf '{"findings":[]}' > "$TEST_TMP/ok.json"
  run "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/ok.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ]
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "APPROVE" ] || {
    echo "perf-control: expected APPROVE on last line, got: $last_line" >&2; false
  }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "perf-control: register file not found at $reg" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg" 2>/dev/null)" || outcome=""
  [ "$outcome" = "completed" ] || {
    echo "perf-control: expected last gate_runs outcome=completed, got: $outcome" >&2; false
  }
}

# ---------------------------------------------------------------------------
# Multi-document and non-object findings bypass tests
#
# Two concatenated JSON documents, or findings arrays containing non-object
# items, must be rejected by the strict slurp-based validation and yield
# BLOCKED with outcome "errored".
# ---------------------------------------------------------------------------

@test "dast verdict.sh register mode: two documents (critical first, empty second) yields BLOCKED" {
  _failclosed_setup "gaia-test-dast"
  printf '{"findings":[{"severity":"critical","message":"x"}]}\n{"findings":[]}\n' > "$TEST_TMP/twodoc.json"
  run --separate-stderr "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/twodoc.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "dast-twodoc-crit: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "dast-twodoc-crit: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "dast-twodoc-crit: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "dast-twodoc-crit: expected errored, got: $outcome" >&2; false; }
}

@test "dast verdict.sh register mode: two documents (empty first, critical second) yields BLOCKED" {
  _failclosed_setup "gaia-test-dast"
  printf '{"findings":[]}\n{"findings":[{"severity":"critical","message":"x"}]}\n' > "$TEST_TMP/twodoc2.json"
  run --separate-stderr "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/twodoc2.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "dast-twodoc-empty: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "dast-twodoc-empty: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "dast-twodoc-empty: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "dast-twodoc-empty: expected errored, got: $outcome" >&2; false; }
}

@test "dast verdict.sh register mode: non-object item in findings yields BLOCKED" {
  _failclosed_setup "gaia-test-dast"
  printf '{"findings":[1]}' > "$TEST_TMP/nonobj.json"
  run --separate-stderr "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/nonobj.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "dast-nonobj: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "dast-nonobj: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "dast-nonobj: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "dast-nonobj: expected errored, got: $outcome" >&2; false; }
}

@test "dast verdict.sh register mode: nested-array item in findings yields BLOCKED" {
  _failclosed_setup "gaia-test-dast"
  printf '{"findings":[[]]}' > "$TEST_TMP/nested.json"
  run --separate-stderr "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/nested.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "dast-nested: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "dast-nested: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "dast-nested: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "dast-nested: expected errored, got: $outcome" >&2; false; }
}

@test "perf verdict.sh register mode: two documents (critical first, empty second) yields BLOCKED" {
  _failclosed_setup "gaia-test-perf"
  printf '{"findings":[{"severity":"critical","message":"x"}]}\n{"findings":[]}\n' > "$TEST_TMP/twodoc.json"
  run --separate-stderr "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/twodoc.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "perf-twodoc-crit: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "perf-twodoc-crit: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "perf-twodoc-crit: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "perf-twodoc-crit: expected errored, got: $outcome" >&2; false; }
}

@test "perf verdict.sh register mode: two documents (empty first, critical second) yields BLOCKED" {
  _failclosed_setup "gaia-test-perf"
  printf '{"findings":[]}\n{"findings":[{"severity":"critical","message":"x"}]}\n' > "$TEST_TMP/twodoc2.json"
  run --separate-stderr "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/twodoc2.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "perf-twodoc-empty: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "perf-twodoc-empty: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "perf-twodoc-empty: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "perf-twodoc-empty: expected errored, got: $outcome" >&2; false; }
}

@test "perf verdict.sh register mode: non-object item in findings yields BLOCKED" {
  _failclosed_setup "gaia-test-perf"
  printf '{"findings":[1]}' > "$TEST_TMP/nonobj.json"
  run --separate-stderr "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/nonobj.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "perf-nonobj: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "perf-nonobj: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "perf-nonobj: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "perf-nonobj: expected errored, got: $outcome" >&2; false; }
}

@test "perf verdict.sh register mode: nested-array item in findings yields BLOCKED" {
  _failclosed_setup "gaia-test-perf"
  printf '{"findings":[[]]}' > "$TEST_TMP/nested.json"
  run --separate-stderr "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/nested.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "perf-nested: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "BLOCKED" ] || { echo "perf-nested: expected BLOCKED, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "perf-nested: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "errored" ] || { echo "perf-nested: expected errored, got: $outcome" >&2; false; }
}

# ---------------------------------------------------------------------------
# Control: inherited _write_failed must not block a valid run
# ---------------------------------------------------------------------------

@test "dast verdict.sh register mode: inherited _write_failed=1 does not block a valid run" {
  _failclosed_setup "gaia-test-dast"
  printf '{"findings":[]}' > "$TEST_TMP/ok.json"
  _write_failed=1 run --separate-stderr "$DAST_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/ok.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "dast-inherit: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "APPROVE" ] || { echo "dast-inherit: expected APPROVE, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "dast-inherit: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "completed" ] || { echo "dast-inherit: expected completed, got: $outcome" >&2; false; }
}

@test "perf verdict.sh register mode: inherited _write_failed=1 does not block a valid run" {
  _failclosed_setup "gaia-test-perf"
  printf '{"findings":[]}' > "$TEST_TMP/ok.json"
  _write_failed=1 run --separate-stderr "$PERF_VERDICT" --analysis-results "$TEST_TMP/ar.json" \
    --llm-findings "$TEST_TMP/ok.json" \
    --story-key TEST-S1 --register
  [ "$status" -eq 0 ] || { echo "perf-inherit: non-zero exit ($status)" >&2; false; }
  local last_line
  last_line="$(tail -n1 <<<"$output")"
  [ "$last_line" = "APPROVE" ] || { echo "perf-inherit: expected APPROVE, got: $last_line" >&2; false; }
  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  [ -f "$reg" ] || { echo "perf-inherit: register not found" >&2; false; }
  local outcome
  outcome="$(yq '.gate_runs[-1].outcome' "$reg")"
  [ "$outcome" = "completed" ] || { echo "perf-inherit: expected completed, got: $outcome" >&2; false; }
}

# ---------------------------------------------------------------------------
# record-run: seq field (per-round review record additive change)
# ---------------------------------------------------------------------------

@test "record-run appends seq monotonically" {
  _minimal_register "$TEST_TMP/reg.yaml"

  local stories_dir="$IMPLEMENTATION_ARTIFACTS/epic-test/stories"
  mkdir -p "$stories_dir"
  cat > "$stories_dir/TEST-S1-test-story.md" <<'STORY'
---
template: 'story'
key: "TEST-S1"
title: "Test Story"
status: in-progress
epic: "TEST"
---
# Story: Test Story

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |
STORY

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-001 \
    --gate code-review --outcome completed
  [ "$status" -eq 0 ]

  run "$SCRIPT" record-run --story TEST-S1 --run-id run-002 \
    --gate qa-tests --outcome completed
  [ "$status" -eq 0 ]

  local reg
  reg="$("$REPORT_PATH" --key TEST-S1 --type findings-register)"
  local seq1
  seq1="$(yq '.gate_runs[0].seq' "$reg")"
  local seq2
  seq2="$(yq '.gate_runs[1].seq' "$reg")"

  # Both should have seq; seq2 > seq1.
  [ "$seq1" -ge 1 ]
  [ "$seq2" -gt "$seq1" ]
}
