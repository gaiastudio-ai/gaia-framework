#!/usr/bin/env bash
# run-with-coverage.sh — E28-S17 coverage wrapper (hardened under E28-S184).
#
# 1. Enumerates documented public functions from every *.sh in
#    plugins/gaia/scripts/ (any `^[a-z_][a-z0-9_]*\(\) {`).
# 2. Runs the full bats suite under plugins/gaia/tests/.
# 3. Asserts every public function name appears at least once inside
#    some .bats file (the NFR-052 binding public-function coverage gate).
# 4. If kcov is available, runs the suite under kcov to produce an advisory
#    line-coverage report at coverage/ (HTML + JSON). kcov is optional — a
#    missing kcov is NOT a hard failure of this wrapper. The CI job does NOT
#    install kcov on Ubuntu 24.04 (noble) because the package is not in the
#    default apt repositories there (see E28-S175); line-coverage is therefore
#    skipped in CI today. The authoritative public-function coverage gate
#    (step 3, NFR-052) does not depend on kcov.
#
# E28-S184 hardening (release blocker for sprint-24):
#   * Guarded `grep` pipelines with `{ ... || true; } | ...` so a zero-match
#     does not abort the wrapper under `set -euo pipefail` (the silent-abort
#     root cause: 4 scripts have zero public functions by design).
#   * Emit a distinct "0 public functions — skipping" log line per skipped
#     script so future regressions are detectable in CI logs.
#   * LC_ALL=C pinned at line 22 (AC-EC10 invariant; do not move).
#   * Known limitation: Step 3 coverage is a textual grep for the function
#     name across .bats files. A public function whose name is a substring
#     of an unrelated bats assertion will register as covered (AC-EC9).
#     Mitigation: keep function names specific; the regression suite uses
#     unique names to prove the primary behavior.
#
# Testability overrides (E28-S184):
#   SCRIPTS_DIR_OVERRIDE  — absolute path to scripts dir (default: derived)
#   TESTS_DIR_OVERRIDE    — absolute path to tests dir   (default: derived)
#   COVERAGE_DIR          — absolute path for coverage outputs
#
# Exit codes:
#   0 — bats suite green AND every public function covered
#   1 — bats suite failed, or a public function has no matching bats test

set -euo pipefail
LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-$REPO_ROOT/plugins/gaia/scripts}"
TESTS_DIR="${TESTS_DIR_OVERRIDE:-$REPO_ROOT/plugins/gaia/tests}"
COVERAGE_DIR="${COVERAGE_DIR:-$REPO_ROOT/coverage}"

mkdir -p "$COVERAGE_DIR"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# enumerate_public_funcs <script-path>
# Emit the sorted-unique list of public function names defined in the
# given script. Public = starts at column 0 with `name()`, no leading
# underscore. Guarded so a zero-match grep does not trip `set -e`.
enumerate_public_funcs() {
  local script_path="$1"
  { grep -E '^[a-z][a-z0-9_]*\(\)' "$script_path" || true; } \
    | sed -E 's/\(\).*$//' \
    | sort -u
}

# ---------------------------------------------------------------------------
# Step 1 — enumerate public functions across every foundation script.
# ---------------------------------------------------------------------------
bold "[1/4] Enumerating public functions in $SCRIPTS_DIR"

PUB_JSON="$COVERAGE_DIR/public-functions.json"
: > "$PUB_JSON.tmp"
printf '{\n' > "$PUB_JSON.tmp"
first_script=1
for s in "$SCRIPTS_DIR"/*.sh; do
  [ -f "$s" ] || continue
  name="$(basename "$s")"
  funcs="$(enumerate_public_funcs "$s")"
  if [ -z "$funcs" ]; then
    bold "  $name: 0 public functions — skipping"
    continue
  fi
  if [ "$first_script" -eq 1 ]; then first_script=0; else printf ',\n' >> "$PUB_JSON.tmp"; fi
  printf '  "%s": [' "$name" >> "$PUB_JSON.tmp"
  first=1
  for f in $funcs; do
    if [ "$first" -eq 1 ]; then first=0; else printf ', ' >> "$PUB_JSON.tmp"; fi
    printf '"%s"' "$f" >> "$PUB_JSON.tmp"
  done
  printf ']' >> "$PUB_JSON.tmp"
done
printf '\n}\n' >> "$PUB_JSON.tmp"
mv "$PUB_JSON.tmp" "$PUB_JSON"

# ---------------------------------------------------------------------------
# Step 2 — run the bats suite.
# ---------------------------------------------------------------------------
# E91-S1 (FR-SRF-1, AF-2026-05-14-9): default-skip @hardware-dependent
# tests via BATS_FILTER_TAGS env var. CI sets BATS_FILTER_TAGS to
# '!hardware-dependent' to exclude tests tagged @hardware-dependent
# (mtime resolution / sleep precision / host-clock semantics).
# Developers run them locally with:
#   BATS_FILTER_TAGS=hardware-dependent bash run-with-coverage.sh
# OR directly:
#   bats --filter-tags hardware-dependent <test-file>
bold "[2/4] Running bats suite"
BATS_ARGS=()
if [ -n "${BATS_FILTER_TAGS:-}" ]; then
  BATS_ARGS+=(--filter-tags "$BATS_FILTER_TAGS")
fi

# Parallelise ACROSS test files to keep wall-clock under the CI job timeout.
# The suite is 580+ files / 7600+ tests; run serially it sits right at the
# 15-minute CI wall and tips into timeout-cancellation on slow runners. bats
# --jobs runs whole files concurrently (NOT tests within a file — that stays
# serial via --no-parallelize-within-files), which is the safe granularity
# here: each file already isolates state in a per-test $BATS_TEST_TMPDIR
# (see tests/test_helper.bash common_setup), so cross-file concurrency cannot
# race on shared mutable state.
#
# bats --jobs requires GNU parallel. When it is absent (e.g. a developer box
# without it) bats would abort, so we probe first and fall back to a serial
# run — identical behaviour to before, just without the speedup. BATS_JOBS
# overrides the degree (default: nproc, capped so a high-core runner does not
# oversubscribe disk I/O on the temp dirs).
BATS_JOBS="${BATS_JOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 1 )}"
if [ "${BATS_JOBS}" -gt 8 ] 2>/dev/null; then BATS_JOBS=8; fi
if [ "${BATS_JOBS}" -gt 1 ] 2>/dev/null && command -v parallel >/dev/null 2>&1; then
  bold "  parallel run: --jobs ${BATS_JOBS} (across files; within-file serial)"
  BATS_ARGS+=(--jobs "$BATS_JOBS" --no-parallelize-within-files)
else
  bold "  serial run (GNU parallel unavailable or BATS_JOBS<=1)"
fi

if ! bats "${BATS_ARGS[@]+"${BATS_ARGS[@]}"}" "$TESTS_DIR/"; then
  red "bats suite failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3 — assert every public function is referenced from some .bats file.
# ---------------------------------------------------------------------------
bold "[3/4] Asserting public-function coverage (NFR-052)"

COVERED_JSON="$COVERAGE_DIR/coverage-summary.json"
: > "$COVERED_JSON.tmp"
printf '{\n  "gate": "NFR-052 public-function coverage",\n  "scripts": {\n' > "$COVERED_JSON.tmp"

uncovered_total=0
script_count=0
script_first=1
for s in "$SCRIPTS_DIR"/*.sh; do
  [ -f "$s" ] || continue
  name="$(basename "$s")"
  bats_file="$TESTS_DIR/${name%.sh}.bats"
  script_count=$((script_count + 1))

  funcs="$(enumerate_public_funcs "$s")"

  if [ -z "$funcs" ]; then
    bold "  $name: 0 public functions — skipping"
    continue
  fi

  covered=()
  uncovered=()
  # Bash 3.2 / nounset: avoid unbound-variable on empty arrays later.
  set +u
  for f in $funcs; do
    # Helper and internal-helper allowlist. Each entry is one of:
    #   (a) a trivial CLI shim (err/warn/die/log/usage) not worth a named
    #       bats assertion, or
    #   (b) an internal helper (E28-S184) exercised functionally through
    #       the parent script's bats suite but whose name is not mentioned
    #       textually in the .bats file. Rationales inline below.
    case "$f" in
      # (a) trivial CLI shims
      err|warn|die|die_usage|log|usage|print_usage|add_line|add_command) covered+=("$f"); continue ;;
      # (b) dead-reference-scan.sh internals — exercised via CLI fixture runs
      is_allowlisted|is_shell_variable_context) covered+=("$f"); continue ;;
      # (b) gaia-cleanup-legacy-engine.sh internals — guarded-delete helpers
      safe_remove_dir|safe_remove_file) covered+=("$f"); continue ;;
      # (b) init-project.sh internals — scaffolding helpers exercised via init-project.bats
      gaia_agent_display_name|gaia_agents_with_tier|gaia_file_is_header_only) covered+=("$f"); continue ;;
      gaia_header_for|gaia_sidecar_for|gaia_write_sidecar_file) covered+=("$f"); continue ;;
      # (b) memory-writer.sh internals — locking/atomic/timestamp/write helpers
      acquire_lock_flock|acquire_lock_mkdir|atomic_replace|now_iso8601) covered+=("$f"); continue ;;
      release_lock|resolve_sidecar_rel|write_decision|write_ground_truth) covered+=("$f"); continue ;;
      # (b) migrate-config-split.sh internals — yq expression/plan helpers
      build_del_expr|build_pick_expr|classify_key|plan_split) covered+=("$f"); continue ;;
      # (b) resolve-config.sh internals — merge/parse helpers
      # E57-S1: merge_doubly_nested_key + parse_yaml_doubly_nested_key are
      # exercised end-to-end via resolve-config's --field flag in
      # dev-story-tdd-review-config.bats (AC1/AC2/AC3).
      merge_key|merge_nested_key|parse_yaml_nested_key) covered+=("$f"); continue ;;
      merge_doubly_nested_key|parse_yaml_doubly_nested_key) covered+=("$f"); continue ;;
      # (b) review-runner.sh internals — CLI arg parser, reviewer dispatch, gate writer
      parse_args|run_reviewer|write_gate) covered+=("$f"); continue ;;
      # (b) sprint-status-dashboard.sh internals — row emitter + YAML extractor
      flush_story|yaml_val) covered+=("$f"); continue ;;
      # (b) validate-gate.sh internals — non-empty file check
      check_file_nonempty) covered+=("$f"); continue ;;
    esac
    if [ -f "$bats_file" ] && grep -q "$f" "$bats_file"; then
      covered+=("$f")
    else
      # Fall back: any .bats file at all references it
      if grep -rq "$f" "$TESTS_DIR"/*.bats 2>/dev/null; then
        covered+=("$f")
      else
        uncovered+=("$f")
      fi
    fi
  done

  if [ "$script_first" -eq 1 ]; then script_first=0; else printf ',\n' >> "$COVERED_JSON.tmp"; fi
  printf '    "%s": {\n      "covered": [' "$name" >> "$COVERED_JSON.tmp"
  first=1
  for f in "${covered[@]}"; do
    if [ "$first" -eq 1 ]; then first=0; else printf ', ' >> "$COVERED_JSON.tmp"; fi
    printf '"%s"' "$f" >> "$COVERED_JSON.tmp"
  done
  printf '],\n      "uncovered": [' >> "$COVERED_JSON.tmp"
  first=1
  for f in "${uncovered[@]}"; do
    if [ "$first" -eq 1 ]; then first=0; else printf ', ' >> "$COVERED_JSON.tmp"; fi
    printf '"%s"' "$f" >> "$COVERED_JSON.tmp"
    uncovered_total=$((uncovered_total + 1))
  done
  printf ']\n    }' >> "$COVERED_JSON.tmp"

  if [ "${#uncovered[@]}" -gt 0 ]; then
    red "  $name: uncovered public function(s): ${uncovered[*]}"
  else
    green "  $name: all public functions covered"
  fi
  set -u
done

printf '\n  },\n  "uncovered_total": %d,\n  "script_count": %d\n}\n' \
  "$uncovered_total" "$script_count" >> "$COVERED_JSON.tmp"
mv "$COVERED_JSON.tmp" "$COVERED_JSON"

if [ "$uncovered_total" -gt 0 ]; then
  red "NFR-052 gate FAILED — $uncovered_total uncovered public function(s)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4 — advisory kcov line-coverage report (optional).
# ---------------------------------------------------------------------------
bold "[4/4] Advisory kcov line-coverage (optional)"

if command -v kcov >/dev/null 2>&1; then
  kcov --bash-dont-parse-binary-dir \
       --include-path="$SCRIPTS_DIR" \
       "$COVERAGE_DIR/kcov" \
       bats "$TESTS_DIR/" || true
  green "kcov report: $COVERAGE_DIR/kcov/index.html"
else
  printf 'kcov not available — skipping line-coverage report (advisory only).\n'
fi

green "E28-S17 coverage wrapper: PASS"
exit 0
