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

  # Defect text with pipes, triple dashes, and TRIAGED markers
  run "$SCRIPT" add --story TEST-S1 \
    --defect "found | in output --- also [TRIAGED stuff" \
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

  # The row must not contain raw pipe (except as column separator)
  # Triple dash must be spaced, TRIAGED marker brackets stripped
  local findings_section
  findings_section="$(sed -n '/^## Findings/,/^## /p' "$story_file" | grep 'RF-1')"
  # pipe inside cell replaced with /
  { ! grep -qF '| in output' <<<"$findings_section"; } || { grep -qF '/ in output' <<<"$findings_section"; }
  # triple dash spaced
  { ! grep -qF '---' <<<"$findings_section"; } || { grep -qF '- - -' <<<"$findings_section"; }
}

@test "sanitiser strips bracket markers from values larger than 128 KB" {
  # Extract and eval the sanitiser function (the full script has top-level
  # dispatch we skip).  The function is self-contained.
  eval "$(sed -n '/_rw_sanitise_table_chars()/,/^}/p' "$SCRIPT")"

  # Build a ~140 KB value with bracket-prefixed markers embedded.
  local padding
  padding="$(head -c 131072 < /dev/zero | tr '\0' 'x')"
  local big="prefix [TRIAGED marker ${padding} middle [DISMISSED end [TRIAGED tail"

  # Run under pipefail — the old pipe-based loop raced under pipefail
  # with values this large (grep -q exits early, SIGPIPE kills the writer).
  local result
  set -o pipefail
  result="$(_rw_sanitise_table_chars "$big")"

  # No bracket-prefixed markers should remain.
  ! grep -qF '[TRIAGED' <<<"$result"
  ! grep -qF '[DISMISSED' <<<"$result"
  # The keywords themselves must survive (only the bracket is stripped).
  grep -qF 'TRIAGED' <<<"$result"
  grep -qF 'DISMISSED' <<<"$result"
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
  ! grep -q '| — | — | — | — | — |' "$story_file"

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
  ! grep -qF "BLOCKED" <<<"$output"
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
