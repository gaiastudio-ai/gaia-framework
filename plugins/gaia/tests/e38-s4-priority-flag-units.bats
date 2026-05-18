#!/usr/bin/env bats
# e38-s4-priority-flag-units.bats
#
# Unit tests for priority-flag.sh public functions added by E38-S4
# (priority_flag auto-include). Satisfies NFR-052 public-function
# coverage gate by directly exercising each new public function.
#
# Functions under test (priority-flag.sh):
#   - pflag_read            — read priority_flag value from story frontmatter
#   - pflag_scan_backlog    — scan implementation-artifacts for backlog stories
#                             with priority_flag: "next-sprint"
#   - pflag_clear           — clear priority_flag to null in a story file
#   - pflag_record_cleared  — append cleared keys to sprint-status.yaml
#
# Contract: NO set/write-next-sprint function exists. This script only
# reads and clears — humans set the flag. Per feedback_priority_flag_never_auto_set.
#
# Pattern: source the script as a library (extract function definitions
# via awk) then call each function directly — same approach as
# e38-s3-lint-dependencies-units.bats and e35-s2-approval-gate-units.bats.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

PRIORITY_FLAG_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/priority-flag.sh"

# ---------------------------------------------------------------------------
# Helper: extract function definitions from priority-flag.sh
# ---------------------------------------------------------------------------
_load_pflag_helpers() {
  local tmp
  tmp="$(mktemp -t pflag-helpers.XXXXXX)"
  printf 'SCRIPT_NAME="priority-flag.sh"\n' > "$tmp"
  awk '
    /^_pflag_fm_field\(\) \{/,/^\}/ { print; next }
    /^pflag_read\(\) \{/,/^\}/ { print; next }
    /^_pflag_scan_by_flag\(\) \{/,/^\}/ { print; next }
    /^pflag_scan_backlog\(\) \{/,/^\}/ { print; next }
    /^pflag_scan_active_hotfix\(\) \{/,/^\}/ { print; next }
    /^pflag_clear\(\) \{/,/^\}/ { print; next }
    /^pflag_record_cleared\(\) \{/,/^\}/ { print; next }
  ' "$PRIORITY_FLAG_SH" >> "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_make_flagged_story() {
  local dir="$1" key="$2" status="$3" flag="$4"
  local file="${dir}/${key}-story.md"
  cat > "$file" <<EOF
---
template: 'story'
key: "${key}"
status: ${status}
priority_flag: ${flag}
sprint_id: null
---

# Story: ${key}

> **Status:** ${status}
EOF
  printf '%s' "$file"
}

# ===========================================================================
# pflag_read — read priority_flag value from story frontmatter
# ===========================================================================

@test "pflag_read: returns next-sprint when flag is set" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog" '"next-sprint"'
  local got
  got="$(pflag_read "$dir/E1-S1-story.md")"
  [ "$got" = "next-sprint" ]
}

@test "pflag_read: returns null when flag is null" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog" "null"
  local got
  got="$(pflag_read "$dir/E1-S1-story.md")"
  [ "$got" = "null" ]
}

@test "pflag_read: returns empty when field is missing" {
  _load_pflag_helpers
  local file="$TEST_TMP/no-flag.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: "E2-S1"
status: backlog
---
> **Status:** backlog
EOF
  local got
  got="$(pflag_read "$file")"
  [ -z "$got" ]
}

# ===========================================================================
# pflag_scan_backlog — find backlog stories with priority_flag: "next-sprint"
# ===========================================================================

@test "pflag_scan_backlog: finds two flagged backlog stories (AC1)" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog" '"next-sprint"'
  _make_flagged_story "$dir" "E1-S2" "backlog" '"next-sprint"'
  _make_flagged_story "$dir" "E1-S3" "backlog" "null"
  _make_flagged_story "$dir" "E1-S4" "ready-for-dev" '"next-sprint"'

  local got
  got="$(pflag_scan_backlog "$dir")"
  local count
  count="$(printf '%s\n' "$got" | grep -c .)"
  [ "$count" -eq 2 ]
  echo "$got" | grep -q "E1-S1"
  echo "$got" | grep -q "E1-S2"
}

@test "pflag_scan_backlog: returns empty when no flagged stories exist" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog" "null"
  _make_flagged_story "$dir" "E1-S2" "backlog" "null"

  local got
  got="$(pflag_scan_backlog "$dir")"
  [ -z "$got" ]
}

@test "pflag_scan_backlog: ignores non-backlog stories even if flagged" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "in-progress" '"next-sprint"'
  _make_flagged_story "$dir" "E1-S2" "done" '"next-sprint"'
  _make_flagged_story "$dir" "E1-S3" "ready-for-dev" '"next-sprint"'

  local got
  got="$(pflag_scan_backlog "$dir")"
  [ -z "$got" ]
}

@test "pflag_scan_backlog: handles empty directory" {
  _load_pflag_helpers
  local dir="$TEST_TMP/empty-impl"
  mkdir -p "$dir"

  local got
  got="$(pflag_scan_backlog "$dir")"
  [ -z "$got" ]
}

# ===========================================================================
# pflag_clear — clear priority_flag to null in a story file
# ===========================================================================

@test "pflag_clear: rewrites priority_flag to null (AC3)" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog" '"next-sprint"'

  pflag_clear "$dir/E1-S1-story.md"

  # Verify the frontmatter now says priority_flag: null
  grep -q 'priority_flag: null' "$dir/E1-S1-story.md"
}

@test "pflag_clear: preserves other frontmatter fields" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog" '"next-sprint"'

  pflag_clear "$dir/E1-S1-story.md"

  # Verify other fields untouched
  grep -q 'key: "E1-S1"' "$dir/E1-S1-story.md"
  grep -q 'status: backlog' "$dir/E1-S1-story.md"
  grep -q 'template:' "$dir/E1-S1-story.md"
}

@test "pflag_clear: no-op on already null flag" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog" "null"

  local before after
  before="$(shasum -a 256 "$dir/E1-S1-story.md" | cut -d' ' -f1)"
  pflag_clear "$dir/E1-S1-story.md"
  after="$(shasum -a 256 "$dir/E1-S1-story.md" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
}

@test "pflag_clear: returns non-zero on missing file" {
  _load_pflag_helpers
  run pflag_clear "$TEST_TMP/nonexistent.md"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# pflag_record_cleared — append cleared keys to sprint-status.yaml
# ===========================================================================

@test "pflag_record_cleared: appends priority_flag_cleared block" {
  _load_pflag_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
duration: "2 weeks"
stories:
  - key: E1-S1
    status: "ready-for-dev"
EOF

  pflag_record_cleared "$yaml" "E1-S1 E1-S2"

  grep -q 'priority_flag_cleared:' "$yaml"
  grep -q 'E1-S1' "$yaml"
  grep -q 'E1-S2' "$yaml"
}

@test "pflag_record_cleared: empty key list writes empty array" {
  _load_pflag_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
stories: []
EOF

  pflag_record_cleared "$yaml" ""

  grep -q 'priority_flag_cleared: \[\]' "$yaml"
}

@test "pflag_record_cleared: preserves existing yaml content" {
  _load_pflag_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
duration: "2 weeks"
velocity_capacity: 21
stories:
  - key: E1-S1
    status: "ready-for-dev"
EOF

  pflag_record_cleared "$yaml" "E1-S1"

  grep -q 'sprint_id: "sprint-99"' "$yaml"
  grep -q 'duration: "2 weeks"' "$yaml"
  grep -q 'velocity_capacity: 21' "$yaml"
}

# ===========================================================================
# Contract: NO set function — verify script does not expose write capability
# ===========================================================================

@test "priority-flag.sh: no set or write-next-sprint function exists" {
  # Per feedback_priority_flag_never_auto_set: the script MUST NOT
  # expose any function that writes "next-sprint" to a story file.
  local functions
  functions="$(grep -E '^pflag_[a-z_]+\(\)' "$PRIORITY_FLAG_SH" || true)"
  echo "$functions" | grep -vq 'pflag_set\|pflag_write\|write_next_sprint'
}
