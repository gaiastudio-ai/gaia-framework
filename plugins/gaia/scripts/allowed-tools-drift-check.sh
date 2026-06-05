#!/usr/bin/env bash
# allowed-tools-drift-check.sh — allowed-tools claims-vs-usage drift check.
#
# Purpose
# -------
# Static `allowed-tools` claims-vs-usage check for Claude Code plugin SKILL.md
# files. Parses the YAML frontmatter `allowed-tools:` declaration, scans the
# skill body (and any referenced scripts via `!path/to/script.sh` directives)
# for invocations of the well-known tools, and emits a CRITICAL finding for
# every tool used without a matching declaration.
#
# Threat model
# ------------
# A plugin skill that invokes a tool not declared in its `allowed-tools:`
# frontmatter creates a privilege-escalation surface — the Claude Code harness
# only enforces the declaration at the skill boundary, so silent drift bypasses
# review. The check mandates CRITICAL severity with no downgrade and no allowlist.
#
# Tracked tools
# -------------
# Bash, Read, Write, Edit, Grep, Glob, Agent, WebFetch, WebSearch, Task.
# These are the canonical Claude Code tool names referenced in skill bodies
# and adapter scripts.
#
# Detection heuristic
# -------------------
# A tool is considered "used" if its name appears as a standalone token in:
#   - the SKILL.md body (outside the frontmatter), OR
#   - any script referenced via `!path/to/script.sh` SKILL directive.
#
# False positives are avoided by requiring the token to appear with at least
# one of these proximity hints: capitalized first letter (e.g., `Bash`), a
# preceding backtick or whitespace boundary, and not as part of a longer
# identifier (e.g., `Readable` does not match `Read`). The check is
# intentionally pragmatic for Tier 1 — Tier 2 may extend it with AST parsing.
#
# Usage
# -----
#   allowed-tools-drift-check.sh --skill <SKILL.md path>
#   allowed-tools-drift-check.sh --help
#
# Exit codes
# ----------
#   0 — No drift detected (declarations match usage).
#   2 — One or more CRITICAL findings emitted (drift detected).
#   1 — Caller error (missing flag, file not found, malformed frontmatter).
#
# Output (stdout)
# ---------------
#   For each undeclared tool: a single line in the format:
#     CRITICAL: <SKILL.md path>: undeclared tool usage: <ToolName>
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="allowed-tools-drift-check.sh"
TRACKED_TOOLS=(Bash Read Write Edit Grep Glob Agent WebFetch WebSearch Task)

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
$SCRIPT_NAME — allowed-tools claims-vs-usage drift check.

Usage:
  $SCRIPT_NAME --skill <SKILL.md path>
  $SCRIPT_NAME --help

Required:
  --skill <path>    Path to the SKILL.md file to audit.

Exit codes:
  0   No drift.
  2   Drift detected — CRITICAL finding(s) emitted on stdout.
  1   Caller error.

Output format (per finding):
  CRITICAL: <SKILL.md path>: undeclared tool usage: <ToolName>

EOF
}

SKILL_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill)
      [ "$#" -ge 2 ] || die "--skill requires a path"
      SKILL_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

[ -n "$SKILL_FILE" ] || die "missing required --skill <path>"
[ -f "$SKILL_FILE" ] || die "skill file not found: $SKILL_FILE"

SKILL_DIR="$(cd "$(dirname "$SKILL_FILE")" && pwd)"

# ---------------------------------------------------------------------------
# Stage 1: parse frontmatter — extract `allowed-tools:` array.
#
# Supported forms (YAML):
#   allowed-tools: [Read, Bash, Write]
#   allowed-tools:
#     - Read
#     - Bash
#     - Write
# ---------------------------------------------------------------------------

extract_frontmatter() {
  awk '
    BEGIN { in_fm = 0; saw_open = 0 }
    /^---[[:space:]]*$/ {
      if (!saw_open) { saw_open = 1; in_fm = 1; next }
      else if (in_fm) { in_fm = 0; exit }
    }
    in_fm { print }
  ' "$1"
}

FRONTMATTER="$(extract_frontmatter "$SKILL_FILE")"
if [ -z "$FRONTMATTER" ]; then
  # No frontmatter at all — treat as no declaration. Per Dev Notes edge case,
  # this is currently an INFO/skip path, not CRITICAL. Exit 0 with no output.
  exit 0
fi

parse_allowed_tools() {
  printf '%s\n' "$FRONTMATTER" | awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function strip_brackets(s) { gsub(/^\[|\]$/, "", s); return s }
    BEGIN { in_block = 0 }
    # Inline form: allowed-tools: [A, B, C]
    /^allowed-tools[[:space:]]*:[[:space:]]*\[/ {
      sub(/^allowed-tools[[:space:]]*:[[:space:]]*/, "")
      line = $0
      # Handle multi-line bracketed list: accumulate until closing ].
      while (line !~ /\]/) {
        if ((getline next_line) <= 0) break
        line = line " " next_line
      }
      sub(/\].*$/, "", line)
      sub(/^\[/, "", line)
      n = split(line, parts, /,/)
      for (i = 1; i <= n; i++) {
        t = trim(parts[i])
        gsub(/^["'\'']|["'\'']$/, "", t)
        if (t != "") print t
      }
      exit
    }
    # Block form: allowed-tools:\n  - A\n  - B
    /^allowed-tools[[:space:]]*:[[:space:]]*$/ { in_block = 1; next }
    in_block && /^[[:space:]]*-[[:space:]]+/ {
      t = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", t)
      t = trim(t)
      gsub(/^["'\'']|["'\'']$/, "", t)
      if (t != "") print t
      next
    }
    in_block && /^[^[:space:]-]/ { in_block = 0 }
  '
}

DECLARED_TOOLS="$(parse_allowed_tools | sort -u)"

# Build a set lookup (declared[ToolName]=1) using a temp file for portability.
# Pre-declare CORPUS_TMP too so a single trap covers both temp files (avoids
# the two-trap pattern where the second trap silently overwrites the first).
DECLARED_TMP="$(mktemp -t declared-XXXXXX)"
CORPUS_TMP="$(mktemp -t corpus-XXXXXX)"
trap 'rm -f "$DECLARED_TMP" "$CORPUS_TMP" 2>/dev/null || true' EXIT
printf '%s\n' "$DECLARED_TOOLS" > "$DECLARED_TMP"

is_declared() {
  local tool="$1"
  grep -Fxq "$tool" "$DECLARED_TMP"
}

# ---------------------------------------------------------------------------
# Stage 2: collect skill body (everything after the closing `---`) and any
# referenced scripts (lines starting with `!` per the SKILL conventions).
# ---------------------------------------------------------------------------

extract_body() {
  awk '
    BEGIN { in_fm = 0; saw_open = 0; past_fm = 0 }
    /^---[[:space:]]*$/ {
      if (!saw_open) { saw_open = 1; in_fm = 1; next }
      else if (in_fm) { in_fm = 0; past_fm = 1; next }
    }
    past_fm { print }
  ' "$1"
}

BODY="$(extract_body "$SKILL_FILE")"

# Collect referenced-script paths (lines starting with `!` whose remainder is a
# path-like token ending in .sh).
REFERENCED_SCRIPTS=()
while IFS= read -r line; do
  case "$line" in
    \!*)
      ref="${line#!}"
      ref="${ref%% *}"
      case "$ref" in
        *.sh)
          # Resolve relative to the skill directory if not absolute.
          case "$ref" in
            /*) abs_ref="$ref" ;;
            *)  abs_ref="$SKILL_DIR/$ref" ;;
          esac
          if [ -f "$abs_ref" ]; then
            REFERENCED_SCRIPTS+=("$abs_ref")
          fi
          ;;
      esac
      ;;
  esac
done < <(printf '%s\n' "$BODY")

# Combined corpus: the skill body plus the contents of every referenced script.
printf '%s\n' "$BODY" > "$CORPUS_TMP"
for s in "${REFERENCED_SCRIPTS[@]:-}"; do
  [ -n "$s" ] || continue
  printf '\n' >> "$CORPUS_TMP"
  cat "$s" >> "$CORPUS_TMP"
done

# ---------------------------------------------------------------------------
# Stage 3: scan corpus for each tracked tool. A tool is "used" if its name
# appears as a standalone capitalized token. Word-boundary matching avoids
# false positives like Readable / Editor / Bashful.
# ---------------------------------------------------------------------------

drift_count=0
for tool in "${TRACKED_TOOLS[@]}"; do
  # Match the tool name as a standalone token: preceded and followed by a
  # non-word character (or BOF/EOF). grep -E with [^[:alnum:]_] boundaries.
  if grep -E "(^|[^[:alnum:]_])${tool}([^[:alnum:]_]|\$)" "$CORPUS_TMP" >/dev/null 2>&1; then
    if ! is_declared "$tool"; then
      printf 'CRITICAL: %s: undeclared tool usage: %s\n' "$SKILL_FILE" "$tool"
      drift_count=$((drift_count + 1))
    fi
  fi
done

if [ "$drift_count" -gt 0 ]; then
  exit 2
fi

exit 0
