#!/usr/bin/env bash
# check-public-function-coverage.sh — Static public-function coverage gate.
#
# Asserts every public function defined in plugins/gaia/scripts/*.sh is
# referenced by at least one .bats file under plugins/gaia/tests/.
# This is the same check as step 3 of run-with-coverage.sh, extracted so
# the sharded CI gate job can run it without re-executing the bats suite.
#
# Exit codes:
#   0 — every public function has at least one .bats reference
#   1 — one or more public functions are uncovered

set -euo pipefail
LC_ALL=C

REPO_ROOT="${1:-.}"
SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
TESTS_DIR="$REPO_ROOT/plugins/gaia/tests"
COVERAGE_DIR="${COVERAGE_DIR:-$REPO_ROOT/coverage}"

mkdir -p "$COVERAGE_DIR"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

enumerate_public_funcs() {
  local script_path="$1"
  { grep -E '^[a-z][a-z0-9_]*\(\)' "$script_path" || true; } \
    | sed -E 's/\(\).*$//' \
    | sort -u
}

bold "Asserting public-function coverage (static check)"

uncovered_total=0
script_count=0

for s in "$SCRIPTS_DIR"/*.sh; do
  [ -f "$s" ] || continue
  name="$(basename "$s")"
  bats_file="$TESTS_DIR/${name%.sh}.bats"
  script_count=$((script_count + 1))

  funcs="$(enumerate_public_funcs "$s")"

  if [ -z "$funcs" ]; then
    bold "  $name: 0 public functions -- skipping"
    continue
  fi

  set +u
  uncovered_here=0
  for f in $funcs; do
    # Allowlist: trivial CLI shims and internal helpers exercised functionally.
    case "$f" in
      err|warn|die|die_usage|log|usage|print_usage|add_line|add_command) continue ;;
      is_allowlisted|is_shell_variable_context) continue ;;
      safe_remove_dir|safe_remove_file) continue ;;
      gaia_agent_display_name|gaia_agents_with_tier|gaia_file_is_header_only) continue ;;
      gaia_header_for|gaia_sidecar_for|gaia_write_sidecar_file) continue ;;
      acquire_lock_flock|acquire_lock_mkdir|atomic_replace|now_iso8601) continue ;;
      release_lock|resolve_sidecar_rel|write_decision|write_ground_truth) continue ;;
      build_del_expr|build_pick_expr|classify_key|plan_split) continue ;;
      merge_key|merge_nested_key|parse_yaml_nested_key) continue ;;
      merge_doubly_nested_key|parse_yaml_doubly_nested_key) continue ;;
      parse_args|run_reviewer|write_gate) continue ;;
      flush_story|yaml_val) continue ;;
      check_file_nonempty) continue ;;
    esac
    found=0
    if [ -f "$bats_file" ] && grep -q "$f" "$bats_file"; then
      found=1
    elif grep -rq "$f" "$TESTS_DIR"/*.bats 2>/dev/null; then
      found=1
    fi
    if [ "$found" -eq 0 ]; then
      red "  $name: uncovered: $f"
      uncovered_here=$((uncovered_here + 1))
    fi
  done
  uncovered_total=$((uncovered_total + uncovered_here))
  if [ "$uncovered_here" -eq 0 ]; then
    green "  $name: all public functions covered"
  fi
  set -u
done

if [ "$uncovered_total" -gt 0 ]; then
  red "Public-function coverage FAILED -- $uncovered_total uncovered function(s)"
  exit 1
fi

green "Public-function coverage: PASS ($script_count scripts checked)"
exit 0
