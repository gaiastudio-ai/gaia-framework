#!/usr/bin/env bats
# e38-s1-reconcile-risk.bats
#
# ATDD failing acceptance tests for E38-S1 — Sprint-status reconciliation
# + risk surfacing (Epic E38, Sprint Planning Quality Gates).
#
# PHASE: RED — all tests FAIL because sprint-state.sh does not yet implement
# the "reconcile" subcommand (see Task 1 in E38-S1 story file).
#
# Refs: FR-SPQG-4, FR-SPQG-5, NFR-SPQG-1, NFR-SPQG-2, ADR-055 §10.29.1
# Script (canonical):  gaia-public/plugins/gaia/scripts/sprint-state.sh
# Script (secondary):  gaia-public/plugins/gaia/skills/gaia-dev-story/scripts/sprint-state.sh
# Dashboard:           gaia-public/plugins/gaia/scripts/sprint-status-dashboard.sh
# Catalog (new file):  gaia-public/plugins/gaia/skills/gaia-sprint-status/mitigation-catalog.yaml
#
# Exit-code contract (ADR-055 §10.29.1):
#   0 — no drift detected, or drift was corrected
#   1 — error (missing file, parse failure, OS error)
#   2 — drift detected in --dry-run mode (nothing written)

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Paths resolved once at load time.
# ---------------------------------------------------------------------------
SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
SPRINT_STATE="$SCRIPTS_DIR/sprint-state.sh"
DASHBOARD="$SCRIPTS_DIR/sprint-status-dashboard.sh"
# Per-test catalog path is set in setup() via $MITIGATION_CATALOG; the
# dashboard resolves the bundled catalog when MITIGATION_CATALOG is unset
# (see sprint-status-dashboard.sh:74). The real on-disk catalog is never
# touched by this fixture (E38-S5 — AC4).

# ---------------------------------------------------------------------------
# assert_reconcile_recognized — fails if the reconcile subcommand is not yet
# wired into sprint-state.sh (the "unknown subcommand: reconcile" error is
# emitted to stderr which bats captures in $output when using run with
# BATS_PIPE_STDERR=1, or can be tested by checking combined output with 2>&1).
# Used as a guard in tests whose remaining assertions would pass trivially even
# before implementation exists.
# ---------------------------------------------------------------------------
assert_reconcile_recognized() {
  # Run reconcile and capture combined stdout+stderr by redirecting stderr.
  local combined
  combined="$("$SPRINT_STATE" reconcile 2>&1 || true)"
  if printf '%s' "$combined" | grep -q "unknown subcommand: reconcile"; then
    echo "ATDD GUARD: reconcile subcommand not yet implemented in sprint-state.sh" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Fixture helpers — each test builds its own isolated temp tree so tests are
# fully atomic and independent.
# ---------------------------------------------------------------------------

# mk_sprint_status <yaml_path> [key status [key status ...]]
# Writes a sprint-status.yaml with the supplied story pairs.
mk_sprint_status() {
  local yaml_path="$1"; shift
  mkdir -p "$(dirname "$yaml_path")"
  {
    printf 'sprint_id: "sprint-test"\nstories:\n'
    while [ $# -ge 2 ]; do
      local key="$1" status="$2"; shift 2
      printf '  - key: "%s"\n    status: "%s"\n    title: "Test story %s"\n' \
        "$key" "$status" "$key"
    done
  } > "$yaml_path"
}

# mk_story_file <artifacts_dir> <key> <status> [risk]
# Writes a minimal story file; prints the path to stdout.
mk_story_file() {
  local dir="$1" key="$2" status="$3" risk="${4:-low}"
  mkdir -p "$dir"
  local slug
  slug="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  local path="$dir/${slug}-story.md"
  {
    printf -- '---\n'
    printf "template: 'story'\n"
    printf 'key: "%s"\n' "$key"
    printf 'status: %s\n' "$status"
    printf 'risk: "%s"\n' "$risk"
    printf 'title: "Test story %s"\n' "$key"
    printf -- '---\n\n'
    printf '# Story: %s\n\n**Status:** %s\n' "$key" "$status"
  } > "$path"
  printf '%s' "$path"
}

# mk_malformed_story_file <artifacts_dir> <key>
# Writes a story file with intentionally unparseable frontmatter.
mk_malformed_story_file() {
  local dir="$1" key="$2"
  mkdir -p "$dir"
  local slug
  slug="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  local path="$dir/${slug}-story.md"
  {
    printf -- '---\n'
    printf "template: 'story'\n"
    printf 'key: %s\n' "$key"
    printf 'status: : : malformed: [unclosed\n'
    printf 'risk: !!invalid_tag !!\n'
    printf -- '---\n\n'
    printf '# Story: %s\n' "$key"
  } > "$path"
  printf '%s' "$path"
}

# mk_catalog <path>
# Writes a minimal mitigation catalog YAML.
mk_catalog() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'CATALOG'
# mitigation-catalog.yaml — bundled risk mitigation suggestions
mitigations:
  - id: pair-programming
    label: "Pair programming"
    description: "Assign two engineers to reduce knowledge silos and catch errors early."
  - id: increased-testing
    label: "Increased test coverage"
    description: "Add unit, integration, and edge-case tests before merging."
  - id: architect-review
    label: "Architect review"
    description: "Request a synchronous review from the system architect before implementation begins."
  - id: security-review
    label: "Security review"
    description: "Run /gaia-security-review to surface OWASP Top-10 risks specific to this story."
CATALOG
}

setup() {
  common_setup
  export ARTIFACTS_DIR="$TEST_TMP/docs/implementation-artifacts"
  export SPRINT_YAML="$TEST_TMP/sprint-status.yaml"
  mkdir -p "$ARTIFACTS_DIR"
  # Export the path variables that sprint-state.sh respects.
  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$ARTIFACTS_DIR"
  # E38-S5 — point the dashboard at a per-test catalog path under
  # BATS_TEST_TMPDIR. The dashboard's MITIGATION_CATALOG env-var override
  # (sprint-status-dashboard.sh:74) consumes this. The real on-disk catalog
  # is never touched, eliminating the prior backup/restore dance and a class
  # of test-ordering races (AC1, AC2, AC4).
  export MITIGATION_CATALOG="$BATS_TEST_TMPDIR/mitigation-catalog.yaml"
}

teardown() {
  common_teardown
}

# ===========================================================================
# AC1 — No-drift state reports "no drift"
# [TC-SPQG-1, FR-SPQG-4]
# ===========================================================================
@test "AC1: no-drift state reports 'no drift' and exits 0" {
  mk_sprint_status "$SPRINT_YAML" "E99-S1" "in-progress"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S1" "in-progress" > /dev/null

  run "$SPRINT_STATE" reconcile
  # RED PHASE: reconcile subcommand not found in sprint-state.sh.
  [ "$status" -eq 0 ]
  [[ "$output" == *"no drift"* ]]
}

# ===========================================================================
# AC2 — Divergent status corrected in yaml; divergence reported with key,
#        old status, and new status.
# [TC-SPQG-2, FR-SPQG-4]
# ===========================================================================
@test "AC2: divergent status is corrected in yaml and divergence is reported with key, old, new status" {
  # yaml says "in-progress"; story file frontmatter says "review" — drift exists.
  mk_sprint_status "$SPRINT_YAML" "E99-S2" "in-progress"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S2" "review" > /dev/null

  run "$SPRINT_STATE" reconcile
  # RED PHASE: reconcile subcommand not found in sprint-state.sh.

  # Exit 0 = drift was corrected.
  [ "$status" -eq 0 ]

  # Output must identify the story key and both statuses.
  [[ "$output" == *"E99-S2"* ]]
  [[ "$output" == *"in-progress"* ]]
  [[ "$output" == *"review"* ]]

  # The yaml entry must now carry the story-file value.
  grep -qE 'status:.*review' "$SPRINT_YAML"
}

# ===========================================================================
# AC3 — Idempotency: second run on reconciled state reports "no drift"
# [TC-SPQG-3, NFR-SPQG-1]
# ===========================================================================
@test "AC3: second reconcile on already-reconciled state reports 'no drift' (idempotency)" {
  mk_sprint_status "$SPRINT_YAML" "E99-S3" "in-progress"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S3" "review" > /dev/null

  # First run corrects the drift.
  run "$SPRINT_STATE" reconcile
  # RED PHASE: reconcile subcommand not found in sprint-state.sh.
  [ "$status" -eq 0 ]

  # Second run on the now-consistent state must report "no drift".
  run "$SPRINT_STATE" reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"no drift"* ]]
}

# ===========================================================================
# AC4 — Story files byte-identical before and after reconcile
# [TC-SPQG-4, NFR-SPQG-2]
# ===========================================================================
@test "AC4: story files are byte-identical after reconcile (reconcile never modifies story files)" {
  # Guard: fails immediately if reconcile is not yet implemented.
  assert_reconcile_recognized

  mk_sprint_status "$SPRINT_YAML" "E99-S4" "backlog"
  local story_path
  story_path="$(mk_story_file "$ARTIFACTS_DIR" "E99-S4" "in-progress")"

  local before_sum
  before_sum="$(md5 -q "$story_path" 2>/dev/null || md5sum "$story_path" | awk '{print $1}')"

  run "$SPRINT_STATE" reconcile
  # Exit 0 (corrected) or 1 (error) — both are valid; we only care that story
  # files were not touched.
  [ "$status" -le 1 ]

  local after_sum
  after_sum="$(md5 -q "$story_path" 2>/dev/null || md5sum "$story_path" | awk '{print $1}')"
  [ "$before_sum" = "$after_sum" ]
}

# ===========================================================================
# AC5 — HIGH-risk story gets inline mitigation from catalog on dashboard
# [TC-SPQG-5, FR-SPQG-5]
# ===========================================================================
@test "AC5: HIGH-risk story shows inline mitigation suggestion from catalog on dashboard" {
  mk_sprint_status "$SPRINT_YAML" "E99-S5" "in-progress"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S5" "in-progress" "high" > /dev/null
  mk_catalog "$MITIGATION_CATALOG"

  run "$DASHBOARD"
  # RED PHASE: dashboard does not yet read mitigation-catalog.yaml or annotate
  # HIGH-risk stories — risk-surfacing code path is unimplemented.
  [ "$status" -eq 0 ]

  # Story must appear in dashboard output.
  [[ "$output" == *"E99-S5"* ]]

  # At least one catalog mitigation label must appear inline with the story.
  [[ "$output" == *"Pair programming"* ]] || \
    [[ "$output" == *"Increased test coverage"* ]] || \
    [[ "$output" == *"Architect review"* ]] || \
    [[ "$output" == *"Security review"* ]]
}

# ===========================================================================
# AC6 — No HIGH-risk stories: no mitigation block in dashboard output
# [FR-SPQG-5]
# ===========================================================================
@test "AC6: when no story has risk: HIGH, dashboard renders no mitigation block" {
  mk_sprint_status "$SPRINT_YAML" "E99-S6" "in-progress"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S6" "in-progress" "low" > /dev/null
  mk_catalog "$MITIGATION_CATALOG"

  run "$DASHBOARD"
  # RED PHASE: dashboard risk-surfacing code path does not yet exist.
  [ "$status" -eq 0 ]

  # None of the mitigation labels must appear (clean output, no-op default).
  [[ "$output" != *"Pair programming"* ]]
  [[ "$output" != *"Increased test coverage"* ]]
  [[ "$output" != *"Architect review"* ]]
  [[ "$output" != *"Security review"* ]]
}

# ===========================================================================
# AC-EC1 — Empty sprint: exits 0, "0 stories checked, 0 divergences"
# [category: boundary]
# ===========================================================================
@test "AC-EC1: empty sprint-status.yaml exits 0 with '0 stories checked, 0 divergences'" {
  mkdir -p "$(dirname "$SPRINT_YAML")"
  printf 'sprint_id: "sprint-test"\nstories: []\n' > "$SPRINT_YAML"

  run "$SPRINT_STATE" reconcile
  # RED PHASE: reconcile subcommand not found in sprint-state.sh.
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 stories checked"* ]]
  [[ "$output" == *"0 divergences"* ]]
}

# ===========================================================================
# AC-EC2 — Missing story file: logs error, skips, continues, exits 1
# [category: error]
# ===========================================================================
@test "AC-EC2: story key in yaml with no matching file logs error and exits 1" {
  # Guard: fails immediately if reconcile is not yet implemented.
  assert_reconcile_recognized

  # yaml references E99-GHOST but no story file is created.
  mk_sprint_status "$SPRINT_YAML" "E99-GHOST" "in-progress"

  run "$SPRINT_STATE" reconcile
  [ "$status" -eq 1 ]
  # Output must reference the missing key (not the generic "unknown subcommand" error).
  [[ "$output" == *"E99-GHOST"* ]] || \
    [[ "$output" == *"missing"* ]] || \
    [[ "$output" == *"not found"* ]]
}

# ===========================================================================
# AC-EC3 — Malformed frontmatter: logs parse error with key+path, exits 1
# [category: error]
# ===========================================================================
@test "AC-EC3: malformed story frontmatter logs parse error with key and path, exits 1" {
  mk_sprint_status "$SPRINT_YAML" "E99-S7" "in-progress"
  mk_malformed_story_file "$ARTIFACTS_DIR" "E99-S7" > /dev/null

  run "$SPRINT_STATE" reconcile
  # RED PHASE: reconcile subcommand not found in sprint-state.sh.
  [ "$status" -eq 1 ]
  # Error output must mention the story key or the path.
  [[ "$output" == *"E99-S7"* ]] || \
    [[ "$output" == *"parse"* ]] || \
    [[ "$output" == *"malformed"* ]]
}

# ===========================================================================
# AC-EC4 — --dry-run on divergent state: DRY-RUN tag, no writes, exits 2
# [category: boundary]
# ===========================================================================
@test "AC-EC4: --dry-run on divergent state reports DRY-RUN, writes nothing, exits 2" {
  mk_sprint_status "$SPRINT_YAML" "E99-S8" "backlog"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S8" "in-progress" > /dev/null

  local before_yaml_sum
  before_yaml_sum="$(md5 -q "$SPRINT_YAML" 2>/dev/null || md5sum "$SPRINT_YAML" | awk '{print $1}')"

  run "$SPRINT_STATE" reconcile --dry-run
  # RED PHASE: reconcile subcommand not found in sprint-state.sh.
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRY-RUN"* ]]

  # The yaml must not have been modified.
  local after_yaml_sum
  after_yaml_sum="$(md5 -q "$SPRINT_YAML" 2>/dev/null || md5sum "$SPRINT_YAML" | awk '{print $1}')"
  [ "$before_yaml_sum" = "$after_yaml_sum" ]
}

# ===========================================================================
# AC-EC5 — Concurrent invocations: lock prevents partial writes / corruption
# [category: concurrency]
# ===========================================================================
@test "AC-EC5: concurrent reconcile invocations do not corrupt sprint-status.yaml" {
  # Guard: fails immediately if reconcile is not yet implemented.
  assert_reconcile_recognized

  # Seed 10 stories with divergent statuses so each reconcile does real work.
  local yaml_args=()
  local i
  for i in $(seq 1 10); do
    mk_story_file "$ARTIFACTS_DIR" "E99-C${i}" "review" > /dev/null
    yaml_args+=("E99-C${i}" "in-progress")
  done
  mk_sprint_status "$SPRINT_YAML" "${yaml_args[@]}"

  # Launch two reconcile processes concurrently.
  "$SPRINT_STATE" reconcile &
  local pid1=$!
  "$SPRINT_STATE" reconcile &
  local pid2=$!
  wait "$pid1" || true
  wait "$pid2" || true

  # After both finish, the yaml must be structurally intact.
  grep -q "sprint_id" "$SPRINT_YAML"

  # All 10 story keys must still appear (no truncation or data loss).
  local story_count
  story_count="$(grep -c '  - key:' "$SPRINT_YAML" || true)"
  [ "$story_count" -eq 10 ]
}

# ===========================================================================
# AC-EC6 — Missing catalog: dashboard renders with warning, does not halt
# [category: error]
# ===========================================================================
@test "AC-EC6: missing mitigation catalog allows dashboard to render with warning, does not halt" {
  mk_sprint_status "$SPRINT_YAML" "E99-S9" "in-progress"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S9" "in-progress" "high" > /dev/null
  # Deliberately do NOT create the catalog file.

  run "$DASHBOARD"
  # RED PHASE: dashboard risk-surfacing code path does not yet exist.
  [ "$status" -eq 0 ]

  # Dashboard must still render the story entry.
  [[ "$output" == *"E99-S9"* ]]

  # Dashboard must emit a catalog-missing warning.
  [[ "$output" == *"mitigation catalog not found"* ]] || \
    [[ "$output" == *"risk surfacing degraded"* ]]
}

# ===========================================================================
# AC-EC7 — Unexpected catalog entry rendered verbatim; no enum rejection
# [category: data]
# ===========================================================================
@test "AC-EC7: unexpected catalog entry is rendered verbatim without enum validation error" {
  mk_sprint_status "$SPRINT_YAML" "E99-S10" "in-progress"
  mk_story_file    "$ARTIFACTS_DIR" "E99-S10" "in-progress" "high" > /dev/null

  # Catalog contains one known entry and one entirely unexpected entry.
  mkdir -p "$(dirname "$MITIGATION_CATALOG")"
  cat > "$MITIGATION_CATALOG" <<'CATALOG'
mitigations:
  - id: pair-programming
    label: "Pair programming"
    description: "Assign two engineers to reduce knowledge silos."
  - id: quantum-entanglement-review
    label: "Quantum entanglement review"
    description: "An unexpected, never-before-cataloged mitigation strategy."
CATALOG

  run "$DASHBOARD"
  # RED PHASE: dashboard does not yet read or render the catalog.
  [ "$status" -eq 0 ]

  # The unexpected entry must appear verbatim (no enum validation rejection).
  [[ "$output" == *"Quantum entanglement review"* ]] || \
    [[ "$output" == *"quantum-entanglement-review"* ]]
}

# ===========================================================================
# AC-EC8 — Read-only yaml: surfaces OS error, exits 1, story files intact
# [category: environment]
# ===========================================================================
@test "AC-EC8: read-only sprint-status.yaml causes reconcile to exit 1; story files byte-identical" {
  # Guard: fails immediately if reconcile is not yet implemented.
  assert_reconcile_recognized

  mk_sprint_status "$SPRINT_YAML" "E99-S11" "backlog"
  local story_path
  story_path="$(mk_story_file "$ARTIFACTS_DIR" "E99-S11" "in-progress")"

  local before_sum
  before_sum="$(md5 -q "$story_path" 2>/dev/null || md5sum "$story_path" | awk '{print $1}')"

  # Make sprint-status.yaml read-only to simulate permission/full-disk error.
  chmod 444 "$SPRINT_YAML"

  run "$SPRINT_STATE" reconcile
  # Must exit 1 and surface OS error with yaml path (not the generic
  # "unknown subcommand" error — that is already excluded by assert_reconcile_recognized).
  [ "$status" -eq 1 ]

  # Error output must reference the yaml path.
  [[ "$output" == *"sprint-status.yaml"* ]] || \
    [[ "$output" == *"$SPRINT_YAML"* ]]

  # Story file must be byte-identical (NFR-SPQG-2 enforced even on write error).
  local after_sum
  after_sum="$(md5 -q "$story_path" 2>/dev/null || md5sum "$story_path" | awk '{print $1}')"
  [ "$before_sum" = "$after_sum" ]

  # Restore permissions so common_teardown can clean up.
  chmod 644 "$SPRINT_YAML" 2>/dev/null || true
}
