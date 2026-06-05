#!/usr/bin/env bash
# check-fork-stripped.sh — static check for fork-context stripping.
#
# Verifies the post-strip skill invariants:
#   1. Non-reviewer plugin SKILL.md MUST NOT declare `context: fork` in
#      its frontmatter.
#   2. Reviewer plugin SKILL.md MAY retain `context: fork` (clean-room
#      invariant). Not required (some reviewers omit it
#      and rely on the substrate default), but never forbidden.
#
# Agent persona files under plugins/gaia/agents/*.md are intentionally
# OUT OF SCOPE for this check — the fork-strip amendment only
# touches the skill-invocation layer. Agent persona forks are guarded
# by a bats regression test that compares against the staging baseline.
#
# Output: one finding per line to stdout, prefixed with severity.
#   CRITICAL: <file>: non-reviewer (orchestration_class=<cls>) still has context: fork
# When no findings: prints PASS summary.
#
# Exit codes:
#   0 — invariants hold
#   1 — at least one CRITICAL finding
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_NAME="check-fork-stripped.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  check-fork-stripped.sh [--skills-dir <path>]

Defaults:
  --skills-dir: ${CLAUDE_PLUGIN_ROOT}/skills (or ../skills relative to this script)
USAGE
}

skills_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skills-dir) skills_dir="${2:-}"; shift 2 ;;
    --skills-dir=*) skills_dir="${1#--skills-dir=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; usage; exit 2 ;;
  esac
done

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

findings=0
checked=0

for d in "$skills_dir"/*/; do
  [ -d "$d" ] || continue
  file="${d}SKILL.md"
  [ -f "$file" ] || continue
  checked=$((checked + 1))

  cls="$(awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm && /^orchestration_class:/{sub(/^orchestration_class:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$file" 2>/dev/null || printf '')"

  # Check for context: fork inside frontmatter only (between first two ---).
  has_fork=$(awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm && /^context:[[:space:]]*fork[[:space:]]*$/{print "yes"; exit}' "$file" 2>/dev/null || printf '')

  if [ "$has_fork" = "yes" ] && [ "$cls" != "reviewer" ]; then
    printf 'CRITICAL: %s: non-reviewer (orchestration_class=%s) still declares context: fork\n' \
      "$file" "${cls:-unset}"
    findings=$((findings + 1))
  fi
done

if [ "$findings" -gt 0 ]; then
  printf 'FAIL: %s skills checked, %s CRITICAL finding(s)\n' "$checked" "$findings"
  exit 1
fi
printf 'PASS: %s skills checked, fork-strip invariant holds\n' "$checked"
exit 0
