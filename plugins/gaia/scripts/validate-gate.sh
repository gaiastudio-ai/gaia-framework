#!/usr/bin/env bash
# validate-gate.sh — GAIA foundation script (E28-S15)
#
# Evaluates quality-gate preconditions deterministically so workflows can
# enforce `quality_gates.pre_start` / `quality_gates.post_complete` blocks
# without relying on LLM interpretation. Replaces the model's ad-hoc
# "check if test-plan.md exists" prompts with a shell-callable contract.
#
# Refs: FR-325 (foundation scripts unlock token reduction),
#       FR-328 (engine deletion prerequisite),
#       NFR-048 (40–55% token reduction),
#       ADR-042 (foundation scripts catalog, §10.26.3),
#       ADR-048 (engine deletion as program-closing action).
# Brief: P2-S7 (docs/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Consumers: every workflow declaring quality_gates.pre_start /
# quality_gates.post_complete, the testing-integration gates enumerated in
# CLAUDE.md, and the review-gate orchestrator (E28-S14).
#
# Usage:
#   validate-gate.sh <gate_type> [--story <key>] [--file <path>...]
#   validate-gate.sh --multi <gate_type>,<gate_type>,...
#   validate-gate.sh --list
#   validate-gate.sh --help
#
# Supported gate types:
#   file_exists            — checks every --file <path> argument
#   test_plan_exists       — ${TEST_ARTIFACTS}/test-plan.md
#   traceability_exists    — ${TEST_ARTIFACTS}/traceability-matrix.md (or strategy/traceability-matrix.md per ADR-072, or traceability-matrix/index.md sharded layout per ADR-070)
#   ci_setup_exists        — ${TEST_ARTIFACTS}/ci-setup.md
#   atdd_exists            — ${TEST_ARTIFACTS}/atdd-<story>.md (requires --story)
#   readiness_report_exists — ${PLANNING_ARTIFACTS}/readiness-report.md (or readiness-report/index.md sharded layout per ADR-070 / ADR-072)
#   epics_and_stories_exists — ${PLANNING_ARTIFACTS}/epics-and-stories.md (or epics-and-stories/index.md sharded layout per ADR-070 / ADR-072)
#   prd_exists              — ${PLANNING_ARTIFACTS}/prd.md (or prd/index.md sharded layout per ADR-070 / ADR-072)
#
# Error format (stable for log parsers / tailing sync agent):
#   validate-gate: <gate_type> failed — expected: <abs_path>
#
# Exit codes:
#   0 — gate(s) passed, or --list / --help completed
#   1 — gate failed, missing args, or unknown gate type
#
# Implementation notes:
#   - Uses a `case` block (not `declare -A`) to stay portable to /bin/bash 3.2
#     on macOS. The table below is the single source of truth; it is
#     intentionally append-only so new gates can be added without breaking
#     the CLI contract.
#   - --multi re-enters evaluate_gate() in the same process (no subshell,
#     no re-exec) to keep a 6-gate chain comfortably under NFR-048's
#     foundation-script latency budget (~50ms wall clock).
#   - resolve-config.sh is a soft dependency — this script degrades via
#     ${VAR:-default} fallbacks so the two scripts can land in any order.
#   - Dual-layout invariant (E53-S233): any gate whose pattern resolves to
#     `{dir}/{name}.md` ALSO accepts `{dir}/{name}/index.md`. The flat
#     layout is checked first; the sharded layout is the additive fallback.
#     Mirror of F-S225-PATH-RESOLVER (#400) and F-S231-DEDUP (#401) — same
#     systemic class, gate-validation layer. Implemented generically via
#     shell parameter expansion (${P%.md}/index.md), NOT per-gate `case`.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------- Fallback config resolution (parallel dev with resolve-config.sh) ----------
TEST_ARTIFACTS="${TEST_ARTIFACTS:-docs/test-artifacts}"
PLANNING_ARTIFACTS="${PLANNING_ARTIFACTS:-docs/planning-artifacts}"
IMPLEMENTATION_ARTIFACTS="${IMPLEMENTATION_ARTIFACTS:-docs/implementation-artifacts}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"

# ---------- Constants ----------
# Supported gate list — keep in sync with gate_path() case block below.
SUPPORTED_GATES="file_exists test_plan_exists traceability_exists ci_setup_exists atdd_exists readiness_report_exists epics_and_stories_exists prd_exists"

# ---------- Helpers ----------

warn() {
  printf 'validate-gate: %s\n' "$1" >&2
}

die_usage() {
  [ -n "${1:-}" ] && warn "$1"
  print_usage >&2
  exit 1
}

print_usage() {
  cat <<'USAGE'
Usage:
  validate-gate.sh <gate_type> [--story <key>] [--file <path>...]
  validate-gate.sh --multi <gate_type>,<gate_type>,...
  validate-gate.sh --list
  validate-gate.sh --help

Flags:
  --story <key>   Story key (required by atdd_exists), e.g. E1-S1
  --file <path>   File path for file_exists (repeatable)
  --multi <list>  Comma-separated list of gate types to evaluate in order
  --list          Print every supported gate type and its path pattern
  --help          Print this usage message and exit 0

Supported gate types:
  file_exists             Check every --file <path> argument
  test_plan_exists        ${TEST_ARTIFACTS}/test-plan.md
  traceability_exists     ${TEST_ARTIFACTS}/traceability-matrix.md OR ${TEST_ARTIFACTS}/strategy/traceability-matrix.md OR ${TEST_ARTIFACTS}/traceability-matrix/index.md
  ci_setup_exists         ${TEST_ARTIFACTS}/ci-setup.md
  atdd_exists             ${TEST_ARTIFACTS}/atdd-<story>.md  (requires --story)
  readiness_report_exists ${PLANNING_ARTIFACTS}/readiness-report.md OR ${PLANNING_ARTIFACTS}/readiness-report/index.md
  epics_and_stories_exists ${PLANNING_ARTIFACTS}/epics-and-stories.md OR ${PLANNING_ARTIFACTS}/epics-and-stories/index.md
  prd_exists              ${PLANNING_ARTIFACTS}/prd.md OR ${PLANNING_ARTIFACTS}/prd/index.md

Exit codes:
  0  gate(s) passed, or --list / --help completed
  1  gate failed, missing args, or unknown gate type
USAGE
}

# Resolve a path to absolute form for stable error messages.
abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null || printf '%s' "$p"
  elif [ "${p#/}" != "$p" ]; then
    printf '%s' "$p"
  else
    printf '%s/%s' "$PWD" "$p"
  fi
}

# Single source of truth: gate type → path pattern.
# Returns the pattern on stdout, or exit 2 for "unknown gate type",
# or exit 3 for "special — handled by evaluate_gate" (file_exists).
gate_path() {
  local gate="$1"
  case "$gate" in
    file_exists)             return 3 ;;
    test_plan_exists)        printf '%s/test-plan.md' "$TEST_ARTIFACTS" ;;
    traceability_exists)     printf '%s/traceability-matrix.md' "$TEST_ARTIFACTS" ;;
    ci_setup_exists)         printf '%s/ci-setup.md' "$TEST_ARTIFACTS" ;;
    atdd_exists)             printf '%s/atdd-{story}.md' "$TEST_ARTIFACTS" ;;
    readiness_report_exists) printf '%s/readiness-report.md' "$PLANNING_ARTIFACTS" ;;
    epics_and_stories_exists) printf '%s/epics-and-stories.md' "$PLANNING_ARTIFACTS" ;;
    prd_exists)              printf '%s/prd.md' "$PLANNING_ARTIFACTS" ;;
    *) return 2 ;;
  esac
}

list_gates() {
  local g pattern rc alt strategy_alt
  for g in $SUPPORTED_GATES; do
    if [ "$g" = "file_exists" ]; then
      printf '%s\t%s\n' "$g" "(uses --file <path> args)"
      continue
    fi
    set +e
    pattern=$(gate_path "$g")
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then
      # Dual-layout invariant (E53-S233): any gate whose pattern resolves to
      # `{dir}/{name}.md` ALSO accepts `{dir}/{name}/index.md`. Render both
      # paths in --list output. The atdd_exists pattern uses a `{story}`
      # template (not a fixed path) — keep it single-layout.
      #
      # E53-S248: traceability_exists also accepts the post-E53 / ADR-072
      # `strategy/traceability-matrix.md` placement; render the third path
      # so the documented contract matches the implementation.
      case "$g" in
        traceability_exists)
          alt="${pattern%.md}/index.md"
          strategy_alt="${pattern%/*}/strategy/${pattern##*/}"
          printf '%s\t%s OR %s OR %s\n' "$g" "$pattern" "$strategy_alt" "$alt"
          continue
          ;;
      esac
      case "$pattern" in
        *'{story}'*)
          printf '%s\t%s\n' "$g" "$pattern"
          ;;
        *.md)
          alt="${pattern%.md}/index.md"
          printf '%s\t%s OR %s\n' "$g" "$pattern" "$alt"
          ;;
        *)
          printf '%s\t%s\n' "$g" "$pattern"
          ;;
      esac
    fi
  done
}

# Check that a file exists and is non-empty. Returns 0 on pass, 1 on fail.
# Args: gate_name file_path
#
# Dual-layout invariant (E53-S233): if `filepath` ends in `.md` and the flat
# path does not exist, the resolver also accepts the sharded sibling
# `${filepath%.md}/index.md` (per ADR-070 / ADR-072). Mirror of
# F-S225-PATH-RESOLVER (#400) and F-S231-DEDUP (#401) — same systemic class,
# gate-validation layer.
#
# Resolution order:
#   1. Flat path `{dir}/{name}.md` (existence + non-empty)
#   2. Sharded path `{dir}/{name}/index.md` (existence + non-empty)
#   3. Gate-specific legacy directory-name aliases (e.g. for
#      `epics-and-stories.md` also accept the shortened sharded form
#      `epics/index.md` — used by brownfield projects whose shard root was
#      named `epics/` before ADR-070 fixed the canonical name to
#      `epics-and-stories/`).
#
# Failure modes:
#   - No layout exists → report the FLAT path (preserves the stable
#     log-parser contract: "validate-gate: <gate> failed — expected: <abs_path>").
#   - The resolved file (flat OR index.md) is 0 bytes → report the actual
#     resolved path so log readers can locate the empty artifact.
#
# The primary fallback is implemented generically via shell parameter
# expansion (`${filepath%.md}/index.md`) — NOT via a per-gate `case` arm.
# Any future `<artifact>_exists` gate whose pattern matches `{dir}/{name}.md`
# inherits dual-layout acceptance with no further code change. Step 3
# handles a small, documented set of legacy directory-name aliases so
# brownfield projects with pre-ADR-070 shard roots keep working without
# requiring a destructive directory rename.
check_file_nonempty() {
  local gate="$1" filepath="$2" abs alt dir
  # Step 1: try the flat path first.
  if [ -f "$filepath" ]; then
    if [ ! -s "$filepath" ]; then
      abs=$(abs_path "$filepath")
      warn "$gate failed — file is empty (0 bytes): $abs"
      return 1
    fi
    return 0
  fi
  # Step 2: derive sharded fallback only when the target ends in .md.
  case "$filepath" in
    *.md)
      alt="${filepath%.md}/index.md"
      if [ -f "$alt" ]; then
        if [ ! -s "$alt" ]; then
          abs=$(abs_path "$alt")
          warn "$gate failed — file is empty (0 bytes): $abs"
          return 1
        fi
        return 0
      fi
      ;;
  esac
  # Step 3: gate-specific legacy directory-name aliases. Brownfield projects
  # migrated before ADR-070 fixed the canonical sharded directory name may
  # ship `epics/index.md` instead of `epics-and-stories/index.md`. Accept
  # that legacy form so the gate does not falsely halt the cascade.
  case "$filepath" in
    */epics-and-stories.md)
      dir="${filepath%/*}"
      alt="$dir/epics/index.md"
      if [ -f "$alt" ]; then
        if [ ! -s "$alt" ]; then
          abs=$(abs_path "$alt")
          warn "$gate failed — file is empty (0 bytes): $abs"
          return 1
        fi
        return 0
      fi
      ;;
    */traceability-matrix.md)
      # E53-S248: post-E53 / ADR-072 placement under strategy/. The
      # canonical artifact ships at `${TEST_ARTIFACTS}/strategy/traceability-matrix.md`
      # since the E53 docs reorganization. Accept it here as a third
      # resolution arm so downstream consumers (readiness-check,
      # dev-story planning gate) stop reporting false-negative BLOCKED on
      # the live layout. Sibling pattern to the epics-and-stories alias
      # above — same shape, gate-specific.
      dir="${filepath%/*}"
      alt="$dir/strategy/traceability-matrix.md"
      if [ -f "$alt" ]; then
        if [ ! -s "$alt" ]; then
          abs=$(abs_path "$alt")
          warn "$gate failed — file is empty (0 bytes): $abs"
          return 1
        fi
        return 0
      fi
      ;;
  esac
  # No layout exists — report the flat path (log-parser contract).
  abs=$(abs_path "$filepath")
  warn "$gate failed — expected: $abs"
  return 1
}

# Evaluate a single gate. Returns 0 on pass, 1 on fail.
# Args: gate_type
# Uses FILE_ARGS array and STORY_KEY from outer scope.
evaluate_gate() {
  local gate="$1"
  local pattern rc path

  case "$gate" in
    file_exists)
      if [ "${#FILE_ARGS[@]}" -eq 0 ]; then
        # Zero --file args is a passing no-op (Cluster 4 setup.sh convention:
        # brainstorm-project has no prereq artifacts and passes an empty set).
        return 0
      fi
      local f
      for f in "${FILE_ARGS[@]}"; do
        check_file_nonempty "$gate" "$f" || return 1
      done
      return 0
      ;;
    atdd_exists)
      if [ -z "${STORY_KEY:-}" ]; then
        warn "atdd_exists requires --story <key>"
        return 1
      fi
      set +e
      pattern=$(gate_path "$gate")
      rc=$?
      set -e
      if [ $rc -ne 0 ]; then
        warn "internal error resolving gate pattern for $gate"
        return 1
      fi
      path="${pattern/\{story\}/$STORY_KEY}"
      check_file_nonempty "$gate" "$path"
      return $?
      ;;
    *)
      set +e
      pattern=$(gate_path "$gate")
      rc=$?
      set -e
      if [ $rc -eq 2 ]; then
        warn "unknown gate type: $gate"
        warn "supported: $SUPPORTED_GATES"
        return 1
      fi
      if [ $rc -ne 0 ]; then
        warn "internal error resolving gate pattern for $gate"
        return 1
      fi
      check_file_nonempty "$gate" "$pattern"
      return $?
      ;;
  esac
}

# ---------- Argument parsing ----------

GATE_TYPE=""
STORY_KEY=""
MULTI_LIST=""
DO_LIST=0
DO_HELP=0
FILE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      DO_HELP=1
      shift
      ;;
    --list)
      DO_LIST=1
      shift
      ;;
    --story)
      [ $# -ge 2 ] || die_usage "--story requires a value"
      STORY_KEY="$2"
      shift 2
      ;;
    --file)
      [ $# -ge 2 ] || die_usage "--file requires a value"
      FILE_ARGS+=("$2")
      shift 2
      ;;
    --multi)
      [ $# -ge 2 ] || die_usage "--multi requires a comma-separated value"
      MULTI_LIST="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [ -z "$GATE_TYPE" ]; then
        GATE_TYPE="$1"
        shift
      else
        die_usage "unexpected positional argument: $1"
      fi
      ;;
  esac
done

# ---------- Dispatch ----------

if [ $DO_HELP -eq 1 ]; then
  print_usage
  exit 0
fi

if [ $DO_LIST -eq 1 ]; then
  list_gates
  exit 0
fi

if [ -n "$MULTI_LIST" ]; then
  # Split on commas and evaluate in order; fail fast.
  IFS=',' read -r -a MULTI_GATES <<< "$MULTI_LIST"
  count=0
  for g in "${MULTI_GATES[@]}"; do
    # Trim whitespace
    g="${g#"${g%%[![:space:]]*}"}"
    g="${g%"${g##*[![:space:]]}"}"
    [ -z "$g" ] && continue
    count=$((count + 1))
    if ! evaluate_gate "$g"; then
      warn "multi chain failed at gate $count: $g"
      exit 1
    fi
  done
  warn "all $count gates passed"
  exit 0
fi

if [ -z "$GATE_TYPE" ]; then
  die_usage "missing <gate_type>"
fi

if evaluate_gate "$GATE_TYPE"; then
  exit 0
else
  exit 1
fi
