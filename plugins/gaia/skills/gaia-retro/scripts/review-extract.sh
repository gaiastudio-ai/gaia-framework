#!/usr/bin/env bash
# review-extract.sh — extract verdicts and key findings from the four review
# artifact families for a given sprint and emit a data-driven findings block
# suitable for the retro facilitator prompt.
#
# Usage:
#   review-extract.sh --impl-dir <dir> --sprint-id <id>
#
# Behavior:
#   * Glob {code-review,security-review,qa-tests,performance-review}-*.md under impl-dir.
#   * Filter to artifacts whose YAML frontmatter sprint_id matches the input.
#   * Extract "**Verdict:** <VALUE>" lines. Missing / truncated → "UNKNOWN".
#   * Print a markdown block listing each artifact + its verdict + a parse note
#     when applicable. When no artifacts match, print an explicit "no review
#     artifacts for sprint <id>" line.

set -euo pipefail

MAX_BYTES=65536

# Extract sprint_id from frontmatter; returns empty string on miss.
frontmatter_sprint() {
  local f="$1"
  head -c "$MAX_BYTES" "$f" | awk '/^sprint_id:/ { gsub(/"/, "", $2); print $2; exit }'
}

# extract_verdict — return the review-report verdict VALUE, or UNKNOWN when no
# verdict line is present. Tolerant of every real-world
# verdict-line shape observed across the report corpus so a present verdict
# never parses as UNKNOWN due to formatting drift:
#   **Verdict:** VALUE         (colon outside the bold span)
#   **Verdict: VALUE**         (colon inside the bold span — the dominant form)
#   ## Verdict: VALUE          (H2 heading form, e.g. code-review-E106-S1.md)
#   Verdict: VALUE             (plain)
#   **Verdict: ORIG -> VALUE** (arrow-override — the POST-arrow value wins)
# The value token is the last ALL-CAPS/underscore word on the line after any
# `->`/`→` override arrow, with surrounding markdown (`*`) stripped.
extract_verdict() {
  local f="$1" v
  v="$(head -c "$MAX_BYTES" "$f" | awk '
    # Portable unicode rightwards-arrow (U+2192) — BSD awk does not interpret
    # \xNN in a regex literal, so build the byte sequence via sprintf and match
    # the ASCII "->" plus this string explicitly.
    BEGIN { UARROW = sprintf("%c%c%c", 226, 134, 146) }
    # Match a line that introduces a verdict in any of the accepted shapes.
    # Strip leading markdown heading/bold + the literal "Verdict" label + colon.
    /[Vv]erdict[*: ]/ && /[Vv]erdict/ {
      line = $0
      # only consider lines whose first non-space token is a Verdict label
      # (heading `##`, bold `**`, or bare) — avoids matching prose mentions.
      probe = line
      gsub(/^[[:space:]]*[#*]*[[:space:]]*/, "", probe)
      if (probe !~ /^[Vv]erdict[[:space:]]*:/) next
      # drop everything up to and including the FIRST colon after "Verdict"
      sub(/^[^:]*:/, "", line)
      # strip markdown bold/italic markers
      gsub(/\*/, "", line)
      # Base verdict = FIRST uppercase/underscore word after the label.
      n = split(line, words, /[[:space:]]+/)
      base = ""
      for (i = 1; i <= n; i++) {
        if (words[i] ~ /^[A-Z][A-Z_]+$/) { base = words[i]; break }
      }
      # Arrow-override (e.g. "FAILED -> PASSED"): take the post-arrow value ONLY
      # when the immediate post-arrow token is a BARE verdict word — NOT a
      # gate-row annotation like "APPROVE -> Review Gate row = PASSED".
      # When the post-arrow text is an annotation, the base verdict wins.
      if (line ~ /->/ || index(line, UARROW) > 0) {
        after = line
        # strip everything through the LAST arrow (ASCII or unicode)
        sub(/^.*->[[:space:]]*/, "", after)
        ua = index(after, UARROW)
        if (ua > 0) { after = substr(after, ua + length(UARROW)) }
        sub(/^[[:space:]]+/, "", after)
        m = split(after, awords, /[[:space:]]+/)
        # bare override = first post-arrow token is an ALL-CAPS verdict word AND
        # is not immediately part of a "word = value" / "row" annotation phrase.
        if (m >= 1 && awords[1] ~ /^[A-Z][A-Z_]+$/ && after !~ /[=]|[Rr]ow/) {
          print awords[1]; exit
        }
      }
      if (base != "") { print base; exit }
    }')"
  if [ -z "$v" ]; then
    printf 'UNKNOWN'
  else
    printf '%s' "$v"
  fi
}

# ---------- Sourced-guard: expose the functions for unit testing ----------
# When sourced (BASH_SOURCE != $0) only the functions above are defined; the
# arg-parsing + main report body below runs ONLY on direct execution.
if [ "${BASH_SOURCE[0]:-$0}" != "${0}" ]; then
  return 0 2>/dev/null || true
fi

IMPL_DIR=""
SPRINT_ID=""

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

emit_block() {
  local header="$1"
  printf '### data-driven findings — sprint %s\n\n' "$SPRINT_ID"
  printf '%s\n' "$header"
}

# Defensive seed before nullglob expansion so set -u survives empty matches
# without "artifacts[@]: unbound variable".
#
# The original glob set walked ONLY the flat {IMPL_DIR}/<type>-<key>.md layer.
# The per-story layout writes review reports to
# `epic-*/{key}-*/reviews/<type>-{key}.md`, so a retro against a new-layout
# sprint reported "no review artifacts" even when 18 reports were on disk.
# Union the flat layer with the per-story `reviews/` layer so both layouts
# are scanned. Realpath dedup at consumption time guards against
# double-counting on transition shims.
declare -a artifacts=()
shopt -s nullglob
artifacts=("$IMPL_DIR"/code-review-*.md \
           "$IMPL_DIR"/security-review-*.md \
           "$IMPL_DIR"/qa-tests-*.md \
           "$IMPL_DIR"/performance-review-*.md \
           "$IMPL_DIR"/epic-*/*/reviews/code-review-*.md \
           "$IMPL_DIR"/epic-*/*/reviews/security-review-*.md \
           "$IMPL_DIR"/epic-*/*/reviews/qa-tests-*.md \
           "$IMPL_DIR"/epic-*/*/reviews/performance-review-*.md \
           "$IMPL_DIR"/epic-*/*/reviews/test-automate-review-*.md \
           "$IMPL_DIR"/epic-*/*/reviews/test-review-*.md)
shopt -u nullglob

# Exclude per-story layout matches that sit under a legacy `stories/` segment
# (the old tier-1 layout) — those would otherwise leak in via the `epic-*/*/`
# wildcard. The canonical per-story layout uses `epic-{slug}/{key}-{slug}/`
# as the second segment, never `stories/`. Mirrors the locate_story_file
# guard in sprint-state.sh.
if [ "${#artifacts[@]}" -gt 0 ]; then
  _filtered=()
  for _m in "${artifacts[@]}"; do
    case "$_m" in
      */stories/*/reviews/*) continue ;;
    esac
    _filtered+=( "$_m" )
  done
  artifacts=( "${_filtered[@]+"${_filtered[@]}"}" )
fi

declare -a matched=()
# Guard the array expansion with `${arr[@]+"${arr[@]}"}` idiom so an empty
# `artifacts` array does not trip `set -u`. The defensive
# `declare -a artifacts=()` above gives a clean baseline; this expansion
# guard handles the case where Bash 3.2 (macOS default) still treats an
# empty indexed array as unbound under `set -u` even after declaration.
# When an artifact lacks sprint_id frontmatter (manual / minimal review
# reports often omit it, and some auto-generated ones do too), fall back to
# glob-matching by story key against sprint-status.yaml. Without this
# fallback, the retro skill reported "no review artifacts for sprint X"
# despite N review reports being on disk.

# Build a set of story keys for the active sprint.
# The yq-gated extraction silently no-op'd when yq was absent (an optional dep),
# so the frontmatter-miss fallback never fired on hosts without yq and reports
# without sprint_id were dropped. Add a yq-less path that greps the `key:` lines
# and validates each token as E<N>-S<N>, normalising to the same space-delimited
# shape the yq path produced.
SPRINT_STORY_KEYS=""
SPRINT_STATUS_YAML="${GAIA_STATE_DIR:-.gaia/state}/sprint-status.yaml"
if [ -f "$SPRINT_STATUS_YAML" ]; then
  if command -v yq >/dev/null 2>&1; then
    SPRINT_STORY_KEYS="$(yq eval '.stories[].key' "$SPRINT_STATUS_YAML" 2>/dev/null | tr '\n' ' ')"
  fi
  # yq-less fallback (also a backstop if the yq query returned nothing): pull
  # E<N>-S<N> tokens from `key:` lines, strip quotes, space-delimit.
  if [ -z "${SPRINT_STORY_KEYS// /}" ]; then
    SPRINT_STORY_KEYS="$(grep -E '^[[:space:]]*-?[[:space:]]*key:' "$SPRINT_STATUS_YAML" 2>/dev/null \
      | grep -oE 'E[0-9]+-S[0-9]+' \
      | tr '\n' ' ')"
  fi
fi

# Helper: extract story key from a review-report filename like
# `code-review-E1-S1.md` or `qa-tests-E101-S1.md`. Returns the EN-SM token.
story_key_from_filename() {
  local b="$(basename "$1")"
  # Strip the review-type prefix and .md suffix to get the story key
  printf '%s' "$b" | awk '{
    gsub(/\.md$/, "");
    if (match($0, /E[0-9]+-S[0-9]+/)) {
      print substr($0, RSTART, RLENGTH)
    }
  }'
}

for art in ${artifacts[@]+"${artifacts[@]}"}; do
  [ -f "$art" ] || continue
  s="$(frontmatter_sprint "$art")"
  if [ "$s" = "$SPRINT_ID" ]; then
    matched+=("$art")
    continue
  fi
  # Frontmatter-miss fallback: match by story key
  if [ -z "$s" ] && [ -n "$SPRINT_STORY_KEYS" ]; then
    key="$(story_key_from_filename "$art")"
    if [ -n "$key" ] && printf ' %s ' "$SPRINT_STORY_KEYS" | grep -qF " $key "; then
      matched+=("$art")
    fi
  fi
done

if [ "${#matched[@]}" -eq 0 ]; then
  # Empty findings block + explicit dev-note-style line.
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
