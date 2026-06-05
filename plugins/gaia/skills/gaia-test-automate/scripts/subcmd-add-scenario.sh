#!/usr/bin/env bash
# subcmd-add-scenario.sh — /gaia-test-automate --add-scenario sub-command
#
# Allocates the next available CS-NNN ID by scanning custom/test-scenarios/
# index.yaml, appends the new scenario to:
#   1. The story file's "## Custom Scenarios" markdown table
#   2. custom/test-scenarios/index.yaml (under scenarios:)
#
# CS-NNN namespace is deliberately separate from Vera's TC-NNN namespace
# so /gaia-review-qa re-runs do not collide.
#
# Usage (non-interactive — flags supply all values; bats-friendly):
#   subcmd-add-scenario.sh \
#     --story-file <path> \
#     --index-file <path> \
#     --description <text> \
#     --tier {unit|integration|e2e} \
#     --priority <P0|P1|P2|P3> \
#     --expected <text>
#
#   subcmd-add-scenario.sh --help
#
# Exit codes:
#   0 — scenario allocated and persisted
#   1 — file write / read failure
#   2 — caller error (missing required flag)
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="subcmd-add-scenario.sh"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat <<EOF
$SCRIPT_NAME — /gaia-test-automate --add-scenario sub-command.

Usage:
  $SCRIPT_NAME \\
    --story-file <path> \\
    --index-file <path> \\
    --description <text> \\
    --tier {unit|integration|e2e} \\
    --priority <P0|P1|P2|P3> \\
    --expected <text>

Allocates the next CS-NNN ID, writes to index.yaml, and appends a row
to the story's Custom Scenarios markdown table.
EOF
}

STORY_FILE=""
INDEX_FILE=""
DESCRIPTION=""
TIER=""
PRIORITY=""
EXPECTED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --story-file)  STORY_FILE="${2:-}";  shift 2 ;;
    --index-file)  INDEX_FILE="${2:-}";  shift 2 ;;
    --description) DESCRIPTION="${2:-}"; shift 2 ;;
    --tier)        TIER="${2:-}";        shift 2 ;;
    --priority)    PRIORITY="${2:-}";    shift 2 ;;
    --expected)    EXPECTED="${2:-}";    shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

[ -n "$STORY_FILE" ]  || { err "missing required --story-file";  exit 2; }
[ -n "$INDEX_FILE" ]  || { err "missing required --index-file";  exit 2; }
[ -n "$DESCRIPTION" ] || { err "missing required --description"; exit 2; }
[ -n "$TIER" ]        || { err "missing required --tier";        exit 2; }
[ -n "$PRIORITY" ]    || { err "missing required --priority";    exit 2; }
[ -n "$EXPECTED" ]    || { err "missing required --expected";    exit 2; }

[ -r "$STORY_FILE" ] || { err "story file not readable: $STORY_FILE"; exit 1; }

# Ensure the index file's parent dir exists, and the file itself contains
# at minimum a `scenarios: []` seed.
INDEX_DIR="$(dirname "$INDEX_FILE")"
mkdir -p "$INDEX_DIR"
if [ ! -f "$INDEX_FILE" ]; then
  printf 'scenarios: []\n' >"$INDEX_FILE"
fi

# ---------------------------------------------------------------------------
# Resolve story key from frontmatter (best-effort fallback to filename).
# ---------------------------------------------------------------------------
story_key="$(awk '
  /^---$/ { fm = !fm; next }
  fm && /^key:/ {
    s = $0; sub(/^key:[[:space:]]*/, "", s); gsub(/"/, "", s); print s; exit
  }
' "$STORY_FILE")"
if [ -z "$story_key" ]; then
  story_key="$(basename "$STORY_FILE" .md | grep -oE '^E[0-9]+-S[0-9]+' || true)"
fi
[ -n "$story_key" ] || { err "could not resolve story key from $STORY_FILE"; exit 1; }

# ---------------------------------------------------------------------------
# Allocate next CS-NNN — scan index for the highest existing CS-N integer.
# Reads both canonical `id:` and legacy `cs_id:` entries
# so backward-compat is preserved across the schema rename.
# ---------------------------------------------------------------------------
max_n=0
while IFS= read -r line; do
  n="${line#CS-}"
  # Strip leading zeros without invoking a subshell octal-trap.
  while [ "${#n}" -gt 1 ] && [ "${n:0:1}" = "0" ]; do n="${n:1}"; done
  case "$n" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$n" -gt "$max_n" ]; then max_n="$n"; fi
done < <(grep -oE 'CS-[0-9]+' "$INDEX_FILE" || true)

next_n=$((max_n + 1))
cs_id="$(printf 'CS-%03d' "$next_n")"

# Capture today's date as ISO-8601 (YYYY-MM-DD) for created_date.
created_date="$(date +%Y-%m-%d)"

# ---------------------------------------------------------------------------
# Append entry to index.yaml. The atomic-rename pattern guards against
# concurrent invocations (last writer wins; no partial files).
#
# Canonical schema: id, story_key, description, tier,
# priority, file_path, created_date. The legacy `cs_id` and `expected`
# fields are dropped — readers tolerate both during the backward-compat window.
# ---------------------------------------------------------------------------
TMP_INDEX="$(mktemp -t e72s2-index.XXXXXX)"
trap 'rm -f "$TMP_INDEX"' EXIT

# If the index file is currently `scenarios: []` (empty seed), rewrite the
# `scenarios:` line to begin a non-empty list while preserving any preceding
# header comments. Otherwise append under the existing `scenarios:` key.
if grep -qE '^scenarios:[[:space:]]*\[\]' "$INDEX_FILE"; then
  awk -v cs_id="$cs_id" -v story_key="$story_key" -v desc="$DESCRIPTION" \
      -v tier="$TIER" -v prio="$PRIORITY" -v cdate="$created_date" '
    /^scenarios:[[:space:]]*\[\]/ {
      print "scenarios:"
      printf "  - id: %s\n", cs_id
      printf "    story_key: %s\n", story_key
      printf "    description: \"%s\"\n", desc
      printf "    tier: %s\n", tier
      printf "    priority: %s\n", prio
      printf "    file_path: \"\"\n"
      printf "    created_date: \"%s\"\n", cdate
      next
    }
    { print }
  ' "$INDEX_FILE" >"$TMP_INDEX"
else
  cp "$INDEX_FILE" "$TMP_INDEX"
  cat >>"$TMP_INDEX" <<EOF
  - id: $cs_id
    story_key: $story_key
    description: "$DESCRIPTION"
    tier: $TIER
    priority: $PRIORITY
    file_path: ""
    created_date: "$created_date"
EOF
fi
mv "$TMP_INDEX" "$INDEX_FILE"
trap - EXIT

# ---------------------------------------------------------------------------
# Append a row to the story's "## Custom Scenarios" markdown table.
# ---------------------------------------------------------------------------
TMP_STORY="$(mktemp -t e72s2-story.XXXXXX)"
trap 'rm -f "$TMP_STORY"' EXIT

awk -v cs="$cs_id" -v tier="$TIER" -v desc="$DESCRIPTION" -v file="" '
  /^## Custom Scenarios/ { in_cs=1; print; next }
  in_cs && /^## / && !/^## Custom Scenarios/ {
    if (!appended) {
      printf "| %s | %s | %s | %s |\n", cs, tier, desc, file
      appended=1
    }
    in_cs=0
    print; next
  }
  in_cs && /^\|[-: ]+\|/ {
    print
    # Inject the new row immediately after the separator if no existing row.
    next
  }
  { print }
  END {
    if (in_cs && !appended) {
      printf "| %s | %s | %s | %s |\n", cs, tier, desc, file
    }
  }
' "$STORY_FILE" >"$TMP_STORY"

# Second-pass: ensure exactly one new CS row was added. If awk did not
# inject (because the section had no separator yet), append a row at the
# end of the file under a fresh "## Custom Scenarios" block.
if ! grep -qE "^\|[[:space:]]*$cs_id[[:space:]]*\|" "$TMP_STORY"; then
  if grep -q "^## Custom Scenarios" "$TMP_STORY"; then
    # Section exists but has no rows — append the row directly under it.
    awk -v cs="$cs_id" -v tier="$TIER" -v desc="$DESCRIPTION" '
      /^## Custom Scenarios/ {
        print
        print "| CS | Tier | Description | File |"
        print "|----|------|-------------|------|"
        printf "| %s | %s | %s |  |\n", cs, tier, desc
        in_cs=1; injected=1; next
      }
      { print }
    ' "$TMP_STORY" >"$TMP_STORY.2"
    mv "$TMP_STORY.2" "$TMP_STORY"
  else
    # No section at all — append one to the end.
    {
      cat "$TMP_STORY"
      printf '\n## Custom Scenarios\n\n'
      printf '| CS | Tier | Description | File |\n'
      printf '|----|------|-------------|------|\n'
      printf '| %s | %s | %s |  |\n' "$cs_id" "$TIER" "$DESCRIPTION"
    } >"$TMP_STORY.2"
    mv "$TMP_STORY.2" "$TMP_STORY"
  fi
fi

mv "$TMP_STORY" "$STORY_FILE"
trap - EXIT

printf '%s\n' "$cs_id"
exit 0
