#!/usr/bin/env bats
# design-record-roster.bats — roster resolution: caching, symlink rejection,
# constant process count, dedup, edge cases.

load 'test_helper.bash'

# fail MSG — abort the current test with a diagnostic message.
fail() { printf '%s\n' "$1" >&2; return 1; }

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/design-record.sh"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  export PROJECT_ROOT="$TEST_TMP"

  STATE_DIR="$TEST_TMP/.gaia/state"
  mkdir -p "$STATE_DIR"
  RECORD="$STATE_DIR/design-record.yaml"

  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"

  # Capture absolute paths for shim delegation BEFORE any shims exist
  REAL_YQ="$(type -P yq)"
  REAL_AWK="$(type -P awk)"
  REAL_GREP="$(type -P grep)"
  REAL_SED="$(type -P sed)"
  REAL_BASENAME="$(type -P basename)"
  REAL_TR="$(type -P tr)"
  REAL_CUT="$(type -P cut)"
  REAL_CAT="$(type -P cat)"
  REAL_HEAD="$(type -P head)"
  REAL_DIRNAME="$(type -P dirname)"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

_seed_record() {
  local state="${1:-draft}" iteration="${2:-1}"
  mkdir -p "$STATE_DIR"
  cat > "$RECORD" <<EOF
schema_version: "1.0"
applicability: applicable
design_state: "$state"
iteration: $iteration
project:
  reference: "test-project-ref"
  discovered_via: "created"
  questionnaire_record: ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF
}

# _mk_stakeholder DIR SLUG TAGS_ARRAY_YAML [BODY]
# Creates a stakeholder .md file with optional body after frontmatter.
_mk_stakeholder() {
  local dir="$1" slug="$2" tags_yaml="$3" body="${4:-}"
  mkdir -p "$dir"
  {
    printf '%s\n' "---"
    printf 'slug: %s\n' "$slug"
    printf 'tags: %s\n' "$tags_yaml"
    printf '%s\n' "---"
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    fi
  } > "$dir/${slug}.md"
}

# _mk_stakeholder_no_slug DIR FILENAME TAGS_ARRAY_YAML [BODY]
_mk_stakeholder_no_slug() {
  local dir="$1" filename="$2" tags_yaml="$3" body="${4:-}"
  mkdir -p "$dir"
  {
    printf '%s\n' "---"
    printf 'tags: %s\n' "$tags_yaml"
    printf '%s\n' "---"
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    fi
  } > "$dir/${filename}"
}

# _mk_stakeholder_raw DIR FILENAME CONTENT
# Writes arbitrary content as a stakeholder file.
_mk_stakeholder_raw() {
  local dir="$1" filename="$2" content="$3"
  mkdir -p "$dir"
  printf '%s\n' "$content" > "$dir/${filename}"
}

# _init_and_transition_to_review — seed a review-state record via the script
# (creates audit entries, used before shims go on PATH).
_init_and_transition_to_review() {
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" init \
    --reference r --discovered-via project-artifacts >/dev/null 2>&1
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" transition \
    --to review --actor t >/dev/null 2>&1
}

# _create_shims — build counting shims under $SHIM_DIR
_create_shims() {
  SHIM_DIR="$BATS_TEST_TMPDIR/shims"
  SHIM_LOG="$BATS_TEST_TMPDIR/shim-log"
  mkdir -p "$SHIM_DIR" "$SHIM_LOG"

  local tool real_var real_path
  for tool in yq awk grep sed basename tr cut cat head dirname; do
    real_var="REAL_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')"
    eval "real_path=\"\$$real_var\""
    cat > "$SHIM_DIR/$tool" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "\$SHIM_LOG/$tool"
exec $real_path "\$@"
SHIM
    chmod +x "$SHIM_DIR/$tool"
  done
}

# _shim_count TOOL — return the number of invocations logged for TOOL
_shim_count() {
  local tool="$1"
  if [ -f "$SHIM_LOG/$tool" ]; then
    wc -l < "$SHIM_LOG/$tool" | tr -d ' '
  else
    printf '0'
  fi
}

# _yq_roster_count — count yq calls whose argv contains _gaia_rix (the
# roster-specific injected key).  This distinguishes roster yq calls from
# other yq -N calls (e.g. _validate_project_references).
_yq_roster_count() {
  if [ -f "$SHIM_LOG/yq" ]; then
    local n
    n="$("$REAL_GREP" -c '_gaia_rix' "$SHIM_LOG/yq" 2>/dev/null)" || true
    printf '%s' "${n:-0}"
  else
    printf '0'
  fi
}

# _mk_n_roster N — create N roster files with s1 design-tagged, rest untagged
_mk_n_roster() {
  local n="$1" roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"
  printf '%s\n' "---
slug: s1
tags: [design]
---" > "$roster_dir/s1.md"
  local i=2
  while [ "$i" -le "$n" ]; do
    printf '%s\n' "---
slug: s$i
tags: [other]
---" > "$roster_dir/s$i.md"
    i=$((i + 1))
  done
}

# _extract_fn_body FUNCNAME FILE — extract a shell function body from FILE.
_extract_fn_body() {
  local funcname="$1" file="$2"
  local body
  body="$("$REAL_AWK" "/^${funcname}\\(\\)/{p=1} p{print} p && /^}\$/{exit}" "$file" 2>/dev/null)"
  [ -n "$body" ] || fail "_extract_fn_body: function '$funcname' not found or empty in $file"
  printf '%s' "$body"
}

# =========================================================================
# constant process count on check-convergence, N=1 vs N=50
# =========================================================================

@test "constant process count on check-convergence, N=1 vs N=50" {
  [ -x "$SCRIPT" ] || fail "script not found"

  # --- N=1 ---
  _mk_n_roster 1
  _init_and_transition_to_review
  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence
  # may be non-zero (not-converged), that's fine

  local yq1 awk1 grep1 sed1 bn1 tr1 cut1 cat1 head1 dir1 yqn1
  yq1="$(_shim_count yq)";   awk1="$(_shim_count awk)"
  grep1="$(_shim_count grep)"; sed1="$(_shim_count sed)"
  bn1="$(_shim_count basename)"; tr1="$(_shim_count tr)"
  cut1="$(_shim_count cut)";   cat1="$(_shim_count cat)"
  head1="$(_shim_count head)"; dir1="$(_shim_count dirname)"
  yqr1="$(_yq_roster_count)"

  [ "$yq1" -gt 0 ] || fail "yq count should be > 0 for N=1, got $yq1"
  [ "$yqr1" -gt 0 ] || fail "expected at least one roster yq call for N=1, got $yqr1"

  # --- N=50 ---
  rm -rf "$TEST_TMP/.gaia/custom/stakeholders" "$TEST_TMP/.gaia/state"
  _mk_n_roster 50
  _init_and_transition_to_review
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  local yq50 awk50 grep50 sed50 bn50 tr50 cut50 cat50 head50 dir50 yqr50
  yq50="$(_shim_count yq)";    awk50="$(_shim_count awk)"
  grep50="$(_shim_count grep)"; sed50="$(_shim_count sed)"
  bn50="$(_shim_count basename)"; tr50="$(_shim_count tr)"
  cut50="$(_shim_count cut)";    cat50="$(_shim_count cat)"
  head50="$(_shim_count head)";  dir50="$(_shim_count dirname)"
  yqr50="$(_yq_roster_count)"

  [ "$yq1"   -eq "$yq50" ]   || fail "yq: N=1=$yq1 N=50=$yq50"
  [ "$awk1"  -eq "$awk50" ]  || fail "awk: N=1=$awk1 N=50=$awk50"
  [ "$grep1" -eq "$grep50" ] || fail "grep: N=1=$grep1 N=50=$grep50"
  [ "$sed1"  -eq "$sed50" ]  || fail "sed: N=1=$sed1 N=50=$sed50"
  [ "$bn1"   -eq "$bn50" ]   || fail "basename: N=1=$bn1 N=50=$bn50"
  [ "$tr1"   -eq "$tr50" ]   || fail "tr: N=1=$tr1 N=50=$tr50"
  [ "$cut1"  -eq "$cut50" ]  || fail "cut: N=1=$cut1 N=50=$cut50"
  [ "$cat1"  -eq "$cat50" ]  || fail "cat: N=1=$cat1 N=50=$cat50"
  [ "$head1" -eq "$head50" ] || fail "head: N=1=$head1 N=50=$head50"
  [ "$dir1"  -eq "$dir50" ]  || fail "dirname: N=1=$dir1 N=50=$dir50"
  [ "$yqr1"  -eq "$yqr50" ]  || fail "roster yq: N=1=$yqr1 N=50=$yqr50"
  [ "$yqr1"  -eq 1 ]         || fail "expected exactly 1 roster yq call, got $yqr1"
}

# =========================================================================
# constant process count on approve, N=1 vs N=50
# =========================================================================

@test "constant process count on approve, N=1 vs N=50" {
  [ -x "$SCRIPT" ] || fail "script not found"

  # --- N=1 ---
  _mk_n_roster 1
  _init_and_transition_to_review
  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" approve --stakeholder s1 --recorded-by test

  local yq1 awk1 grep1 sed1 bn1 tr1 yqr1
  yq1="$(_shim_count yq)";   awk1="$(_shim_count awk)"
  grep1="$(_shim_count grep)"; sed1="$(_shim_count sed)"
  bn1="$(_shim_count basename)"; tr1="$(_shim_count tr)"
  yqr1="$(_yq_roster_count)"

  # --- N=50 ---
  rm -rf "$TEST_TMP/.gaia/custom/stakeholders" "$TEST_TMP/.gaia/state"
  _mk_n_roster 50
  _init_and_transition_to_review
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" approve --stakeholder s1 --recorded-by test

  local yq50 awk50 grep50 sed50 bn50 tr50 yqr50
  yq50="$(_shim_count yq)";    awk50="$(_shim_count awk)"
  grep50="$(_shim_count grep)"; sed50="$(_shim_count sed)"
  bn50="$(_shim_count basename)"; tr50="$(_shim_count tr)"
  yqr50="$(_yq_roster_count)"

  [ "$yq1"   -eq "$yq50" ]   || fail "yq: N=1=$yq1 N=50=$yq50"
  [ "$awk1"  -eq "$awk50" ]  || fail "awk: N=1=$awk1 N=50=$awk50"
  [ "$grep1" -eq "$grep50" ] || fail "grep: N=1=$grep1 N=50=$grep50"
  [ "$sed1"  -eq "$sed50" ]  || fail "sed: N=1=$sed1 N=50=$sed50"
  [ "$bn1"   -eq "$bn50" ]   || fail "basename: N=1=$bn1 N=50=$bn50"
  [ "$tr1"   -eq "$tr50" ]   || fail "tr: N=1=$tr1 N=50=$tr50"
  [ "$yqr1"  -eq 1 ]         || fail "expected exactly 1 roster yq call for approve, got $yqr1"
}

# =========================================================================
# constant process count on transition --to approved, N=1 vs N=50
# =========================================================================

@test "constant process count on transition --to approved, N=1 vs N=50" {
  [ -x "$SCRIPT" ] || fail "script not found"

  # --- N=1 ---
  _mk_n_roster 1
  _init_and_transition_to_review
  # Approve s1 so convergence passes
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder s1 --recorded-by test >/dev/null 2>&1
  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" transition --to approved --actor test

  local yq1 awk1 yqr1
  yq1="$(_shim_count yq)"; awk1="$(_shim_count awk)"; yqr1="$(_yq_roster_count)"

  # --- N=50 ---
  rm -rf "$TEST_TMP/.gaia/custom/stakeholders" "$TEST_TMP/.gaia/state"
  _mk_n_roster 50
  _init_and_transition_to_review
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder s1 --recorded-by test >/dev/null 2>&1
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" transition --to approved --actor test

  local yq50 awk50 yqr50
  yq50="$(_shim_count yq)"; awk50="$(_shim_count awk)"; yqr50="$(_yq_roster_count)"

  [ "$yq1"  -eq "$yq50" ]  || fail "yq: N=1=$yq1 N=50=$yq50"
  [ "$awk1" -eq "$awk50" ] || fail "awk: N=1=$awk1 N=50=$awk50"
  [ "$yqr1" -eq 1 ]        || fail "expected exactly 1 roster yq call for transition, got $yqr1"
}

# =========================================================================
# one resolution per process (sourced functions)
# =========================================================================

@test "one resolution per process (sourced functions)" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _mk_stakeholder "$TEST_TMP/.gaia/custom/stakeholders" "alice" "[design]"
  _seed_record "review" 1

  local counter_file="$BATS_TEST_TMPDIR/resolve-count"
  : > "$counter_file"

  # Source the script (the guard at the bottom prevents main from running)
  # then call functions directly — NOT through $(...).
  # Bounded to 30 s so a regression loop fails instead of hanging.
  local helper="$BATS_TEST_TMPDIR/resolve-count-helper.sh"
  cat > "$helper" <<HELPER
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT"
eval "\$(declare -f _resolve_merged_roster_impl | sed '1s/_resolve_merged_roster_impl/_orig_resolve/')"
_resolve_merged_roster_impl() {
  printf 'x\n' >> "$counter_file"
  _orig_resolve "\$@"
}
_get_required_stakeholders > "$BATS_TEST_TMPDIR/req-out"
_assert_known_stakeholder "alice" > "$BATS_TEST_TMPDIR/assert-out"
HELPER
  chmod +x "$helper"
  source "$PLUGIN_ROOT/scripts/lib/exec-with-timeout.sh"
  exec_with_timeout 30 bash "$helper"

  local count
  count="$(wc -l < "$counter_file" | tr -d ' ')"
  [ "$count" -eq 1 ] || fail "expected exactly 1 resolution, got $count"
}

# =========================================================================
# static: entry-point calls to _ensure_roster exist and are correct
# =========================================================================

@test "static: entry-point calls to _ensure_roster exist and are correct" {
  [ -f "$SCRIPT" ] || fail "script not found"

  # cmd_check_convergence must call _ensure_roster
  local body
  body="$(_extract_fn_body cmd_check_convergence "$SCRIPT")"
  printf '%s' "$body" | "$REAL_GREP" -q '_ensure_roster' \
    || fail "cmd_check_convergence does not call _ensure_roster"

  # cmd_approve must call _ensure_roster
  body="$(_extract_fn_body cmd_approve "$SCRIPT")"
  printf '%s' "$body" | "$REAL_GREP" -q '_ensure_roster' \
    || fail "cmd_approve does not call _ensure_roster"

  # cmd_transition must call _ensure_roster (conditionally, for approved)
  body="$(_extract_fn_body cmd_transition "$SCRIPT")"
  printf '%s' "$body" | "$REAL_GREP" -q '_ensure_roster' \
    || fail "cmd_transition does not call _ensure_roster"
  # The roster call must be guarded: only on --to approved
  printf '%s' "$body" | "$REAL_GREP" -q 'approved' \
    || fail "cmd_transition: _ensure_roster must be guarded by approved check"

  # _ensure_roster must come before _locked_mutate in cmd_approve
  local ensure_line mutate_line
  body="$(_extract_fn_body cmd_approve "$SCRIPT")"
  ensure_line="$(printf '%s' "$body" | "$REAL_GREP" -n '_ensure_roster' | head -1 | cut -d: -f1)"
  mutate_line="$(printf '%s' "$body" | "$REAL_GREP" -n '_locked_mutate' | head -1 | cut -d: -f1)"
  [ "$ensure_line" -lt "$mutate_line" ] \
    || fail "cmd_approve: _ensure_roster (line $ensure_line) must come before _locked_mutate (line $mutate_line)"

  # _ensure_roster must come before _locked_mutate in cmd_transition
  body="$(_extract_fn_body cmd_transition "$SCRIPT")"
  ensure_line="$(printf '%s' "$body" | "$REAL_GREP" -n '_ensure_roster' | head -1 | cut -d: -f1)"
  mutate_line="$(printf '%s' "$body" | "$REAL_GREP" -n '_locked_mutate' | head -1 | cut -d: -f1)"
  [ "$ensure_line" -lt "$mutate_line" ] \
    || fail "cmd_transition: _ensure_roster (line $ensure_line) must come before _locked_mutate (line $mutate_line)"

  # _ensure_roster must NOT be inside $(...) in any entry point
  for fn in cmd_check_convergence cmd_approve cmd_transition; do
    body="$(_extract_fn_body "$fn" "$SCRIPT")"
    local subshell_match
    subshell_match="$(printf '%s' "$body" | "$REAL_GREP" -E '\$\(.*_ensure_roster' || true)"
    [ -z "$subshell_match" ] \
      || fail "$fn: _ensure_roster is inside \$(...): $subshell_match"
  done
}

# =========================================================================
# symlinked roster file refused
# =========================================================================

@test "symlinked roster file refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # Valid stakeholder
  _mk_stakeholder "$roster_dir" "alice" "[design]"

  # Symlinked file pointing to a real target
  local target="$BATS_TEST_TMPDIR/evil-target"
  printf '%s\n' "---" "slug: evil" "tags: [design]" "---" > "$target"
  ln -s "$target" "$roster_dir/evil.md"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail on symlinked roster file"
  [[ "$output" == *"refusing symlinked roster file"* ]] \
    || fail "expected symlink refusal diagnostic, got: $output"
  [[ "$output" == *"evil-target"* ]] \
    || fail "expected target path in diagnostic, got: $output"
}

# =========================================================================
# dangling symlinked roster file refused
# =========================================================================

@test "dangling symlinked roster file refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"
  _mk_stakeholder "$roster_dir" "alice" "[design]"

  ln -s "/nonexistent/x" "$roster_dir/broken.md"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail on dangling symlinked file"
  [[ "$output" == *"refusing symlinked roster file"* ]] \
    || fail "expected symlink refusal diagnostic, got: $output"
  [[ "$output" == *"/nonexistent/x"* ]] \
    || fail "expected dangling target in diagnostic, got: $output"
}

# =========================================================================
# symlinked roster directory refused
# =========================================================================

@test "symlinked roster directory refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # Create the target with a planted stakeholder
  local target="$BATS_TEST_TMPDIR/evil"
  mkdir -p "$target"
  _mk_stakeholder "$target" "planted-evil" "[design]"

  # Symlink the roster directory to the target
  mkdir -p "$TEST_TMP/.gaia/custom"
  ln -s "$target" "$TEST_TMP/.gaia/custom/stakeholders"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail on symlinked roster directory"
  [[ "$output" == *"refusing symlinked roster directory"* ]] \
    || fail "expected directory symlink refusal, got: $output"
  [[ "$output" != *"planted-evil"* ]] \
    || fail "planted stakeholder should NOT appear in output"
}

# =========================================================================
# dangling symlinked roster directory refused
# =========================================================================

@test "dangling symlinked roster directory refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  mkdir -p "$TEST_TMP/.gaia/custom"
  ln -s "/nonexistent/dir" "$TEST_TMP/.gaia/custom/stakeholders"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail on dangling symlinked directory"
  [[ "$output" == *"refusing symlinked roster directory"* ]] \
    || fail "expected directory symlink refusal, got: $output"
  [[ "$output" == *"/nonexistent/dir"* ]] \
    || fail "expected dangling target in diagnostic, got: $output"
}

# =========================================================================
# symlinked parent .gaia refused
# =========================================================================

@test "symlinked parent .gaia refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  # Build the target: has both custom/stakeholders and state/design-record.yaml
  local target="$BATS_TEST_TMPDIR/evil-gaia"
  local record_name; record_name="$(basename "$SCRIPT" .sh).yaml"
  mkdir -p "$target/custom/stakeholders" "$target/state"
  _mk_stakeholder "$target/custom/stakeholders" "planted-gaia" "[design]"

  # Create a valid record inside the target so _preflight_read doesn't exit first
  cat > "$target/state/$record_name" <<EOF
schema_version: "1.0"
applicability: applicable
design_state: review
iteration: 1
project:
  reference: "test-project-ref"
  discovered_via: "created"
  questionnaire_record: ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF

  # Remove the real .gaia created by setup, then symlink .gaia -> target
  rm -rf "$TEST_TMP/.gaia"
  ln -s "$target" "$TEST_TMP/.gaia"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail when .gaia is a symlink"
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "expected symlink refusal diagnostic, got: $output"
  [[ "$output" != *"planted-gaia"* ]] \
    || fail "planted stakeholder should NOT appear"
}

# =========================================================================
# symlinked parent .gaia/custom refused
# =========================================================================

@test "symlinked parent .gaia/custom refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  local target="$BATS_TEST_TMPDIR/evil-custom"
  mkdir -p "$target/stakeholders"
  _mk_stakeholder "$target/stakeholders" "planted-evil" "[design]"

  mkdir -p "$TEST_TMP/.gaia"
  ln -s "$target" "$TEST_TMP/.gaia/custom"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail when .gaia/custom is a symlink"
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "expected symlink refusal diagnostic, got: $output"
  [[ "$output" != *"planted-evil"* ]] \
    || fail "planted stakeholder should NOT appear"
}

# =========================================================================
# symlinked parent custom refused
# =========================================================================

@test "symlinked parent custom refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  local target="$BATS_TEST_TMPDIR/evil-root-custom"
  mkdir -p "$target/stakeholders"
  _mk_stakeholder "$target/stakeholders" "planted-root" "[design]"

  ln -s "$target" "$TEST_TMP/custom"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail when custom is a symlink"
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "expected symlink refusal diagnostic, got: $output"
  [[ "$output" != *"planted-root"* ]] \
    || fail "planted stakeholder should NOT appear"
}

# =========================================================================
# approve fails closed on symlink with approval-refused audit
# =========================================================================

@test "approve fails closed on symlink with approval-refused audit" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # Plant a stakeholder inside the symlink target
  local target="$BATS_TEST_TMPDIR/evil-approve"
  mkdir -p "$target"
  _mk_stakeholder "$target" "planted-approve" "[design]"

  mkdir -p "$TEST_TMP/.gaia/custom"
  ln -s "$target" "$TEST_TMP/.gaia/custom/stakeholders"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve \
    --stakeholder planted-approve --recorded-by test
  [ "$status" -ne 0 ] || fail "approve should fail on symlinked roster"
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "expected symlink refusal diagnostic, got: $output"

  # Verify approval-refused audit entry was written
  local audit_event
  audit_event="$(yq '.audit[-1].event' "$RECORD" 2>/dev/null || true)"
  [ "$audit_event" = "approval-refused" ] \
    || fail "expected approval-refused audit entry, got: $audit_event"
}

# =========================================================================
# space-in-stem keeps both entries
# =========================================================================

@test "space-in-stem keeps both entries" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  local roster_dir="$TEST_TMP/custom/stakeholders"
  _mk_stakeholder "$roster_dir" "alice" "[design]"
  _mk_stakeholder_no_slug "$roster_dir" "alice review.md" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # Both should appear in the missing stakeholders list (not just in warnings)
  local missing_lines
  missing_lines="$(printf '%s\n' "$output" | "$REAL_GREP" -i 'missing:' || true)"
  [[ "$missing_lines" == *"alice"* ]] \
    || fail "alice should be in missing: line, got missing_lines=$missing_lines output=$output"
  [[ "$missing_lines" == *"alice review"* ]] \
    || fail "'alice review' should be in missing: line, got missing_lines=$missing_lines output=$output"
}

# =========================================================================
# higher-precedence directory wins exact duplicate [regression]
# =========================================================================

@test "higher-precedence directory wins exact duplicate [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # .gaia/custom/stakeholders has alice tagged design (required)
  _mk_stakeholder "$TEST_TMP/.gaia/custom/stakeholders" "alice" "[design]"
  # custom/stakeholders has alice tagged other (NOT required)
  # If precedence is wrong and the lower-dir wins, alice is NOT required
  # and convergence would be vacuous — proving higher-precedence won.
  _mk_stakeholder "$TEST_TMP/custom/stakeholders" "alice" "[other]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice should appear in missing (design-tagged from .gaia wins, she's required)
  local missing_lines
  missing_lines="$(printf '%s\n' "$output" | "$REAL_GREP" -i 'missing:' || true)"
  [[ "$missing_lines" == *"alice"* ]] \
    || fail "alice should be required (design tag from higher-precedence dir): missing_lines=$missing_lines output=$output"
  [[ "$output" == *"not-converged"* ]] \
    || fail "should be not-converged: $output"
}

# =========================================================================
# dedup after slug validation [regression]
# =========================================================================

@test "dedup after slug validation [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # Higher-precedence alice has wrong slug — should be dropped
  local gaia_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$gaia_dir"
  cat > "$gaia_dir/alice.md" <<'EOF'
---
slug: someone-else
tags: [design]
---
EOF

  # Lower-precedence alice has matching slug — should resolve
  _mk_stakeholder "$TEST_TMP/custom/stakeholders" "alice" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice should appear in the missing list (from custom/stakeholders after
  # .gaia's alice was dropped for slug mismatch); match on missing: line
  # to avoid false-matching the slug-mismatch warning text
  local missing_lines
  missing_lines="$(printf '%s\n' "$output" | "$REAL_GREP" -i 'missing:' || true)"
  [[ "$missing_lines" == *"alice"* ]] \
    || fail "alice from lower-precedence dir should be in missing: line: missing_lines=$missing_lines output=$output"
  # The higher-precedence alice's slug mismatch should produce a warning
  [[ "$output" == *"disagrees with filename"* ]] \
    || fail "expected slug-mismatch warning: $output"
  [[ "$output" == *"not-converged"* ]] \
    || fail "should be not-converged: $output"
}

# =========================================================================
# empty roster directory returns empty roster
# =========================================================================

@test "empty roster directory returns empty roster" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  mkdir -p "$TEST_TMP/custom/stakeholders"
  # No .md files inside

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should return non-zero for empty roster"
  [[ "$output" == *"vacuous"* ]] \
    || fail "expected vacuous diagnostic: $output"
}

# =========================================================================
# no roster directories on convergence path [regression]
# =========================================================================

@test "no roster directories on convergence path [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  # No roster directories at all

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  [ "$status" -ne 0 ] || fail "should return non-zero with no roster dirs"
  [[ "$output" == *"vacuous-convergence"* ]] \
    || fail "expected vacuous-convergence: $output"

  # No roster resolution should have occurred
  local yqr_c
  yqr_c="$(_yq_roster_count)"
  [ "$yqr_c" -eq 0 ] || fail "no roster yq call expected without roster dirs, got $yqr_c"
}

# =========================================================================
# no roster directories on approve path [regression]
# =========================================================================

@test "no roster directories on approve path [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  # No roster directories

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve \
    --stakeholder x --recorded-by test
  [ "$status" -ne 0 ] || fail "approve should fail with no roster"
  [[ "$output" == *"no stakeholder directory found"* ]] \
    || fail "expected 'no stakeholder directory found' warning: $output"

  # Check approval-refused audit
  local audit_event
  audit_event="$(yq '.audit[-1].event' "$RECORD" 2>/dev/null || true)"
  [ "$audit_event" = "approval-refused" ] \
    || fail "expected approval-refused audit entry, got: $audit_event"
}

# =========================================================================
# per-process caches isolated [regression]
# =========================================================================

@test "per-process caches isolated [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  # Project 1: stakeholder alpha
  local proj1="$BATS_TEST_TMPDIR/proj1"
  mkdir -p "$proj1/.gaia/state" "$proj1/.gaia/custom/stakeholders"
  _mk_stakeholder "$proj1/.gaia/custom/stakeholders" "alpha" "[design]"
  (
    export PROJECT_ROOT="$proj1"
    "$SCRIPT" init --reference r --discovered-via project-artifacts >/dev/null 2>&1
    "$SCRIPT" transition --to review --actor t >/dev/null 2>&1
  )

  # Project 2: stakeholder beta
  local proj2="$BATS_TEST_TMPDIR/proj2"
  mkdir -p "$proj2/.gaia/state" "$proj2/.gaia/custom/stakeholders"
  _mk_stakeholder "$proj2/.gaia/custom/stakeholders" "beta" "[design]"
  (
    export PROJECT_ROOT="$proj2"
    "$SCRIPT" init --reference r --discovered-via project-artifacts >/dev/null 2>&1
    "$SCRIPT" transition --to review --actor t >/dev/null 2>&1
  )

  # Run both in background
  local out1="$BATS_TEST_TMPDIR/out1" out2="$BATS_TEST_TMPDIR/out2"
  env PROJECT_ROOT="$proj1" "$SCRIPT" check-convergence > "$out1" 2>&1 &
  local pid1=$!
  env PROJECT_ROOT="$proj2" "$SCRIPT" check-convergence > "$out2" 2>&1 &
  local pid2=$!
  wait "$pid1" || true
  wait "$pid2" || true

  # Each must mention its own stakeholder
  "$REAL_GREP" -q "alpha" "$out1" || fail "proj1 should mention alpha: $(cat "$out1")"
  "$REAL_GREP" -q "beta" "$out2" || fail "proj2 should mention beta: $(cat "$out2")"
  # Neither mentions the other's stakeholder
  local cross1 cross2
  cross1="$("$REAL_GREP" "beta" "$out1" || true)"
  cross2="$("$REAL_GREP" "alpha" "$out2" || true)"
  [ -z "$cross1" ] || fail "proj1 should NOT mention beta: $cross1"
  [ -z "$cross2" ] || fail "proj2 should NOT mention alpha: $cross2"
}

# =========================================================================
# non-YAML body does not break the roster [regression]
# =========================================================================

@test "non-YAML body does not break the roster [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"

  # dan: valid, no design tag
  _mk_stakeholder "$roster_dir" "dan" "[other]"

  # eve: design-tagged, with prose body that isn't valid YAML
  _mk_stakeholder "$roster_dir" "eve" "[design]" \
    "Note: Eve reviews tokens.
Also she reviews more."

  # frank: valid, design-tagged, sorts AFTER eve
  _mk_stakeholder "$roster_dir" "frank" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # All three should resolve; eve and frank are required (design-tagged)
  [[ "$output" == *"eve"* ]] || fail "eve should be in output: $output"
  [[ "$output" == *"frank"* ]] || fail "frank should be in output: $output"
}

# =========================================================================
# malformed frontmatter isolated and named
# =========================================================================

@test "malformed frontmatter isolated and named" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # alice in .gaia (higher precedence)
  _mk_stakeholder "$TEST_TMP/.gaia/custom/stakeholders" "alice" "[design]"
  # bob: malformed frontmatter
  _mk_stakeholder_raw "$TEST_TMP/.gaia/custom/stakeholders" "bob.md" \
    "---
slug: [unclosed
tags: [design]
---"
  # carol in custom (lower precedence)
  _mk_stakeholder "$TEST_TMP/custom/stakeholders" "carol" "[design]"
  # cross-directory duplicate alice in custom (should be deduped by fallback)
  _mk_stakeholder "$TEST_TMP/custom/stakeholders" "alice" "[ux]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice and carol must appear in the exact missing list.
  # alice appears once (deduped across directories).
  [[ "$output" == *"not-converged (missing: alice carol)"* ]] \
    || fail "expected exact missing list 'alice carol': $output"
  # bob is malformed and excluded — named in diagnostic
  [[ "$output" == *"malformed"*"bob.md"* ]] \
    || fail "expected malformed diagnostic naming bob.md: $output"
  # Must NOT be vacuous — valid stakeholders must survive
  [[ "$output" != *"vacuous"* ]] \
    || fail "vacuous should be absent when valid stakeholders exist: $output"
}

# =========================================================================
# tab in stem refused, valid entries kept
# =========================================================================

@test "tab in stem refused, valid entries kept" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  _mk_stakeholder "$roster_dir" "alice" "[design]"

  # Create a file with a tab in the filename
  local tab_file
  tab_file="${roster_dir}/bad$(printf '\t')name.md"
  printf '%s\n' "---" "tags: [design]" "---" > "$tab_file"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice should still resolve
  [[ "$output" == *"alice"* ]] || fail "alice should still resolve: $output"
  # diagnostic for the bad stem
  [[ "$output" == *"refusing stem with tab/newline"* ]] \
    || fail "expected tab refusal diagnostic: $output"
}

# =========================================================================
# newline in stem refused, valid entries kept
# =========================================================================

@test "newline in stem refused, valid entries kept" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  _mk_stakeholder "$roster_dir" "alice" "[design]"

  # Create a file with a newline in the filename
  local nl_file
  nl_file="${roster_dir}/bad"$'\n'"name.md"
  printf '%s\n' "---" "tags: [design]" "---" > "$nl_file"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice should still resolve
  [[ "$output" == *"alice"* ]] || fail "alice should still resolve: $output"
  # diagnostic for the bad stem
  [[ "$output" == *"refusing stem with tab/newline"* ]] \
    || fail "expected newline refusal diagnostic: $output"
}

# =========================================================================
# transition with symlinked roster fails closed
# =========================================================================

@test "transition with symlinked roster fails closed" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # Plant a stakeholder inside the symlink target
  local target="$BATS_TEST_TMPDIR/evil-transition"
  mkdir -p "$target"
  _mk_stakeholder "$target" "planted-trans" "[design]"

  mkdir -p "$TEST_TMP/.gaia/custom"
  ln -s "$target" "$TEST_TMP/.gaia/custom/stakeholders"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" transition --to approved --actor test
  [ "$status" -ne 0 ] || fail "transition should fail on symlinked roster"
  [[ "$output" == *"refusing symlinked roster directory"* ]] \
    || fail "expected exact symlink diagnostic, got: $output"

  # design_state must remain review
  local state
  state="$(yq '.design_state' "$RECORD")"
  [ "$state" = "review" ] || fail "design_state should remain review, got: $state"
}

# =========================================================================
# user-authored _gaia_rix key does not break index mapping [regression]
# =========================================================================

@test "user-authored _gaia_rix key does not break index mapping [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  # File with a user-authored _gaia_rix key (unquoted)
  cat > "$roster_dir/alice.md" <<'EOF'
---
slug: alice
tags: [design]
_gaia_rix: 999
---
EOF

  # File with a user-authored _gaia_rix key (quoted form)
  cat > "$roster_dir/bob.md" <<'EOF'
---
slug: bob
tags: [design]
"_gaia_rix": 888
---
EOF

  # Valid sibling
  _mk_stakeholder "$roster_dir" "carol" "[ux]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # All three should resolve
  [[ "$output" == *"alice"* ]] || fail "alice should resolve: $output"
  [[ "$output" == *"bob"* ]] || fail "bob should resolve: $output"
}

# =========================================================================
# spaces in project root path [regression]
# =========================================================================

@test "spaces in project root path [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  # Create a project root with spaces in the path
  local spaced_root="$BATS_TEST_TMPDIR/root with spaces/my project"
  mkdir -p "$spaced_root/.gaia/state"
  local spaced_record="$spaced_root/.gaia/state/design-record.yaml"

  cat > "$spaced_record" <<EOF
schema_version: "1.0"
applicability: applicable
design_state: review
iteration: 1
project:
  reference: "test-project-ref"
  discovered_via: "created"
  questionnaire_record: ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF

  _mk_stakeholder "$spaced_root/.gaia/custom/stakeholders" "alice" "[design]"
  _mk_stakeholder "$spaced_root/custom/stakeholders" "bob" "[design]"

  run env PROJECT_ROOT="$spaced_root" "$SCRIPT" check-convergence
  # Both should resolve despite spaces in path
  [[ "$output" == *"alice"* ]] || fail "alice should resolve with spaces in root: $output"
  [[ "$output" == *"bob"* ]] || fail "bob should resolve with spaces in root: $output"
  [[ "$output" == *"not-converged"* ]] || fail "should be not-converged: $output"
}

# =========================================================================
# document splitting line does not split frontmatter [regression]
# =========================================================================

@test "document splitting line does not split frontmatter [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # A file with a "--- # comment" line in the body (not a doc separator)
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
tags: [design]
---
Some prose.

--- # section divider

More prose here.
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice should resolve correctly; the "--- # section divider" in the body
  # must not break frontmatter parsing (it's after the closing ---)
  [[ "$output" == *"alice"* ]] || fail "alice should resolve: $output"
  [[ "$output" == *"bob"* ]] || fail "bob should resolve: $output"
}

# =========================================================================
# (deleted) slug with embedded tab/newline is sanitized [regression]
# Removed: this test accepted either outcome (slug mismatch warning OR
# sanitized slug).  The exact-match variants cover both paths:
#   - "tab-bearing slug in fallback still resolves correctly"
#   - "tab-bearing slug on fast path resolves correctly"
#   - "newline-bearing slug exact match on both paths"
# =========================================================================

# =========================================================================
# symlinked project root is not falsely refused [regression]
# =========================================================================

@test "symlinked project root is not falsely refused [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  # Create a real project directory, seeding the record without a literal
  # write to the sole-writer filename (avoids the write-pattern scan).
  local real_root="$BATS_TEST_TMPDIR/real-project"
  mkdir -p "$real_root/.gaia/state"
  _mk_stakeholder "$real_root/.gaia/custom/stakeholders" "alice" "[design]"

  # Seed the record via the script itself (no redirect to the record file)
  env PROJECT_ROOT="$real_root" "$SCRIPT" init \
    --reference r --discovered-via project-artifacts >/dev/null 2>&1
  env PROJECT_ROOT="$real_root" "$SCRIPT" transition \
    --to review --actor t >/dev/null 2>&1

  # Create a symlink to the project root
  local sym_root="$BATS_TEST_TMPDIR/sym-project"
  ln -s "$real_root" "$sym_root"

  # Running with PROJECT_ROOT pointing at the symlink should work —
  # the ancestry check must stop at PROJECT_ROOT before testing -L
  run env PROJECT_ROOT="$sym_root" "$SCRIPT" check-convergence
  [[ "$output" != *"refusing symlinked"* ]] \
    || fail "symlinked project root should NOT be refused: $output"
  [[ "$output" == *"alice"* ]] \
    || fail "alice should resolve with symlinked project root: $output"
}

# =========================================================================
# dangling parent symlinks refused
# =========================================================================

@test "dangling parent symlinks refused" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # Dangling .gaia/custom symlink (not .gaia itself, since that holds the
  # state dir and preflight would fail before reaching roster resolution).
  mkdir -p "$TEST_TMP/.gaia"
  rm -rf "$TEST_TMP/.gaia/custom"
  ln -s "/nonexistent/custom-target" "$TEST_TMP/.gaia/custom"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "should fail on dangling .gaia/custom symlink"
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "expected symlink refusal for dangling .gaia/custom: $output"
}

# =========================================================================
# scalar tag ignored; only list-valued tags count [regression]
# =========================================================================

@test "scalar tag ignored; only list-valued tags count [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # Scalar tag (not array) — must NOT count as required
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
tags: design
---
Alice is the design lead.
STAKE

  # bob with list tag — IS required
  _mk_stakeholder "$roster_dir" "bob" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice resolves but is NOT required (scalar tag ignored)
  local missing_lines
  missing_lines="$(printf '%s\n' "$output" | "$REAL_GREP" -i 'missing:' || true)"
  [[ "$missing_lines" != *"alice"* ]] \
    || fail "alice (scalar tag) should NOT be required: missing_lines=$missing_lines output=$output"
  # bob IS required (list tag)
  [[ "$missing_lines" == *"bob"* ]] \
    || fail "bob (list tag) should be required: missing_lines=$missing_lines output=$output"
  [[ "$output" == *"not-converged"* ]] \
    || fail "should be not-converged: $output"
}

# =========================================================================
# slug-mismatch file skipped with diagnostic [regression]
# =========================================================================

@test "slug-mismatch file skipped with diagnostic [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # bob.md has slug: not-bob — mismatch
  cat > "$roster_dir/bob.md" <<'EOF'
---
slug: not-bob
tags: [design]
---
EOF

  # carol.md is valid
  _mk_stakeholder "$roster_dir" "carol" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # carol must resolve; bob must be skipped with a warning
  [[ "$output" == *"carol"* ]] || fail "carol should resolve: $output"
  [[ "$output" == *"disagrees with filename"* ]] \
    || fail "expected slug-mismatch warning for bob: $output"
}

# =========================================================================
# static: roster pipeline structural guards
# =========================================================================

@test "static: roster pipeline structural guards" {
  [ -f "$SCRIPT" ] || fail "script not found"

  # Index key is injected AFTER user frontmatter content, so yq sees
  # slug/tags before the index.
  local awk1_body
  awk1_body="$("$REAL_GREP" -A2 'printf.*_gaia_rix.*%d' "$SCRIPT" | head -3)"
  [[ "$awk1_body" == *'%s_gaia_rix'* ]] \
    || fail "awk1 must inject index key AFTER frontmatter content (%%s prefix): $awk1_body"

  # User-authored _gaia_rix keys are NOT stripped — yq last-wins handles
  # them because the pipeline's injected index is always the LAST key.
  # Verify the strip patterns are absent (the old approach was removed).
  local strip_count
  strip_count="$("$REAL_GREP" -c '_gaia_rix.*continue' "$SCRIPT" 2>/dev/null)" || true
  [ "${strip_count:-0}" -eq 0 ] \
    || fail "expected 0 strip patterns for user index keys (yq last-wins), got ${strip_count:-0}"

  # awk1 detects the reserved map prefix anywhere on the line (unanchored,
  # to catch NUL-prefixed lines under mawk) and forces a safe fallback.
  "$REAL_GREP" -q 'index(line.*#GAIAMAP:' "$SCRIPT" \
    || fail "awk1 must detect the reserved map prefix (#GAIAMAP:) via index() (unanchored)"
  "$REAL_GREP" -q '#GAIAMAP:.*needs_fallback' "$SCRIPT" \
    || fail "awk1 must set needs_fallback when prefix is detected"

  # awk3 validates index is numeric — rejects corrupted output.
  "$REAL_GREP" -q 'rix !~.*/\^.0-9' "$SCRIPT" \
    || fail "awk3 must validate index is numeric"

  # awk3 tracks seen indices to reject duplicates (exactly-once).
  "$REAL_GREP" -q 'rix_seen' "$SCRIPT" \
    || fail "awk3 must track seen indices for exactly-once validation"
}

# =========================================================================
# frontmatter-level document split triggers fallback, keeps valid siblings
# =========================================================================

@test "frontmatter-level document split triggers fallback, keeps valid siblings" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md has '--- # section' inside frontmatter — a YAML document
  # separator that splits her frontmatter for yq, triggering the fallback.
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
--- # section
tags: [design]
---
STAKE

  # frank is a valid sibling that must survive the fallback
  _mk_stakeholder "$roster_dir" "frank" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence

  # alice is skipped (multi-doc frontmatter); frank is the only required
  # stakeholder.  The exact missing list must name only frank.
  [[ "$output" == *"not-converged (missing: frank)"* ]] \
    || fail "expected exact missing list 'frank': $output"
  # alice's multi-doc frontmatter must produce a malformed diagnostic
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice.md: $output"
  [[ "$output" != *"vacuous"* ]] \
    || fail "vacuous should be absent when frank is valid: $output"
}

# =========================================================================
# user index key resolved via yq last-wins on the fast path
# =========================================================================

@test "user index key resolved via yq last-wins on the fast path" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  # Single-quoted _gaia_rix key — yq last-wins resolves to the pipeline's
  # injected index (always the last key), so the user value is harmless.
  cat > "$roster_dir/alice.md" <<'EOF'
---
slug: alice
tags: [design]
'_gaia_rix': 2
---
EOF

  # Valid sibling
  _mk_stakeholder "$roster_dir" "bob" "[design]"

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # Both must resolve correctly via the fast path (not fallback)
  local missing_lines
  missing_lines="$(printf '%s\n' "$output" | "$REAL_GREP" -i 'missing:' || true)"
  [[ "$missing_lines" == *"alice"* ]] \
    || fail "alice should resolve despite user index key: missing_lines=$missing_lines output=$output"
  [[ "$missing_lines" == *"bob"* ]] \
    || fail "bob should resolve: missing_lines=$missing_lines output=$output"

  # Fast path: exactly 1 roster yq call
  local yqr
  yqr="$(_yq_roster_count)"
  [ "$yqr" -eq 1 ] \
    || fail "expected fast path (1 roster yq call), got roster_yq=$yqr"
}

# =========================================================================
# numeric slug resolves via tostring, not rejected as !!int [regression]
# =========================================================================

@test "numeric slug resolves via tostring, not rejected as !!int [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # Numeric slug — yq returns !!int without tostring
  cat > "$roster_dir/123.md" <<'STAKE'
---
slug: 123
tags: [design]
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  local missing_lines
  missing_lines="$(printf '%s\n' "$output" | "$REAL_GREP" -i 'missing:' || true)"
  [[ "$missing_lines" == *"123"* ]] \
    || fail "numeric slug should resolve via tostring: missing_lines=$missing_lines output=$output"
  [[ "$missing_lines" == *"bob"* ]] \
    || fail "bob should resolve: missing_lines=$missing_lines output=$output"
}

# =========================================================================
# multi-doc frontmatter injection: phantom stakeholder refused [regression]
# =========================================================================

@test "multi-doc frontmatter injection: phantom stakeholder refused [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md has '--- # x' inside frontmatter, creating a second YAML
  # document.  Before the fix, yq would see the second document as a
  # separate stakeholder with slug "design", allowing a phantom approval.
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
--- # x
tags: [design]
---
STAKE

  # frank is a valid required stakeholder
  _mk_stakeholder "$roster_dir" "frank" "[ux]"

  # alice must be refused as malformed; "design" must NOT be a known
  # stakeholder; approving the phantom must fail.
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder design --recorded-by t
  [ "$status" -ne 0 ] || fail "approving phantom stakeholder 'design' should fail: $output"
  [[ "$output" == *"unknown stakeholder"* ]] \
    || fail "expected 'unknown stakeholder' for phantom 'design': $output"

  # check-convergence must report frank as missing (alice is malformed)
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: frank)"* ]] \
    || fail "expected exact missing list 'frank': $output"
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice.md: $output"
}

# =========================================================================
# escaped control chars in tag do not create fake roster rows [regression]
# =========================================================================

@test "escaped control chars in tag do not create fake roster rows [regression]" {
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice's tag contains escaped \n and \t — if not stripped per-item,
  # the newline creates a fake "bob" row and the tab injects a fake path.
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
tags: ["x\nbob\t/nowhere\tother"]
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"
  _mk_stakeholder "$roster_dir" "carol" "[ux]"

  # With a malformed sibling to force fallback
  _mk_stakeholder_raw "$roster_dir" "zed.md" \
    "---
slug: [unclosed
---"

  # Fallback path: bob and carol must be in the missing list.
  # alice must NOT appear as required (her tags are not design/ux after strip).
  # The fake "bob" row from the escaped newline must NOT satisfy bob's requirement.
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: bob carol)"* ]] \
    || fail "expected exact missing list 'bob carol' in fallback: $output"

  # Without malformed sibling (fast path) — same result
  rm -f "$roster_dir/zed.md"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: bob carol)"* ]] \
    || fail "expected exact missing list 'bob carol' in fast path: $output"

  # Approve carol, then re-check — bob must still be missing
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder carol --recorded-by t >/dev/null 2>&1
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob' after carol approved: $output"
}

# =========================================================================
# escaped user index key resolves via fast path without warnings [regression]
# =========================================================================

@test "escaped user index key resolves via fast path without warnings [regression]" {
  # A stakeholder file with _gaia_rix in a complex-key form that survives
  # the awk1 literal-strip patterns (? _gaia_rix / : 1).  yq interprets
  # this as _gaia_rix: 1, so the pipeline must still produce a correct
  # result.  With the index injected LAST, yq sees the user value first,
  # then the pipeline's value overwrites it — so the fast path succeeds.
  # If injection were FIRST, the user's value would overwrite the
  # pipeline's, causing a wrong index and triggering the fallback with
  # a spurious slug-mismatch warning.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice has a YAML complex-key _gaia_rix that awk1 cannot strip.
  # The "? key\n: value" form is valid YAML but does not match any of
  # the three strip patterns (unquoted, double-quoted, single-quoted).
  # yq decodes it to _gaia_rix: 1 in the document.
  cat > "$roster_dir/alice.md" <<'EOF'
---
slug: alice
tags: [other]
? _gaia_rix
: 1
---
EOF

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # Fast path: exactly 1 roster yq call (not per-file fallback)
  local yqr
  yqr="$(_yq_roster_count)"
  [ "$yqr" -eq 1 ] \
    || fail "expected fast path (1 roster yq call), got roster_yq=$yqr"

  # bob must resolve as required; no slug-mismatch warning for alice
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob': $output"
  [[ "$output" != *"disagrees"* ]] \
    || fail "unexpected slug-mismatch warning: $output"
}

# =========================================================================
# split frontmatter falls back to safe per-file resolution [regression]
# =========================================================================

@test "split frontmatter falls back to safe per-file resolution [regression]" {
  # A file with '--- # section' inside frontmatter produces two yq
  # documents from a single file.  The index-validation checks in awk3
  # detect the inconsistency (duplicate or missing index) and exit 2,
  # triggering the per-file fallback — where the split file is refused
  # as malformed.  Without those checks, a bogus slug from the second
  # document would leak into the roster.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
--- # section
tags: [design]
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # Fallback runs: the total yq count exceeds the fast-path 1 because
  # each valid file in the fallback gets its own yq calls.
  local yq_total
  yq_total="$(_shim_count yq)"
  [ "$yq_total" -gt 1 ] \
    || fail "expected fallback (>1 total yq calls), got yq_total=$yq_total"

  # alice is malformed and skipped; bob is the only required stakeholder.
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob': $output"
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice.md: $output"
}

# =========================================================================
# reserved-prefix check forces safe fallback on forged map line [regression]
# =========================================================================

@test "reserved-prefix check forces safe fallback on forged map line [regression]" {
  # A malicious stakeholder file contains a frontmatter line starting with
  # #GAIAMAP: (the reserved in-stream map prefix).  The reserved-prefix
  # check in awk1 detects it and forces the safe per-file fallback, which
  # reads true YAML for each file individually.  Without this check, the
  # forged line could corrupt the index-to-path mapping and allow phantom
  # stakeholder approvals.  This test asserts the FALLBACK PATH (total yq
  # count > 1) to prove the reserved-prefix check fired.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  _mk_stakeholder "$roster_dir" "alice" "[design]"
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # zed.md contains a frontmatter line forging the map prefix for index 0.
  # The reserved-prefix check must detect it and force per-file fallback.
  # The duplicate-index guard would also catch it independently if the
  # prefix check were absent — but the yq-count assertion here proves
  # the prefix check specifically fired (fallback path, >1 yq calls).
  local tab=$'\t'
  cat > "$roster_dir/zed.md" <<STAKE
---
slug: zed
tags: [other]
#GAIAMAP:0${tab}${roster_dir}/zed.md
---
STAKE

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "expected exact missing list 'alice bob': $output"

  # Fallback path: the reserved-prefix check forced per-file resolution
  local yq_total
  yq_total="$(_shim_count yq)"
  [ "$yq_total" -gt 1 ] \
    || fail "expected fallback (>1 total yq calls, prefix check fired), got yq_total=$yq_total"

  # Phantom approval must be refused
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder mallory --recorded-by t
  [ "$status" -ne 0 ] || fail "phantom 'mallory' should be refused: $output"
  [[ "$output" == *"unknown stakeholder"* ]] \
    || fail "expected 'unknown stakeholder' for phantom 'mallory': $output"
}

# =========================================================================
# duplicate map index forces safe fallback independently [regression]
# =========================================================================

@test "duplicate map index forces safe fallback independently [regression]" {
  # This test verifies the duplicate-index guard in awk3 in isolation.
  # alice.md has a '--- # x' line inside frontmatter.  awk1 treats it as
  # content (not == "---"), but yq interprets it as a YAML document
  # separator, producing two documents from one file.  The second document
  # inherits _gaia_rix from the appended line, while the first gets null.
  # awk3 sees the non-numeric index on the first document and triggers the
  # fallback.  In the per-file fallback, alice is refused as malformed
  # (multi-doc frontmatter), leaving bob as the only required stakeholder.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: awk1 reads '--- # x' as frontmatter content (line != "---"),
  # but yq interprets it as a document separator.  The injected _gaia_rix
  # lands only in the second document; the first document's rix is null
  # (non-numeric), so awk3 triggers the fallback.
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
--- # x
tags: [design]
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice is malformed in the fallback; bob is the only required stakeholder.
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob': $output"
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice.md: $output"
}

# =========================================================================
# escaped control chars in tag do not make stakeholder required [regression]
# =========================================================================

@test "escaped control chars in tag do not make stakeholder required [regression]" {
  # A tag value containing escaped \n and \t that, after yq decoding,
  # would spell out "design" on a subsequent line.  Per-item stripping
  # removes the control characters before the tag-matching check, so
  # the decoded value must NOT count as a "design" or "ux" tag.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice's tag decodes to "x\n\tdesign" — without per-item stripping,
  # the decoded newline+tab could produce a line that matches "design".
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
tags: ["x\n\tdesign"]
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice must NOT be required (her tag is "x\n\tdesign" → stripped to
  # "xdesign", which is not "design").  bob IS required.
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob' only: $output"
}

# =========================================================================
# quoted scalar with col-0 hash keeps YAML meaning intact [regression]
# =========================================================================

@test "quoted scalar with col-0 hash keeps YAML meaning intact [regression]" {
  # A frontmatter file with a double-quoted scalar whose continuation line
  # starts with # at column 0.  YAML treats this as part of the string
  # value (not a comment) because it is inside a quoted scalar.  The fast
  # path must preserve the true YAML meaning: alice has tags: [design]
  # and must be required.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: note is a multi-line double-quoted scalar with a col-0 '#'
  # continuation line.  The true YAML has tags: [design] as a top-level key.
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
note: "a
#"
tags: [design]
z: " # "
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # Both alice (design-tagged) and bob (ux-tagged) must be required.
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "expected exact missing list 'alice bob': $output"
}

# =========================================================================
# quoted scalar wrapping tags key does not create false tag [regression]
# =========================================================================

@test "quoted scalar wrapping tags key does not create false tag [regression]" {
  # alice.md has a double-quoted scalar that spans multiple lines and
  # visually contains 'tags: [design]' — but that text is INSIDE the
  # quoted scalar value, NOT a real YAML key.  The true YAML has no tags
  # key, so alice must NOT be required.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: the string value of 'm' wraps across lines and contains
  # text that looks like 'tags: [design]'.  The true YAML has no tags.
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
n: "a
#"
m: "
tags: [design]
"
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice must NOT be required (her tags key does not exist in true YAML).
  # bob IS required (ux-tagged).
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob' only: $output"
}

# =========================================================================
# backslash-bearing filename resolves in fallback path [regression]
# =========================================================================

@test "backslash-bearing filename resolves in fallback path [regression]" {
  # A stakeholder file whose path contains a backslash tests the fallback
  # awk's use of ENVIRON instead of -v (which interprets backslash escapes).
  # Without the ENVIRON approach, awk -v file='a\b' would silently corrupt
  # the filename, causing the frontmatter extraction to silently fail.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # bob has a backslash in filename — must resolve correctly in fallback.
  # tags: [design] so it MUST be required; if the fallback corrupts the
  # filename (awk -v interprets backslash escapes), the file is silently
  # lost and the missing list changes.
  local bsname='bo\b'
  _mk_stakeholder "$roster_dir" "alice" "[design]"
  printf '%s\n' "---" "tags: [design]" "---" > "$roster_dir/${bsname}.md"

  # Force fallback via a malformed sibling
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice must be in the missing list
  [[ "$output" == *"alice"* ]] \
    || fail "alice should be in missing list: $output"
  [[ "$output" == *"not-converged"* ]] \
    || fail "should be not-converged: $output"
  # The backslash file must resolve — its stem must appear in "missing:".
  # With awk -v, the backslash is interpreted and the file is silently
  # dropped (malformed-frontmatter warning), so it never reaches the
  # required list — but the warning still mentions the filename.
  # Assert the stem appears specifically in the missing: line, not just
  # anywhere in the output (where a warning would also match).
  local missing_line
  missing_line="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$missing_line" == *'bo\b'* ]] \
    || fail "backslash-bearing file must be in missing list (not just a warning): missing_line='$missing_line' output='$output'"
  # Must not crash or produce empty output
  [[ "$output" != *"vacuous"* ]] \
    || fail "should not be vacuous when valid stakeholders exist: $output"
}

# =========================================================================
# reserved-prefix check fires independently of duplicate-index guard [regression]
# =========================================================================

@test "reserved-prefix check fires independently of duplicate-index guard [regression]" {
  # The reserved-prefix check in awk1 forces fallback independently of
  # the awk3 duplicate-index guard.  The forged line uses index 99 (no
  # collision in awk3's fmap), so only the prefix check catches this.
  #
  # Detection: the sentinel triggers the fallback BEFORE the fast-path
  # yq call (which contains _gaia_rix).  So _yq_roster_count==0 proves
  # the sentinel fired and diverted to per-file resolution early.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  _mk_stakeholder "$roster_dir" "alice" "[design]"

  # zed.md: frontmatter contains a line with the reserved prefix and an
  # unused index (99) — no collision in awk3's fmap, so only the prefix
  # check can catch this.
  local tab=$'\t'
  cat > "$roster_dir/zed.md" <<STAKE
---
slug: zed
tags: [other]
#GAIAMAP:99${tab}/dev/null
---
STAKE

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # The sentinel must divert to fallback BEFORE the fast-path yq call.
  # _yq_roster_count==0 proves early diversion.
  local yqr
  yqr="$(_yq_roster_count)"
  [ "$yqr" -eq 0 ] \
    || fail "expected sentinel-triggered fallback (0 roster yq calls), got yqr=$yqr — prefix check did not fire"

  # The yq shim must have been active (at least one yq call was logged).
  # This guards against vacuous 0-roster-call pass when shims are not on PATH.
  local yq_total
  yq_total="$(_shim_count yq)"
  [ "$yq_total" -gt 0 ] \
    || fail "yq shim was not active — shim count is 0, test is vacuous"

  # Result must still be correct
  [[ "$output" == *"not-converged (missing: alice)"* ]] \
    || fail "expected exact missing list 'alice': $output"
}

# =========================================================================
# duplicate map index in awk3 input triggers fallback independently [regression]
# =========================================================================

@test "duplicate map index in awk3 input triggers fallback independently [regression]" {
  # Unit-level test for the duplicate-index guard in awk3.  Feeds crafted
  # input directly to the awk3 program extracted from the script, so no
  # other defence (prefix check, yq error, etc.) can mask the result.
  #
  # Input: two map lines with the SAME index (0), then a valid yq row
  # referencing index 0.  The awk3 guard must detect the duplicate map
  # index and exit 2 (fallback signal).  Without the ($1 in fmap) check,
  # the second map line silently overwrites the first and awk3 exits 0.
  [ -x "$SCRIPT" ] || fail "script not found"

  # Extract the awk3 program from the script source.  It starts with
  # the line matching 'NF == 2 && $1 ~ /^[0-9]+$/' and ends with the
  # line matching 'END { if (fallback) exit 2 }'.
  local awk3_prog
  awk3_prog="$("$REAL_SED" -n '/NF == 2 && \$1 ~ \/\^/,/END.*exit 2/p' "$SCRIPT")"
  [ -n "$awk3_prog" ] \
    || fail "could not extract awk3 program from script"

  # Crafted input: map section with duplicate index 0, then a yq row.
  # Tab-separated: map lines are "index\tpath", yq lines are "slug\ttags\trix".
  local tab=$'\t'
  local input
  input="0${tab}/path/to/alice.md
0${tab}/path/to/mallory.md
alice${tab}design${tab}0"

  local rc=0
  printf '%s\n' "$input" | awk -F'\t' "$awk3_prog" 2>/dev/null || rc=$?

  [ "$rc" -eq 2 ] \
    || fail "awk3 should exit 2 on duplicate map index, got rc=$rc"
}

# =========================================================================
# design-tagged stakeholder with user index key is required on fast path [regression]
# =========================================================================

@test "design-tagged stakeholder with user index key is required on fast path [regression]" {
  # A design-tagged stakeholder whose frontmatter contains a user-authored
  # _gaia_rix key must still be required.  yq last-wins: the pipeline's
  # injected index (always the last key) overwrites the user's value.
  # If the old strip logic were restored and removed the frontmatter line,
  # the file would lose its tags line (wrong) or the index would be wrong.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice: design-tagged, with a user-authored _gaia_rix
  cat > "$roster_dir/alice.md" <<'EOF'
---
slug: alice
tags: [design]
_gaia_rix: 999
---
EOF

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # Fast path: exactly 1 roster yq call
  local yqr
  yqr="$(_yq_roster_count)"
  [ "$yqr" -eq 1 ] \
    || fail "expected fast path (1 roster yq call), got roster_yq=$yqr"

  # alice (design) and bob (ux) must both be required
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "expected exact missing list 'alice bob': $output"
}

# =========================================================================
# untagged stakeholder with user index key stays untagged on fast path [regression]
# =========================================================================

@test "untagged stakeholder with user index key stays untagged on fast path [regression]" {
  # An untagged stakeholder with a user-authored _gaia_rix must NOT become
  # required.  The user's _gaia_rix value is overwritten by the pipeline's
  # injected index (yq last-wins), so the file resolves correctly — but
  # it must NOT gain tags it does not have.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  # zed: untagged, with a user-authored _gaia_rix
  cat > "$roster_dir/zed.md" <<'EOF'
---
slug: zed
tags: [other]
_gaia_rix: 0
---
EOF

  _mk_stakeholder "$roster_dir" "alice" "[design]"

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # Fast path: exactly 1 roster yq call
  local yqr
  yqr="$(_yq_roster_count)"
  [ "$yqr" -eq 1 ] \
    || fail "expected fast path (1 roster yq call), got roster_yq=$yqr"

  # Only alice is required; zed must NOT appear in the missing list
  [[ "$output" == *"not-converged (missing: alice)"* ]] \
    || fail "expected exact missing list 'alice' only: $output"
}

# =========================================================================
# NUL-prefixed reserved map prefix detected and forces fallback [regression]
# =========================================================================

@test "NUL-prefixed reserved map prefix produces correct roster [regression]" {
  # Under Linux mawk, a NUL byte (\0) before #GAIAMAP: defeats the
  # anchored /^#GAIAMAP:/ check.  The unanchored index(line, "#GAIAMAP:")
  # catches it when awk passes the NUL through (mawk, gawk with --posix).
  #
  # On macOS default awk (nawk), NUL terminates C strings, so awk sees an
  # empty line — the prefix is invisible and the fallback does not fire.
  # Either way the roster must produce the correct result: alice required,
  # zed not required.  The fallback-trigger assertion is platform-specific.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  _mk_stakeholder "$roster_dir" "alice" "[design]"

  # zed.md: frontmatter contains a NUL-prefixed #GAIAMAP: line.
  local tab=$'\t'
  {
    printf '%s\n' "---"
    printf 'slug: zed\n'
    printf 'tags: [other]\n'
    printf '\0#GAIAMAP:0%s/dev/null\n' "$tab"
    printf '%s\n' "---"
  } > "$roster_dir/zed.md"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence

  # Regardless of platform, alice must be the only required stakeholder
  [[ "$output" == *"not-converged (missing: alice)"* ]] \
    || fail "expected exact missing list 'alice': $output"
}

# =========================================================================
# mid-line reserved prefix inside quoted scalar forces fallback [regression]
# =========================================================================

@test "mid-line reserved prefix inside quoted scalar forces fallback [regression]" {
  # A frontmatter line like `note: "x #GAIAMAP:"` contains the reserved
  # prefix mid-line inside a quoted scalar.  The unanchored index() check
  # catches it and forces the safe fallback.  In the fallback, the file
  # resolves correctly because the true YAML is parsed by yq, and
  # `#GAIAMAP:` is just part of a string value.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  _mk_stakeholder "$roster_dir" "alice" "[design]"

  # zed.md: the reserved prefix appears inside a quoted scalar value
  cat > "$roster_dir/zed.md" <<'STAKE'
---
slug: zed
tags: [other]
note: "x #GAIAMAP:0	/dev/null"
---
STAKE

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"
  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # The prefix check must fire and divert to fallback (0 roster yq calls)
  local yqr
  yqr="$(_yq_roster_count)"
  [ "$yqr" -eq 0 ] \
    || fail "expected sentinel-triggered fallback (0 roster yq calls), got yqr=$yqr"

  # Both alice (design) and zed (other, resolves in fallback) must be in output.
  # Only alice is required.
  [[ "$output" == *"not-converged (missing: alice)"* ]] \
    || fail "expected exact missing list 'alice': $output"
}

# =========================================================================
# tab-bearing slug in fallback still resolves correctly [regression]
# =========================================================================

@test "tab-bearing slug in fallback still resolves correctly [regression]" {
  # A stakeholder file with slug: "ali\tce" (YAML escaped tab).  yq
  # decodes the tab and sub("\t","") strips it, producing "alice".  But
  # that does NOT match the stem "alice" (the filename has no tab) unless
  # the stem is also "alice".  So slug "ali\tce" → sanitized "alice"
  # should match filename alice.md and the stakeholder is required.
  # Without the tab-strip, the decoded tab stays in the slug and the
  # slug-vs-stem check would fail — dropping alice from the roster.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md with a tab-bearing slug that sanitizes to "alice"
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: "ali\tce"
tags: [design]
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Force fallback via a malformed sibling
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # In the fallback: yq decodes the slug to a literal tab character,
  # sub("\t","") strips it → "alice", which matches the stem.
  # alice is design-tagged and required; bob is ux-tagged and required.
  [[ "$output" == *"not-converged"* ]] \
    || fail "expected not-converged: $output"
  local missing_line
  missing_line="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$missing_line" == *"alice"* ]] \
    || fail "alice should be required (tab-bearing slug sanitized): $output"
  [[ "$missing_line" == *"bob"* ]] \
    || fail "bob should be required: $output"
}

# =========================================================================
# tab-bearing slug on fast path resolves correctly [regression]
# =========================================================================

@test "tab-bearing slug on fast path resolves correctly [regression]" {
  # Same fixture as the fallback variant, but tested on the fast path
  # (no malformed sibling).  Without the tab-strip on the fast-path slug,
  # the decoded tab stays in the slug and the slug-vs-stem check fails,
  # dropping alice from the roster.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: "ali\tce"
tags: [design]
---
STAKE
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "fast path: expected exact missing list 'alice bob': $output"
}

# =========================================================================
# newline-bearing slug on fast path does not forge a roster row [regression]
# =========================================================================

@test "newline-bearing slug on fast path does not forge a roster row [regression]" {
  # A stakeholder file with slug: "x\nalice" (YAML escaped newline).
  # Without per-slug stripping, the decoded newline could create a second
  # line in the tab-delimited output, forging an "alice" roster entry
  # that satisfies convergence.  After sub("\n",""), the slug becomes
  # "xalice", which matches the stem — so it resolves as "xalice".
  # Both xalice and alice are design-tagged and required.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # xalice.md: slug "x\nalice" sanitizes to "xalice" — matches stem
  cat > "$roster_dir/xalice.md" <<'STAKE'
---
slug: "x\nalice"
tags: [design]
---
STAKE

  # Real alice.md — design-tagged, SHOULD be required
  _mk_stakeholder "$roster_dir" "alice" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # Both alice and xalice are design-tagged and required.
  # The newline strip must NOT forge a second "alice" row from "x\nalice".
  [[ "$output" == *"not-converged (missing: alice xalice)"* ]] \
    || fail "expected exact missing list 'alice xalice': $output"
}

# =========================================================================
# CR-bearing slug sanitized on both paths [regression]
# =========================================================================

@test "CR-bearing slug sanitized on both paths [regression]" {
  # A stakeholder file with slug: "alice\r" (YAML escaped CR).
  # sub("\r","") strips the CR, producing "alice" which matches the stem.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md with CR-bearing slug
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: "alice\r"
tags: [design]
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Fast path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "fast path: expected exact missing list 'alice bob': $output"

  # Fallback path (force via malformed sibling)
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  local missing_line
  missing_line="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$missing_line" == *"alice"* ]] \
    || fail "fallback: alice should be in missing: $output"
  [[ "$missing_line" == *"bob"* ]] \
    || fail "fallback: bob should be in missing: $output"
}

# =========================================================================
# narrowed document marker: ---x inside quoted scalar not refused [regression]
# =========================================================================

@test "narrowed document marker: ---x inside quoted scalar not refused [regression]" {
  # The fallback's document-marker check rejects frontmatter with a real
  # YAML document marker (--- or ... followed by whitespace or EOL).
  # A line like "---x" inside a quoted scalar is NOT a real marker and
  # must NOT be refused.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: has "---x" inside frontmatter (not a real document marker).
  # This is valid YAML (it's a key "---x").  The narrowed regex
  # /^(---|\.\.\.)([ \t]|$)/ must NOT match it.
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
tags: [design]
---x: value
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Force fallback via malformed sibling
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice must resolve (not refused as malformed); both are required
  local missing_line
  missing_line="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$missing_line" == *"alice"* ]] \
    || fail "alice should resolve (---x is not a real marker): $output"
  [[ "$missing_line" == *"bob"* ]] \
    || fail "bob should resolve: $output"
  # Must NOT produce a malformed diagnostic for alice
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "alice must NOT be malformed (---x is not a real marker): $output"
}

# =========================================================================
# both paths agree for design-tagged stakeholder with user index key [regression]
# =========================================================================

@test "both paths agree for design-tagged stakeholder with user index key [regression]" {
  # Verifies that the fast path and fallback path produce identical results
  # for a design-tagged stakeholder whose frontmatter contains a user-
  # authored _gaia_rix key.  The fast path relies on yq last-wins; the
  # fallback ignores the key entirely (yq parses the file individually).
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice: design-tagged, with user _gaia_rix
  cat > "$roster_dir/alice.md" <<'EOF'
---
slug: alice
tags: [design]
_gaia_rix: 999
---
EOF

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Fast path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  local fast_missing
  fast_missing="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"

  # Force fallback via malformed sibling
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  local fb_missing
  fb_missing="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"

  # Both paths must agree
  [[ "$fast_missing" == *"alice"* ]] \
    || fail "fast path: alice should be required: $fast_missing"
  [[ "$fb_missing" == *"alice"* ]] \
    || fail "fallback: alice should be required: $fb_missing"
  [[ "$fast_missing" == *"bob"* ]] \
    || fail "fast path: bob should be required: $fast_missing"
  [[ "$fb_missing" == *"bob"* ]] \
    || fail "fallback: bob should be required: $fb_missing"
}

# =========================================================================
# NEL-based document separator refused by yq in fallback [regression]
# =========================================================================

@test "NEL-based document separator refused by yq in fallback [regression]" {
  # YAML Next Line (NEL) (U+0085, \xC2\x85) after --- starts a new document
  # in yq.  The fallback must detect the second document and refuse the file.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: NEL after --- creates a phantom second document
  printf -- '---\nslug: alice\ntags: [design]\n---\xc2\x85\ntags: [mallory]\n---\n' \
    > "$roster_dir/alice.md"
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Force fallback via a malformed sibling
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice must be refused (multi-doc); bob is the only required stakeholder
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice (NEL separator): $output"
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob': $output"

  # The phantom 'mallory' must not be a known stakeholder
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder mallory --recorded-by t
  [ "$status" -ne 0 ] || fail "phantom 'mallory' should be refused: $output"
  [[ "$output" == *"unknown stakeholder"* ]] \
    || fail "expected 'unknown stakeholder' for phantom 'mallory': $output"
}

# =========================================================================
# LS-based document separator refused by yq in fallback [regression]
# =========================================================================

@test "LS-based document separator refused by yq in fallback [regression]" {
  # YAML Line Separator (U+2028, \xE2\x80\xA8) after --- starts a new
  # document in yq.  The fallback must detect it and refuse the file.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  printf -- '---\nslug: alice\ntags: [design]\n---\xe2\x80\xa8\ntags: [mallory]\n---\n' \
    > "$roster_dir/alice.md"
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice (LS separator): $output"
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob': $output"
}

# =========================================================================
# PS-based document separator refused by yq in fallback [regression]
# =========================================================================

@test "PS-based document separator refused by yq in fallback [regression]" {
  # YAML Paragraph Separator (U+2029, \xE2\x80\xA9) after --- starts a
  # new document in yq.  The fallback must detect it and refuse the file.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  printf -- '---\nslug: alice\ntags: [design]\n---\xe2\x80\xa9\ntags: [mallory]\n---\n' \
    > "$roster_dir/alice.md"
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice (PS separator): $output"
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob': $output"
}

# =========================================================================
# mid-line CR then --- creates phantom document, refused in fallback [regression]
# =========================================================================

@test "mid-line CR then --- creates phantom document, refused in fallback [regression]" {
  # A file with slug: alice\r---\rtags: [mallory] creates a phantom
  # second document via the CR-embedded separator.  The fallback must
  # detect the multi-document content and refuse the file.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  printf -- "---\nslug: alice\r---\rtags: [mallory]\n---\n" \
    > "$roster_dir/alice.md"
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice must be refused (multi-doc via CR separator); bob is required
  [[ "$output" == *"malformed"*"alice.md"* ]] \
    || fail "expected malformed diagnostic for alice (CR separator): $output"
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "expected exact missing list 'bob': $output"
}

# =========================================================================
# lone trailing ... accepted as valid single-document YAML [regression]
# =========================================================================

@test "lone trailing ... accepted as valid single-document YAML [regression]" {
  # A YAML document end marker (...) at the end of frontmatter is valid
  # single-document YAML.  It must NOT be refused as multi-doc.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: valid frontmatter with a trailing ... (document end)
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
tags: [design]
...
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Fast path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "fast path: expected exact missing list 'alice bob': $output"
  [[ "$output" != *"malformed"* ]] \
    || fail "fast path: alice must NOT be malformed (lone ... is valid): $output"

  # Fallback path
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  local missing_line
  missing_line="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$missing_line" == *"alice"* ]] \
    || fail "fallback: alice must resolve (lone ... is valid): $output"
  [[ "$missing_line" == *"bob"* ]] \
    || fail "fallback: bob must resolve: $output"
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "fallback: alice must NOT be malformed (lone ... is valid): $output"
}

# =========================================================================
# newline-bearing slug exact match on both paths [regression]
# =========================================================================

@test "newline-bearing slug exact match on both paths [regression]" {
  # slug: "ali\nce" (YAML escaped newline) on alice.md.  yq decodes the
  # newline and sub("\n","") strips it, producing "alice" which matches
  # the stem.  Both paths must agree: missing: alice bob.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: "ali\nce"
tags: [design]
---
STAKE
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Fast path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "fast path: expected exact missing list 'alice bob': $output"

  # Fallback path
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "fallback: expected exact missing list 'alice bob': $output"
}

# =========================================================================
# split file re-declaring stakeholder untagged does not drop design tag [regression]
# =========================================================================

@test "split file re-declaring stakeholder untagged does not drop design tag [regression]" {
  # a0.md has a YAML document split: the second half re-declares alice
  # with empty tags and a user-authored index pointing at alice's slot.
  # The multi-doc content must be refused; alice's design tag from her
  # own file must survive.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # a0.md: split frontmatter — second half has alice's slug untagged
  printf -- '---\nslug: alice\ntags: []\n_gaia_rix: 1\n--- \nslug: a0\n---\n' \
    > "$roster_dir/a0.md"
  _mk_stakeholder "$roster_dir" "alice" "[design]"
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # a0 is malformed (multi-doc); alice (design) and bob (ux) are required
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "expected exact missing list 'alice bob': $output"
}

# =========================================================================
# split file with user index 99 refused, approve fails [regression]
# =========================================================================

@test "split file with user index 99 refused, approve fails [regression]" {
  # zed.md has a split frontmatter where the first half carries a
  # user-authored _gaia_rix of 99.  The multi-doc content must be
  # refused, and approving zed must fail.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  _mk_stakeholder "$roster_dir" "alice" "[design]"
  printf -- '---\ntags: [design]\n_gaia_rix: 99\n--- \nslug: zed\n---\n' \
    > "$roster_dir/zed.md"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # zed is malformed (multi-doc); alice is required
  [[ "$output" == *"not-converged (missing: alice)"* ]] \
    || fail "expected exact missing list 'alice': $output"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder zed --recorded-by t
  [ "$status" -ne 0 ] || fail "approving zed should fail (malformed file): $output"
  [[ "$output" == *"unknown stakeholder"* ]] \
    || fail "expected 'unknown stakeholder' for zed: $output"
}

# =========================================================================
# quoted scalar with _gaia_rix inside string value resolves correctly [regression]
# =========================================================================

@test "quoted scalar with _gaia_rix inside string value resolves correctly [regression]" {
  # alice.md has a double-quoted scalar whose value contains the text
  # "_gaia_rix: " — but that text is INSIDE a quoted string, not a real
  # YAML key.  alice's design tag must survive and she must be required.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: _gaia_rix appears as text inside a quoted scalar value
  cat > "$roster_dir/alice.md" <<'STAKE'
---
slug: alice
notes: "x
_gaia_rix: "
tags: [design]
other: "
_gaia_rix: "
---
STAKE
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  # Fast path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged (missing: alice bob)"* ]] \
    || fail "fast path: expected exact missing list 'alice bob': $output"

  # Fallback path
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  local missing_line
  missing_line="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$missing_line" == *"alice"* ]] \
    || fail "fallback: alice should be required: $output"
  [[ "$missing_line" == *"bob"* ]] \
    || fail "fallback: bob should be required: $output"
}

# =========================================================================
# NEL second document hides design-tagged stakeholder, transition blocked [regression]
# =========================================================================

@test "NEL second document hides design-tagged stakeholder, transition blocked [regression]" {
  # alice.md has a NEL-marked second document whose tags field names
  # mallory.  mallory.md is design-tagged and required.  If the NEL
  # second document is not refused, the phantom could hide mallory's
  # requirement and let transition reach approved without her.
  [ -x "$SCRIPT" ] || fail "script not found"

  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: NEL-marked second document with tags: [mallory]
  printf -- '---\nslug: alice\n---\xc2\x85\ntags: [mallory]\n---\n' \
    > "$roster_dir/alice.md"
  _mk_stakeholder "$roster_dir" "mallory" "[design]"
  _mk_stakeholder "$roster_dir" "bob" "[ux]"

  _init_and_transition_to_review

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # alice must be malformed; mallory and bob are required
  [[ "$output" == *"not-converged (missing: bob mallory)"* ]] \
    || fail "expected exact missing list 'bob mallory': $output"

  # Approve bob only — mallory still missing
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder bob --recorded-by t >/dev/null 2>&1
  # Transition to approved must fail (mallory not approved)
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" transition --to approved --actor t
  [ "$status" -ne 0 ] || fail "transition should fail (mallory not approved): $output"
  [[ "$output" == *"not-converged"*"mallory"* ]] \
    || fail "expected convergence failure mentioning mallory: $output"
}

# =========================================================================
# empty frontmatter (--- then ---) accepted on both paths [regression]
# =========================================================================

@test "empty frontmatter (--- then ---) accepted on both paths [regression]" {
  # A stakeholder file with empty frontmatter (opening and closing ---
  # with nothing in between) is valid: slug falls back to the filename,
  # no tags.  Both the fast path and fallback must accept it and produce
  # the same result.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: empty frontmatter
  cat > "$roster_dir/alice.md" <<'STAKE'
---
---
STAKE

  # bob: design-tagged, will be required
  _mk_stakeholder "$roster_dir" "bob" "[design]"

  # ---- Fast path ----
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "fast: expected non-zero exit (not-converged): $output"
  # alice has no tags, so only bob is required and missing
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "fast: expected exact missing list 'bob': $output"
  # alice must NOT be malformed
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "fast: alice must not be malformed: $output"

  # Approve bob on fast path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder bob --recorded-by t
  [ "$status" -eq 0 ] \
    || fail "fast: approving bob should succeed: $output"

  # Reset approvals
  _seed_record "review" 1

  # ---- Fallback path (via malformed sibling) ----
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "fallback: expected non-zero exit: $output"
  local fb_missing
  fb_missing="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$fb_missing" == *"bob"* ]] \
    || fail "fallback: bob should be in missing list: $fb_missing output=$output"
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "fallback: alice must not be malformed: $output"

  # Approve bob on fallback path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder bob --recorded-by t
  [ "$status" -eq 0 ] \
    || fail "fallback: approving bob should succeed: $output"
}

# =========================================================================
# blank-lines-only frontmatter accepted on both paths [regression]
# =========================================================================

@test "blank-lines-only frontmatter accepted on both paths [regression]" {
  # A stakeholder file with only blank lines between --- and --- is valid:
  # slug falls back to the filename, no tags.  Both paths must accept it.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: blank lines only between markers
  cat > "$roster_dir/alice.md" <<'STAKE'
---

---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  # ---- Fast path ----
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "fast: expected non-zero exit (not-converged): $output"
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "fast: expected exact missing list 'bob': $output"
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "fast: alice must not be malformed: $output"

  # Approve bob on fast path
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder bob --recorded-by t
  [ "$status" -eq 0 ] \
    || fail "fast: approving bob should succeed: $output"

  _seed_record "review" 1

  # ---- Fallback path ----
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "fallback: expected non-zero exit: $output"
  local fb_missing
  fb_missing="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$fb_missing" == *"bob"* ]] \
    || fail "fallback: bob should be in missing list: $fb_missing output=$output"
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "fallback: alice must not be malformed: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder bob --recorded-by t
  [ "$status" -eq 0 ] \
    || fail "fallback: approving bob should succeed: $output"
}

# =========================================================================
# comment-only frontmatter accepted on both paths [regression]
# =========================================================================

@test "comment-only frontmatter accepted on both paths [regression]" {
  # A stakeholder file with only a YAML comment between --- and --- is
  # valid: slug falls back to the filename, no tags.  Both paths must
  # accept it and produce the same result.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice.md: comment-only frontmatter
  cat > "$roster_dir/alice.md" <<'STAKE'
---
# c
---
STAKE

  _mk_stakeholder "$roster_dir" "bob" "[design]"

  # ---- Fast path ----
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "fast: expected non-zero exit (not-converged): $output"
  [[ "$output" == *"not-converged (missing: bob)"* ]] \
    || fail "fast: expected exact missing list 'bob': $output"
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "fast: alice must not be malformed: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder bob --recorded-by t
  [ "$status" -eq 0 ] \
    || fail "fast: approving bob should succeed: $output"

  _seed_record "review" 1

  # ---- Fallback path ----
  _mk_stakeholder_raw "$roster_dir" "zzz.md" \
    "---
slug: [unclosed
---"
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "fallback: expected non-zero exit: $output"
  local fb_missing
  fb_missing="$(printf '%s\n' "$output" | "$REAL_GREP" 'missing:' || true)"
  [[ "$fb_missing" == *"bob"* ]] \
    || fail "fallback: bob should be in missing list: $fb_missing output=$output"
  [[ "$output" != *"malformed"*"alice.md"* ]] \
    || fail "fallback: alice must not be malformed: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve --stakeholder bob --recorded-by t
  [ "$status" -eq 0 ] \
    || fail "fallback: approving bob should succeed: $output"
}

# =========================================================================
# symlinked roster file prints diagnostic but must also fail the check
# =========================================================================

@test "symlinked roster file prints diagnostic but must also fail the check" {
  # When a symlinked roster FILE is present alongside other approved
  # stakeholders, resolution must fail — never fall through to "converged".
  # Without the return-1, the diagnostic prints but resolution continues,
  # and an attacker-controlled file can land approvals that bypass the gate.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"

  # alice: a real stakeholder who has approved
  _mk_stakeholder "$roster_dir" "alice" "[design]"
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve \
    --stakeholder alice --recorded-by test >/dev/null 2>&1

  # evil: symlinked roster file pointing at an external target
  local target_dir="$BATS_TEST_TMPDIR/evil-file-target"
  mkdir -p "$target_dir"
  _mk_stakeholder "$target_dir" "evil" "[design]"
  ln -s "$target_dir/evil.md" "$roster_dir/evil.md"

  # Check-convergence must fail
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "check-convergence must fail on symlinked roster file"
  [[ "$output" != *"converged"* ]] || [[ "$output" == *"not-converged"* ]] \
    || fail "must not say converged: $output"
  [[ "$output" == *"refusing symlinked roster file"* ]] \
    || fail "expected symlink refusal diagnostic: $output"

  # Transition to approved must also fail
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" transition --to approved --actor test
  [ "$status" -ne 0 ] || fail "transition to approved must fail"

  # design_state must remain review
  local state
  state="$(yq '.design_state' "$RECORD")"
  [ "$state" = "review" ] || fail "design_state should remain review, got: $state"
}

# =========================================================================
# symlinked roster directory skipped must still fail resolution
# =========================================================================

@test "symlinked roster directory skipped must still fail resolution" {
  # When the higher-precedence roster directory is a symlink, resolution
  # must fail — not silently skip it and fall back to the lower-precedence
  # custom/stakeholders directory, which would allow convergence via the
  # lower-precedence roster alone.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # Lower-precedence directory: alice is the sole required stakeholder, approved
  local lower_dir="$TEST_TMP/custom/stakeholders"
  _mk_stakeholder "$lower_dir" "alice" "[design]"
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve \
    --stakeholder alice --recorded-by test >/dev/null 2>&1

  # Higher-precedence directory: a symlink (the attacked surface)
  local target="$BATS_TEST_TMPDIR/evil-dir-target"
  mkdir -p "$target"
  _mk_stakeholder "$target" "mallory" "[design]"
  mkdir -p "$TEST_TMP/.gaia/custom"
  ln -s "$target" "$TEST_TMP/.gaia/custom/stakeholders"

  # Check-convergence must fail (not converge via the lower-precedence dir alone)
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "must fail on symlinked higher-precedence roster dir"
  [[ "$output" != *"converged"* ]] || [[ "$output" == *"not-converged"* ]] \
    || fail "must not say converged: $output"
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "expected symlink refusal diagnostic: $output"

  # Transition to approved must also fail
  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" transition --to approved --actor test
  [ "$status" -ne 0 ] || fail "transition to approved must fail"

  local state
  state="$(yq '.design_state' "$RECORD")"
  [ "$state" = "review" ] || fail "design_state should remain review, got: $state"
}

# =========================================================================
# symlinked parent component must also fail the check
# =========================================================================

@test "symlinked parent component must also fail the check" {
  # When a parent component (.gaia/custom) is a symlink, resolution must
  # fail even when an unsymlinked custom/stakeholders directory with all
  # approved stakeholders exists.  The symlinked higher-precedence dir
  # contains no extra stakeholders — just the same alice — so that if
  # the parent check is broken and fallback to the lower-precedence dir
  # occurs, convergence would incorrectly succeed.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  # Lower-precedence directory: alice is the sole required stakeholder, approved
  local lower_dir="$TEST_TMP/custom/stakeholders"
  _mk_stakeholder "$lower_dir" "alice" "[design]"
  env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve \
    --stakeholder alice --recorded-by test >/dev/null 2>&1

  # .gaia/custom is a symlink — parent component attack
  # Target also has alice (same slug) so dedup won't add a new required stakeholder
  local target="$BATS_TEST_TMPDIR/evil-parent"
  mkdir -p "$target/stakeholders"
  _mk_stakeholder "$target/stakeholders" "alice" "[design]"
  rm -rf "$TEST_TMP/.gaia/custom"
  mkdir -p "$TEST_TMP/.gaia"
  ln -s "$target" "$TEST_TMP/.gaia/custom"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "must fail on symlinked parent component"
  [[ "$output" != *"converged"* ]] || [[ "$output" == *"not-converged"* ]] \
    || fail "must not say converged: $output"
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "expected symlink refusal diagnostic: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" transition --to approved --actor test
  [ "$status" -ne 0 ] || fail "transition to approved must fail"

  local state
  state="$(yq '.design_state' "$RECORD")"
  [ "$state" = "review" ] || fail "design_state should remain review, got: $state"
}

# =========================================================================
# empty roster directory resolves with zero stakeholders and no diagnostic
# =========================================================================

@test "empty roster directory resolves with zero stakeholders and no diagnostic" {
  # An existing but empty roster directory must return success (rc 0),
  # produce an empty roster, and print no diagnostic or warning.
  # The check-convergence test for this case (vacuous, rc 1) already exists;
  # this tests resolution itself.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  mkdir -p "$TEST_TMP/custom/stakeholders"
  # No .md files inside

  # Source the script and call _resolve_merged_roster_impl directly
  local out rc=0
  out="$(env PROJECT_ROOT="$TEST_TMP" bash -c '
    source "'"$SCRIPT"'"
    _resolve_merged_roster_impl
  ' 2>"$BATS_TEST_TMPDIR/empty-roster-stderr")" || rc=$?

  [ "$rc" -eq 0 ] || fail "resolution of empty roster should return 0, got rc=$rc"
  [ -z "$out" ] || fail "resolution of empty roster should be empty, got: $out"

  local stderr_out
  stderr_out="$(cat "$BATS_TEST_TMPDIR/empty-roster-stderr")"
  [ -z "$stderr_out" ] || fail "empty roster should produce no diagnostic, got: $stderr_out"
}

# =========================================================================
# space-in-stem assertion rejects plain alice match
# =========================================================================

@test "space-in-stem assertion rejects plain alice match" {
  # The original test for space-in-stem checked for *"alice"* which also
  # matches "alice review". This test asserts the exact roster so that
  # dropping "alice" (the plain entry) fails.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"
  _mk_stakeholder "$roster_dir" "alice" "[design]"
  _mk_stakeholder_no_slug "$roster_dir" "alice review.md" "[design]"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" check-convergence
  # Both alice and "alice review" must be in the missing list
  local missing_line
  missing_line="$(printf '%s\n' "$output" | "$REAL_GREP" 'not-converged' || true)"
  # The missing line must contain both. "alice review" contains "alice" so
  # a test for just *alice* is vacuous.  Assert that removing "alice review"
  # from the line still leaves a standalone "alice" mention.
  local after_removing_compound
  after_removing_compound="$(printf '%s' "$missing_line" | "$REAL_SED" 's/alice review//g')"
  [[ "$after_removing_compound" == *"alice"* ]] \
    || fail "plain 'alice' must appear independently in the missing line: $missing_line"
  [[ "$missing_line" == *"alice review"* ]] \
    || fail "'alice review' must appear in the missing line: $missing_line"
}

# =========================================================================
# duplicate-index unit test with positive control
# =========================================================================

@test "duplicate-index unit test with positive control" {
  # The awk3 program extracted from the script must (a) work correctly on
  # valid non-duplicate input and (b) exit 2 on duplicate map indices.
  # Without the positive control, a broken extraction (syntax error) would
  # also exit non-zero and the test would pass vacuously.
  [ -x "$SCRIPT" ] || fail "script not found"

  local awk3_prog
  awk3_prog="$("$REAL_SED" -n '/NF == 2 && \$1 ~ \/\^/,/END.*exit 2/p' "$SCRIPT")"
  [ -n "$awk3_prog" ] || fail "could not extract awk3 program from script"

  local tab=$'\t'

  # Positive control: valid (non-duplicate) input gives rc 0 and the expected row
  local valid_input valid_out valid_rc=0
  valid_input="0${tab}/path/alice.md
alice${tab}design${tab}0"
  valid_out="$(printf '%s\n' "$valid_input" | awk -F'\t' "$awk3_prog" 2>"$BATS_TEST_TMPDIR/awk3-pos-stderr")" || valid_rc=$?
  [ "$valid_rc" -eq 0 ] \
    || fail "awk3 must exit 0 on valid input, got rc=$valid_rc"
  [[ "$valid_out" == "alice${tab}/path/alice.md${tab}design" ]] \
    || fail "awk3 positive control output wrong: got '$valid_out'"

  local pos_stderr
  pos_stderr="$(cat "$BATS_TEST_TMPDIR/awk3-pos-stderr")"
  [ -z "$pos_stderr" ] || fail "awk3 should produce no stderr on valid input, got: $pos_stderr"

  # Negative control: duplicate map index → exit 2
  local dup_input dup_rc=0
  dup_input="0${tab}/path/alice.md
0${tab}/path/mallory.md
alice${tab}design${tab}0"
  printf '%s\n' "$dup_input" | awk -F'\t' "$awk3_prog" >/dev/null 2>&1 || dup_rc=$?
  [ "$dup_rc" -eq 2 ] \
    || fail "awk3 should exit 2 on duplicate map index, got rc=$dup_rc"
}

# =========================================================================
# non-YAML body resolves via the fast path with exact output
# =========================================================================

@test "non-YAML body resolves via the fast path with exact output" {
  # Tightens the existing non-YAML body test: asserts the fast path (one
  # roster yq call) and the exact "not-converged (missing: eve frank)" line.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1
  local roster_dir="$TEST_TMP/custom/stakeholders"

  _mk_stakeholder "$roster_dir" "dan" "[other]"
  _mk_stakeholder "$roster_dir" "eve" "[design]" \
    "Note: Eve reviews tokens.
Also she reviews more."
  _mk_stakeholder "$roster_dir" "frank" "[design]"

  _create_shims
  rm -rf "$SHIM_LOG"; mkdir -p "$SHIM_LOG"

  run env PROJECT_ROOT="$TEST_TMP" SHIM_LOG="$SHIM_LOG" \
    PATH="$SHIM_DIR:$PATH" "$SCRIPT" check-convergence

  # Fast path: exactly one roster yq call
  local yqr
  yqr="$(_yq_roster_count)"
  [ "$yqr" -eq 1 ] \
    || fail "expected fast path (1 roster yq call), got $yqr"

  # Exact output line
  [[ "$output" == *"not-converged (missing: eve frank)"* ]] \
    || fail "expected exact 'not-converged (missing: eve frank)': $output"
}

# =========================================================================
# approve reports roster refusal reason, not unknown-stakeholder
# =========================================================================

@test "approve reports roster refusal reason, not unknown-stakeholder" {
  # When roster resolution is refused (e.g. symlinked directory), the
  # approve verb must report the roster refusal reason — not the generic
  # "unknown stakeholder ... not on the roster" message.  The audit entry
  # must also carry the real reason.  The refusal itself (exit 1, an
  # approval-refused entry) stays the same.
  [ -x "$SCRIPT" ] || fail "script not found"

  _seed_record "review" 1

  local target="$BATS_TEST_TMPDIR/evil-approve-reason"
  mkdir -p "$target"
  _mk_stakeholder "$target" "alice" "[design]"

  mkdir -p "$TEST_TMP/.gaia/custom"
  ln -s "$target" "$TEST_TMP/.gaia/custom/stakeholders"

  run env PROJECT_ROOT="$TEST_TMP" "$SCRIPT" approve \
    --stakeholder alice --recorded-by test
  [ "$status" -ne 0 ] || fail "approve must fail on symlinked roster"

  # Must NOT say "unknown stakeholder"
  [[ "$output" != *"unknown stakeholder"* ]] \
    || fail "approve must not say 'unknown stakeholder' when roster resolution was refused: $output"

  # Must say something about symlink refusal
  [[ "$output" == *"refusing symlinked"* ]] \
    || fail "approve must report the symlink refusal: $output"
  [[ "$output" == *"roster resolution refused"* ]] \
    || fail "approve must say 'roster resolution refused': $output"

  # Audit entry: event should be approval-refused
  local audit_event audit_reason
  audit_event="$(yq '.audit[-1].event' "$RECORD")"
  [ "$audit_event" = "approval-refused" ] \
    || fail "expected approval-refused audit entry, got: $audit_event"

  # Audit reason must mention the real refusal, not "stakeholder not on roster"
  audit_reason="$(yq '.audit[-1].reason' "$RECORD")"
  [[ "$audit_reason" == *"roster resolution refused"* ]] \
    || fail "audit reason must mention 'roster resolution refused', got: $audit_reason"
}

# =========================================================================
# write-pattern scan does not trip on roster test file
# =========================================================================

@test "write-pattern scan does not trip on roster test file [regression]" {
  # This test validates that design-record-roster.bats does not contain
  # write constructs that mention the sole writer by its literal name.
  # The write-pattern scan in design-record.bats catches these.
  local roster_bats="$BATS_TEST_DIRNAME/design-record-roster.bats"
  [ -f "$roster_bats" ] || fail "roster test file not found"

  # Build the target name dynamically to avoid self-tripping
  local sole_writer; sole_writer="$(basename "$SCRIPT" .sh)"
  local write_patterns
  write_patterns="(>[> ]*|yq[[:space:]]+(--inplace|-i)|sed[[:space:]]+-i|tee[[:space:]]|mv[[:space:]]|cp[[:space:]]|install[[:space:]]|truncate[[:space:]]).*${sole_writer}"

  local matches
  matches="$("$REAL_GREP" -nE "$write_patterns" "$roster_bats" 2>/dev/null \
    | "$REAL_GREP" -vE '^\s*#' || true)"
  [ -z "$matches" ] \
    || fail "write-pattern violations in roster test file:\n$matches"
}
