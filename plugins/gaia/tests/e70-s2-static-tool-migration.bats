#!/usr/bin/env bats
# e70-s2-static-tool-migration.bats — E70-S2 acceptance tests.
#
# Story: E70-S2 — Migrate five existing static-tool integrations to adapter form
#        (Semgrep, gitleaks, radon, gocyclo, eslint-plugin-sonarjs) + backward-compat
#        alias layer (one-sprint deprecation window).
# Decisions: ADR-077 (Three-Tier Review Pipeline), ADR-078 (Tool Adapter Framework).
# Refs: FR-RSV2-17, FR-RSV2-18, FR-RSV2-19, FR-RSV2-20.
#
# Strict 1:1 AC-to-test mapping per atdd-E70-S2.md, reconciled to the canonical
# E70-S1 `--input <file-list>` flag form (the ATDD pre-dated E70-S1 finalising
# the contract; this bats reflects what actually shipped).

bats_require_minimum_version 1.5.0

ADAPTERS_DIR="$BATS_TEST_DIRNAME/../scripts/adapters"
REVIEW_COMMON_DIR="$BATS_TEST_DIRNAME/../scripts/review-common"
PROBE="$BATS_TEST_DIRNAME/../scripts/tool-availability-probe.sh"
LEGACY_ALIASES="$REVIEW_COMMON_DIR/legacy-tool-aliases.sh"
STORY_FILE_GLOB="$BATS_TEST_DIRNAME/../../../../docs/implementation-artifacts/epic-E70-gaia-review-system-v2-tool-adapter-framework/stories/E70-S2-*.md"

# Helper: write a single-path file-list and echo the path.
_filelist() {
  local target="$1"
  local listfile="$BATS_TEST_TMPDIR/filelist-$RANDOM.txt"
  printf '%s\n' "$target" > "$listfile"
  printf '%s' "$listfile"
}

# Helper: empty file-list (drives not_applicable).
_empty_filelist() {
  local listfile="$BATS_TEST_TMPDIR/filelist-empty-$RANDOM.txt"
  : > "$listfile"
  printf '%s' "$listfile"
}

# Helper: PATH stripped of typical tool homebrew/local locations but keeping
# /usr/bin and /bin so coreutils (jq, env, bash, awk, grep) still resolve.
# This forces the five static tools (semgrep, gitleaks, radon, gocyclo, eslint)
# to be unavailable while leaving the run.sh execution environment functional.
_path_without_tools() {
  printf '%s' "/usr/bin:/bin"
}

# ---------------- AC1 — five adapters exist with conforming files ---------

@test "AC1: all five adapters exist with adapter.json + executable run.sh" {
  for tool in semgrep gitleaks radon gocyclo eslint-plugin-sonarjs; do
    [ -d "${ADAPTERS_DIR}/${tool}" ] || { echo "missing dir: ${tool}" >&2; return 1; }
    [ -f "${ADAPTERS_DIR}/${tool}/adapter.json" ] || { echo "missing adapter.json: ${tool}" >&2; return 1; }
    [ -x "${ADAPTERS_DIR}/${tool}/run.sh" ] || { echo "run.sh not executable: ${tool}" >&2; return 1; }
    run jq empty "${ADAPTERS_DIR}/${tool}/adapter.json"
    [ "$status" -eq 0 ] || { echo "adapter.json invalid JSON: ${tool}" >&2; return 1; }
  done
}

# ---------------- AC2 — Semgrep adapter fragment shape --------------------

# Helper: assert a run.sh source emits the canonical {name, status, findings}
# fragment shape per E70-S1 run-contract.md §2.1. The jq filter uses the
# unquoted-key form `{name: $name, status: ..., findings: [...]}`.
_assert_fragment_shape_in_source() {
  local script="$1"
  [ -f "$script" ] || { echo "missing: $script" >&2; return 1; }
  grep -qE 'name:[[:space:]]*\$name' "$script" \
    || { echo "missing 'name: \$name' in $script" >&2; return 1; }
  grep -qE 'status:[[:space:]]*\(if[[:space:]]+\$rc' "$script" \
    || { echo "missing canonical status: branch in $script" >&2; return 1; }
  grep -qE 'findings:[[:space:]]*\[\]' "$script" \
    || { echo "missing 'findings: []' in $script" >&2; return 1; }
}

@test "AC2: semgrep run.sh emits canonical analysis-results fragment shape" {
  _assert_fragment_shape_in_source "${ADAPTERS_DIR}/semgrep/run.sh"
}

@test "AC3: gitleaks run.sh emits canonical analysis-results fragment shape" {
  _assert_fragment_shape_in_source "${ADAPTERS_DIR}/gitleaks/run.sh"
}

@test "AC4: radon run.sh emits canonical analysis-results fragment shape" {
  _assert_fragment_shape_in_source "${ADAPTERS_DIR}/radon/run.sh"
}

@test "AC5: gocyclo run.sh emits canonical analysis-results fragment shape" {
  _assert_fragment_shape_in_source "${ADAPTERS_DIR}/gocyclo/run.sh"
}

@test "AC6: eslint-plugin-sonarjs run.sh emits canonical analysis-results fragment shape" {
  _assert_fragment_shape_in_source "${ADAPTERS_DIR}/eslint-plugin-sonarjs/run.sh"
}

# ---------------- AC7 — backward-compat alias layer -----------------------

@test "AC7: legacy-tool-aliases.sh exists and is sourceable" {
  [ -f "$LEGACY_ALIASES" ]
  bash -n "$LEGACY_ALIASES"
}

@test "AC7: legacy alias defines run_<tool>_legacy functions for all five tools" {
  # shellcheck disable=SC1090
  source "$LEGACY_ALIASES"
  for fn in run_semgrep_legacy run_gitleaks_legacy run_radon_legacy run_gocyclo_legacy run_eslint_sonarjs_legacy; do
    type "$fn" >/dev/null 2>&1 || { echo "missing function: $fn" >&2; return 1; }
  done
}

@test "AC7: legacy alias emits DEPRECATION warning to stderr including canonical adapter path" {
  # shellcheck disable=SC1090
  source "$LEGACY_ALIASES"
  local list; list="$(_empty_filelist)"

  # Capture stderr separately. We expect:
  #  - a "DEPRECATION" warning on stderr
  #  - the canonical adapter path "adapters/semgrep/run.sh" mentioned on stderr
  #  - the call still completes (exit code propagates from run.sh; not asserted
  #    here because tool may or may not be installed on the host).
  local stderr_capture="${BATS_TEST_TMPDIR}/stderr-cap.txt"
  bash -c '
    # shellcheck disable=SC1090
    source "$1"
    run_semgrep_legacy --input "$2" 2>"$3" >/dev/null || true
  ' _ "$LEGACY_ALIASES" "$list" "$stderr_capture" || true

  grep -qi 'DEPRECATION' "$stderr_capture" || { cat "$stderr_capture" >&2; return 1; }
  grep -q 'adapters/semgrep/run.sh' "$stderr_capture" || { cat "$stderr_capture" >&2; return 1; }
}

# ---------------- AC8 — deprecation window documented ---------------------

@test "AC8: story Dev Notes documents one-sprint deprecation window + out-of-scope removal" {
  local story_file
  story_file="$(ls $STORY_FILE_GLOB 2>/dev/null | head -n1)"
  [ -n "$story_file" ] && [ -f "$story_file" ]

  # Dev Notes block from the story file
  awk '/^## Dev Notes/,/^## Technical Notes/' "$story_file" \
    | grep -qE 'one[[:space:]]sprint|deprecation.*window|deprecation.*one|sprint.*deprecation'

  awk '/^## Dev Notes/,/^## Technical Notes/' "$story_file" \
    | grep -qE 'out[[:space:]]of[[:space:]]scope|not[[:space:]]in[[:space:]]scope|separate[[:space:]]cleanup'
}

# ---------------- AC9 — each adapter passes contract.bats template -------

@test "AC9: each adapter ships a contract.bats matching the E70-S1 template structure" {
  local schema_template="${ADAPTERS_DIR}/_schema/test/contract.bats"
  [ -f "$schema_template" ]
  for tool in semgrep gitleaks radon gocyclo eslint-plugin-sonarjs; do
    local bats="${ADAPTERS_DIR}/${tool}/test/contract.bats"
    [ -f "$bats" ] || { echo "missing: $bats" >&2; return 1; }
    # All four states + assert_files_exist + assert_fragment_shape are present
    grep -q "assert_files_exist" "$bats" || { echo "missing assert_files_exist: $tool" >&2; return 1; }
    for state in available expected_and_missing ran_and_errored not_applicable; do
      grep -q "assert_state .* $state" "$bats" || { echo "missing state=$state: $tool" >&2; return 1; }
    done
    grep -q "assert_fragment_shape" "$bats" || { echo "missing assert_fragment_shape: $tool" >&2; return 1; }
  done
}

# ---------------- AC10 — missing tool propagates to BLOCKED + exit 127 ---

@test "AC10: probe returns expected_and_missing when adapter provider is absent from PATH" {
  [ -x "$PROBE" ]
  local list; list="$(_filelist "${BATS_TEST_TMPDIR}/x.py")"
  : > "${BATS_TEST_TMPDIR}/x.py"
  local stdout_capture="${BATS_TEST_TMPDIR}/probe-stdout.txt"
  # Run the probe with PATH stripped of tool binaries (stderr discarded so
  # JSON-only output reaches the captured stdout file).
  run -1 bash -c '
    env PATH="$1" "$2" --adapter-dir "$3" --file-list "$4" 2>/dev/null > "$5"
  ' _ "$(_path_without_tools)" "$PROBE" "${ADAPTERS_DIR}/semgrep" "$list" "$stdout_capture"
  # Probe exits 1 for expected_and_missing per its contract
  jq -e '.state == "expected_and_missing"' "$stdout_capture" >/dev/null
  jq -e '.failure_kind == "tool_missing"' "$stdout_capture" >/dev/null
}

@test "AC10: adapter run.sh exits with unavailable code 127 when provider absent from PATH" {
  local list; list="$(_filelist "${BATS_TEST_TMPDIR}/x.py")"
  : > "${BATS_TEST_TMPDIR}/x.py"
  for tool in semgrep gitleaks radon gocyclo eslint-plugin-sonarjs; do
    # Per E70-S2 AC10: exit 127 is the contract-defined unavailable code
    # (distinct from generic error 1 / POSIX "command not found"). The
    # `run -127` form acknowledges 127 as expected and silences BW01.
    run -127 env PATH="$(_path_without_tools)" \
      "${ADAPTERS_DIR}/${tool}/run.sh" --input "$list"
    [ "$status" -eq 127 ] || { echo "expected exit 127 for $tool, got $status" >&2; return 1; }
  done
}
