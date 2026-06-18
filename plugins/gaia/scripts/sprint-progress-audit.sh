#!/usr/bin/env bash
# sprint-progress-audit.sh — merge-not-done checkpoint for multi-story sprints
#
# Detects stories in the active sprint whose PR is merged on the promotion
# target but whose status has not reached done with a COMPLETE Review Gate.
# Composes two existing foundation scripts rather than reimplementing their
# detection logic:
#
#   - verify-pr-merged.sh  (merge detection via safe_grep_log)
#   - review-gate.sh       (review-gate-check composite gate status)
#
# Usage:
#   sprint-progress-audit.sh --sprint-status <path> --target-branch <branch>
#   sprint-progress-audit.sh --help
#
# Environment:
#   PROJECT_PATH              — git work tree (defaults to .)
#   IMPLEMENTATION_ARTIFACTS  — story-file root (defaults via resolve-story-file.sh)
#
# Output:
#   For each offending story (merged on target but not status:done with
#   COMPLETE Review Gate), emits a WARNING line on stdout:
#     WARNING: <key> — merged on <branch> but status=<status>, Review Gate=<gate-status>
#
# Exit codes:
#   0  — no offending stories (all clear)
#   1  — usage/argument error
#   4  — one or more merged-but-not-done stories detected
#
# Non-git CWD:
#   When PROJECT_PATH is outside any git work tree, the merge check cannot
#   run. The script degrades gracefully with exit 0 (matching verify-pr-merged.sh
#   posture) and a stderr warning.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="sprint-progress-audit.sh"

# Resolve library directory relative to this script.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_DIR="${_SCRIPT_DIR}/lib"

# Source shared helpers.
# shellcheck disable=SC1091
. "${_LIB_DIR}/shell-idioms.sh"
# shellcheck disable=SC1091
. "${_LIB_DIR}/non-git-cwd-guard.sh"

_log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_die() { local rc="$1"; shift; _log "$*"; exit "$rc"; }

_usage() {
  cat <<EOF
$SCRIPT_NAME — merge-not-done checkpoint for multi-story sprints

Detects stories whose PR is merged on the promotion target but whose status
has not reached done with a COMPLETE Review Gate. Composes verify-pr-merged.sh
(merge detection) and review-gate.sh (gate completeness) rather than building
a parallel scanner.

Usage:
  $SCRIPT_NAME --sprint-status <path> --target-branch <branch>
  $SCRIPT_NAME --help

Options:
  --sprint-status <path>    Path to the sprint-status.yaml file
  --target-branch <branch>  The promotion target branch (e.g. staging, main)
  --help                    Show this help and exit

Environment:
  PROJECT_PATH              Git work tree (defaults to .)
  IMPLEMENTATION_ARTIFACTS  Story-file root directory

Exit codes:
  0 — no offending stories (all clear)
  1 — usage/argument error
  4 — one or more merged-but-not-done stories detected
EOF
}

# ---------- Parse arguments ----------
_SPRINT_STATUS=""
_TARGET_BRANCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sprint-status)
      [ "$#" -ge 2 ] || _die 1 "--sprint-status requires a path"
      _SPRINT_STATUS="$2"; shift 2 ;;
    --target-branch)
      [ "$#" -ge 2 ] || _die 1 "--target-branch requires a branch name"
      _TARGET_BRANCH="$2"; shift 2 ;;
    -h|--help)
      _usage; exit 0 ;;
    *)
      _die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$_SPRINT_STATUS" ] || _die 1 "missing required --sprint-status <path>"
[ -n "$_TARGET_BRANCH" ] || _die 1 "missing required --target-branch <branch>"
[ -f "$_SPRINT_STATUS" ] || _die 1 "sprint-status.yaml not found: $_SPRINT_STATUS"

# ---------- Resolve working directory ----------
_WORK_DIR="${PROJECT_PATH:-.}"

# Non-git CWD guard: if PROJECT_PATH is not inside a git work tree, the
# merge check cannot run. Degrade gracefully with exit 0.
if ! git -C "$_WORK_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _log "skipped (non-git CWD at $_WORK_DIR) — merge-check requires a git work tree"
  exit 0
fi

# ---------- Extract story keys and statuses from sprint-status.yaml ----------
# Produces lines like: EX-S1|in-progress
_extract_stories() {
  awk '
    /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = $0
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/"/, "", k)
      gsub(/[[:space:]]*$/, "", k)
      key = k
    }
    /^[[:space:]]+status:[[:space:]]*/ {
      s = $0
      sub(/^[[:space:]]+status:[[:space:]]*/, "", s)
      gsub(/"/, "", s)
      gsub(/[[:space:]]*$/, "", s)
      if (key != "") { printf "%s|%s\n", key, s; key="" }
    }
  ' "$_SPRINT_STATUS"
}

# ---------- Check merge state for a single story key ----------
# Reuses safe_grep_log from shell-idioms.sh (the same function verify-pr-merged.sh
# uses for merge detection). Returns 0 if the key is found on the target branch.
_is_merged() {
  local story_key="$1" target="$2" work_dir="$3"
  local pattern="\\b${story_key}\\b"

  # Primary: word-boundary match on one-line log
  if (cd "$work_dir" && safe_grep_log -i -q -E "$pattern" --oneline "$target") 2>/dev/null; then
    return 0
  fi

  # Fallback: "Story: <key>" in full commit bodies
  if (cd "$work_dir" && safe_grep_log -i -q -E "Story:[[:space:]]*${story_key}\\b" --format='%B' "$target") 2>/dev/null; then
    return 0
  fi

  return 1
}

# ---------- Check Review Gate composite status for a story ----------
# Calls review-gate.sh review-gate-check. Returns the composite status
# (COMPLETE, BLOCKED, PENDING) on stdout, or "UNKNOWN" if the check fails.
_REVIEW_GATE_SCRIPT="${_SCRIPT_DIR}/review-gate.sh"

_gate_status() {
  local story_key="$1"
  if [ ! -x "$_REVIEW_GATE_SCRIPT" ]; then
    printf 'UNKNOWN'
    return 0
  fi

  local gate_out
  # review-gate-check exits 0=COMPLETE, 1=BLOCKED, 2=PENDING.
  # Capture stdout (which includes the gate table + summary line).
  set +e
  gate_out="$(IMPLEMENTATION_ARTIFACTS="${IMPLEMENTATION_ARTIFACTS:-}" \
    "$_REVIEW_GATE_SCRIPT" review-gate-check --story "$story_key" 2>/dev/null)"
  local rc=$?
  set -e

  case $rc in
    0) printf 'COMPLETE' ;;
    1) printf 'BLOCKED' ;;
    2) printf 'PENDING' ;;
    *) printf 'UNKNOWN' ;;
  esac
  return 0
}

# ---------- Main audit loop ----------
_offender_count=0

while IFS='|' read -r key story_status; do
  # Skip stories that are already done — they are not a concern.
  if [ "$story_status" = "done" ]; then
    continue
  fi

  # Check if the PR is merged on the target branch.
  if ! _is_merged "$key" "$_TARGET_BRANCH" "$_WORK_DIR"; then
    # Not merged — no concern; the story hasn't reached the merge step yet.
    continue
  fi

  # PR is merged but status is not done. Check the Review Gate.
  local_gate="$(_gate_status "$key")" || local_gate="UNKNOWN"

  if [ "$local_gate" = "COMPLETE" ] && [ "$story_status" = "done" ]; then
    # Should not reach here (done is filtered above), but defensive.
    continue
  fi

  # This story is merged but not done. Report it.
  printf 'WARNING: %s — merged on %s but status=%s, Review Gate=%s\n' \
    "$key" "$_TARGET_BRANCH" "$story_status" "$local_gate"
  _offender_count=$(( _offender_count + 1 ))

done < <(_extract_stories)

if [ "$_offender_count" -gt 0 ]; then
  _log "$_offender_count story(ies) merged but not done — resolve before advancing"
  exit 4
fi

exit 0
