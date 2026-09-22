#!/usr/bin/env bash
# memory-writethrough.sh — gaia-meeting per-agent sidecar decision write-through
#
# Reads a per-agent draft directory (`<agent>.md` files, one per accepted
# entry) and renders one decision file per agent at the canonical sidecar
# location under the memory tree:
#   <root>/<memory-tree>/<agent>-sidecar/decisions/<YYYY-MM-DD>-<slug>.md
#
# <root> is the required --root argument. The memory-tree segment is resolved
# through the shared paths helper, never spelled out here; with the default
# tree it is `.gaia/memory`, so a sidecar lands at
# <root>/.gaia/memory/<agent>-sidecar/decisions/<YYYY-MM-DD>-<slug>.md.
#
# The output frontmatter contains: agent, date, source_meeting, type: decision,
# tags. The body contains the four mandatory H2 sections in fixed order:
#   1. ## What I decided / agreed to in this meeting
#   2. ## Constraints I committed to
#   3. ## Open items I'm tracking
#   4. ## Sources I relied on
#
# Each input draft is itself a small frontmatter+body file in this loose
# schema:
#   ---
#   agent: <name>
#   decided:    [ - "..." ]
#   constraints:[ - "..." ]
#   open_items: [ - "AI-..." ]
#   sources:    [ - "<path-or-url>" ]
#   tags:       [ - "<tag>" ]
#   ---
#
# Atomic writes: each output file is written to a sibling tempfile and `mv`d
# into place.
#
# Usage:
#   memory-writethrough.sh \
#     --root <project-root>   # the sidecar tree is written under this root; \
#                             # `.` means the root PROJECT_ROOT names \
#     --drafts <dir-with-agent-files> \
#     --source-meeting <slug> \
#     --date <YYYY-MM-DD> \
#     --slug <slug>
#
# Exit codes:
#   0 = success (or zero accepted drafts — nothing to write)
#   2 = invalid args
#   3 = I/O error

set -euo pipefail

# Canonical state-tree root.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"

# Memory-tree segment, resolved through the shared paths helper rather than
# spelled out here, so a move of the tree is picked up automatically.
#
# The helper is sourced in a subshell pinned to a sentinel root: the sidecar
# path is composed from the caller's --root, and letting the helper walk up
# from CWD would resolve some unrelated ancestor as the root instead. Pinning
# the root suppresses the walk-up; stripping it back off leaves the segment.
_gaia_memory_segment() {
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
    [ -n "${GAIA_MEMORY_DIR:-}" ] || exit 1
    printf '%s' "${GAIA_MEMORY_DIR#"$_GAIA_ROOT_CANON"/}"
  )
}

MEMORY_SEGMENT="$(_gaia_memory_segment || true)"
if [[ -z "$MEMORY_SEGMENT" ]]; then
  echo "memory-writethrough.sh: could not resolve the memory tree via the shared paths helper" >&2
  exit 3
fi

ROOT=""
DRAFTS=""
SOURCE_MEETING=""
DATE=""
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)            ROOT="$2"; shift 2 ;;
    --drafts)          DRAFTS="$2"; shift 2 ;;
    --source-meeting)  SOURCE_MEETING="$2"; shift 2 ;;
    --date)            DATE="$2"; shift 2 ;;
    --slug)            SLUG="$2"; shift 2 ;;
    *) echo "memory-writethrough.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ROOT" || -z "$DRAFTS" || -z "$SOURCE_MEETING" || -z "$DATE" || -z "$SLUG" ]]; then
  echo "memory-writethrough.sh: --root, --drafts, --source-meeting, --date, --slug required" >&2
  exit 2
fi

if [[ ! -d "$DRAFTS" ]]; then
  echo "memory-writethrough.sh: drafts dir not found: $DRAFTS" >&2
  exit 3
fi

# Sidecar root prefix. --root is authoritative and required; PROJECT_ROOT is
# kept only as a fallback for the `--root .` form, where the caller means
# "the project root I am already standing in". `--root .` with PROJECT_ROOT
# set therefore resolves against PROJECT_ROOT rather than the bare CWD.
if [[ "$ROOT" == "." || "$ROOT" == "./" ]]; then
  # shellcheck disable=SC2031  # the segment probe's PROJECT_ROOT is scoped to
  # its own subshell; this reads the caller's value, which is unchanged.
  SIDECAR_ROOT="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}"
else
  SIDECAR_ROOT="${ROOT%/}/"
fi

# Helper: extract a YAML list block (lines like `  - "x"`) under a top-level
# key. Returns one item per line, each item already trimmed of quotes.
_extract_list() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_block = 0 }
    # Match top-level key:
    $0 ~ ("^" k ":[[:space:]]*$") { in_block = 1; next }
    # Leave the block on next top-level key or end-of-frontmatter.
    in_block && /^[A-Za-z_][A-Za-z0-9_]*:/ { in_block = 0 }
    in_block && /^---[[:space:]]*$/ { in_block = 0 }
    in_block && /^[[:space:]]+-[[:space:]]+/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      gsub(/^"/, "")
      gsub(/"$/, "")
      print
    }
  ' "$file"
}

shopt -s nullglob
drafts=("$DRAFTS"/*.md)
shopt -u nullglob

if [[ ${#drafts[@]} -eq 0 ]]; then
  exit 0  # nothing accepted — not an error
fi

for draft in "${drafts[@]}"; do
  agent="$(basename "$draft" .md)"

  # The memory tree is the only sidecar tree; the legacy fallback was removed
  # with the consolidation migration. The root comes from --root (required, so
  # always present) — previously --root was accepted and then ignored here, and
  # with PROJECT_ROOT unset the sidecar tree landed relative to the current
  # working directory, leaking files into whatever directory the caller ran in.
  out_dir="${SIDECAR_ROOT}${MEMORY_SEGMENT}/${agent}-sidecar/decisions"
  out="$out_dir/${DATE}-${SLUG}.md"
  mkdir -p "$out_dir"

  tmp="$(mktemp)"

  {
    echo "---"
    echo "agent: ${agent}"
    echo "date: ${DATE}"
    echo "source_meeting: ${SOURCE_MEETING}"
    echo "type: decision"
    echo "tags:"
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      echo "  - \"${tag}\""
    done < <(_extract_list "$draft" tags)
    echo "---"
    echo ""
    echo "## What I decided / agreed to in this meeting"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" decided)
    echo ""
    echo "## Constraints I committed to"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" constraints)
    echo ""
    echo "## Open items I'm tracking"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" open_items)
    echo ""
    echo "## Sources I relied on"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" sources)
  } > "$tmp"

  mv "$tmp" "$out"
done

exit 0
