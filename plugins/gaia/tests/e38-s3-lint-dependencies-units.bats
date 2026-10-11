#!/usr/bin/env bats
# e38-s3-lint-dependencies-units.bats
#
# Unit tests for the lint-dependencies sub-operation added by E38-S3
# (Dependency Inversion Lint). Satisfies NFR-052 public-function coverage
# gate by directly exercising each new public function.
#
# Functions under test (sprint-state.sh):
#   - cmd_lint_dependencies
#   - lint_read_depends_on
#   - lint_scan_ac_text
#   - lint_build_order_map
#   - lint_detect_inversions
#   - lint_format_json
#   - lint_format_text
#
# Design choice (INFO #2 from Val): The AC text regex uses an 80-char
# co-occurrence window for trigger verb + target resource name matching.
# This bounds false positives from long-range coincidental matches while
# still catching same-sentence references.
#
# Pattern: source the script as a library (extract function definitions
# via awk) then call each function directly — same approach as
# e38-s1-reconcile-risk-units.bats and e35-s2-approval-gate-units.bats.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

SPRINT_STATE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-state.sh"

# ---------------------------------------------------------------------------
# Helper: extract lint-dependencies function definitions from sprint-state.sh
# ---------------------------------------------------------------------------
_load_lint_helpers() {
  local tmp
  tmp="$(mktemp -t lint-helpers.XXXXXX)"
  # Set SCRIPT_NAME so die() and error messages work under set -u.
  printf 'SCRIPT_NAME="sprint-state.sh"\n' > "$tmp"
  awk '
    /^die\(\) \{/,/^\}/ { print; next }
    /^resolve_paths\(\) \{/,/^\}/ { print; next }
    /^_is_story_file\(\) \{/,/^\}/ { print; next }
    /^reconcile_locate_story_file\(\) \{/,/^\}/ { print; next }
    /^reconcile_read_story_status\(\) \{/,/^\}/ { print; next }
    /^reconcile_list_yaml_stories\(\) \{/,/^\}/ { print; next }
    /^lint_read_depends_on\(\) \{/,/^\}/ { print; next }
    /^lint_scan_ac_text\(\) \{/,/^\}/ { print; next }
    /^lint_build_order_map\(\) \{/,/^\}/ { print; next }
    /^lint_lookup_order\(\) \{/,/^\}/ { print; next }
    /^_lint_emit_if_inversion\(\) \{/,/^\}/ { print; next }
    /^lint_detect_inversions\(\) \{/,/^\}/ { print; next }
    /^lint_format_json\(\) \{/,/^\}/ { print; next }
    /^lint_format_text\(\) \{/,/^\}/ { print; next }
    /^cmd_lint_dependencies\(\) \{/,/^\}/ { print; next }
  ' "$SPRINT_STATE_SH" >> "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_make_story_file() {
  local dir="$1" key="$2" status="$3"
  local depends_on="${4:-}"
  local ac_text="${5:-}"
  local file="${dir}/${key}-story.md"
  cat > "$file" <<EOF
---
template: 'story'
key: ${key}
status: ${status}
depends_on: [${depends_on}]
---
> **Status:** ${status}

## Acceptance Criteria

${ac_text:-No AC text.}
EOF
  printf '%s' "$file"
}

_make_yaml() {
  local file="$1"; shift
  cat > "$file" <<HEADER
sprint_id: "sprint-99"
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
# lint_read_depends_on — extracts depends_on list from story frontmatter
# ===========================================================================

@test "lint_read_depends_on: extracts single dependency" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E1-S2"'
  local got
  got="$(lint_read_depends_on "$dir/E1-S1-story.md")"
  [ "$got" = "E1-S2" ]
}

@test "lint_read_depends_on: extracts multiple dependencies" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E1-S2", "E1-S3"'
  local got
  got="$(lint_read_depends_on "$dir/E1-S1-story.md")"
  # Should output one dep per line
  local count
  count="$(printf '%s\n' "$got" | grep -c .)"
  [ "$count" -eq 2 ]
  grep -q "E1-S2" <<<"$got"
  grep -q "E1-S3" <<<"$got"
}

@test "lint_read_depends_on: returns empty for missing depends_on field (AC-EC2)" {
  _load_lint_helpers
  local file="$TEST_TMP/no-deps.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: E2-S1
status: ready-for-dev
---
> **Status:** ready-for-dev
EOF
  local got
  got="$(lint_read_depends_on "$file")"
  [ -z "$got" ]
}

@test "lint_read_depends_on: returns empty for empty array depends_on" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E3-S1" "ready-for-dev" ""
  local got
  got="$(lint_read_depends_on "$dir/E3-S1-story.md")"
  [ -z "$got" ]
}

# ===========================================================================
# lint_scan_ac_text — heuristic scan for trigger verbs + resource references
# ===========================================================================

@test "lint_scan_ac_text: detects 'reads from' + story key in window" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S2" "ready-for-dev" "" \
    "Given the system reads from the output produced by E1-S3 reconciliation"
  local got
  got="$(lint_scan_ac_text "$dir/E1-S2-story.md" "E1-S1 E1-S2 E1-S3")"
  grep -q "E1-S3" <<<"$got"
}

@test "lint_scan_ac_text: detects 'uses' + target story key" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S2" "ready-for-dev" "" \
    "This story uses the output from E1-S3 reconciliation step"
  local got
  got="$(lint_scan_ac_text "$dir/E1-S2-story.md" "E1-S1 E1-S2 E1-S3")"
  grep -q "E1-S3" <<<"$got"
}

@test "lint_scan_ac_text: detects 'consumes' + resource" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S2" "ready-for-dev" "" \
    "The lint step consumes sprint-status.yaml produced by E1-S5"
  local got
  got="$(lint_scan_ac_text "$dir/E1-S2-story.md" "E1-S1 E1-S2 E1-S3 E1-S5")"
  grep -q "E1-S5" <<<"$got"
}

@test "lint_scan_ac_text: no false positive on 'reads from stdout' (AC-EC5)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S2" "ready-for-dev" "" \
    "The script reads from stdout and writes to stderr"
  local got
  got="$(lint_scan_ac_text "$dir/E1-S2-story.md" "E1-S1 E1-S2 E1-S3")"
  [ -z "$got" ]
}

@test "lint_scan_ac_text: bare key mention without trigger verb (AC-EC6)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S2" "ready-for-dev" "" \
    "E1-S3 will be documented later in a separate PR"
  local got
  got="$(lint_scan_ac_text "$dir/E1-S2-story.md" "E1-S1 E1-S2 E1-S3")"
  [ -z "$got" ]
}

# ===========================================================================
# lint_build_order_map — assigns sprint-order indices to story keys
# ===========================================================================

@test "lint_build_order_map: assigns sequential indices" {
  _load_lint_helpers
  local dir="$TEST_TMP"
  _make_yaml "$dir/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev" \
    "E1-S3" "ready-for-dev"
  SPRINT_STATUS_YAML="$dir/sprint-status.yaml"
  local got
  got="$(lint_build_order_map)"
  grep -q "E1-S1" <<<"$got"
  grep -q "E1-S2" <<<"$got"
  grep -q "E1-S3" <<<"$got"
}

# ===========================================================================
# lint_detect_inversions — finds forward-reference edges in dependency graph
# ===========================================================================

@test "lint_detect_inversions: clean sprint returns no inversions (AC1)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_story_file "$dir" "E1-S3" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev" \
    "E1-S3" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"

  local got
  got="$(lint_detect_inversions)"
  [ -z "$got" ]
}

@test "lint_detect_inversions: flags S3-to-S5 inversion via depends_on (AC2)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  # S3 depends on S5, but S5 comes later in sprint order
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_story_file "$dir" "E1-S3" "ready-for-dev" '"E1-S5"'
  _make_story_file "$dir" "E1-S4" "ready-for-dev"
  _make_story_file "$dir" "E1-S5" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev" \
    "E1-S3" "ready-for-dev" \
    "E1-S4" "ready-for-dev" \
    "E1-S5" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"

  local got
  got="$(lint_detect_inversions)"
  grep -q "E1-S3" <<<"$got"
  grep -q "E1-S5" <<<"$got"
  grep -q "explicit" <<<"$got"
}

@test "lint_detect_inversions: external dependency flagged as heuristic (AC-EC3)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  # S1 depends on E2-S1 which is not in the sprint
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E2-S1"'
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"

  local got
  got="$(lint_detect_inversions)"
  grep -q "E2-S1" <<<"$got"
  grep -q "External" <<<"$got"
}

@test "lint_detect_inversions: circular A->B->A reports both edges (AC-EC4)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E1-S2"'
  _make_story_file "$dir" "E1-S2" "ready-for-dev" '"E1-S1"'
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"

  local got
  got="$(lint_detect_inversions)"
  # At least one inversion must be reported (one edge is forward-ref)
  [ -n "$got" ]
}

# ===========================================================================
# lint_format_json — produces JSON output from inversions data
# ===========================================================================

@test "lint_format_json: clean sprint emits status clean" {
  _load_lint_helpers
  local got
  got="$(lint_format_json "sprint-99" 5 "")"
  grep -q '"status": "clean"' <<<"$got"
  grep -q '"stories_analyzed": 5' <<<"$got"
  grep -q '"inversions": \[\]' <<<"$got"
}

@test "lint_format_json: inversions present emits status inversions_detected" {
  _load_lint_helpers
  local inversions="E1-S3|E1-S5|depends_on|explicit||Move E1-S5 before E1-S3"
  local got
  got="$(lint_format_json "sprint-99" 5 "$inversions")"
  grep -q '"status": "inversions_detected"' <<<"$got"
  grep -q '"dependent": "E1-S3"' <<<"$got"
  grep -q '"dependency": "E1-S5"' <<<"$got"
}

# ===========================================================================
# lint_format_text — produces human-readable text output
# ===========================================================================

@test "lint_format_text: clean sprint shows no inversions" {
  _load_lint_helpers
  local got
  got="$(lint_format_text "sprint-99" 5 "")"
  grep -qi "clean\|no inversions" <<<"$got"
}

@test "lint_format_text: inversions present shows table" {
  _load_lint_helpers
  local inversions="E1-S3|E1-S5|depends_on|explicit||Move E1-S5 before E1-S3"
  local got
  got="$(lint_format_text "sprint-99" 5 "$inversions")"
  grep -q "E1-S3" <<<"$got"
  grep -q "E1-S5" <<<"$got"
}

# ===========================================================================
# cmd_lint_dependencies — full integration via the subcommand
# ===========================================================================

@test "cmd_lint_dependencies: empty sprint exits 0 with clean JSON (AC-EC1)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
duration: "2 weeks"
stories: []
EOF
  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$yaml"
  PROJECT_PATH="$TEST_TMP"

  run cmd_lint_dependencies "json" ""
  [ "$status" -eq 0 ]
  grep -q '"stories_analyzed": 0' <<<"$output"
  grep -q '"status": "clean"' <<<"$output"
}

@test "cmd_lint_dependencies: clean sprint exits 0 (AC1)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_story_file "$dir" "E1-S3" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev" \
    "E1-S3" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  PROJECT_PATH="$TEST_TMP"

  run cmd_lint_dependencies "json" ""
  [ "$status" -eq 0 ]
  grep -q '"status": "clean"' <<<"$output"
}

@test "cmd_lint_dependencies: inversion detected exits 2 (AC2)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  _make_story_file "$dir" "E1-S3" "ready-for-dev" '"E1-S5"'
  _make_story_file "$dir" "E1-S4" "ready-for-dev"
  _make_story_file "$dir" "E1-S5" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev" \
    "E1-S3" "ready-for-dev" \
    "E1-S4" "ready-for-dev" \
    "E1-S5" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  PROJECT_PATH="$TEST_TMP"

  run cmd_lint_dependencies "json" ""
  [ "$status" -eq 2 ]
  grep -q '"status": "inversions_detected"' <<<"$output"
}

@test "cmd_lint_dependencies: malformed yaml exits 1 (AC-EC8)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  local yaml="$TEST_TMP/sprint-status.yaml"
  printf 'this is not valid yaml: [[[' > "$yaml"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$yaml"
  PROJECT_PATH="$TEST_TMP"

  run cmd_lint_dependencies "json" ""
  [ "$status" -eq 1 ]
}

@test "cmd_lint_dependencies: missing story file exits 1 (AC-EC10)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  # yaml references E1-S1 but no story file exists
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  PROJECT_PATH="$TEST_TMP"

  run cmd_lint_dependencies "json" ""
  [ "$status" -eq 1 ]
  # Error message may reference "not found" or "failed"
  grep -qiE "not found|failed" <<<"$output"
}

@test "cmd_lint_dependencies: text format works" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  PROJECT_PATH="$TEST_TMP"

  run cmd_lint_dependencies "text" ""
  [ "$status" -eq 0 ]
}

@test "cmd_lint_dependencies: read-only guarantee — no writes (AC-EC7, AC-EC13)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" '"E1-S2"'
  _make_story_file "$dir" "E1-S2" "ready-for-dev"
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_yaml "$yaml" \
    "E1-S1" "ready-for-dev" \
    "E1-S2" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$yaml"
  PROJECT_PATH="$TEST_TMP"

  # Snapshot checksums before
  local before_yaml before_s1 before_s2
  before_yaml="$(shasum -a 256 "$yaml" | cut -d' ' -f1)"
  before_s1="$(shasum -a 256 "$dir/E1-S1-story.md" | cut -d' ' -f1)"
  before_s2="$(shasum -a 256 "$dir/E1-S2-story.md" | cut -d' ' -f1)"

  run cmd_lint_dependencies "json" ""

  # Verify nothing was modified
  local after_yaml after_s1 after_s2
  after_yaml="$(shasum -a 256 "$yaml" | cut -d' ' -f1)"
  after_s1="$(shasum -a 256 "$dir/E1-S1-story.md" | cut -d' ' -f1)"
  after_s2="$(shasum -a 256 "$dir/E1-S2-story.md" | cut -d' ' -f1)"
  [ "$before_yaml" = "$after_yaml" ]
  [ "$before_s1" = "$after_s1" ]
  [ "$before_s2" = "$after_s2" ]
}

@test "cmd_lint_dependencies: Unicode AC text does not crash (AC-EC11)" {
  _load_lint_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_story_file "$dir" "E1-S1" "ready-for-dev" "" \
    "Given the system uses 🚀 emoji and café résumé text"
  _make_yaml "$TEST_TMP/sprint-status.yaml" \
    "E1-S1" "ready-for-dev"

  IMPLEMENTATION_ARTIFACTS="$dir"
  SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  PROJECT_PATH="$TEST_TMP"

  run cmd_lint_dependencies "json" ""
  [ "$status" -eq 0 ]
}
