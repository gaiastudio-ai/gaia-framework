#!/usr/bin/env bash
# check-orchestration-class.sh — E84-S2 / ADR-093 static check.
#
# Verifies every SKILL.md under plugins/gaia/skills/*/SKILL.md declares
# an orchestration_class frontmatter field set to one of the canonical
# four values: reviewer, light-procedural, heavy-procedural, conversational.
#
# Exit codes:
#   0 — every SKILL.md has a valid orchestration_class
#   1 — at least one CRITICAL finding (missing field, unknown value, duplicate)
#
# Output: one finding per line to stdout, prefixed with severity.
#   CRITICAL: <file>: orchestration_class missing
#   CRITICAL: <file>: orchestration_class invalid: <value>
#   CRITICAL: <file>: orchestration_class declared N times (must be exactly 1)
# When no findings: prints "PASS: N skills checked, N classified" to stdout.
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_NAME="check-orchestration-class.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  check-orchestration-class.sh [--skills-dir <path>]

Defaults to ${CLAUDE_PLUGIN_ROOT}/skills, falling back to the directory
containing this script's parent (../skills) when CLAUDE_PLUGIN_ROOT is unset.
USAGE
}

# ---- Arg parse ----
skills_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skills-dir) skills_dir="${2:-}"; shift 2 ;;
    --skills-dir=*) skills_dir="${1#--skills-dir=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; usage; exit 2 ;;
  esac
done

# ---- Resolve skills_dir ----
if [ -z "$skills_dir" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT}/skills" ]; then
    skills_dir="${CLAUDE_PLUGIN_ROOT}/skills"
  else
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    if [ -d "$self_dir/../skills" ]; then
      skills_dir="$(cd "$self_dir/../skills" && pwd)"
    else
      printf '%s: cannot resolve skills_dir; pass --skills-dir <path>\n' \
        "$SCRIPT_NAME" >&2
      exit 2
    fi
  fi
fi

[ -d "$skills_dir" ] || {
  printf '%s: skills_dir does not exist: %s\n' "$SCRIPT_NAME" "$skills_dir" >&2
  exit 2
}

# ---- Canonical class enum ----
_is_canonical_class() {
  case "$1" in
    reviewer|light-procedural|heavy-procedural|conversational) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- Scan ----
total=0
classified=0
findings=0

for d in "$skills_dir"/*/; do
  [ -d "$d" ] || continue
  file="${d}SKILL.md"
  [ -f "$file" ] || continue
  total=$((total + 1))

  # Extract frontmatter (between the first two `---` lines).
  # Then count orchestration_class declarations and extract the value.
  fm="$(awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm' "$file" 2>/dev/null || printf '')"

  # Match the field key whether it has a value or not (no [[:space:]]
  # anchor after the colon — empty value is a different finding class).
  count=$(printf '%s\n' "$fm" | grep -cE '^orchestration_class:' || true)
  if [ "$count" = "0" ]; then
    printf 'CRITICAL: %s: orchestration_class missing\n' "$file"
    findings=$((findings + 1))
    continue
  fi
  if [ "$count" -gt 1 ]; then
    printf 'CRITICAL: %s: orchestration_class declared %s times (must be exactly 1)\n' \
      "$file" "$count"
    findings=$((findings + 1))
    continue
  fi

  value="$(printf '%s\n' "$fm" | awk -F: '/^orchestration_class:/{sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit}')"
  if ! _is_canonical_class "$value"; then
    printf 'CRITICAL: %s: orchestration_class invalid: %s\n' "$file" "$value"
    findings=$((findings + 1))
    continue
  fi

  classified=$((classified + 1))
done

if [ "$findings" -gt 0 ]; then
  printf 'FAIL: %s/%s skills classified, %s CRITICAL finding(s)\n' \
    "$classified" "$total" "$findings"
  exit 1
fi

printf 'PASS: %s skills checked, %s classified\n' "$total" "$classified"
exit 0
