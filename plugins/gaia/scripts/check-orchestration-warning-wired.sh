#!/usr/bin/env bash
# check-orchestration-warning-wired.sh — static check for orchestration-warning wiring.
#
# Verifies that every SKILL.md under plugins/gaia/skills/*/SKILL.md whose
# frontmatter declares orchestration_class ∈ {heavy-procedural, conversational}
# invokes BOTH helper scripts in its procedural body:
#
#   - detect-orchestration-mode.sh   (resolves Mode A vs Mode B)
#   - orchestration-warning.sh       (emits the one-shot lossy-mode warning)
#
# Out-of-scope classes (light-procedural, reviewer) are silently ignored —
# no warnings, no findings, regardless of whether they invoke either helper.
# Reviewers in particular are clean-room one-shot forks; the warning is not
# applicable there.
#
# Output: one finding per line to stdout, prefixed with severity.
#   CRITICAL: <file>: orchestration_class=<cls> missing invocation: <script>.sh
# When no findings: prints PASS summary.
#
# Exit codes:
#   0 — invariants hold
#   1 — at least one CRITICAL finding
#   2 — usage error (bad flag or skills-dir does not exist)
#
# Sibling of:
#   check-orchestration-class.sh
#   check-fork-stripped.sh
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_NAME="check-orchestration-warning-wired.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  check-orchestration-warning-wired.sh [--skills-dir <path>]

Defaults:
  --skills-dir: ${CLAUDE_PLUGIN_ROOT}/skills (or ../skills relative to this script)
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

# ---- Scan ----
checked=0
in_scope=0
findings=0

for d in "$skills_dir"/*/; do
  [ -d "$d" ] || continue
  file="${d}SKILL.md"
  [ -f "$file" ] || continue
  checked=$((checked + 1))

  # Extract orchestration_class from the frontmatter (between first two ---).
  cls="$(awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm && /^orchestration_class:/{sub(/^orchestration_class:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$file" 2>/dev/null || printf '')"

  # Only heavy-procedural and conversational are in scope. Light-procedural
  # and reviewer are silently skipped — sibling scripts handle their own
  # invariants.
  case "$cls" in
    heavy-procedural|conversational) ;;
    *) continue ;;
  esac
  in_scope=$((in_scope + 1))

  if ! grep -q 'detect-orchestration-mode\.sh' "$file"; then
    printf 'CRITICAL: %s: orchestration_class=%s missing invocation: detect-orchestration-mode.sh\n' \
      "$file" "$cls"
    findings=$((findings + 1))
  fi
  if ! grep -q 'orchestration-warning\.sh' "$file"; then
    printf 'CRITICAL: %s: orchestration_class=%s missing invocation: orchestration-warning.sh\n' \
      "$file" "$cls"
    findings=$((findings + 1))
  fi
done

if [ "$findings" -gt 0 ]; then
  printf 'FAIL: %s/%s skills in scope, %s CRITICAL finding(s)\n' \
    "$in_scope" "$checked" "$findings"
  exit 1
fi

printf 'PASS: %s skills checked, %s in scope, orchestration-warning wiring invariant holds\n' \
  "$checked" "$in_scope"
exit 0
