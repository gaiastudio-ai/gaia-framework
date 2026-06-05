#!/usr/bin/env bash
# assessment-doc-bypass-check.sh — anti-pattern scanner for Val-gate bypass indicators
#
# Scans `/gaia-add-feature` assessment-doc emissions for three Val-gate bypass
# smoking-gun strings:
#   1. literal: "auto-judged in patch mode"
#   2. literal: "inline, read-only verification"
#   3. regex:   /Agent.{0,2}tool subagent dispatch primitive not surfaced/   (backtick-tolerant)
#
# Backtick-tolerance is load-bearing — three of four historical occurrences of
# string 3 are backtick variants (`Agent`-tool …); a literal-string grep would
# miss them.
#
# Usage:
#   assessment-doc-bypass-check.sh [--allowlist FILE] [--no-allowlist] FILE [FILE ...]
#
# Exit codes:
#   0 — no violations (or all violations occurred in allowlisted files)
#   1 — at least one violation in a non-allowlisted file
#   2 — usage error (no files specified)
#
# Output format (one line per (pattern, file, line) tuple):
#   {file}:{line}:{matched-string}
#
# The matched-string field is the smoking-gun string itself (string 1 or 2 in
# literal form; string 3 normalized to its plain-text canonical form regardless
# of backtick / hyphen variant) so output stays readable and stable.
#
# Pure deterministic scan; no LLM judgment. `grep -nE` (not Perl regex / not
# awk) for portability across CI runners.

set -euo pipefail

PROG="$(basename "$0")"
ALLOWLIST_FILE=""
USE_ALLOWLIST=1

# Default allowlist sits next to the bats tests under tests/.
DEFAULT_ALLOWLIST="$(cd "$(dirname "$0")/../tests" 2>/dev/null && pwd)/assessment-doc-bypass-allowlist.txt"

usage() {
  cat >&2 <<EOF
Usage: $PROG [--allowlist FILE] [--no-allowlist] FILE [FILE ...]

Scan assessment-AF-*.md files for known Val-gate bypass smoking-gun strings.
Exit non-zero on any violation in a non-allowlisted file.

Options:
  --allowlist FILE     Path to allowlist file (one filename basename per line;
                       lines beginning with '#' and blank lines are ignored).
  --no-allowlist       Disable the allowlist (validation mode — reports the
                       full historical baseline).

Default allowlist: $DEFAULT_ALLOWLIST
EOF
}

# ---- Parse args -----------------------------------------------------------

FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allowlist)
      ALLOWLIST_FILE="$2"
      shift 2
      ;;
    --no-allowlist)
      USE_ALLOWLIST=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        FILES+=("$1")
        shift
      done
      ;;
    -*)
      echo "$PROG: unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "$PROG: no files specified" >&2
  usage
  exit 2
fi

# ---- Resolve allowlist ----------------------------------------------------

if [ "$USE_ALLOWLIST" -eq 1 ] && [ -z "$ALLOWLIST_FILE" ]; then
  if [ -f "$DEFAULT_ALLOWLIST" ]; then
    ALLOWLIST_FILE="$DEFAULT_ALLOWLIST"
  fi
fi

# Read allowlist into a sorted, comment-stripped, unique list of basenames.
ALLOWLIST_BASENAMES=()
if [ "$USE_ALLOWLIST" -eq 1 ] && [ -n "$ALLOWLIST_FILE" ] && [ -f "$ALLOWLIST_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip leading/trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # Skip blank lines and comments.
    case "$line" in
      ""|"#"*) continue ;;
    esac
    ALLOWLIST_BASENAMES+=("$line")
  done < "$ALLOWLIST_FILE"
fi

is_allowlisted() {
  local target_base
  target_base="$(basename "$1")"
  local entry
  for entry in "${ALLOWLIST_BASENAMES[@]+"${ALLOWLIST_BASENAMES[@]}"}"; do
    if [ "$entry" = "$target_base" ]; then
      return 0
    fi
  done
  return 1
}

# ---- Scan -----------------------------------------------------------------

# String 3 canonical form for output normalization (so backtick vs. hyphen
# variants both report as the same plain-text string — keeps output stable
# and grep-able for downstream tooling).
STRING3_CANONICAL="Agent-tool subagent dispatch primitive not surfaced"

violations=0

for file in "${FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "$PROG: not a file: $file" >&2
    continue
  fi

  if is_allowlisted "$file"; then
    continue
  fi

  # String 1 — literal
  while IFS=: read -r lineno _; do
    [ -z "$lineno" ] && continue
    printf '%s:%s:%s\n' "$file" "$lineno" "auto-judged in patch mode"
    violations=$((violations + 1))
  done < <(grep -nF "auto-judged in patch mode" "$file" 2>/dev/null || true)

  # String 2 — literal
  while IFS=: read -r lineno _; do
    [ -z "$lineno" ] && continue
    printf '%s:%s:%s\n' "$file" "$lineno" "inline, read-only verification"
    violations=$((violations + 1))
  done < <(grep -nF "inline, read-only verification" "$file" 2>/dev/null || true)

  # String 3 — backtick-tolerant regex (.{0,2} accommodates backtick + hyphen
  # variants, smart quotes, en-dashes, and other 0-to-2-character formatting
  # drift). Output normalizes to the canonical plain-text form.
  while IFS=: read -r lineno _; do
    [ -z "$lineno" ] && continue
    printf '%s:%s:%s\n' "$file" "$lineno" "$STRING3_CANONICAL"
    violations=$((violations + 1))
  done < <(grep -nE "Agent.{0,2}tool subagent dispatch primitive not surfaced" "$file" 2>/dev/null || true)
done

if [ "$violations" -gt 0 ]; then
  exit 1
fi
exit 0
