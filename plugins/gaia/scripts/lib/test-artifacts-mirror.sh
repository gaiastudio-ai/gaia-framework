#!/usr/bin/env bash
# test-artifacts-mirror.sh — AF-2026-05-31-3 / Test14 F-15
#
# Shared writer for the per-story test-artifacts/ mirror + per-tier
# execution-evidence split.
#
# Test14 §F-15 caught that the test-lens review artifacts (qa-tests.md,
# test-automation.md, test-review.md) AND the execution-evidence.json
# were all co-located under
#   .gaia/artifacts/implementation-artifacts/{epic}/{key}/reviews/
# even though the target layout expects them mirrored at
#   .gaia/artifacts/test-artifacts/{epic}/{key}/
# with the evidence split per-tier under
#   .gaia/artifacts/test-artifacts/{epic}/{key}/execution-evidence/{qa-tests,test-automation,test-review}.json
#
# This helper centralises the mirror write so each of the three test-lens
# review skills (gaia-qa-tests, gaia-test-automate, gaia-test-review) and
# the bridge's run-tests.sh have ONE place to call. The implementation-
# artifacts/ copies remain as the primary, byte-identical write — the
# mirror is purely additive (no behaviour change for callers that don't
# invoke the helper).
#
# Usage:
#   . test-artifacts-mirror.sh
#   test_artifacts_mirror_report  <story-key> <impl-report-path> <report-type>
#   test_artifacts_mirror_evidence <story-key> <impl-evidence-path> <tier>
#
# <report-type>:  qa-tests | test-automation | test-review
# <tier>:         qa-tests | test-automation | test-review
#
# All paths are resolved from CLAUDE_PROJECT_ROOT (or PWD when unset).
# Errors are non-fatal — the helper logs a WARNING and returns 0 so a
# missing target directory never breaks the primary review write path.

# Idempotent against re-sourcing.
[ "${_TEST_ARTIFACTS_MIRROR_LOADED:-0}" = "1" ] && return 0
_TEST_ARTIFACTS_MIRROR_LOADED=1

_taim_log()  { printf 'INFO: test-artifacts-mirror: %s\n' "$*" >&2; }
_taim_warn() { printf 'WARNING: test-artifacts-mirror: %s\n' "$*" >&2; }

# _taim_resolve_target_dir <story-key>
# Echoes the absolute test-artifacts/{epic}/{key}/ target dir. The epic
# slug is derived from the implementation-artifacts per-story dir layout
# (epic-{slug}/{key}-{slug}/) so the mirror tree shape matches the
# implementation tree shape 1:1.
_taim_resolve_target_dir() {
  local story_key="$1"
  local proj_root="${CLAUDE_PROJECT_ROOT:-$PWD}"
  local impl_root="${proj_root}/.gaia/artifacts/implementation-artifacts"
  local test_root="${proj_root}/.gaia/artifacts/test-artifacts"

  # Locate the per-story dir under impl_root: epic-{slug}/{key}-{slug}/.
  local story_dir
  story_dir="$(find "$impl_root" -type d -name "${story_key}-*" 2>/dev/null | head -1)"
  if [ -z "$story_dir" ]; then
    return 1
  fi
  # Compute the relative path inside impl_root, then re-anchor under test_root.
  local rel="${story_dir#${impl_root}/}"
  printf '%s/%s' "$test_root" "$rel"
}

# test_artifacts_mirror_report <story-key> <impl-report-path> <report-type>
test_artifacts_mirror_report() {
  local story_key="${1:-}"
  local impl_path="${2:-}"
  local report_type="${3:-}"
  if [ -z "$story_key" ] || [ -z "$impl_path" ] || [ -z "$report_type" ]; then
    _taim_warn "test_artifacts_mirror_report missing arg (story_key/impl_path/report_type)"
    return 0
  fi
  [ -f "$impl_path" ] || { _taim_warn "source report not found: $impl_path"; return 0; }
  case "$report_type" in
    qa-tests|test-automation|test-review) : ;;
    *) _taim_warn "unrecognised report_type: $report_type (accept: qa-tests, test-automation, test-review)"; return 0 ;;
  esac

  local target_dir
  if ! target_dir="$(_taim_resolve_target_dir "$story_key")"; then
    _taim_warn "could not resolve test-artifacts mirror dir for story=$story_key (per-story dir missing under implementation-artifacts/)"
    return 0
  fi
  mkdir -p "$target_dir" 2>/dev/null || { _taim_warn "mkdir failed: $target_dir"; return 0; }
  local mirror_path="$target_dir/${report_type}.md"
  cp "$impl_path" "$mirror_path" 2>/dev/null \
    && _taim_log "mirrored $(basename "$impl_path") → $mirror_path" \
    || _taim_warn "cp failed: $impl_path → $mirror_path"
  return 0
}

# test_artifacts_mirror_evidence <story-key> <impl-evidence-path> <tier>
# Mirrors the single execution-evidence.json under
#   test-artifacts/{epic}/{key}/execution-evidence/{tier}.json
# Each test-lens skill writes the tier matching its own scope (qa-tests
# writes qa-tests.json; test-automate writes test-automation.json; etc.).
test_artifacts_mirror_evidence() {
  local story_key="${1:-}"
  local impl_path="${2:-}"
  local tier="${3:-}"
  if [ -z "$story_key" ] || [ -z "$impl_path" ] || [ -z "$tier" ]; then
    _taim_warn "test_artifacts_mirror_evidence missing arg"
    return 0
  fi
  [ -f "$impl_path" ] || { _taim_warn "source evidence not found: $impl_path"; return 0; }
  case "$tier" in
    qa-tests|test-automation|test-review) : ;;
    *) _taim_warn "unrecognised tier: $tier"; return 0 ;;
  esac

  local target_dir
  if ! target_dir="$(_taim_resolve_target_dir "$story_key")"; then
    _taim_warn "could not resolve test-artifacts mirror dir for story=$story_key"
    return 0
  fi
  local evidence_dir="$target_dir/execution-evidence"
  mkdir -p "$evidence_dir" 2>/dev/null || { _taim_warn "mkdir failed: $evidence_dir"; return 0; }
  local mirror_path="$evidence_dir/${tier}.json"
  cp "$impl_path" "$mirror_path" 2>/dev/null \
    && _taim_log "mirrored execution-evidence (tier=$tier) → $mirror_path" \
    || _taim_warn "cp failed: $impl_path → $mirror_path"
  return 0
}
