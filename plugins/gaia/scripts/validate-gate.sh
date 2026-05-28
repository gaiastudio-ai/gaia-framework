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
# Brief: P2-S7 (.gaia/artifacts/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
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
#   test_plan_exists       — ${TEST_ARTIFACTS}/test-plan.md (or strategy/test-plan.md per ADR-072, or test-plan/index.md sharded layout per ADR-070)
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
# E96-S7 AC3: smart-fallback — env-var > .gaia/artifacts/<type>-artifacts/ (when
# present on disk, post-migration canonical) > legacy docs/<type>-artifacts/
# (in-deprecation-window consumers + bats fixtures). Env-var overrides win.
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"

if [ -z "${TEST_ARTIFACTS:-}" ]; then
  if [ -d "${PROJECT_ROOT}/.gaia/artifacts/test-artifacts" ]; then
    TEST_ARTIFACTS="${PROJECT_ROOT}/.gaia/artifacts/test-artifacts"
  else
    TEST_ARTIFACTS="docs/test-artifacts"
  fi
fi

if [ -z "${PLANNING_ARTIFACTS:-}" ]; then
  if [ -d "${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts" ]; then
    PLANNING_ARTIFACTS="${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts"
  else
    PLANNING_ARTIFACTS="docs/planning-artifacts"
  fi
fi

if [ -z "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
  if [ -d "${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" ]; then
    IMPLEMENTATION_ARTIFACTS="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts"
  else
    IMPLEMENTATION_ARTIFACTS="docs/implementation-artifacts"
  fi
fi

# ---------- Constants ----------
# Supported gate list — keep in sync with gate_path() case block below.
SUPPORTED_GATES="file_exists test_plan_exists traceability_exists ci_setup_exists atdd_exists readiness_report_exists epics_and_stories_exists prd_exists config_phase_gate"

# Supported artifact types for config_phase_gate (E85-S4 — keep in sync with
# required_phase_for_artifact() / remediation_for_artifact() case blocks below).
SUPPORTED_ARTIFACT_TYPES="prd architecture infra-design test-plan epics"

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
  validate-gate.sh <gate_type> [--story <key>] [--file <path>...] [--artifact-type <type>]
  validate-gate.sh --multi <gate_type>,<gate_type>,... [--artifact-type <type>]
  validate-gate.sh --list
  validate-gate.sh --help

Flags:
  --story <key>          Story key (required by atdd_exists), e.g. E1-S1
  --file <path>          File path for file_exists (repeatable)
  --artifact-type <type> Artifact type for config_phase_gate (E85-S4):
                         prd | architecture | infra-design | test-plan | epics
  --multi <list>         Comma-separated list of gate types to evaluate in order
  --list                 Print every supported gate type and its path pattern
  --help                 Print this usage message and exit 0

Supported gate types:
  file_exists             Check every --file <path> argument
  test_plan_exists        ${TEST_ARTIFACTS}/test-plan.md OR ${TEST_ARTIFACTS}/strategy/test-plan.md OR ${TEST_ARTIFACTS}/test-plan/index.md
  traceability_exists     ${TEST_ARTIFACTS}/traceability-matrix.md OR ${TEST_ARTIFACTS}/strategy/traceability-matrix.md OR ${TEST_ARTIFACTS}/traceability-matrix/index.md
  ci_setup_exists         ${TEST_ARTIFACTS}/ci-setup.md
  atdd_exists             ${TEST_ARTIFACTS}/atdd-<story>.md  (requires --story)
  readiness_report_exists ${PLANNING_ARTIFACTS}/readiness-report.md OR ${PLANNING_ARTIFACTS}/readiness-report/index.md
  epics_and_stories_exists ${PLANNING_ARTIFACTS}/epics-and-stories.md OR ${PLANNING_ARTIFACTS}/epics-and-stories/index.md
  prd_exists              ${PLANNING_ARTIFACTS}/prd.md OR ${PLANNING_ARTIFACTS}/prd/index.md
  config_phase_gate       ${PROJECT_ROOT}/config/project-config.yaml — config_phase >= required-for-artifact (requires --artifact-type)

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
    config_phase_gate)       return 3 ;;
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
  local g pattern rc alt strategy_alt strategy_named
  for g in $SUPPORTED_GATES; do
    if [ "$g" = "file_exists" ]; then
      printf '%s\t%s\n' "$g" "(uses --file <path> args)"
      continue
    fi
    if [ "$g" = "config_phase_gate" ]; then
      printf '%s\t%s\n' "$g" "\${PROJECT_ROOT}/config/project-config.yaml (requires --artifact-type: $SUPPORTED_ARTIFACT_TYPES)"
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
      #
      # AI-2026-05-16-9: test_plan_exists also accepts the post-E53 / ADR-072
      # `strategy/test-plan.md` placement, mirroring the traceability_exists
      # treatment from E53-S248. The canonical test-plan in projects with
      # an E53-style docs reorganization lives under strategy/.
      case "$g" in
        test_plan_exists)
          # AF-2026-05-22-5: also accept strategy/test-strategy.md (renamed by /gaia-test-strategy).
          alt="${pattern%.md}/index.md"
          strategy_alt="${pattern%/*}/strategy/${pattern##*/}"
          strategy_named="${pattern%/*}/strategy/test-strategy.md"
          printf '%s\t%s OR %s OR %s OR %s\n' "$g" "$pattern" "$strategy_alt" "$strategy_named" "$alt"
          continue
          ;;
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
      # E105-S2 / ADR-127 §7.2: the NEW canonical home for docs-about-testing is
      # planning-artifacts/ (traceability-matrix moved out of test-artifacts/).
      # Highest-precedence read-side fallback; the legacy strategy/ + flat arms
      # below remain for the migration read-compat window (ADR-070 three-tier).
      if [ -n "${PLANNING_ARTIFACTS:-}" ] && [ -f "${PLANNING_ARTIFACTS}/traceability-matrix.md" ]; then
        if [ ! -s "${PLANNING_ARTIFACTS}/traceability-matrix.md" ]; then
          abs=$(abs_path "${PLANNING_ARTIFACTS}/traceability-matrix.md")
          warn "$gate failed — file is empty (0 bytes): $abs"
          return 1
        fi
        return 0
      fi
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
    */test-plan.md)
      # E105-S2 / ADR-127 §7.2: the NEW canonical home for docs-about-testing is
      # planning-artifacts/ (test-plan moved out of test-artifacts/). Highest-
      # precedence read-side fallback; the legacy strategy/ + test-strategy.md +
      # flat arms below remain for the migration read-compat window. Also accept
      # the renamed test-strategy.md at the new home.
      if [ -n "${PLANNING_ARTIFACTS:-}" ]; then
        for _pa in "${PLANNING_ARTIFACTS}/test-plan.md" "${PLANNING_ARTIFACTS}/test-strategy.md"; do
          if [ -f "$_pa" ]; then
            if [ ! -s "$_pa" ]; then
              abs=$(abs_path "$_pa")
              warn "$gate failed — file is empty (0 bytes): $abs"
              return 1
            fi
            return 0
          fi
        done
      fi
      # AI-2026-05-16-9: post-E53 / ADR-072 placement under strategy/. The
      # canonical test plan ships at `${TEST_ARTIFACTS}/strategy/test-plan.md`
      # since the E53 docs reorganization, mirroring traceability-matrix.md
      # above. Without this resolution arm, /gaia-add-feature setup.sh HALTs
      # every enhancement/feature classification with "test-plan.md is missing"
      # even when the strategy/ canonical exists.
      dir="${filepath%/*}"
      alt="$dir/strategy/test-plan.md"
      if [ -f "$alt" ]; then
        if [ ! -s "$alt" ]; then
          abs=$(abs_path "$alt")
          warn "$gate failed — file is empty (0 bytes): $abs"
          return 1
        fi
        return 0
      fi
      # AF-2026-05-22-5: /gaia-test-strategy --plan renamed the artifact from
      # test-plan.md to test-strategy.md (and ships under strategy/). Accept
      # both filenames so the documented happy path /gaia-test-strategy --plan
      # → /gaia-create-epics succeeds without a workaround. Sibling resolution
      # arms above (strategy/test-plan.md, test-plan/index.md) remain unchanged.
      strategy_named="$dir/strategy/test-strategy.md"
      if [ -f "$strategy_named" ]; then
        if [ ! -s "$strategy_named" ]; then
          abs=$(abs_path "$strategy_named")
          warn "$gate failed — file is empty (0 bytes): $abs"
          return 1
        fi
        return 0
      fi
      ;;
  esac
  # No layout exists — report the flat path (log-parser contract).
  # AF-2026-05-22-5: when the test_plan gate fails, also list the alternate
  # canonical paths so users aren't pointed at the legacy/flat location only.
  abs=$(abs_path "$filepath")
  case "$gate" in
    test_plan_exists)
      dir="${filepath%/*}"
      warn "$gate failed — expected one of: $abs OR $(abs_path "$dir/strategy/test-plan.md") OR $(abs_path "$dir/strategy/test-strategy.md") OR $(abs_path "${filepath%.md}/index.md") OR $(abs_path "${PLANNING_ARTIFACTS:-./.gaia/artifacts/planning-artifacts}/test-plan.md") OR $(abs_path "${PLANNING_ARTIFACTS:-./.gaia/artifacts/planning-artifacts}/test-strategy.md")"
      ;;
    traceability_exists)
      # AF-2026-05-28-1 / Test07 D-6: the gate accepts FOUR locations (canonical
      # planning-artifacts/ post-E105-S2 / ADR-127 §7.2 PLUS three legacy
      # test-artifacts/ placements per ADR-070 / ADR-072). The prior error
      # message named ONLY the flat legacy test-artifacts path, misleading
      # users into thinking the producer wrote to the wrong place when the
      # actual issue was a missing file at any accepted location.
      dir="${filepath%/*}"
      warn "$gate failed — expected one of: $(abs_path "${PLANNING_ARTIFACTS:-./.gaia/artifacts/planning-artifacts}/traceability-matrix.md") (canonical) OR $abs OR $(abs_path "$dir/strategy/traceability-matrix.md") OR $(abs_path "${filepath%.md}/index.md")"
      ;;
    *)
      warn "$gate failed — expected: $abs"
      ;;
  esac
  return 1
}

# ---------- config_phase_gate helpers (E85-S4) ----------
#
# Phase ordinal: minimal=0, partial=1, full=2. Bash 3.2 portable case block —
# no `declare -A`. Returns the integer on stdout or exit 1 for invalid input
# (caller treats this as a separate failure mode per ADR-101 §6).
phase_ordinal() {
  case "$1" in
    minimal) printf '0' ;;
    partial) printf '1' ;;
    full)    printf '2' ;;
    *)       return 1 ;;
  esac
}

# Required phase for an artifact type. Hardcoded per the story Technical Notes
# table. Exit 1 = unknown artifact type (caller surfaces a distinct error).
required_phase_for_artifact() {
  case "$1" in
    prd|epics)                    printf 'minimal' ;;
    architecture|infra-design|test-plan) printf 'partial' ;;
    *) return 1 ;;
  esac
}

# Sections that an artifact type requires (used in the failure message and the
# SR-44 content cross-reference). Space-separated on stdout for predictable
# tokenisation.
required_sections_for_artifact() {
  case "$1" in
    prd|epics)        printf 'project_name project_kind' ;;
    architecture)     printf 'stacks platforms' ;;
    infra-design)     printf 'environments ci_cd' ;;
    test-plan)        printf 'stacks platforms' ;;
    *) return 1 ;;
  esac
}

# Remediation command suggestion for an artifact type.
remediation_for_artifact() {
  case "$1" in
    prd|epics)     printf '/gaia-init' ;;
    architecture)  printf '/gaia-create-arch' ;;
    infra-design)  printf '/gaia-infra-design' ;;
    test-plan)     printf '/gaia-create-arch' ;;
    *) return 1 ;;
  esac
}

# Sections that must be present for a given phase (SR-44 content cross-reference).
# partial -> stacks + platforms; full -> stacks + platforms + environments + ci_cd.
# minimal has no SR-44 content requirements beyond the base project_name /
# project_kind (those are validated by the schema layer in E85-S2, not here).
sections_for_phase() {
  case "$1" in
    minimal) printf '' ;;
    partial) printf 'stacks platforms' ;;
    full)    printf 'stacks platforms environments ci_cd' ;;
    *) return 1 ;;
  esac
}

# Read config_phase from ${PROJECT_ROOT}/.gaia/config/project-config.yaml
# (canonical per ADR-111; legacy ${PROJECT_ROOT}/config/project-config.yaml
# retained as fallback on pre-migration installs — see the `if [ -f .gaia/...`
# / `else cfg=...` branches below at lines 415-420, 444-449, 543-548).
# Absence-means-full per NFR-062 / ADR-097: missing file OR missing field =>
# "full". yq is a soft dependency — if absent, treat as "full".
# Emits the raw value on stdout (caller validates the enum).
read_config_phase() {
  # E96-S1 / ADR-111: prefer `.gaia/config/` over legacy `config/` location.
  local cfg
  if [ -f "${PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
    cfg="${PROJECT_ROOT}/.gaia/config/project-config.yaml"
  else
    cfg="${PROJECT_ROOT}/config/project-config.yaml"
  fi
  if [ ! -f "$cfg" ]; then
    printf 'full'
    return 0
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'full'
    return 0
  fi
  local val
  val=$(yq -r '.config_phase // "full"' "$cfg" 2>/dev/null || printf 'full')
  # yq may emit "null" if the key is explicitly null; coerce to "full".
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    val="full"
  fi
  printf '%s' "$val"
}

# Check whether a top-level section in project-config.yaml is "present and
# non-empty". Returns 0 = present, 1 = missing/empty/yq-unavailable.
# Used by SR-44 content cross-reference (AC7).
config_section_present() {
  local section="$1"
  # E96-S1 / ADR-111: prefer `.gaia/config/` over legacy `config/` location.
  local cfg
  if [ -f "${PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
    cfg="${PROJECT_ROOT}/.gaia/config/project-config.yaml"
  else
    cfg="${PROJECT_ROOT}/config/project-config.yaml"
  fi
  if [ ! -f "$cfg" ]; then
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    # Without yq we cannot verify content; the gate degrades to phase-ordinal-only.
    return 0
  fi
  local kind length
  # `type` reports !!map / !!seq / !!str / !!null / "object"|"array"|"string"|"null"
  # (Go-yq normalises to YAML tag form; Python yq normalises to JSON-ish).
  kind=$(yq -r ".${section} | type" "$cfg" 2>/dev/null || printf '')
  case "$kind" in
    *null*|"") return 1 ;;
  esac
  # For map/object: at least one key required. For seq/array: at least one element.
  case "$kind" in
    *map*|*object*)
      length=$(yq -r ".${section} | length" "$cfg" 2>/dev/null || printf '0')
      [ "${length:-0}" -gt 0 ] 2>/dev/null
      return $?
      ;;
    *seq*|*array*)
      length=$(yq -r ".${section} | length" "$cfg" 2>/dev/null || printf '0')
      [ "${length:-0}" -gt 0 ] 2>/dev/null
      return $?
      ;;
    *string*|*str*)
      length=$(yq -r ".${section}" "$cfg" 2>/dev/null || printf '')
      [ -n "$length" ]
      return $?
      ;;
    *)
      # Anything else (scalar, number, bool): treat as present if non-null.
      return 0
      ;;
  esac
}

# Evaluate config_phase_gate. Returns 0 on pass, 1 on fail.
# Uses ARTIFACT_TYPE from outer scope (set by --artifact-type arg parsing).
evaluate_config_phase_gate() {
  local artifact="${ARTIFACT_TYPE:-}"
  if [ -z "$artifact" ]; then
    warn "config_phase_gate requires --artifact-type <type>"
    warn "supported: $SUPPORTED_ARTIFACT_TYPES"
    return 1
  fi

  # AC8 — unknown artifact type rejection.
  local required
  set +e
  required=$(required_phase_for_artifact "$artifact")
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    warn "Unknown artifact type '$artifact' -- supported: prd, architecture, infra-design, test-plan, epics"
    return 1
  fi

  # AC4 — read current phase (absence-means-full).
  local current
  current=$(read_config_phase)

  # AC6 — invalid enum rejection (defense-in-depth, ADR-101 §6).
  local cur_ord req_ord
  set +e
  cur_ord=$(phase_ordinal "$current")
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    warn "Invalid config_phase value '$current' -- expected one of: minimal, partial, full"
    return 1
  fi
  req_ord=$(phase_ordinal "$required")

  # AC3 — phase ordinal comparison.
  if [ "$cur_ord" -lt "$req_ord" ]; then
    local sections command
    sections=$(required_sections_for_artifact "$artifact")
    command=$(remediation_for_artifact "$artifact")
    warn "config_phase_gate failed -- config_phase is '$current' but '$artifact' requires '$required'. Missing sections: $sections. Run $command to hydrate."
    return 1
  fi

  # AC7 — SR-44 phase-vs-content cross-reference. Only verify the sections
  # claimed by the CURRENT phase (not the artifact's required phase) — if the
  # config claims partial, partial-level sections must exist; if it claims full,
  # full-level sections must exist. minimal has no SR-44 content claims.
  #
  # Skip SR-44 entirely when the config file is absent: NFR-062 / ADR-097
  # "absence-means-full" is a graceful-degradation default, not a content
  # claim — there is nothing to cross-reference, so the gate passes.
  # E96-S1 / ADR-111: prefer `.gaia/config/` over legacy `config/` location.
  local cfg
  if [ -f "${PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
    cfg="${PROJECT_ROOT}/.gaia/config/project-config.yaml"
  else
    cfg="${PROJECT_ROOT}/config/project-config.yaml"
  fi
  if [ ! -f "$cfg" ]; then
    return 0
  fi
  local claimed_sections section
  claimed_sections=$(sections_for_phase "$current")
  if [ -n "$claimed_sections" ]; then
    for section in $claimed_sections; do
      if ! config_section_present "$section"; then
        warn "config_phase_gate failed -- config_phase is '$current' but section '$section' is missing -- phase/content mismatch (CRITICAL)"
        return 1
      fi
    done
  fi

  return 0
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
    config_phase_gate)
      evaluate_config_phase_gate
      return $?
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
ARTIFACT_TYPE=""
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
    --artifact-type)
      [ $# -ge 2 ] || die_usage "--artifact-type requires a value"
      ARTIFACT_TYPE="$2"
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
