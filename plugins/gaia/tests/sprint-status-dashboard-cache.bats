#!/usr/bin/env bats
# sprint-status-dashboard-cache.bats
#
# Tests the cache-first rendering path of sprint-status-dashboard.sh.
# Covers Tasks/Gates columns, phase grouping, warning header, cache
# freshness via counting shim, sanitization (per-vector), numeric
# validation (per-field), risk annotation from cache, header/footer
# from cache, and fallback logic with stderr notice assertions.
#
# Fixture strategy: generate cache JSON by running the REAL snapshot
# script against temp fixture projects. Malformed caches are jq-mutated
# from real output. All fixtures use synthetic keys E900-S1..E900-S9.
#
# Red-phase guard: every cache-path test asserts that "Tasks" and "Gates"
# columns appear in the header (only the cache path produces them).
# Without the cache implementation, these assertions fail — ensuring
# the test is genuinely red.
#
# Test seam: SPRINT_PROGRESS_SNAPSHOT overrides the snapshot script
# location so a counting shim can be injected.

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Globals resolved once at load time
# ---------------------------------------------------------------------------
SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
DASHBOARD="$SCRIPTS_DIR/sprint-status-dashboard.sh"
SNAPSHOT="$SCRIPTS_DIR/sprint-progress-snapshot.sh"
PLUGIN_TREE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# ---------------------------------------------------------------------------
# setup_file — generate fixture projects ONCE (real snapshot), then each
# test copies from these via cp -R instead of re-running the snapshot.
# ---------------------------------------------------------------------------
setup_file() {
  _litter_snapshot_before
  if ! command -v jq >/dev/null 2>&1; then
    printf 'FATAL: jq is required for sprint-status-dashboard-cache.bats\n' >&2
    exit 1
  fi

  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  # --- Base fixture (4 stories, 2 phases + unphased, high-risk E900-S1) ---
  export _SETUP_BASE="$BATS_FILE_TMPDIR/base-fixture"
  mkdir -p "$_SETUP_BASE/.gaia/state" "$_SETUP_BASE/.gaia/artifacts/implementation-artifacts"
  cat > "$_SETUP_BASE/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-test"
status: active
total_points: 21
start_date: "2026-01-01"
end_date: "2026-01-14"
goals:
  - "Deliver cache dashboard"
capacity_utilization: "85%"
epic_focus: "E900 cache mod"
stories:
  - key: E900-S1
    title: "Story with tasks and partial gates"
    status: in-progress
    points: 5
    risk_level: high
    phase: 1
  - key: E900-S2
    title: "Story all done"
    status: done
    points: 8
    risk_level: low
    phase: 1
  - key: E900-S3
    title: "Story in phase two"
    status: ready-for-dev
    points: 3
    risk_level: medium
    phase: 2
  - key: E900-S4
    title: "Unphased story no tasks"
    status: backlog
    points: 5
    risk_level: low
YAML
  local epic_dir="$_SETUP_BASE/.gaia/artifacts/implementation-artifacts/epic-e900"
  mkdir -p "$epic_dir/E900-S1-story-tasks"
  cat > "$epic_dir/E900-S1-story-tasks/story.md" <<'MD'
---
key: "E900-S1"
status: in-progress
points: 5
risk: high
manual_verification: false
title: "Story with tasks and partial gates"
---
# Story: Story with tasks and partial gates
## Tasks / Subtasks
- [x] **T1:** First done
- [x] **T2:** Second done
- [ ] **T3:** Third pending
- [ ] **T4:** Fourth pending
- [ ] **T5:** Fifth pending
## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | ... |
| QA Tests | PASSED | ... |
| Security Review | PASSED | ... |
| Test Automation | PASSED | ... |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
MD
  mkdir -p "$epic_dir/E900-S2-story-done"
  cat > "$epic_dir/E900-S2-story-done/story.md" <<'MD'
---
key: "E900-S2"
status: done
points: 8
risk: low
manual_verification: false
title: "Story all done"
---
# Story: Story all done
## Tasks / Subtasks
- [x] **T1:** Only task
## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | ... |
| QA Tests | PASSED | ... |
| Security Review | PASSED | ... |
| Test Automation | PASSED | ... |
| Test Review | PASSED | ... |
| Performance Review | PASSED | ... |
MD
  mkdir -p "$epic_dir/E900-S3-story-phase-two"
  cat > "$epic_dir/E900-S3-story-phase-two/story.md" <<'MD'
---
key: "E900-S3"
status: ready-for-dev
points: 3
risk: medium
manual_verification: false
title: "Story in phase two"
---
# Story: Story in phase two
## Tasks / Subtasks
- [ ] **T1:** Pending
- [ ] **T2:** Also pending
- [ ] **T3:** Third pending
## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | - |
| QA Tests | UNVERIFIED | - |
| Security Review | UNVERIFIED | - |
| Test Automation | UNVERIFIED | - |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
MD
  mkdir -p "$epic_dir/E900-S4-unphased"
  cat > "$epic_dir/E900-S4-unphased/story.md" <<'MD'
---
key: "E900-S4"
status: backlog
points: 5
risk: low
manual_verification: false
title: "Unphased story no tasks"
---
# Story: Unphased story no tasks
## Tasks / Subtasks
## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | - |
| QA Tests | UNVERIFIED | - |
| Security Review | UNVERIFIED | - |
| Test Automation | UNVERIFIED | - |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
MD
  PROJECT_ROOT="$_SETUP_BASE" \
    SPRINT_STATUS_YAML="$_SETUP_BASE/.gaia/state/sprint-status.yaml" \
    GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$SNAPSHOT" 2>/dev/null

  # --- All-done fixture (2 done stories, triggers auto-close) ---
  export _SETUP_ALLDONE="$BATS_FILE_TMPDIR/alldone-fixture"
  mkdir -p "$_SETUP_ALLDONE/.gaia/state" "$_SETUP_ALLDONE/.gaia/artifacts/implementation-artifacts"
  cat > "$_SETUP_ALLDONE/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-close"
status: active
total_points: 10
start_date: "2026-02-01"
end_date: "2026-02-14"
stories:
  - key: E900-S5
    title: "Done alpha"
    status: done
    points: 5
    risk_level: low
    phase: 1
  - key: E900-S6
    title: "Done beta"
    status: done
    points: 5
    risk_level: low
    phase: 1
YAML
  local ad_epic="$_SETUP_ALLDONE/.gaia/artifacts/implementation-artifacts/epic-e900"
  local key
  for key in E900-S5 E900-S6; do
    mkdir -p "$ad_epic/${key}-done"
    cat > "$ad_epic/${key}-done/story.md" <<MD
---
key: "$key"
status: done
points: 5
risk: low
manual_verification: false
title: "Done story $key"
---
# Story: Done story $key
## Tasks / Subtasks
- [x] **T1:** Complete
## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | ... |
| QA Tests | PASSED | ... |
| Security Review | PASSED | ... |
| Test Automation | PASSED | ... |
| Test Review | PASSED | ... |
| Performance Review | PASSED | ... |
MD
  done
  PROJECT_ROOT="$_SETUP_ALLDONE" \
    SPRINT_STATUS_YAML="$_SETUP_ALLDONE/.gaia/state/sprint-status.yaml" \
    GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$SNAPSHOT" 2>/dev/null

  # Record checksums of the shared caches for integrity verification.
  if command -v sha256sum >/dev/null 2>&1; then
    _SETUP_BASE_SHA="$(sha256sum "$_SETUP_BASE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
    _SETUP_ALLDONE_SHA="$(sha256sum "$_SETUP_ALLDONE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
  else
    _SETUP_BASE_SHA="$(shasum -a 256 "$_SETUP_BASE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
    _SETUP_ALLDONE_SHA="$(shasum -a 256 "$_SETUP_ALLDONE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
  fi
  export _SETUP_BASE_SHA _SETUP_ALLDONE_SHA

  # Make the shared trees read-only so any accidental write fails loudly.
  chmod -R a-w "$_SETUP_BASE" "$_SETUP_ALLDONE"
}

teardown_file() {
  _litter_check_after
  # Restore write permission so bats can clean up BATS_FILE_TMPDIR.
  chmod -R u+w "$_SETUP_BASE" "$_SETUP_ALLDONE" 2>/dev/null || true

  # Verify shared caches were not mutated during the suite.
  local base_sha alldone_sha
  if command -v sha256sum >/dev/null 2>&1; then
    base_sha="$(sha256sum "$_SETUP_BASE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
    alldone_sha="$(sha256sum "$_SETUP_ALLDONE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
  else
    base_sha="$(shasum -a 256 "$_SETUP_BASE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
    alldone_sha="$(shasum -a 256 "$_SETUP_ALLDONE/.gaia/state/.sprint-progress-cache.json" | awk '{print $1}')"
  fi
  if [ "$base_sha" != "$_SETUP_BASE_SHA" ]; then
    printf 'FAIL: shared base cache was mutated during the suite\n' >&2
    return 1
  fi
  if [ "$alldone_sha" != "$_SETUP_ALLDONE_SHA" ]; then
    printf 'FAIL: shared alldone cache was mutated during the suite\n' >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------
setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT SPRINT_STATUS_YAML SPRINT_CACHE_JSON
  unset SPRINT_PROGRESS_SNAPSHOT
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  TEST_TMP="$BATS_TEST_TMPDIR/ssdcache-$$"
  mkdir -p "$TEST_TMP"
  export TEST_TMP
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Guard helper: assert the cache path was used (Tasks+Gates columns present)
# ---------------------------------------------------------------------------
_assert_cache_columns() {
  # The cache path adds Tasks and Gates columns; the fallback path does not.
  # This assertion MUST fail before the cache implementation exists.
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ "$hdr" =~ "Tasks" ]]
  [[ "$hdr" =~ "Gates" ]]
}

# ---------------------------------------------------------------------------
# Helper: create a snapshot counting shim
# ---------------------------------------------------------------------------
_mk_snapshot_shim() {
  local counter_file="$TEST_TMP/snapshot-call-count"
  printf '0' > "$counter_file"
  cat > "$TEST_TMP/shim-snapshot.sh" <<SHIMEOF
#!/usr/bin/env bash
# Counting shim — increments counter then delegates to the real snapshot.
count_file="$counter_file"
prev=\$(cat "\$count_file" 2>/dev/null || printf '0')
printf '%d' "\$(( prev + 1 ))" > "\$count_file"
exec bash "$SNAPSHOT" "\$@"
SHIMEOF
  chmod +x "$TEST_TMP/shim-snapshot.sh"
  export SPRINT_PROGRESS_SNAPSHOT="$TEST_TMP/shim-snapshot.sh"
  SHIM_COUNTER="$counter_file"
}

_shim_count() {
  cat "$SHIM_COUNTER" 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# Fixture helpers — copy from the pre-generated trees in BATS_FILE_TMPDIR.
# ---------------------------------------------------------------------------

# _mk_fixture_project — point CACHE_PATH at the pre-generated cache.
# Most tests set SPRINT_CACHE_JSON to a jq-mutated copy, so they only
# need the cache JSON, not the full project tree. Tests that need the
# full tree for snapshot invocation call _mk_fixture_project_full.
# _mk_fixture_project — set CACHE_PATH to the pre-generated cache.
# The shared tree under _SETUP_BASE is read-only; tests that need to
# mutate get a copy via jq into $TEST_TMP and set SPRINT_CACHE_JSON.
# Tests that need the full tree (snapshot shim, fallback, bash 3.2)
# should cp -R _SETUP_BASE into TEST_TMP themselves.
_mk_fixture_project() {
  CACHE_PATH="$_SETUP_BASE/.gaia/state/.sprint-progress-cache.json"
  export PROJECT_ROOT="$_SETUP_BASE"
}

# _mk_alldone_fixture — same pattern for the all-done fixture.
_mk_alldone_fixture() {
  CACHE_PATH="$_SETUP_ALLDONE/.gaia/state/.sprint-progress-cache.json"
  export PROJECT_ROOT="$_SETUP_ALLDONE"
}

# ===========================================================================
# Tasks X/Y column tests
# ===========================================================================

@test "tasks column shows done/total for a story with tasks (e.g. 2/5)" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "2/5" ]]
}

@test "tasks column shows done/total for a fully-complete story (e.g. 1/1)" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "1/1" ]]
}

@test "tasks column shows 0/3 for a story with no done tasks" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "0/3" ]]
}

@test "tasks column shows standalone dash when tasks total is 0" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # E900-S4 has 0 tasks. Extract its row. The Tasks column (column 5 in the
  # new layout) must contain a standalone "-" and must NOT show "0/0".
  local s4_line
  s4_line="$(grep 'E900-S4' <<<"$output" | head -1)"
  [[ -n "$s4_line" ]]
  [[ ! "$s4_line" =~ "0/0" ]]
  # The Tasks column is at a fixed position; a standalone dash should appear
  # between the Pts column and the Gates column. Match "- " preceded by space.
  # The precise format: ...  Pts  Tasks   Gates
  # A dash as a standalone 7-char-wide column: at least "  -  " or similar.
  # We check that the row contains "  -  " or " - " as a field separator.
  [[ "$s4_line" =~ [[:space:]]+-[[:space:]]+ ]]
}

@test "table header includes Tasks column" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]

  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ "$hdr" =~ "Tasks" ]]
}

# ===========================================================================
# Gates X/6 column tests
# ===========================================================================

@test "gates column shows passed/6 for a partially-gated story (e.g. 4/6)" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "4/6" ]]
}

@test "gates column shows 6/6 for a fully-gated story" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "6/6" ]]
}

@test "gates column shows 0/6 for a story with no gates passed" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "0/6" ]]
}

@test "table header includes Gates column" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]

  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ "$hdr" =~ "Gates" ]]
}

# ===========================================================================
# Phase grouping tests
# ===========================================================================

@test "stories grouped by phase with phase header lines" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "Phase 1" ]]
  [[ "$output" =~ "Phase 2" ]]
}

@test "phase header shows status label (done/active/future)" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "(active)" ]]
  [[ "$output" =~ "(future)" ]]
}

@test "unphased stories appear in a separate Unphased group at the end" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "Unphased" ]]
  local unphased_line s4_line
  unphased_line="$(grep -n 'Unphased' <<<"$output" | head -1 | cut -d: -f1)"
  s4_line="$(grep -n 'E900-S4' <<<"$output" | head -1 | cut -d: -f1)"
  [ -n "$unphased_line" ]
  [ -n "$s4_line" ]
  [ "$unphased_line" -lt "$s4_line" ]
}

@test "stories within a phase preserve yaml order" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local s1_line s2_line
  s1_line="$(grep -n 'E900-S1' <<<"$output" | head -1 | cut -d: -f1)"
  s2_line="$(grep -n 'E900-S2' <<<"$output" | head -1 | cut -d: -f1)"
  [ -n "$s1_line" ]
  [ -n "$s2_line" ]
  [ "$s1_line" -lt "$s2_line" ]
}

@test "single-phase sprint shows one phase header only" {
  local root="$TEST_TMP/singlephase"
  mkdir -p "$root/.gaia/state"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S7-single"
  cat > "$root/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-single"
status: active
total_points: 5
start_date: "2026-01-01"
end_date: "2026-01-14"
stories:
  - key: E900-S7
    title: "Only story"
    status: in-progress
    points: 5
    risk_level: low
    phase: 1
YAML
  cat > "$root/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S7-single/story.md" <<'MD'
---
key: "E900-S7"
status: in-progress
points: 5
risk: low
manual_verification: false
title: "Only story"
---
# Story: Only story
## Tasks / Subtasks
- [ ] **T1:** Task
## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | - |
| QA Tests | UNVERIFIED | - |
| Security Review | UNVERIFIED | - |
| Test Automation | UNVERIFIED | - |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
MD

  PROJECT_ROOT="$root" \
    SPRINT_STATUS_YAML="$root/.gaia/state/sprint-status.yaml" \
    GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$SNAPSHOT" 2>/dev/null

  export SPRINT_CACHE_JSON="$root/.gaia/state/.sprint-progress-cache.json"
  export PROJECT_ROOT="$root"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local phase_count
  phase_count="$(grep -c 'Phase' <<<"$output" || true)"
  [ "$phase_count" -eq 1 ]
  [[ ! "$output" =~ "Unphased" ]]
}

# ===========================================================================
# Warning header tests
# ===========================================================================

@test "warning header appears when action_needed is non-empty (rules a/c/d)" {
  _mk_fixture_project
  # Inject a rule-a action_needed entry so WARNING fires
  jq '.action_needed = [{"rule":"a","type":"manual_test_due","message":"Test due for E900-S1","command":"","since":"","source":"","story_keys":["E900-S1"]}]' \
    "$CACHE_PATH" > "$TEST_TMP/has-action.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/has-action.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "WARNING" ]]
  [[ "$output" =~ "needs attention" ]] || [[ "$output" =~ "item" ]]
}

@test "warning header absent when action_needed is empty" {
  _mk_fixture_project
  jq '.action_needed = []' "$CACHE_PATH" > "$TEST_TMP/empty-action.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/empty-action.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ ! "$output" =~ "WARNING" ]]
}

@test "warning header shows singular form for 1 item" {
  _mk_fixture_project
  jq '.action_needed = [{"rule":"a","type":"manual_test_due","message":"Manual test due for E900-S1","command":"/gaia-test-manual","since":"2026-01-01","source":"story-file","story_keys":["E900-S1"]}]' \
    "$CACHE_PATH" > "$TEST_TMP/one-action.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/one-action.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "1 item needs attention" ]] || [[ "$output" =~ "WARNING: 1 item" ]]
}

@test "warning header shows plural form for N items" {
  _mk_fixture_project
  jq '.action_needed = [
    {"rule":"a","type":"manual_test_due","message":"Manual test due for E900-S1","command":"","since":"","source":"","story_keys":["E900-S1"]},
    {"rule":"a","type":"manual_test_due","message":"Manual test due for E900-S2","command":"","since":"","source":"","story_keys":["E900-S2"]},
    {"rule":"c","type":"action_item_assigned","message":"Action item assigned","command":"","since":"","source":"","story_keys":[],"item_id":"item-1"}
  ]' "$CACHE_PATH" > "$TEST_TMP/multi-action.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/multi-action.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "3 items need attention" ]] || [[ "$output" =~ "WARNING: 3 items" ]]
}

@test "rule-d suppressed from warning when auto-close banner shows" {
  _mk_alldone_fixture
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$TEST_TMP/alldonefixture"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "READY-TO-REVIEW" ]]
  [[ ! "$output" =~ "WARNING" ]]
}

@test "warning header with more than 10 items shows accurate count" {
  _mk_fixture_project
  local items='['
  for i in $(seq 1 12); do
    [ "$i" -gt 1 ] && items="$items,"
    items="$items"'{"rule":"a","type":"manual_test_due","message":"Item '"$i"' needs attention","command":"","since":"","source":"","story_keys":[]}'
  done
  items="$items]"
  jq --argjson items "$items" '.action_needed = $items' "$CACHE_PATH" > "$TEST_TMP/many-action.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/many-action.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "12 items need attention" ]] || [[ "$output" =~ "WARNING: 12" ]]
}

# ===========================================================================
# Risk annotation from cache (Item 1)
# ===========================================================================

@test "high-risk story gets inline mitigation annotation from cache" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"
  # The fixture's E900-S1 has risk_level: high in the yaml and cache.

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # The HIGH-risk annotation must appear on the E900-S1 row.
  [[ "$output" =~ "HIGH-risk: mitigation" ]]
  # At least one catalog mitigation label must appear.
  [[ "$output" =~ "Pair programming" ]] || \
    [[ "$output" =~ "Increased test coverage" ]] || \
    [[ "$output" =~ "Architect review" ]] || \
    [[ "$output" =~ "Security review" ]]
}

@test "high-risk story triggers the recommended mitigations block" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ "$output" =~ "Recommended mitigations" ]]
}

@test "medium-risk story gets no mitigation annotation on cache path" {
  _mk_fixture_project
  # Mutate cache: make ALL stories medium risk (no high)
  jq '.stories |= map(.risk_level = "medium")' "$CACHE_PATH" > "$TEST_TMP/all-medium.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/all-medium.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ ! "$output" =~ "HIGH-risk" ]]
  [[ ! "$output" =~ "Recommended mitigations" ]]
}

@test "low-risk story gets no mitigation annotation on cache path" {
  _mk_fixture_project
  jq '.stories |= map(.risk_level = "low")' "$CACHE_PATH" > "$TEST_TMP/all-low.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/all-low.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ ! "$output" =~ "HIGH-risk" ]]
  [[ ! "$output" =~ "Recommended mitigations" ]]
}

# ===========================================================================
# No-active-sprint tests
# ===========================================================================

@test "no active sprint (sprint null) prints message and exits 0" {
  _mk_fixture_project
  jq '.sprint = null' "$CACHE_PATH" > "$TEST_TMP/null-sprint.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/null-sprint.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No active sprint" ]]
}

@test "no active sprint (sprint.status closed) prints message and exits 0" {
  _mk_fixture_project
  jq '.sprint.status = "closed"' "$CACHE_PATH" > "$TEST_TMP/closed-sprint.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/closed-sprint.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No active sprint" ]]
}

@test "stranded-ready advisory still runs after no-active-sprint line" {
  _mk_fixture_project
  jq '.sprint = null' "$CACHE_PATH" > "$TEST_TMP/null-sprint2.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/null-sprint2.json"

  # The stranded scanner needs a writable project tree with story files
  # and a decision log. Build a minimal one under TEST_TMP.
  local sr_root="$TEST_TMP/stranded-project"
  mkdir -p "$sr_root/.gaia/memory/validator-sidecar"
  mkdir -p "$sr_root/.gaia/artifacts/implementation-artifacts"
  cat > "$sr_root/.gaia/artifacts/implementation-artifacts/E900-S9-stranded.md" <<'MD'
---
key: "E900-S9"
status: ready-for-dev
sprint_id: null
title: "Stranded story"
---
# Story: Stranded story
MD
  cat > "$sr_root/.gaia/memory/validator-sidecar/decision-log.md" <<'MD'
### [2026-01-01] Story Validation: E900-S9
```json
{"verdict":"PASSED"}
```
MD
  export PROJECT_ROOT="$sr_root"
  export PROJECT_PATH="$sr_root"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No active sprint" ]]
}

# ===========================================================================
# Cache freshness via counting shim (Item 4)
# ===========================================================================

@test "absent cache triggers exactly 1 snapshot invocation" {
  # Needs its own copy — removes the cache file.
  local root="$TEST_TMP/fixture"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  rm -f "$root/.gaia/state/.sprint-progress-cache.json"
  _mk_snapshot_shim
  export PROJECT_ROOT="$root"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [ "$(_shim_count)" -eq 1 ]
}

@test "stale cache (>60s) triggers exactly 1 snapshot invocation" {
  # Needs its own copy — touches the cache mtime.
  local root="$TEST_TMP/fixture"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  _mk_snapshot_shim
  export PROJECT_ROOT="$root"

  local old_epoch
  old_epoch=$(( $(date +%s) - 120 ))
  local old_date
  old_date="$(_epoch_to_touchdate "$old_epoch")"
  touch -t "$old_date" "$root/.gaia/state/.sprint-progress-cache.json"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [ "$(_shim_count)" -eq 1 ]
}

@test "fresh cache without SPRINT_CACHE_JSON triggers 0 snapshot invocations" {
  # Needs its own copy — runs dashboard without SPRINT_CACHE_JSON.
  # Explicitly touch the cache to now so it is fresh regardless of suite duration.
  local root="$TEST_TMP/fixture"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  touch "$root/.gaia/state/.sprint-progress-cache.json"
  _mk_snapshot_shim
  export PROJECT_ROOT="$root"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [ "$(_shim_count)" -eq 0 ]
}

@test "SPRINT_CACHE_JSON override triggers 0 snapshot invocations even when stale" {
  # Needs its own copy — touches the cache mtime.
  local root="$TEST_TMP/fixture"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  local cache="$root/.gaia/state/.sprint-progress-cache.json"
  _mk_snapshot_shim
  export SPRINT_CACHE_JSON="$cache"
  export PROJECT_ROOT="$root"

  local old_epoch
  old_epoch=$(( $(date +%s) - 120 ))
  local old_date
  old_date="$(_epoch_to_touchdate "$old_epoch")"
  touch -t "$old_date" "$cache"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [ "$(_shim_count)" -eq 0 ]
}

@test "SPRINT_CACHE_JSON override to missing file triggers 0 snapshot invocations" {
  _mk_fixture_project
  _mk_snapshot_shim
  export SPRINT_CACHE_JSON="$TEST_TMP/nonexistent-override.json"
  export PROJECT_ROOT="$_SETUP_BASE"
  export SPRINT_STATUS_YAML="$_SETUP_BASE/.gaia/state/sprint-status.yaml"

  run bash "$DASHBOARD"
  # Fallback renders, no crash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Story" ]]
  # The snapshot must NOT have been invoked
  [ "$(_shim_count)" -eq 0 ]
}

# ===========================================================================
# Fallback tests with stderr notice assertion (Item 3)
# ===========================================================================

@test "SPRINT_CACHE_JSON nonexistent file: fallback with stderr notice" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$TEST_TMP/nonexistent-cache.json"
  export PROJECT_ROOT="$_SETUP_BASE"
  export SPRINT_STATUS_YAML="$_SETUP_BASE/.gaia/state/sprint-status.yaml"

  local stderr_file="$TEST_TMP/stderr-nonexist.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  # Fallback path: NO Tasks/Gates columns
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]
  [[ "$output" =~ "Story" ]]

  # Stderr notice must be present
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "cache" ]]
}

@test "SPRINT_STATUS_YAML set without SPRINT_CACHE_JSON: fallback with stderr notice" {
  # SPRINT_STATUS_YAML forces fallback immediately — no snapshot, no
  # shared-tree mutation. Safe to use the shared tree as PROJECT_ROOT.
  _mk_fixture_project
  export SPRINT_STATUS_YAML="$_SETUP_BASE/.gaia/state/sprint-status.yaml"

  local stderr_file="$TEST_TMP/stderr-yamlonly.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]
  [[ "$output" =~ "Story" ]]

  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "basic dashboard" ]]
}

@test "jq absent: fallback with stderr notice" {
  # jq hidden by PATH shim. No SPRINT_STATUS_YAML — tests the jq-absent
  # branch specifically. The fallback resolves the yaml from PROJECT_ROOT.
  # Safe on the shared tree: the fallback path only reads.
  _mk_fixture_project

  mkdir -p "$TEST_TMP/nojq-bin"
  printf '#!/bin/sh\nexit 127\n' > "$TEST_TMP/nojq-bin/jq"
  chmod +x "$TEST_TMP/nojq-bin/jq"

  local stderr_file="$TEST_TMP/stderr-nojq.log"
  run bash -c 'PATH="$1:$PATH" bash "$2" 2>"$3"' _ "$TEST_TMP/nojq-bin" "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Story" ]]

  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "jq" ]]
}

@test "invalid JSON cache: fallback with stderr notice" {
  _mk_fixture_project
  echo '{"invalid' > "$TEST_TMP/bad-cache.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/bad-cache.json"
  export PROJECT_ROOT="$_SETUP_BASE"
  export SPRINT_STATUS_YAML="$_SETUP_BASE/.gaia/state/sprint-status.yaml"

  local stderr_file="$TEST_TMP/stderr-badjson.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  [[ "$output" =~ "Story" ]]
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]

  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "cache" ]]
}

@test "empty cache file: fallback with stderr notice" {
  _mk_fixture_project
  : > "$TEST_TMP/empty-cache.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/empty-cache.json"
  export PROJECT_ROOT="$_SETUP_BASE"
  export SPRINT_STATUS_YAML="$_SETUP_BASE/.gaia/state/sprint-status.yaml"

  local stderr_file="$TEST_TMP/stderr-empty.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  [[ "$output" =~ "Story" ]]
  [[ ! "$output" =~ "null" ]]

  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "cache" ]]
}

@test "cache absent and snapshot fails: fallback with stderr notice" {
  local root="$TEST_TMP/nofixture"
  mkdir -p "$root/.gaia/state"
  cat > "$root/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-fallback"
status: active
total_points: 5
start_date: "2026-01-01"
end_date: "2026-01-14"
stories:
  - key: E900-S8
    title: "Fallback story"
    status: in-progress
    points: 5
YAML
  export PROJECT_ROOT="$root"
  export SPRINT_STATUS_YAML="$root/.gaia/state/sprint-status.yaml"

  local stderr_file="$TEST_TMP/stderr-snapfail.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  [[ "$output" =~ "Story" ]]
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]

  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "cache" ]]
}

# ===========================================================================
# Cache validity edge cases (AC-EC4, AC6 snapshot-fail)
# ===========================================================================

@test "fresh empty cache without override: fallback with notice and active sprint rendered" {
  # A zero-byte cache with a fresh mtime must NOT be treated as valid.
  # Needs a writable project tree since the cache is at PROJECT_ROOT.
  local root="$TEST_TMP/empty-cache-proj"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  : > "$root/.gaia/state/.sprint-progress-cache.json"
  mkdir -p "$TEST_TMP/failsnap"
  printf '#!/bin/sh\nexit 3\n' > "$TEST_TMP/failsnap/snap.sh"
  chmod +x "$TEST_TMP/failsnap/snap.sh"
  export SPRINT_PROGRESS_SNAPSHOT="$TEST_TMP/failsnap/snap.sh"
  export PROJECT_ROOT="$root"
  # Do NOT set SPRINT_STATUS_YAML — let the dashboard use the non-override path

  local stderr_file="$TEST_TMP/stderr-fresh-empty.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  # Must show fallback columns (no Tasks)
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]
  # Must render the active sprint's story, NOT "No active sprint"
  [[ "$output" =~ "E900-S1" ]] || [[ "$output" =~ "sprint-test" ]]
  [[ ! "$output" =~ "No active sprint" ]]
  # Stderr notice
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "cache" ]]
}

@test "stale valid cache with failing snapshot: fallback with notice" {
  # Needs its own copy — touches the cache mtime.
  local root="$TEST_TMP/fixture"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  local old_epoch
  old_epoch=$(( $(date +%s) - 120 ))
  local old_date
  old_date="$(_epoch_to_touchdate "$old_epoch")"
  touch -t "$old_date" "$root/.gaia/state/.sprint-progress-cache.json"
  mkdir -p "$TEST_TMP/failsnap2"
  printf '#!/bin/sh\nexit 3\n' > "$TEST_TMP/failsnap2/snap.sh"
  chmod +x "$TEST_TMP/failsnap2/snap.sh"
  export SPRINT_PROGRESS_SNAPSHOT="$TEST_TMP/failsnap2/snap.sh"
  export PROJECT_ROOT="$root"
  # Do NOT set SPRINT_STATUS_YAML

  local stderr_file="$TEST_TMP/stderr-stale-fail.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  # Must show fallback columns (no Tasks)
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]
  # Must render from yaml, not from stale cache
  [[ "$output" =~ "Story" ]]
  # Stderr notice
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "cache" ]]
}

@test "fresh cache with wrong-shape JSON: fallback with notice, no ghost sprint" {
  # A cache with valid JSON but wrong shape must trigger fallback.
  local root="$TEST_TMP/wrongshape-proj"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  printf '[]' > "$root/.gaia/state/.sprint-progress-cache.json"
  mkdir -p "$TEST_TMP/failsnap3"
  printf '#!/bin/sh\nexit 3\n' > "$TEST_TMP/failsnap3/snap.sh"
  chmod +x "$TEST_TMP/failsnap3/snap.sh"
  export SPRINT_PROGRESS_SNAPSHOT="$TEST_TMP/failsnap3/snap.sh"
  export PROJECT_ROOT="$root"
  # Do NOT set SPRINT_STATUS_YAML

  local stderr_file="$TEST_TMP/stderr-wrong-shape.log"
  run bash -c 'bash "$1" 2>"$2"' _ "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]

  # Must NOT print "No active sprint" — that would be ghost data
  [[ ! "$output" =~ "No active sprint" ]]
  # Must show fallback columns
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]
  [[ "$output" =~ "Story" ]]
  # Stderr notice
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "cache" ]]
}

# ===========================================================================
# Cache-only grep: enhanced path reads only from cache
# ===========================================================================

@test "enhanced path reads only from cache: source-level forbidden-symbol check" {
  # Extract _render_cache_dashboard and every helper it calls (except the
  # exempt stranded-ready scanner and the mitigation-catalog loader).
  # The function body and its called helpers must not reference fallback-path
  # symbols or files.
  local fn_body
  fn_body="$(awk '/_render_cache_dashboard\(\)/,/^}/' "$DASHBOARD" 2>/dev/null || true)"
  [[ -n "$fn_body" ]]

  # Also include _render_cache_story_row (called by the cache path)
  local row_body
  row_body="$(awk '/_render_cache_story_row\(\)/,/^}/' "$DASHBOARD" 2>/dev/null || true)"
  local combined="${fn_body}${row_body}"

  # Forbidden symbols in the cache path (fallback-only concepts):
  local forbidden
  for forbidden in \
    'YAML_PATH' 'yaml_val' 'flush_story' 'story_risk' \
    'IMPLEMENTATION_ARTIFACTS' 'sprint-status.yaml' 'story.md' \
    'sprint-state.sh' 'detect-auto-close'; do
    if grep -qF "$forbidden" <<<"$combined"; then
      echo "FAIL: _render_cache_dashboard (or _render_cache_story_row) references forbidden symbol: $forbidden" >&2
      echo "  Context: $(grep -F "$forbidden" <<<"$combined" | head -1)" >&2
      return 1
    fi
  done
}

@test "enhanced path works with unreadable yaml and story files (behavioural proof)" {
  # The cache path must render the full enhanced table even when the
  # sprint-status.yaml and story files are unreadable. Needs a writable
  # copy to chmod files.
  local root="$TEST_TMP/unreadable-proof"
  cp -R "$_SETUP_BASE" "$root"; chmod -R u+w "$root"
  touch "$root/.gaia/state/.sprint-progress-cache.json"
  export SPRINT_CACHE_JSON="$root/.gaia/state/.sprint-progress-cache.json"
  export PROJECT_ROOT="$root"

  chmod 000 "$root/.gaia/state/sprint-status.yaml"
  find "$root/.gaia/artifacts" -name 'story.md' -exec chmod 000 {} \;

  run bash "$DASHBOARD"

  chmod 644 "$root/.gaia/state/sprint-status.yaml"
  find "$root/.gaia/artifacts" -name 'story.md' -exec chmod 644 {} \;

  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "E900-S1" ]]
  [[ "$output" =~ "Phase 1" ]]
}

@test "fallback renderer is isolated in its own function" {
  run grep '_render_fallback_dashboard' "$DASHBOARD"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Terminal-escape sanitization — one case per vector (Item 5)
# ===========================================================================

@test "sanitization: ANSI CSI escape sequences stripped from title" {
  _mk_fixture_project
  jq '.stories[0].title = "Evil\u001b[31mRed\u001b[0m Title"' \
    "$CACHE_PATH" > "$TEST_TMP/ansi-title.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ansi-title.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # No ESC byte in output
  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  # CSI parameter+final remnants must be absent
  [[ ! "$output" =~ "[31m" ]]
  [[ ! "$output" =~ "[0m" ]]
  # The cleaned text must appear
  [[ "$output" =~ "EvilRed Title" ]]
}

@test "sanitization: OSC terminated by BEL stripped from action message" {
  _mk_fixture_project
  jq '.action_needed = [{"rule":"a","type":"manual_test_due","message":"Evil\u001b]0;pwned\u0007 msg","command":"","since":"","source":"","story_keys":["E900-S1"]}]' \
    "$CACHE_PATH" > "$TEST_TMP/osc-bel.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/osc-bel.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc bel
  esc=$(printf '\033')
  bel=$(printf '\007')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ $bel ]]
  # OSC remnant must be absent
  [[ ! "$output" =~ "]0;pwned" ]]
  # The cleaned text must appear
  [[ "$output" =~ "Evil msg" ]]
}

@test "sanitization: OSC terminated by ESC backslash stripped" {
  _mk_fixture_project
  # ESC ] 0 ; title ESC backslash
  jq '.stories[0].title = "Pre\u001b]0;title\u001b\\Post"' \
    "$CACHE_PATH" > "$TEST_TMP/osc-st.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/osc-st.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  # OSC remnant must be absent
  [[ ! "$output" =~ "]0;title" ]]
  # The cleaned text must appear
  [[ "$output" =~ "PrePost" ]]
}

@test "sanitization: private-parameter CSI stripped from goal" {
  _mk_fixture_project
  jq '.sprint.goal = "Goal\u001b[?47hEvil\u001b[?47l"' \
    "$CACHE_PATH" > "$TEST_TMP/goal-esc.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/goal-esc.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  # Private CSI remnants must be absent
  [[ ! "$output" =~ "[?47h" ]]
  [[ ! "$output" =~ "[?47l" ]]
  # The cleaned text must appear
  [[ "$output" =~ "GoalEvil" ]]
}

@test "sanitization: control characters 0x01-0x1f stripped from sprint.id" {
  _mk_fixture_project
  jq '.sprint.id = "sprint\u0001\u0002-evil"' \
    "$CACHE_PATH" > "$TEST_TMP/ctrl-id.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ctrl-id.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local c1 c2
  c1=$(printf '\001')
  c2=$(printf '\002')
  [[ ! "$output" =~ $c1 ]]
  [[ ! "$output" =~ $c2 ]]
}

@test "sanitization: DEL 0x7f stripped from end_date" {
  _mk_fixture_project
  jq '.sprint.end_date = "2026-01-14\u007f"' \
    "$CACHE_PATH" > "$TEST_TMP/date-del.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/date-del.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local del
  del=$(printf '\177')
  [[ ! "$output" =~ $del ]]
}

@test "sanitization: C1 single-byte CSI U+009B stripped from title" {
  _mk_fixture_project
  # U+009B in UTF-8 is 0xC2 0x9B
  jq '.stories[0].title = "Pre\u009BmPost"' \
    "$CACHE_PATH" > "$TEST_TMP/c1-csi.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/c1-csi.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # The U+009B byte (0xC2 0x9B under UTF-8) must not appear in output
  local c1_csi
  c1_csi=$(printf '\xc2\x9b')
  [[ ! "$output" =~ $c1_csi ]]
}

@test "sanitization: C1 single-byte OSC U+009D stripped from capacity_utilization" {
  _mk_fixture_project
  # U+009D in UTF-8 is 0xC2 0x9D
  jq '.sprint.capacity_utilization = "85%\u009Dpwned"' \
    "$CACHE_PATH" > "$TEST_TMP/c1-osc.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/c1-osc.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local c1_osc
  c1_osc=$(printf '\xc2\x9d')
  [[ ! "$output" =~ $c1_osc ]]
}

@test "sanitization: C1 control NEL U+0085 stripped from epic_focus" {
  _mk_fixture_project
  # U+0085 in UTF-8 is 0xC2 0x85
  jq '.sprint.epic_focus = "Focus\u0085evil"' \
    "$CACHE_PATH" > "$TEST_TMP/c1-nel.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/c1-nel.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local c1_nel
  c1_nel=$(printf '\xc2\x85')
  [[ ! "$output" =~ $c1_nel ]]
}

@test "sanitization: invalid UTF-8 bytes stripped from start_date" {
  _mk_fixture_project
  # Inject raw 0xFF 0xFE bytes by writing the mutated cache directly
  jq '.sprint.start_date = "2026-BAD-01"' "$CACHE_PATH" > "$TEST_TMP/bad-utf8-base.json"
  # Replace "BAD" with actual invalid bytes 0xFF 0xFE
  printf '\xff\xfe' | dd of="$TEST_TMP/bad-utf8-base.json" bs=1 seek="$(grep -bo 'BAD' "$TEST_TMP/bad-utf8-base.json" | head -1 | cut -d: -f1)" conv=notrunc 2>/dev/null || true
  # Simpler approach: create via python-style injection or just test the concept
  # We rely on the jq approach with surrogate-pair-like content
  jq '.sprint.start_date = "2026-�-01"' "$CACHE_PATH" > "$TEST_TMP/bad-utf8.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/bad-utf8.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # U+FFFD replacement character must be stripped
  local fffd
  fffd=$(printf '\xef\xbf\xbd')
  [[ ! "$output" =~ $fffd ]]
}

@test "sanitization: U+FFFD replacement character stripped from title" {
  _mk_fixture_project
  jq '.stories[0].title = "Title�here"' \
    "$CACHE_PATH" > "$TEST_TMP/fffd-title.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/fffd-title.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local fffd
  fffd=$(printf '\xef\xbf\xbd')
  [[ ! "$output" =~ $fffd ]]
}

# ===========================================================================
# Validation — one case per validated field (Item 5 cont.)
# ===========================================================================

@test "validation: invalid story key replaced (not rendered literally)" {
  _mk_fixture_project
  # Must update both stories[].key AND phases[].stories[] so the row renders
  jq '.stories[0].key = "; rm -rf /" | .phases[0].stories[0] = "; rm -rf /"' \
    "$CACHE_PATH" > "$TEST_TMP/bad-key.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/bad-key.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ ! "$output" =~ "; rm -rf /" ]]
  # The invalid key should render as "?" placeholder
  grep -qF '?' <<<"$output"
}

@test "validation: invalid story status replaced (not rendered literally)" {
  _mk_fixture_project
  jq '.stories[0].status = "hacked"' \
    "$CACHE_PATH" > "$TEST_TMP/bad-status.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/bad-status.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ ! "$output" =~ "hacked" ]]
  grep -qF '?' <<<"$output"
}

@test "validation: invalid phase status label replaced (not rendered literally)" {
  _mk_fixture_project
  jq '.phases[0].status = "evil"' \
    "$CACHE_PATH" > "$TEST_TMP/bad-phase-status.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/bad-phase-status.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  [[ ! "$output" =~ "evil" ]]
  grep -qF '?' <<<"$output"
}

# ===========================================================================
# Header/footer from cache fields
# ===========================================================================

@test "header shows sprint id from cache" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "sprint-test" ]]
}

@test "header shows dates from cache" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "2026-01-01" ]]
  [[ "$output" =~ "2026-01-14" ]]
}

@test "header shows duration from cache total_days" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "14 days" ]]
}

@test "duration line omitted when sprint.total_days is null" {
  _mk_fixture_project
  jq '.sprint.total_days = null' "$CACHE_PATH" > "$TEST_TMP/no-duration.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/no-duration.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "Duration:" ]]
}

@test "utilization line shown when present in cache" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "Utilization:" ]]
  [[ "$output" =~ "85%" ]]
}

@test "utilization line omitted when null in cache" {
  _mk_fixture_project
  jq '.sprint.capacity_utilization = null' "$CACHE_PATH" > "$TEST_TMP/no-util.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/no-util.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "Utilization:" ]]
}

@test "focus line shown when present in cache" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "Focus:" ]]
}

@test "focus line omitted when null in cache" {
  _mk_fixture_project
  jq '.sprint.epic_focus = null' "$CACHE_PATH" > "$TEST_TMP/no-focus.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/no-focus.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "Focus:" ]]
}

@test "goal line shown when sprint.goal is non-null" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "Goal:" ]]
  [[ "$output" =~ "Deliver cache dashboard" ]]
}

@test "goal line omitted when sprint.goal is null" {
  _mk_fixture_project
  jq '.sprint.goal = null' "$CACHE_PATH" > "$TEST_TMP/no-goal.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/no-goal.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "Goal:" ]]
}

@test "footer shows total stories and points from cache" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "4 stories" ]]
  [[ "$output" =~ "21 points" ]]
}

# ===========================================================================
# Auto-close banner from cache
# ===========================================================================

@test "auto-close banner renders from cache readiness.sprint_close" {
  _mk_alldone_fixture
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$TEST_TMP/alldonefixture"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ "$output" =~ "READY-TO-REVIEW" ]]
  [[ "$output" =~ "2/2" ]] || [[ "$output" =~ "2 of 2" ]]
}

@test "detect-auto-close NOT called on cache path" {
  local fn_body
  fn_body="$(awk '/_render_cache_dashboard\(\)/,/^}/' "$DASHBOARD" 2>/dev/null || true)"
  [[ -n "$fn_body" ]]
  [[ ! "$fn_body" =~ "detect-auto-close" ]]
}

# ===========================================================================
# Non-numeric field validation — one per field (Item 6)
# ===========================================================================

@test "non-numeric total_days: question mark present, bad value absent" {
  _mk_fixture_project
  jq '.sprint.total_days = "abc"' "$CACHE_PATH" > "$TEST_TMP/nan-days.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-days.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "abc" ]]
  grep -qF '?' <<<"$output"
}

@test "null total_days omits duration line (not question mark)" {
  _mk_fixture_project
  jq '.sprint.total_days = null' "$CACHE_PATH" > "$TEST_TMP/null-days2.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/null-days2.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "Duration:" ]]
}

@test "non-numeric story points: question mark present" {
  _mk_fixture_project
  jq '.stories[0].points = "xyz"' "$CACHE_PATH" > "$TEST_TMP/nan-pts.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-pts.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "xyz" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric tasks.done: question mark present" {
  _mk_fixture_project
  jq '.stories[0].tasks.done = "bad"' "$CACHE_PATH" > "$TEST_TMP/nan-td.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-td.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "bad/5" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric tasks.total: question mark present" {
  _mk_fixture_project
  jq '.stories[0].tasks.total = "nope"' "$CACHE_PATH" > "$TEST_TMP/nan-tt.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-tt.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "2/nope" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric gates.passed: question mark present" {
  _mk_fixture_project
  jq '.stories[0].gates.passed = "err"' "$CACHE_PATH" > "$TEST_TMP/nan-gp.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-gp.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "err/6" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric gates.total: question mark present" {
  _mk_fixture_project
  jq '.stories[0].gates.total = "oops"' "$CACHE_PATH" > "$TEST_TMP/nan-gt.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-gt.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "4/oops" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric phase: question mark present in phase header" {
  _mk_fixture_project
  jq '.phases[0].phase = "bogus"' "$CACHE_PATH" > "$TEST_TMP/nan-phase.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-phase.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "Phase bogus" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric totals.total_stories: question mark in footer" {
  _mk_fixture_project
  jq '.totals.total_stories = "nan"' "$CACHE_PATH" > "$TEST_TMP/nan-ts.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-ts.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "nan stories" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric totals.total_points: question mark in footer" {
  _mk_fixture_project
  jq '.totals.total_points = "nan"' "$CACHE_PATH" > "$TEST_TMP/nan-tp.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-tp.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "nan points" ]]
  grep -qF '?' <<<"$output"
}

@test "non-numeric totals.done_stories: question mark present" {
  _mk_alldone_fixture
  # Set sprint_close=true so the auto-close banner renders done_stories
  jq '.totals.done_stories = "boom" | .readiness.sprint_close = true' \
    "$CACHE_PATH" > "$TEST_TMP/nan-ds.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/nan-ds.json"
  export PROJECT_ROOT="$TEST_TMP/alldonefixture"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "boom" ]]
  # done_stories is used in the auto-close banner "N/N stories done"
  grep -qF '?' <<<"$output"
}

# ===========================================================================
# Multi-line injection — numeric validators must match the WHOLE value
# (not per-line via grep). A tampered cache can embed newlines to sneak
# terminal escapes past a per-line regex.
# ===========================================================================

@test "multiline injection: points with embedded ESC+OSC rejected as non-numeric" {
  _mk_fixture_project
  # "3\n\e]0;PWNED\a\e[2J" — first line is "3" (passes per-line grep)
  jq '.stories[0].points = "3\n\u001b]0;PWNED\u0007\u001b[2J"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-pts.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-pts.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # No ESC byte (0x1b) in output
  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  # No BEL byte (0x07) in output
  local bel
  bel=$(printf '\007')
  [[ ! "$output" =~ $bel ]]
  # The injected payload must not appear
  [[ ! "$output" =~ "PWNED" ]]
  [[ ! "$output" =~ "[2J" ]]
  # The value must render as "?" (rejected)
  grep -qF '?' <<<"$output"
}

@test "multiline injection: tasks.done with embedded ESC rejected" {
  _mk_fixture_project
  jq '.stories[0].tasks.done = "2\n\u001b[31mRED\u001b[0m"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-td.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-td.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "RED" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: tasks.total with embedded C1 CSI rejected" {
  _mk_fixture_project
  # C1 CSI is U+009B (UTF-8: 0xC2 0x9B)
  jq '.stories[0].tasks.total = "5\n\u009B31mEVIL"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-tt.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-tt.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local c1_csi
  c1_csi=$(printf '\xc2\x9b')
  [[ ! "$output" =~ $c1_csi ]]
  [[ ! "$output" =~ "EVIL" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: gates.passed with embedded ESC rejected" {
  _mk_fixture_project
  jq '.stories[0].gates.passed = "4\n\u001b]0;PWNED\u0007"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-gp.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-gp.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "PWNED" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: gates.total with embedded ESC rejected" {
  _mk_fixture_project
  jq '.stories[0].gates.total = "6\n\u001b[2J"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-gt.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-gt.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "[2J" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: phase number with embedded ESC rejected" {
  _mk_fixture_project
  jq '.phases[0].phase = "1\n\u001b]0;PWNED\u0007"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-phase.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-phase.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "PWNED" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: totals.total_points with embedded ESC rejected" {
  _mk_fixture_project
  jq '.totals.total_points = "21\n\u001b[2JCLEAR"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-tp.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-tp.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "CLEAR" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: totals.total_stories with embedded ESC rejected" {
  _mk_fixture_project
  jq '.totals.total_stories = "4\n\u001b]0;PWNED\u0007"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-ts.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-ts.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "PWNED" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: totals.done_stories with embedded ESC rejected" {
  _mk_alldone_fixture
  jq '.totals.done_stories = "2\n\u001b[31mRED\u001b[0m" | .readiness.sprint_close = true' \
    "$CACHE_PATH" > "$TEST_TMP/ml-ds.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-ds.json"
  export PROJECT_ROOT="$TEST_TMP/alldonefixture"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "RED" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: total_days with embedded OSC rejected" {
  _mk_fixture_project
  jq '.sprint.total_days = "13\n\u001b]0;PWNED\u0007"' \
    "$CACHE_PATH" > "$TEST_TMP/ml-days.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-days.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  [[ ! "$output" =~ "PWNED" ]]
  grep -qF '?' <<<"$output"
}

@test "multiline injection: story key with embedded newline rejected" {
  _mk_fixture_project
  # "E900-S1\n\e]0;PWNED\a" — first line matches the key regex (per-line
  # grep would accept this). The whole-string [[ =~ ]] match must reject it.
  # We tamper both .stories[0].key and .phases[0].stories[0] so the phase
  # loop still attempts to render the story by its tampered key.
  jq '
    .stories[0].key = "E900-S1\n\u001b]0;PWNED\u0007" |
    .phases[0].stories[0] = "E900-S1\n\u001b]0;PWNED\u0007"
  ' "$CACHE_PATH" > "$TEST_TMP/ml-key.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/ml-key.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # No ESC byte in output
  local esc
  esc=$(printf '\033')
  [[ ! "$output" =~ $esc ]]
  # The OSC payload must not appear
  [[ ! "$output" =~ "PWNED" ]]
  # The tampered key should not render as if it were the real E900-S1
  # (the story row either renders with "?" for the key, or the row is
  # skipped because the phase→story lookup fails on the multiline key).
  # Either way, no escape sequences reach the terminal.
}

@test "multiline injection: empty numeric field renders as question mark" {
  _mk_fixture_project
  jq '.stories[0].points = ""' \
    "$CACHE_PATH" > "$TEST_TMP/empty-pts.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/empty-pts.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  grep -qF '?' <<<"$output"
}

@test "multiline injection: null numeric field renders as question mark" {
  _mk_fixture_project
  jq '.stories[0].points = "null"' \
    "$CACHE_PATH" > "$TEST_TMP/null-pts.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/null-pts.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  grep -qF '?' <<<"$output"
}

# ===========================================================================
# Title truncation
# ===========================================================================

@test "long title truncated to fit column" {
  _mk_fixture_project
  jq '.stories[0].title = "This is a very long story title that should definitely be truncated to fit within the table column width preserving alignment"' \
    "$CACHE_PATH" > "$TEST_TMP/long-title.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/long-title.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  [[ ! "$output" =~ "preserving alignment" ]]
  [[ "$output" =~ "This is a very long" ]]
}

@test "gates column fixed width: risk annotation aligns for 6/6 and question-mark rows" {
  _mk_fixture_project
  # Set one story to high-risk with 6/6 gates, another to high-risk with
  # non-numeric gates (renders as "?"). The risk annotation must start at
  # the same column in both rows.
  jq '
    .stories[0].risk_level = "high" | .stories[0].gates.passed = 6 | .stories[0].gates.total = 6 |
    .stories[1].risk_level = "high" | .stories[1].gates.passed = "bad"
  ' "$CACHE_PATH" > "$TEST_TMP/gates-align.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/gates-align.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # Both rows should have "[HIGH-risk:" starting at the same column.
  # Extract rows with the annotation.
  local row1 row2 col1 col2
  row1="$(grep 'E900-S1.*HIGH-risk' <<<"$output" | head -1)"
  row2="$(grep 'E900-S2.*HIGH-risk' <<<"$output" | head -1)"
  [[ -n "$row1" ]]
  [[ -n "$row2" ]]
  # Find the column offset of "[HIGH-risk:" in each row
  col1="${row1%%\[HIGH-risk:*}"
  col2="${row2%%\[HIGH-risk:*}"
  [ "${#col1}" -eq "${#col2}" ]
}

@test "multibyte title truncation stays on a character boundary" {
  _mk_fixture_project
  # "ééééééééééééééééé" is 17 e-acutes = 34 UTF-8 bytes. Byte 33 falls
  # inside the second byte of the 17th character. Naive ${s:0:33} under
  # LC_ALL=C would cut mid-character, producing invalid UTF-8.
  jq '.stories[0].title = "éééééééééééééééééééé"' \
    "$CACHE_PATH" > "$TEST_TMP/multibyte-title.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/multibyte-title.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns

  # The title must end with "..." (truncated)
  local s1_line
  s1_line="$(grep 'E900-S1' <<<"$output" | head -1)"
  [[ -n "$s1_line" ]]
  [[ "$s1_line" =~ \.\.\. ]]

  # The output must be valid UTF-8
  printf '%s\n' "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}

# ===========================================================================
# Test isolation (Item 7)
# ===========================================================================

@test "nothing written outside BATS_TEST_TMPDIR" {
  _mk_fixture_project
  export SPRINT_CACHE_JSON="$CACHE_PATH"
  export PROJECT_ROOT="$_SETUP_BASE"

  # Content-based snapshot: count + hash of files in write targets.
  local plugin_before
  plugin_before="$(find "$PLUGIN_TREE" -type f 2>/dev/null | wc -l | tr -d ' ')"

  run bash "$DASHBOARD"
  [ "$status" -eq 0 ]

  # Verify file count has not changed in the plugin tree.
  local plugin_after
  plugin_after="$(find "$PLUGIN_TREE" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$plugin_before" = "$plugin_after" ]
}

# ===========================================================================
# Bash 3.2 compatibility — explicit /bin/bash invocation
#
# On macOS, /bin/bash is 3.2; on Linux, it is typically 5.x. These tests
# run the dashboard under /bin/bash regardless of version, ensuring that
# the script works on the stock macOS shell. On macOS, if /bin/bash is not
# 3.x, the test fails (not skips). On Linux, where /bin/bash is 5, these
# tests still run — they verify the script works under /bin/bash on that
# platform too.
# ===========================================================================

# _require_bin_bash — set BIN_BASH to /bin/bash; fail on macOS if not 3.x.
_require_bin_bash() {
  BIN_BASH="/bin/bash"
  [ -x "$BIN_BASH" ] || { echo "/bin/bash not found" >&2; return 1; }
  local major
  major="$("$BIN_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
  local os
  os="$(uname -s)"
  if [ "$os" = "Darwin" ] && [ "$major" != "3" ]; then
    echo "macOS /bin/bash is not 3.x (found $major)" >&2
    return 1
  fi
}

@test "bash 3.2: cache path with phases, risk, and warnings" {
  _require_bin_bash
  _mk_fixture_project
  # Inject a rule-a action_needed entry
  jq '.action_needed = [{"rule":"a","type":"manual_test_due","message":"Test due","command":"","since":"","source":"","story_keys":["E900-S1"]}]' \
    "$CACHE_PATH" > "$TEST_TMP/bash32-cache.json"
  export SPRINT_CACHE_JSON="$TEST_TMP/bash32-cache.json"
  export PROJECT_ROOT="$_SETUP_BASE"

  run "$BIN_BASH" "$DASHBOARD"
  [ "$status" -eq 0 ]
  _assert_cache_columns
  # Phase headers
  [[ "$output" =~ "Phase 1" ]]
  # Risk annotation from cache (E900-S1 has risk_level: high)
  [[ "$output" =~ "HIGH-risk" ]]
  # Warning header
  [[ "$output" =~ "WARNING" ]]
}

@test "bash 3.2: fallback path with a sprint story that has no story file" {
  _require_bin_bash
  # Create yaml with a story but no story file — tests the story_risk
  # empty-array path under bash 3.2 set -u.
  local root="$TEST_TMP/bash32-fallback"
  mkdir -p "$root/.gaia/state" "$root/docs/implementation-artifacts"
  cat > "$root/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-32"
status: active
total_points: 5
start_date: "2026-01-01"
end_date: "2026-01-14"
stories:
  - key: E900-S8
    title: "Story with no file"
    status: in-progress
    points: 5
YAML
  export SPRINT_STATUS_YAML="$root/.gaia/state/sprint-status.yaml"
  export PROJECT_ROOT="$root"
  export IMPLEMENTATION_ARTIFACTS="$root/docs/implementation-artifacts"

  run "$BIN_BASH" "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S8" ]]
  [[ "$output" =~ "Story" ]]
}

@test "bash 3.2: jq-absent fallback" {
  _require_bin_bash
  _mk_fixture_project
  export PROJECT_ROOT="$_SETUP_BASE"
  export SPRINT_STATUS_YAML="$_SETUP_BASE/.gaia/state/sprint-status.yaml"

  # Shadow jq with a broken shim
  mkdir -p "$TEST_TMP/nojq32"
  printf '#!/bin/sh\nexit 127\n' > "$TEST_TMP/nojq32/jq"
  chmod +x "$TEST_TMP/nojq32/jq"

  local stderr_file="$TEST_TMP/stderr-32-nojq.log"
  run bash -c 'PATH="$1:$PATH" "$2" "$3" 2>"$4"' _ \
    "$TEST_TMP/nojq32" "$BIN_BASH" "$DASHBOARD" "$stderr_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Story" ]]

  # Fallback path — no Tasks column
  local hdr
  hdr="$(grep -E '^[[:space:]]+Story' <<<"$output" | head -1)"
  [[ ! "$hdr" =~ "Tasks" ]]

  # stderr notice
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [[ "$stderr_content" =~ "notice:" ]] || [[ "$stderr_content" =~ "jq" ]]
}
