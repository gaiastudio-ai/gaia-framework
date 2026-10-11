#!/usr/bin/env bats
# e38-s1-reconcile-risk-units.bats
#
# Supplementary public-function unit tests for the 6 functions added by
# E38-S1 (sprint-status reconciliation + risk surfacing). These tests
# satisfy the NFR-052 public-function coverage gate by directly exercising
# each function that the authoritative ATDD fixture
# (e38-s1-reconcile-risk.bats) covers behaviourally but does not name
# textually as a direct call.
#
# Functions under test:
#   sprint-state.sh:
#     - cmd_reconcile
#     - do_reconcile_locked
#     - reconcile_list_yaml_stories
#     - reconcile_locate_story_file
#     - reconcile_read_story_status
#   sprint-status-dashboard.sh:
#     - story_risk
#
# Pattern: source the script as a library (extract function definitions
# via awk) then call each function directly — same approach as
# e36-s2-retro-sidecar-write-units.bats.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

SPRINT_STATE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-state.sh"
DASHBOARD_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-status-dashboard.sh"

# ---------------------------------------------------------------------------
# Helper: extract function definitions from sprint-state.sh into the current
# shell. We pull out the reconcile-family functions plus their dependencies
# (resolve_paths, die, helpers used internally).
# ---------------------------------------------------------------------------
_load_sprint_state_helpers() {
  local tmp
  tmp="$(mktemp -t sprint-state-helpers.XXXXXX)"
  awk '
    /^die\(\) \{/,/^\}/ { print; next }
    /^is_canonical_state\(\) \{/,/^\}/ { print; next }
    /^resolve_paths\(\) \{/,/^\}/ { print; next }
    /^_is_story_file\(\) \{/,/^\}/ { print; next }
    /^read_story_status\(\) \{/,/^\}/ { print; next }
    /^reconcile_locate_story_file\(\) \{/,/^\}/ { print; next }
    /^reconcile_read_story_status\(\) \{/,/^\}/ { print; next }
    /^reconcile_list_yaml_stories\(\) \{/,/^\}/ { print; next }
    /^write_sprint_status_yaml\(\) \{/,/^\}/ { print; next }
    /^rewrite_sprint_status_yaml\(\) \{/,/^\}/ { print; next }
    /^read_sprint_status_yaml_status\(\) \{/,/^\}/ { print; next }
    /^do_reconcile_locked\(\) \{/,/^\}/ { print; next }
    /^cmd_reconcile\(\) \{/,/^\}/ { print; next }
  ' "$SPRINT_STATE_SH" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Helper: extract story_risk from sprint-status-dashboard.sh.
# ---------------------------------------------------------------------------
_load_dashboard_helpers() {
  local tmp
  tmp="$(mktemp -t dashboard-helpers.XXXXXX)"
  awk '
    /^story_risk\(\) \{/,/^\}/ { print; next }
  ' "$DASHBOARD_SH" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_make_story_file() {
  local dir="$1" key="$2" status="$3"
  local file="${dir}/${key}-story.md"
  cat > "$file" <<EOF
---
template: 'story'
key: ${key}
status: ${status}
---
> **Status:** ${status}

Story body.
EOF
  printf '%s' "$file"
}

_make_yaml() {
  local file="$1"; shift
  # Accepts pairs of (key, status).
  cat > "$file" <<HEADER
sprint_id: "S99"
duration: "2 weeks"
stories:
HEADER
  while [ $# -ge 2 ]; do
    local k="$1" st="$2"; shift 2
    cat >> "$file" <<ENTRY
  - key: ${k}
    title: "Title for ${k}"
    status: "${st}"
    points: 3
ENTRY
  done
}

# ===========================================================================
# reconcile_locate_story_file
# ===========================================================================

@test "reconcile_locate_story_file returns the first matching file" {
  _load_sprint_state_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "in-progress"
  IMPLEMENTATION_ARTIFACTS="$dir"
  local got
  got="$(reconcile_locate_story_file "E1-S1")"
  [ "$got" = "$dir/E1-S1-story.md" ]
}

@test "reconcile_locate_story_file returns non-zero when no file exists" {
  _load_sprint_state_helpers
  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/empty"
  mkdir -p "$IMPLEMENTATION_ARTIFACTS"
  run reconcile_locate_story_file "NO-SUCH-KEY"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# reconcile_read_story_status
# ===========================================================================

@test "reconcile_read_story_status extracts status from frontmatter" {
  _load_sprint_state_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  local f
  f="$(_make_story_file "$dir" "E2-S1" "review")"
  local got
  got="$(reconcile_read_story_status "$f")"
  [ "$got" = "review" ]
}

@test "reconcile_read_story_status exits 2 on missing status field" {
  _load_sprint_state_helpers
  local file="$TEST_TMP/no-status.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: E3-S1
---
Body text.
EOF
  run reconcile_read_story_status "$file"
  [ "$status" -eq 2 ]
}

@test "reconcile_read_story_status exits 2 on malformed status with colons" {
  _load_sprint_state_helpers
  local file="$TEST_TMP/bad-status.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: E4-S1
status: : : malformed
---
Body text.
EOF
  run reconcile_read_story_status "$file"
  [ "$status" -eq 2 ]
}

# ===========================================================================
# reconcile_list_yaml_stories
# ===========================================================================

@test "reconcile_list_yaml_stories emits key-status pairs" {
  _load_sprint_state_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_yaml "$yaml" "E5-S1" "in-progress" "E5-S2" "done"
  local got
  got="$(reconcile_list_yaml_stories "$yaml")"
  grep -q "E5-S1" <<<"$got"
  grep -q "in-progress" <<<"$got"
  grep -q "E5-S2" <<<"$got"
  grep -q "done" <<<"$got"
}

@test "reconcile_list_yaml_stories returns 1 for unreadable file" {
  _load_sprint_state_helpers
  run reconcile_list_yaml_stories "$TEST_TMP/nonexistent.yaml"
  [ "$status" -ne 0 ]
}

@test "reconcile_list_yaml_stories emits nothing for yaml with empty stories" {
  _load_sprint_state_helpers
  local yaml="$TEST_TMP/empty-stories.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "S99"
stories: []
EOF
  local got
  got="$(reconcile_list_yaml_stories "$yaml")"
  [ -z "$got" ]
}

# ===========================================================================
# do_reconcile_locked — core algorithm (no flock wrapper)
# ===========================================================================

@test "do_reconcile_locked detects drift and corrects yaml in live mode" {
  _load_sprint_state_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E6-S1" "review"
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_yaml "$yaml" "E6-S1" "in-progress"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$yaml"
  SPRINT_STATUS_LOCK="${yaml}.lock"
  SCRIPT_NAME="sprint-state.sh"
  RECONCILE_CHECKED=0
  RECONCILE_DIVERGENCES=0
  RECONCILE_ERRORS=0

  do_reconcile_locked "0"

  [ "$RECONCILE_CHECKED" -eq 1 ]
  [ "$RECONCILE_DIVERGENCES" -eq 1 ]
  [ "$RECONCILE_ERRORS" -eq 0 ]
  # Verify the yaml was corrected to match the story file.
  grep -q '"review"' "$yaml"
}

@test "do_reconcile_locked reports no drift when yaml matches stories" {
  _load_sprint_state_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E7-S1" "done"
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_yaml "$yaml" "E7-S1" "done"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$yaml"
  SPRINT_STATUS_LOCK="${yaml}.lock"
  SCRIPT_NAME="sprint-state.sh"
  RECONCILE_CHECKED=0
  RECONCILE_DIVERGENCES=0
  RECONCILE_ERRORS=0

  do_reconcile_locked "0"

  [ "$RECONCILE_CHECKED" -eq 1 ]
  [ "$RECONCILE_DIVERGENCES" -eq 0 ]
  [ "$RECONCILE_ERRORS" -eq 0 ]
}

# ===========================================================================
# cmd_reconcile — top-level entry point exercised via CLI invocation.
# The function uses flock/spin-lock + subshell + exit codes internally, so
# we invoke the script as a subprocess (the way it runs in production) and
# assert the documented exit-code contract (ADR-055 section 10.29.1).
# ===========================================================================

@test "cmd_reconcile --dry-run exits 2 on detected drift" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E8-S1" "blocked"
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_yaml "$yaml" "E8-S1" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$SPRINT_STATE_SH" reconcile --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_reconcile exits 0 when no drift exists" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E9-S1" "in-progress"
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_yaml "$yaml" "E9-S1" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$SPRINT_STATE_SH" reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 divergences"* ]]
}

# ===========================================================================
# story_risk (sprint-status-dashboard.sh)
# ===========================================================================

@test "story_risk returns high for a story with risk: high" {
  _load_dashboard_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  cat > "$dir/E10-S1-story.md" <<'EOF'
---
template: 'story'
key: E10-S1
status: in-progress
risk: high
---
> **Status:** in-progress

Story body.
EOF
  IMPLEMENTATION_ARTIFACTS="$dir"
  local got
  got="$(story_risk "E10-S1")"
  [ "$got" = "high" ]
}

@test "story_risk returns empty string when story file has no risk field" {
  _load_dashboard_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  cat > "$dir/E11-S1-story.md" <<'EOF'
---
template: 'story'
key: E11-S1
status: done
---
> **Status:** done

No risk field here.
EOF
  IMPLEMENTATION_ARTIFACTS="$dir"
  local got
  got="$(story_risk "E11-S1")"
  [ -z "$got" ]
}

@test "story_risk returns empty string when no story file exists for key" {
  _load_dashboard_helpers
  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/empty-dir"
  mkdir -p "$IMPLEMENTATION_ARTIFACTS"
  local got
  got="$(story_risk "NONEXISTENT-KEY")"
  [ -z "$got" ]
}

@test "story_risk lowercases the risk value" {
  _load_dashboard_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  cat > "$dir/E12-S1-story.md" <<'EOF'
---
template: 'story'
key: E12-S1
status: review
risk: MEDIUM
---
> **Status:** review

Story body.
EOF
  IMPLEMENTATION_ARTIFACTS="$dir"
  local got
  got="$(story_risk "E12-S1")"
  [ "$got" = "medium" ]
}
