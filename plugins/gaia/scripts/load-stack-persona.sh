#!/usr/bin/env bash
# load-stack-persona.sh — GAIA shared review-skill script
#
# Resolves the project's primary stack and lazy-loads the matching reviewer
# persona file (from plugins/gaia/agents/) plus the matching memory sidecar.
# Runs in the parent context BEFORE fork dispatch — the fork tool allowlist
# stays `[Read, Grep, Glob, Bash]`.
#
# Stack resolution order:
#   1. Explicit --stack <name> flag
#   2. resolve-config.sh project.stack field (when available)
#   3. File-glob heuristics in --project-root:
#        angular.json                 -> angular-dev
#        tsconfig.json or package.json -> ts-dev
#        pom.xml or build.gradle      -> java-dev
#        requirements.txt or pyproject.toml -> python-dev
#        go.mod                       -> go-dev
#        pubspec.yaml                 -> flutter-dev
#        Podfile or AndroidManifest.xml (depth 4) -> mobile-dev
#
# Canonical stack name -> agent filename map:
#   ts-dev      -> typescript-dev.md
#   java-dev    -> java-dev.md
#   python-dev  -> python-dev.md
#   go-dev      -> go-dev.md
#   flutter-dev -> flutter-dev.md
#   mobile-dev  -> mobile-dev.md
#   angular-dev -> angular-dev.md
#
# Output (stdout) — KEY='VALUE' shell-evalable lines:
#   stack='<canonical-stack>'
#   agent_file='<absolute path to agent .md>'
#   sidecar_file='<absolute path to memory sidecar, if present>'
#
# Invocation:
#   load-stack-persona.sh [--stack <name>] [--project-root <dir>]
#                         [--agents-dir <dir>] [--memory-dir <dir>]
#   load-stack-persona.sh --help
#
# Exit codes:
#   0  — success (one persona resolved and loaded)
#   1  — caller error (missing/unknown flag)
#   2  — missing resource: unsupported stack OR persona file not found
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="load-stack-persona.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — load reviewer persona + sidecar for the project stack

Usage:
  $SCRIPT_NAME [--stack <name>] [--project-root <dir>]
               [--agents-dir <dir>] [--memory-dir <dir>]
  $SCRIPT_NAME --help

Options:
  --stack <name>          Skip heuristics; force stack (one of: ts-dev, java-dev,
                          python-dev, go-dev, flutter-dev, mobile-dev, angular-dev)
  --project-root <dir>    Where to run file-glob heuristics (default: cwd)
  --agents-dir <dir>      Where to find <stack>.md agent files (default: plugin agents)
  --memory-dir <dir>      Where to find <stack>-sidecar.md (default: .gaia/memory/)
  --help                  Show this help and exit 0

Output (stdout, shell-evalable):
  stack='<canonical-stack>'
  agent_file='<path>'
  sidecar_file='<path or empty>'

Exits 2 with stderr 'unsupported stack' when no canonical file is detected.
EOF
}

STACK=""
PROJECT_ROOT=""
AGENTS_DIR=""
MEMORY_DIR=""
STORY_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stack)         [ "$#" -ge 2 ] || die 1 "--stack requires a name";        STACK="$2";         shift 2 ;;
    --project-root)  [ "$#" -ge 2 ] || die 1 "--project-root requires a dir";  PROJECT_ROOT="$2";  shift 2 ;;
    --agents-dir)    [ "$#" -ge 2 ] || die 1 "--agents-dir requires a dir";    AGENTS_DIR="$2";    shift 2 ;;
    --memory-dir)    [ "$#" -ge 2 ] || die 1 "--memory-dir requires a dir";    MEMORY_DIR="$2";    shift 2 ;;
    # --story-file <path>: canonical invocation form so the persona resolution
    # can key off the story's frontmatter (e.g. `stack:` field) before falling
    # back to project-root-based detection.
    --story-file)    [ "$#" -ge 2 ] || die 1 "--story-file requires a path";   STORY_FILE="$2";    shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die 1 "unknown argument: $1" ;;
  esac
done

# If --story-file was passed and --stack was NOT, try to derive the stack from
# the story's `stack:` frontmatter field. Falls through to project-root-based
# file-marker detection (the legacy path) when the story lacks a stack field or
# the file is unreadable — preserves backward-compat for callers that pass only
# --project-root.
if [ -n "$STORY_FILE" ] && [ -z "$STACK" ] && [ -r "$STORY_FILE" ]; then
  _story_stack="$(awk '
    /^---[[:space:]]*$/ { n++; if (n == 2) exit }
    n == 1 && /^stack:[[:space:]]*/ {
      val = $0
      sub(/^stack:[[:space:]]*/, "", val)
      gsub(/^["\x27]|["\x27]$/, "", val)
      sub(/[[:space:]]+$/, "", val)
      if (length(val) > 0) { print val; exit }
    }
  ' "$STORY_FILE" 2>/dev/null || true)"
  if [ -n "$_story_stack" ]; then
    STACK="$_story_stack"
  fi
  # When --project-root wasn't set explicitly, default to the story file's
  # nearest project root: walk up from its dir until we find an artifact-bearing
  # marker (a .gaia/ tree). Keeps the persona/memory dirs anchored consistently.
  if [ -z "$PROJECT_ROOT" ]; then
    _story_dir="$(cd "$(dirname "$STORY_FILE")" 2>/dev/null && pwd || true)"
    _walk="$_story_dir"
    while [ -n "$_walk" ] && [ "$_walk" != "/" ]; do
      if [ -d "$_walk/.gaia" ]; then
        PROJECT_ROOT="$_walk"
        break
      fi
      _parent="$(dirname "$_walk" 2>/dev/null || printf '/')"
      [ "$_parent" = "$_walk" ] && break
      _walk="$_parent"
    done
  fi
fi

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default agents dir = sibling agents/ relative to this script's plugin tree.
if [ -z "$AGENTS_DIR" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  AGENTS_DIR="$SCRIPT_DIR/../agents"
fi
AGENTS_DIR="$(cd "$AGENTS_DIR" 2>/dev/null && pwd || true)"
[ -n "$AGENTS_DIR" ] || die 2 "agents-dir not found: ${AGENTS_DIR:-<unset>}"

# --- 1. Resolve stack ---

# canonical stack -> agent filename
canonical_to_filename() {
  case "$1" in
    ts-dev)      echo "typescript-dev.md" ;;
    java-dev)    echo "java-dev.md" ;;
    python-dev)  echo "python-dev.md" ;;
    go-dev)      echo "go-dev.md" ;;
    flutter-dev) echo "flutter-dev.md" ;;
    mobile-dev)  echo "mobile-dev.md" ;;
    angular-dev) echo "angular-dev.md" ;;
    *)           return 1 ;;
  esac
}

detect_stack_from_files() {
  local root="$1"
  # Highest-specificity wins. Order matters: angular.json beats tsconfig.json.
  if [ -f "$root/angular.json" ]; then
    echo "angular-dev"; return 0
  fi
  if [ -f "$root/pubspec.yaml" ]; then
    echo "flutter-dev"; return 0
  fi
  if [ -f "$root/go.mod" ]; then
    echo "go-dev"; return 0
  fi
  if [ -f "$root/pom.xml" ] || [ -f "$root/build.gradle" ] || [ -f "$root/build.gradle.kts" ]; then
    echo "java-dev"; return 0
  fi
  if [ -f "$root/requirements.txt" ] || [ -f "$root/pyproject.toml" ] || [ -f "$root/Pipfile" ]; then
    echo "python-dev"; return 0
  fi
  # Mobile native (AndroidManifest.xml in app/src/main or Podfile in iOS root)
  # checked BEFORE TS so an Android/iOS project that also has a tsconfig.json
  # for tooling does not get classified ts-dev.
  if [ -f "$root/Podfile" ] || find "$root" -maxdepth 4 -name AndroidManifest.xml -print -quit 2>/dev/null | grep -q .; then
    # But only when there is no top-level pubspec.yaml (Flutter wins above).
    echo "mobile-dev"; return 0
  fi
  if [ -f "$root/tsconfig.json" ] || [ -f "$root/package.json" ]; then
    echo "ts-dev"; return 0
  fi
  return 1
}

if [ -z "$STACK" ]; then
  # try resolve-config.sh project.stack
  if command -v resolve-config.sh >/dev/null 2>&1; then
    resolved="$(resolve-config.sh --field project.stack 2>/dev/null || true)"
    if [ -n "$resolved" ] && [ "$resolved" != "null" ]; then
      STACK="$resolved"
    fi
  fi
fi

if [ -z "$STACK" ]; then
  if ! STACK="$(detect_stack_from_files "$PROJECT_ROOT")"; then
    printf '%s: unsupported stack: no canonical stack file detected under %s\n' "$SCRIPT_NAME" "$PROJECT_ROOT" >&2
    exit 2
  fi
fi

# Validate the canonical stack name and resolve filename.
if ! AGENT_FILENAME="$(canonical_to_filename "$STACK")"; then
  printf '%s: unsupported stack: %s (expected one of: ts-dev, java-dev, python-dev, go-dev, flutter-dev, mobile-dev, angular-dev)\n' \
    "$SCRIPT_NAME" "$STACK" >&2
  exit 2
fi

AGENT_FILE="$AGENTS_DIR/$AGENT_FILENAME"
if [ ! -r "$AGENT_FILE" ]; then
  printf '%s: persona file not found: %s\n' "$SCRIPT_NAME" "$AGENT_FILE" >&2
  exit 2
fi

# --- 2. Memory sidecar (lazy, optional) ---
SIDECAR_FILE=""
if [ -n "${MEMORY_DIR:-}" ] && [ -d "$MEMORY_DIR" ]; then
  CAND="$MEMORY_DIR/${STACK}-sidecar.md"
  if [ -r "$CAND" ]; then
    SIDECAR_FILE="$CAND"
  fi
fi

# --- 3. Emit shell-evalable payload ---
printf "stack='%s'\n" "$STACK"
printf "agent_file='%s'\n" "$AGENT_FILE"
printf "sidecar_file='%s'\n" "$SIDECAR_FILE"
exit 0
