#!/usr/bin/env bash
# check-stray-snapshots.sh — detect context-window snapshot files outside the
# project root's .gaia/memory/.
#
# Usage:
#   check-stray-snapshots.sh [--json] [--project-root DIR]
#
# Reports each stray path and prints the removal command. Never deletes
# anything itself. Exit 0 always (read-only diagnostic).
#
# "Stray" means any .gaia/memory/.context-window-snapshot.json that is NOT the
# canonical <root>/.gaia/memory/ location. Linked worktrees (.gaia-worktrees/)
# are excluded — they carry their own .gaia/ by design.
#
# POSIX discipline: bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

JSON_OUT="false"
_PROJECT_ROOT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)        JSON_OUT="true"; shift ;;
    --project-root)
      [ "$#" -ge 2 ] || { echo "check-stray-snapshots.sh: --project-root requires a value" >&2; exit 1; }
      _PROJECT_ROOT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Resolve project root: explicit flag > PROJECT_ROOT env > CLAUDE_PROJECT_ROOT
# env > config-anchored walk-up.
if [ -z "$_PROJECT_ROOT" ]; then
  _PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}"
fi
if [ -z "$_PROJECT_ROOT" ]; then
  # Walk up from CWD looking for .gaia/config/project-config.yaml (pass 1)
  # then bare .gaia/ (pass 2), matching gaia-paths.sh's two-tier logic.
  _d="$PWD"
  while true; do
    if [ -f "$_d/.gaia/config/project-config.yaml" ]; then
      _PROJECT_ROOT="$_d"; break
    fi
    [ "$_d" = "/" ] || [ "$_d" = "${HOME:-/nonexistent}" ] && break
    _d="$(dirname "$_d")"
  done
  if [ -z "$_PROJECT_ROOT" ]; then
    _d="$PWD"
    while true; do
      if [ -d "$_d/.gaia" ]; then
        _PROJECT_ROOT="$_d"; break
      fi
      [ "$_d" = "/" ] || [ "$_d" = "${HOME:-/nonexistent}" ] && break
      _d="$(dirname "$_d")"
    done
  fi
fi

if [ -z "$_PROJECT_ROOT" ] || [ ! -d "$_PROJECT_ROOT" ]; then
  if [ "$JSON_OUT" = "true" ]; then
    printf '{"stray_snapshots":{"count":0,"paths":[],"note":"no project root resolved"}}\n'
  else
    echo "check-stray-snapshots.sh: no project root resolved; skipping stray scan"
  fi
  exit 0
fi

# Canonical snapshot location (the one the statusline SHOULD write to).
_CANONICAL="${_PROJECT_ROOT}/.gaia/memory/.context-window-snapshot.json"

# Bounded find: prune heavy subtrees, max 12 levels deep.
_SNAPSHOT_NAME=".context-window-snapshot.json"
# bash 3.2 + set -u: ${arr[@]} on an empty array is "unbound variable".
# Work around by seeding a sentinel and filtering it out, or by using
# ${arr[@]+"${arr[@]}"} everywhere. We use the +x pattern.
_STRAYS=()
while IFS= read -r _path; do
  [ -z "$_path" ] && continue
  # Normalise to absolute for comparison.
  case "$_path" in
    /*) ;;
    *)  _path="${_PROJECT_ROOT}/${_path}" ;;
  esac
  # Skip the canonical location.
  [ "$_path" = "$_CANONICAL" ] && continue
  _STRAYS+=("$_path")
done < <(
  find "$_PROJECT_ROOT" \
    -maxdepth 12 \
    \( -name ".git" -o -name "node_modules" -o -name ".gaia-worktrees" \) -prune \
    -o -path "*/.gaia/memory/$_SNAPSHOT_NAME" -print 2>/dev/null || true
)

# bash 3.2 + set -u safe: ${_STRAYS[@]} is "unbound variable" when empty.
# shellcheck disable=SC2199  # we only test for "defined and non-empty"
if [ -n "${_STRAYS[*]+x}" ]; then
  _COUNT="${#_STRAYS[@]}"
else
  _COUNT=0
fi

if [ "$JSON_OUT" = "true" ]; then
  # Build a JSON array of relative paths.
  _json_paths="[]"
  if [ "$_COUNT" -gt 0 ]; then
    for _s in "${_STRAYS[@]}"; do
      _rel="${_s#"${_PROJECT_ROOT}/"}"
      _json_paths="$(printf '%s' "$_json_paths" | jq --arg p "$_rel" '. + [$p]')"
    done
  fi
  jq -n --argjson count "$_COUNT" --argjson paths "$_json_paths" \
    '{"stray_snapshots":{"count":$count,"paths":$paths}}'
  exit 0
fi

if [ "$_COUNT" -eq 0 ]; then
  echo "No stray context-window snapshot files found."
  exit 0
fi

echo "WARNING: found $_COUNT stray context-window snapshot file(s) outside the project root."
echo "These were created by an older statusline that followed the session's working"
echo "directory instead of anchoring to the project root. A nested sub-repo state"
echo "tree (e.g. inside a product-source checkout) is recreated whenever a session"
echo "is launched from that directory; that is expected and not a stray."
echo ""
for _s in "${_STRAYS[@]}"; do
  _rel="${_s#"${_PROJECT_ROOT}/"}"
  printf '  %s\n' "$_rel"
done
echo ""
echo "To remove them:"
for _s in "${_STRAYS[@]}"; do
  printf '  rm -f "%s"\n' "$_s"
done
exit 0
