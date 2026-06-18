#!/usr/bin/env bash
# skill-rename-preflight.sh — pre-flight checklist for skill renames
#
# Scans five surfaces where a skill name is hard-coded and reports every
# hit the developer must update before pushing a rename. Advisory only --
# always exits 0 regardless of findings.
#
# Usage:
#   skill-rename-preflight.sh --old <old-name> --new <new-name> [--repo-root <path>]
#
# Surfaces scanned:
#   1. .github/workflows/         — hardcoded bats invocation lists
#   2. knowledge CSVs             — workflow-manifest.csv, gaia-help.csv
#   3. lifecycle-sequence.yaml    — ordered skill references
#   4. test directories           — tests/skills/ AND plugins/gaia/tests/
#   5. renamed SKILL.md           — legacy _gaia/lifecycle/ dead references

set -euo pipefail
LC_ALL=C
export LC_ALL

# ── Internal helpers (underscore-prefixed → skipped by coverage gate) ──

_log() { printf '%s\n' "$*"; }

_section_header() {
  printf '\n── %s ──\n' "$1"
}

_resolve_repo_root() {
  # Walk upward from the script's own directory to find the repo root
  # (the directory containing .github/). Accepts an override via --repo-root.
  local dir="${1:-}"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    printf '%s' "$dir"
    return 0
  fi

  # Derive from this script's location
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.github" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  # Fallback: try CLAUDE_PROJECT_ROOT
  if [ -n "${CLAUDE_PROJECT_ROOT:-}" ] && [ -d "$CLAUDE_PROJECT_ROOT" ]; then
    printf '%s' "$CLAUDE_PROJECT_ROOT"
    return 0
  fi

  return 1
}

# ── Public functions (covered by bats source+call tests) ──

scan_workflows() {
  local repo_root="$1" old_name="$2"
  local workflows_dir="$repo_root/.github/workflows"
  local found=0

  if [ ! -d "$workflows_dir" ]; then
    _log "  (directory not found — clean)"
    return 0
  fi

  while IFS= read -r hit; do
    _log "  $hit"
    found=1
  done < <(grep -rn -- "$old_name" "$workflows_dir" 2>/dev/null \
    | sed "s|^$repo_root/||" || true)

  if [ "$found" -eq 0 ]; then
    _log "  clean"
  fi
}

scan_knowledge() {
  local repo_root="$1" old_name="$2"
  local knowledge_dir="$repo_root/plugins/gaia/knowledge"
  local found=0

  for file in workflow-manifest.csv gaia-help.csv lifecycle-sequence.yaml; do
    local filepath="$knowledge_dir/$file"
    if [ ! -f "$filepath" ]; then
      continue
    fi
    while IFS= read -r hit; do
      _log "  $hit"
      found=1
    done < <(grep -n -- "$old_name" "$filepath" 2>/dev/null \
      | sed "s|^|$file:|" || true)
  done

  if [ "$found" -eq 0 ]; then
    _log "  clean"
  fi
}

scan_test_dirs() {
  local repo_root="$1" old_name="$2"
  local found=0

  # Surface A: tests/skills/ at repo root
  local tests_skills="$repo_root/tests/skills"
  if [ -d "$tests_skills" ]; then
    while IFS= read -r match; do
      local relpath
      relpath="$(printf '%s' "$match" | sed "s|^$repo_root/||")"
      _log "  $relpath"
      found=1
    done < <(find "$tests_skills" -maxdepth 1 -name "*${old_name}*" 2>/dev/null || true)
  fi

  # Surface B: plugins/gaia/tests/
  local plugin_tests="$repo_root/plugins/gaia/tests"
  if [ -d "$plugin_tests" ]; then
    while IFS= read -r match; do
      local relpath
      relpath="$(printf '%s' "$match" | sed "s|^$repo_root/||")"
      _log "  $relpath"
      found=1
    done < <(find "$plugin_tests" -maxdepth 1 -name "*${old_name}*" 2>/dev/null || true)
  fi

  if [ "$found" -eq 0 ]; then
    _log "  clean"
  fi
}

scan_legacy_paths() {
  local repo_root="$1" new_name="$2"
  local skill_md="$repo_root/plugins/gaia/skills/$new_name/SKILL.md"
  local found=0

  if [ ! -f "$skill_md" ]; then
    _log "  (SKILL.md not found for $new_name — clean)"
    return 0
  fi

  while IFS= read -r hit; do
    _log "  SKILL.md:$hit"
    found=1
  done < <(grep -n '_gaia/lifecycle/' "$skill_md" 2>/dev/null || true)

  if [ "$found" -eq 0 ]; then
    _log "  clean"
  fi
}

# ── Main ──

main() {
  local old_name="" new_name="" repo_root_override=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --old)  old_name="${2:-}"; shift 2 ;;
      --new)  new_name="${2:-}"; shift 2 ;;
      --repo-root) repo_root_override="${2:-}"; shift 2 ;;
      *)      shift ;;
    esac
  done

  if [ -z "$old_name" ] || [ -z "$new_name" ]; then
    _log "Usage: skill-rename-preflight.sh --old <old-name> --new <new-name> [--repo-root <path>]"
    _log ""
    _log "Advisory pre-flight scan for skill rename blast radius."
    _log "Always exits 0 (non-blocking)."
    exit 0
  fi

  local repo_root
  repo_root="$(_resolve_repo_root "$repo_root_override")" || {
    _log "WARNING: could not resolve repo root. Exiting clean."
    exit 0
  }

  _log "Skill rename pre-flight: '$old_name' -> '$new_name'"
  _log "Repo root: $repo_root"

  # Surface 1: CI workflow files
  _section_header "CI Workflows (.github/workflows/)"
  scan_workflows "$repo_root" "$old_name"

  # Surface 2+3: Knowledge CSVs and lifecycle YAML
  _section_header "Knowledge files (CSVs + lifecycle YAML)"
  scan_knowledge "$repo_root" "$old_name"

  # Surface 4: Test directories
  _section_header "Test directories (tests/skills/ + plugins/gaia/tests/)"
  scan_test_dirs "$repo_root" "$old_name"

  # Surface 5: Legacy _gaia/lifecycle/ paths in the renamed SKILL.md
  _section_header "Legacy paths in renamed SKILL.md"
  scan_legacy_paths "$repo_root" "$new_name"

  _log ""
  _log "Pre-flight complete. Review hits above and update before pushing."

  # Always exit 0 — advisory only
  exit 0
}

# Main guard: allow sourcing without running main
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
