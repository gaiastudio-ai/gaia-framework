#!/usr/bin/env bash
# detect-open-questions.sh — open-question indicator scanner for artifacts
#
# Scans a single artifact for open-question indicators. Read-only,
# informational, non-blocking — exits 0 on findings AND on no-findings.
# Exits non-zero only on argument or I/O errors.
#
# Detection targets (architecture §10.31.7):
#   1. TBD                — case-insensitive, word-bounded ASCII token
#   2. TODO               — case-insensitive, word-bounded ASCII token
#   3. (needs decision)   — case-insensitive literal incl. parentheses
#   4. - [ ]              — unchecked checkbox; - [x] / - [X] are NOT flagged
#   5. ## Open Questions  — heading at any level (#{1,6}); only flagged if
#                           the body before the next heading or EOF contains
#                           non-whitespace content
#
# Out-of-scope: non-ASCII / Unicode
# variants of TBD/TODO (full-width CJK, Cyrillic lookalikes) are NOT
# flagged. Future maintainers MUST NOT silently widen the regex.
#
# Output schema (Technical Notes "Output schema for findings block"):
#   Open Questions Detected:
#     TBD ({N} found):
#       L{line}: {context}
#     TODO ({N} found):
#       L{line}: {context}
#     needs-decision ({N} found):
#       L{line}: {context}
#     Unchecked checkboxes ({N} found):
#       L{line}: {context}
#     Open Questions sections ({N} found):
#       L{line}: {heading} -- {first_120_chars_of_body}
#
# Portability: macOS bash 3.2 + BSD grep AND Ubuntu bash 5 + GNU grep.
# Avoids Bash 4 features (associative arrays, readarray) and GNU-only
# grep flags (-P, --line-buffered).
#
# Usage:
#   detect-open-questions.sh <artifact-path>
#   detect-open-questions.sh --help

set -u

usage() {
  cat <<'USAGE'
Usage:
  detect-open-questions.sh <artifact-path>
  detect-open-questions.sh --help

Scans the artifact for open-question indicators (TBD, TODO,
(needs decision), unchecked checkboxes, non-empty Open Questions
sections). Prints a structured findings block to stdout. Exits 0
whether findings exist or not (informational, non-blocking).
Exits non-zero on argument or I/O errors.
USAGE
}

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

ARTIFACT="$1"

if [ ! -f "$ARTIFACT" ] || [ ! -r "$ARTIFACT" ]; then
  printf 'detect-open-questions.sh: cannot read artifact: %s\n' "$ARTIFACT" >&2
  exit 3
fi

# Truncate context to a maximum width (~120 chars).
CONTEXT_MAX=120

# Trim leading whitespace and clip context to CONTEXT_MAX chars.
_trim_context() {
  # awk preserves portability across macOS BSD awk and GNU awk.
  awk -v max="$CONTEXT_MAX" '
    {
      sub(/^[ \t]+/, "", $0);
      if (length($0) > max) {
        $0 = substr($0, 1, max) "...";
      }
      print $0;
    }
  '
}

# --- Group 1: TBD (word-bounded, case-insensitive) ---
# (^|[^A-Za-z])TBD($|[^A-Za-z]) — POSIX ERE; works on BSD and GNU grep.
TBD_HITS="$(grep -niE '(^|[^A-Za-z])TBD($|[^A-Za-z])' "$ARTIFACT" 2>/dev/null || true)"

# --- Group 2: TODO (word-bounded, case-insensitive) ---
TODO_HITS="$(grep -niE '(^|[^A-Za-z])TODO($|[^A-Za-z])' "$ARTIFACT" 2>/dev/null || true)"

# --- Group 3: (needs decision) (case-insensitive literal) ---
ND_HITS="$(grep -niE '\(needs decision\)' "$ARTIFACT" 2>/dev/null || true)"

# --- Group 4: unchecked checkboxes ---
# Pattern: optional leading whitespace + dash + space + [ + space + ]
CB_HITS="$(grep -nE '^[[:space:]]*-[[:space:]]\[[[:space:]]\]' "$ARTIFACT" 2>/dev/null || true)"

# --- Group 5: ## Open Questions sections ---
# A heading is flagged ONLY if the body between this heading and the next
# heading (or EOF) contains at least one non-whitespace character.
# Implemented in awk to keep portability (no GNU sed extensions).
OQ_HITS="$(awk '
  BEGIN { in_oq = 0; oq_line = 0; oq_text = ""; has_body = 0; }
  function flush() {
    if (in_oq && has_body) {
      printf("%d:%s\n", oq_line, oq_text);
    }
    in_oq = 0; has_body = 0; oq_text = "";
  }
  {
    line = $0;
    # Heading detection: ^#{1,6}<space>...
    if (match(line, /^#{1,6}[ \t]+/) > 0) {
      # Close any prior Open Questions block first.
      flush();
      # Extract heading text (after the # markers and whitespace).
      heading = line;
      sub(/^#{1,6}[ \t]+/, "", heading);
      sub(/[ \t]+$/, "", heading);
      if (tolower(heading) == "open questions") {
        in_oq = 1;
        oq_line = NR;
        oq_text = line;
        has_body = 0;
      }
      next;
    }
    if (in_oq) {
      # Any non-whitespace character in the body marks the section non-empty.
      if (line ~ /[^[:space:]]/) {
        has_body = 1;
      }
    }
  }
  END { flush(); }
' "$ARTIFACT" 2>/dev/null || true)"

# --- Count and emit ---
_count_lines() {
  if [ -z "$1" ]; then
    printf '0'
  else
    printf '%s\n' "$1" | grep -c '.'
  fi
}

TBD_N=$(_count_lines "$TBD_HITS")
TODO_N=$(_count_lines "$TODO_HITS")
ND_N=$(_count_lines "$ND_HITS")
CB_N=$(_count_lines "$CB_HITS")
OQ_N=$(_count_lines "$OQ_HITS")

TOTAL=$((TBD_N + TODO_N + ND_N + CB_N + OQ_N))

# Zero-finding fast path: silent exit 0.
if [ "$TOTAL" -eq 0 ]; then
  exit 0
fi

# Helper: emit a group block. $1 = label, $2 = count, $3 = grep -n output
# Note: input lines look like "{lineno}:{rest}" — split on the first colon.
_emit_group() {
  local label="$1"
  local n="$2"
  local body="$3"
  if [ "$n" -eq 0 ]; then
    return 0
  fi
  printf '  %s (%d found):\n' "$label" "$n"
  printf '%s\n' "$body" | while IFS= read -r row; do
    [ -z "$row" ] && continue
    # Split first ":" — portable POSIX-shell idiom.
    lineno="${row%%:*}"
    rest="${row#*:}"
    ctx=$(printf '%s' "$rest" | _trim_context)
    printf '    L%s: %s\n' "$lineno" "$ctx"
  done
}

printf 'Open Questions Detected:\n'
_emit_group 'TBD' "$TBD_N" "$TBD_HITS"
_emit_group 'TODO' "$TODO_N" "$TODO_HITS"
_emit_group 'needs-decision' "$ND_N" "$ND_HITS"
_emit_group 'Unchecked checkboxes' "$CB_N" "$CB_HITS"
_emit_group 'Open Questions sections' "$OQ_N" "$OQ_HITS"

exit 0
