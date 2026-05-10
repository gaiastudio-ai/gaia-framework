#!/usr/bin/env bash
# review-extract.sh — extract verdicts and key findings from the four review
# artifact families for a given sprint and emit a data-driven findings block
# suitable for the retro facilitator prompt.
#
# Usage:
#   review-extract.sh --impl-dir <dir> --sprint-id <id>
#
# Behavior (FR-RIM-2, architecture §10.28.4):
#   * Glob {code-review,security-review,qa-tests,performance-review}-*.md under impl-dir.
#   * Filter to artifacts whose YAML frontmatter sprint_id matches the input.
#   * Extract "**Verdict:** <VALUE>" lines. Missing / truncated → "UNKNOWN".
#   * Print a markdown block listing each artifact + its verdict + a parse note
#     when applicable. When no artifacts match, print an explicit "no review
#     artifacts for sprint <id>" line (AC-EC5).

set -euo pipefail

IMPL_DIR=""
SPRINT_ID=""
MAX_BYTES=65536

while [ $# -gt 0 ]; do
  case "$1" in
    --impl-dir)  IMPL_DIR="$2"; shift 2 ;;
    --sprint-id) SPRINT_ID="$2"; shift 2 ;;
    *) echo "error: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$IMPL_DIR" ] || [ -z "$SPRINT_ID" ]; then
  echo "usage: $0 --impl-dir <dir> --sprint-id <id>" >&2
  exit 1
fi

if [ ! -d "$IMPL_DIR" ]; then
  echo "no review artifacts for sprint $SPRINT_ID (impl-dir missing)"
  exit 0
fi

# Extract sprint_id from frontmatter; returns empty string on miss.
frontmatter_sprint() {
  local f="$1"
  head -c "$MAX_BYTES" "$f" | awk '/^sprint_id:/ { gsub(/"/, "", $2); print $2; exit }'
}

extract_verdict() {
  local f="$1" v
  v="$(head -c "$MAX_BYTES" "$f" | awk -F '[:*]' '
    /^\*\*Verdict:\*\*/ {
      # Line is like: **Verdict:** PASSED
      match($0, /\*\*Verdict:\*\*[[:space:]]*[A-Za-z]+/)
      if (RLENGTH > 0) {
        chunk = substr($0, RSTART, RLENGTH)
        n = split(chunk, parts, /[[:space:]]+/)
        print parts[n]
        exit
      }
    }')"
  if [ -z "$v" ]; then
    printf 'UNKNOWN'
  else
    printf '%s' "$v"
  fi
}

emit_block() {
  local header="$1"
  printf '### data-driven findings — sprint %s\n\n' "$SPRINT_ID"
  printf '%s\n' "$header"
}

# AC-EC5 (E55-S12) — defensive seed before nullglob expansion so set -u
# survives empty matches without "artifacts[@]: unbound variable".
declare -a artifacts=()
shopt -s nullglob
artifacts=("$IMPL_DIR"/code-review-*.md \
           "$IMPL_DIR"/security-review-*.md \
           "$IMPL_DIR"/qa-tests-*.md \
           "$IMPL_DIR"/performance-review-*.md)
shopt -u nullglob

declare -a matched=()
# AC-EC5 (E55-S12) — guard the array expansion with `${arr[@]+"${arr[@]}"}`
# idiom so an empty `artifacts` array does not trip `set -u`. The defensive
# `declare -a artifacts=()` above gives a clean baseline; this expansion
# guard handles the case where Bash 3.2 (macOS default) still treats an
# empty indexed array as unbound under `set -u` even after declaration.
for art in ${artifacts[@]+"${artifacts[@]}"}; do
  [ -f "$art" ] || continue
  s="$(frontmatter_sprint "$art")"
  if [ "$s" = "$SPRINT_ID" ]; then
    matched+=("$art")
  fi
done

if [ "${#matched[@]}" -eq 0 ]; then
  # AC-EC5 — empty findings block + explicit dev-note-style line.
  emit_block "_no review artifacts for sprint ${SPRINT_ID}_ (empty findings)"
  exit 0
fi

emit_block "| artifact | verdict | note |"
printf '|---|---|---|\n'
for art in "${matched[@]}"; do
  base="$(basename "$art")"
  # Derive family name: strip sprint-id suffix and .md extension.
  family="$(printf '%s' "$base" | sed -E 's/-sprint-.*\.md$//')"
  verdict="$(extract_verdict "$art")"
  note="ok"
  if [ "$verdict" = "UNKNOWN" ]; then
    note="parse-warning: verdict line missing or malformed"
  fi
  printf '| %s | %s | %s |\n' "$family" "$verdict" "$note"
done

exit 0
