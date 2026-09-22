#!/usr/bin/env bash
# scratchpad-resolve-path.sh — gaia-meeting deterministic extraction-path resolver
#
# Computes the extraction path purely from the inputs:
#   .gaia/artifacts/creative-artifacts/meeting-scratchpad/{YYYY-MM}/{slug}/SP-{N}-{auto-slug}.{ext}
#
# Auto-slug derivation:
#   1. If the content's first non-blank line is "textual" (does NOT look like
#      raw code/JSON), derive the slug from that line.
#   2. Otherwise (raw code/JSON/etc.), derive the slug from the pinning agent's
#      intent statement.
#   3. If both are empty/non-textual, the slug is "untitled".
#
# Slug projection rule (matches gaia-create-story/scripts/slugify.sh):
#   lowercase, replace runs of non-alphanumeric with `-`, collapse, strip
#   leading/trailing `-`, truncate to ≤ 40 chars, strip trailing `-` again.
#
# Usage:
#   scratchpad-resolve-path.sh \
#     --date <YYYY-MM-DD> \
#     --slug <meeting-slug> \
#     --sp-n <SP-N> \
#     --content <content-string> \
#     --intent <intent-string> \
#     --content-type <json|ts|py|sh|md|go|swift|kt|rs|java>
#
# Exit codes:
#   0 = success (path emitted to stdout)
#   2 = invalid args (malformed date / SP-N / unknown content-type / slug)

set -euo pipefail
LC_ALL=C
export LC_ALL

# Canonical state-tree root.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"

# Artifacts-tree segment, resolved through the shared paths helper rather than
# spelled out here, so a move of the runtime tree is picked up automatically.
#
# The helper is sourced in a subshell pinned to a sentinel root: this resolver
# emits a PROJECT-RELATIVE path when PROJECT_ROOT is unset (callers prefix
# their own root), and the helper's walk-up would otherwise resolve some
# unrelated ancestor as the root and turn the output absolute. Pinning the root
# suppresses the walk-up; stripping it back off leaves just the tree segment.
_gaia_artifacts_segment() {
  local lib _sentinel
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/gaia-paths.sh"
  [ -r "$lib" ] || return 1
  _sentinel="/gaia-path-segment-probe"
  (
    # shellcheck disable=SC2030  # the subshell is the point: the probe root must
    # not escape into the caller's environment.
    PROJECT_ROOT="$_sentinel"
    _GAIA_PATHS_LOADED=""
    # shellcheck source=../../../scripts/lib/gaia-paths.sh
    # shellcheck disable=SC1091  # resolved at runtime from the plugin root.
    . "$lib" >/dev/null 2>&1 || exit 1
    [ -n "${GAIA_ARTIFACTS_DIR:-}" ] || exit 1
    printf '%s' "${GAIA_ARTIFACTS_DIR#"$_GAIA_ROOT_CANON"/}"
  )
}

ARTIFACTS_SEGMENT="$(_gaia_artifacts_segment || true)"
if [ -z "$ARTIFACTS_SEGMENT" ]; then
  echo "scratchpad-resolve-path.sh: could not resolve the artifacts tree via the shared paths helper" >&2
  exit 3
fi

DATE=""
SLUG=""
SP_N=""
CONTENT=""
INTENT=""
CTYPE=""

usage() {
  cat >&2 <<'USAGE'
Usage: scratchpad-resolve-path.sh \
  --date <YYYY-MM-DD> --slug <s> --sp-n SP-<N> \
  --content <s> --intent <s> --content-type <ext>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)         DATE="$2"; shift 2 ;;
    --slug)         SLUG="$2"; shift 2 ;;
    --sp-n)         SP_N="$2"; shift 2 ;;
    --content)      CONTENT="$2"; shift 2 ;;
    --intent)       INTENT="$2"; shift 2 ;;
    --content-type) CTYPE="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

# Validate inputs
if [[ -z "$DATE" || -z "$SLUG" || -z "$SP_N" || -z "$CTYPE" ]]; then
  usage
  exit 2
fi

# Date: strict YYYY-MM-DD
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "scratchpad-resolve-path.sh: malformed --date (expected YYYY-MM-DD): $DATE" >&2
  exit 2
fi

# SP-N: SP-<positive integer>
if ! [[ "$SP_N" =~ ^SP-[1-9][0-9]*$ ]]; then
  echo "scratchpad-resolve-path.sh: malformed --sp-n (expected SP-<N>): $SP_N" >&2
  exit 2
fi

# Slug: must not contain '..' or path separators or leading dash/dot
case "$SLUG" in
  *..*|*/*|.*) echo "scratchpad-resolve-path.sh: invalid --slug: $SLUG" >&2; exit 2 ;;
esac

# Content-type: known set
case "$CTYPE" in
  json|ts|py|sh|md|go|swift|kt|rs|java) ;;
  *) echo "scratchpad-resolve-path.sh: unknown --content-type: $CTYPE" >&2; exit 2 ;;
esac

YYYY_MM="${DATE%-*}"

# Slug projection — matches gaia-create-story/scripts/slugify.sh contract
_project_slug() {
  local s="$1"
  s="$(printf '%s' "$s" | tr 'A-Z' 'a-z' | tr -c '[:alnum:]' '-' | tr -s '-' | sed 's/^-//; s/-$//')"
  # Truncate to 40 chars and strip trailing - again
  if (( ${#s} > 40 )); then
    s="${s:0:40}"
  fi
  s="${s%-}"
  printf '%s' "$s"
}

# Take the first non-blank line of content and strip leading whitespace
_first_line() {
  local txt="$1"
  local line trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -n "$trimmed" ]]; then
      printf '%s' "$trimmed"
      return 0
    fi
  done <<EOF
$txt
EOF
}

# A first line is "textual" when it does NOT begin with a code/JSON sigil:
# {, [, <, # (if not "# heading"), shebang (#!), function/interface keywords,
# `import `, `def `, `package `, `func `, `fn `, `fun `, `class `, `public `.
_is_textual() {
  local fl="$1"
  [[ -z "$fl" ]] && return 1
  case "$fl" in
    '#!'*|'{'*|'['*|'<'*) return 1 ;;
    'interface '*|'type '*|'export '*|'function '*) return 1 ;;
    'def '*|'import '*|'from '*' import '*) return 1 ;;
    'package '*|'func '*|'fn '*|'fun '*) return 1 ;;
    'class '*|'public '*|'private '*) return 1 ;;
  esac
  return 0
}

first_line="$(_first_line "$CONTENT")"

auto_slug=""
if _is_textual "$first_line"; then
  auto_slug="$(_project_slug "$first_line")"
fi
if [[ -z "$auto_slug" ]]; then
  auto_slug="$(_project_slug "$INTENT")"
fi
if [[ -z "$auto_slug" ]]; then
  auto_slug="untitled"
fi

# Canonical-unconditional path (no legacy fallback supported). The artifacts
# segment comes from the shared paths helper; this resolver contributes only
# the leaf layout below it.
# shellcheck disable=SC2031  # the segment probe's PROJECT_ROOT is scoped to
# its own subshell; this reads the caller's value, which is unchanged.
_scratchpad_root="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}"
printf '%s\n' "${_scratchpad_root}${ARTIFACTS_SEGMENT}/creative-artifacts/meeting-scratchpad/${YYYY_MM}/${SLUG}/${SP_N}-${auto_slug}.${CTYPE}"
