#!/usr/bin/env bats
# e39-s1-triage-guard-units.bats
#
# Unit tests for triage-guard.sh public functions added by E39-S1
# (Done-story guard in triage-findings). Satisfies NFR-052 public-function
# coverage gate by directly exercising each new public function.
#
# Functions under test (triage-guard.sh):
#   - tg_read_status       — read status field from story frontmatter
#   - tg_is_done           — test whether status == "done"
#   - tg_render_guidance   — emit halt guidance for done-story targets
#   - tg_record_override   — append override record to triage report
#
# Pattern: source the script as a library (extract function definitions
# via awk) then call each function directly — same approach as
# e38-s4-priority-flag-units.bats and e38-s3-lint-dependencies-units.bats.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

TRIAGE_GUARD_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/triage-guard.sh"

# ---------------------------------------------------------------------------
# Helper: extract public function definitions from triage-guard.sh
# ---------------------------------------------------------------------------
_load_guard_helpers() {
  local tmp
  tmp="$(mktemp -t tg-helpers.XXXXXX)"
  printf 'SCRIPT_NAME="triage-guard.sh"\n' > "$tmp"
  awk '
    /^_tg_fm_field\(\) \{/,/^\}/ { print; next }
    /^tg_read_status\(\) \{/,/^\}/ { print; next }
    /^tg_is_done\(\) \{/,/^\}/ { print; next }
    /^tg_render_guidance\(\) \{/,/^\}/ { print; next }
    /^tg_record_override\(\) \{/,/^\}/ { print; next }
  ' "$TRIAGE_GUARD_SH" >> "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_make_story() {
  local dir="$1" key="$2" status="$3" sprint="${4:-sprint-26}"
  local file="${dir}/${key}-story.md"
  cat > "$file" <<EOF
---
template: 'story'
key: "${key}"
status: ${status}
sprint_id: "${sprint}"
---

# Story: ${key}
EOF
  printf '%s' "$file"
}

# ===========================================================================
# tg_read_status — read status field from frontmatter
# ===========================================================================

@test "tg_read_status: reads done status" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "done")"
  local got
  got="$(tg_read_status "$file")"
  [ "$got" = "done" ]
}

@test "tg_read_status: reads in-progress status" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "in-progress")"
  local got
  got="$(tg_read_status "$file")"
  [ "$got" = "in-progress" ]
}

@test "tg_read_status: reads review status" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "review")"
  local got
  got="$(tg_read_status "$file")"
  [ "$got" = "review" ]
}

@test "tg_read_status: handles quoted status value" {
  _load_guard_helpers
  local file="$TEST_TMP/quoted.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: "E1-S1"
status: "done"
---
EOF
  local got
  got="$(tg_read_status "$file")"
  [ "$got" = "done" ]
}

@test "tg_read_status: returns empty when status missing" {
  _load_guard_helpers
  local file="$TEST_TMP/nostatus.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: "E1-S1"
---
EOF
  local got
  got="$(tg_read_status "$file" || true)"
  [ -z "$got" ]
}

@test "tg_read_status: fails on missing file" {
  _load_guard_helpers
  run tg_read_status "$TEST_TMP/nonexistent.md"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# tg_is_done — boolean check on done status
# ===========================================================================

@test "tg_is_done: returns 0 when status is done" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "done")"
  run tg_is_done "$file"
  [ "$status" -eq 0 ]
}

@test "tg_is_done: returns 1 when status is in-progress" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "in-progress")"
  run tg_is_done "$file"
  [ "$status" -eq 1 ]
}

@test "tg_is_done: returns 1 when status is review" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "review")"
  run tg_is_done "$file"
  [ "$status" -eq 1 ]
}

@test "tg_is_done: returns 1 when status is backlog" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "backlog")"
  run tg_is_done "$file"
  [ "$status" -eq 1 ]
}

@test "tg_is_done: returns 1 when status is ready-for-dev" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "ready-for-dev")"
  run tg_is_done "$file"
  [ "$status" -eq 1 ]
}

@test "tg_is_done: returns 1 when status is validating" {
  _load_guard_helpers
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "validating")"
  run tg_is_done "$file"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# tg_render_guidance — halt guidance message
# ===========================================================================

@test "tg_render_guidance: includes story key" {
  _load_guard_helpers
  local out
  out="$(tg_render_guidance "E39-S1" "sprint-26")"
  grep -q "E39-S1" <<<"$out"
}

@test "tg_render_guidance: includes sprint ID" {
  _load_guard_helpers
  local out
  out="$(tg_render_guidance "E39-S1" "sprint-26")"
  grep -q "sprint-26" <<<"$out"
}

@test "tg_render_guidance: recommends /gaia-create-story" {
  _load_guard_helpers
  local out
  out="$(tg_render_guidance "E39-S1" "sprint-26")"
  grep -q "/gaia-create-story" <<<"$out"
}

@test "tg_render_guidance: recommends /gaia-add-feature" {
  _load_guard_helpers
  local out
  out="$(tg_render_guidance "E39-S1" "sprint-26")"
  grep -q "/gaia-add-feature" <<<"$out"
}

@test "tg_render_guidance: mentions retrospective linkage" {
  _load_guard_helpers
  local out
  out="$(tg_render_guidance "E39-S1" "sprint-26")"
  # Must include a retrospective-linkage sentence
  grep -qi "retro" <<<"$out"
}

@test "tg_render_guidance: handles null sprint ID gracefully" {
  _load_guard_helpers
  local out
  out="$(tg_render_guidance "E1-S99" "null")"
  grep -q "E1-S99" <<<"$out"
}

# ===========================================================================
# tg_record_override — append override record to triage report
# ===========================================================================

@test "tg_record_override: creates report when missing" {
  _load_guard_helpers
  local report="$TEST_TMP/triage-report.md"
  tg_record_override "$report" "julien" "2026-04-22" "F-001" "E1-S1" "urgent hotfix"
  [ -f "$report" ]
}

@test "tg_record_override: records user/date/finding/target/reason" {
  _load_guard_helpers
  local report="$TEST_TMP/triage-report.md"
  tg_record_override "$report" "julien" "2026-04-22" "F-001" "E1-S1" "urgent hotfix"
  grep -q "julien" "$report"
  grep -q "2026-04-22" "$report"
  grep -q "F-001" "$report"
  grep -q "E1-S1" "$report"
  grep -q "urgent hotfix" "$report"
}

@test "tg_record_override: sets retro_flag: true" {
  _load_guard_helpers
  local report="$TEST_TMP/triage-report.md"
  tg_record_override "$report" "julien" "2026-04-22" "F-001" "E1-S1" "urgent hotfix"
  grep -q "retro_flag: true" "$report"
}

@test "tg_record_override: appends to existing report without truncating" {
  _load_guard_helpers
  local report="$TEST_TMP/triage-report.md"
  cat > "$report" <<'EOF'
# Triage Report
prior content line
EOF
  tg_record_override "$report" "julien" "2026-04-22" "F-001" "E1-S1" "urgent hotfix"
  grep -q "prior content line" "$report"
  grep -q "julien" "$report"
}

@test "tg_record_override: allows multiple override entries" {
  _load_guard_helpers
  local report="$TEST_TMP/triage-report.md"
  tg_record_override "$report" "alice" "2026-04-22" "F-001" "E1-S1" "first reason"
  tg_record_override "$report" "bob"   "2026-04-23" "F-002" "E2-S3" "second reason"
  grep -q "alice" "$report"
  grep -q "bob" "$report"
  grep -q "F-001" "$report"
  grep -q "F-002" "$report"
}

@test "tg_record_override: rejects missing required args" {
  _load_guard_helpers
  run tg_record_override "$TEST_TMP/r.md" "julien" "2026-04-22" "F-001" "E1-S1"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Contract: triage-guard.sh must be executable as standalone CLI
# ===========================================================================

@test "triage-guard.sh: is executable" {
  [ -x "$TRIAGE_GUARD_SH" ]
}

@test "triage-guard.sh: shellcheck-safe shebang" {
  head -n 1 "$TRIAGE_GUARD_SH" | grep -q '^#!/usr/bin/env bash'
}
