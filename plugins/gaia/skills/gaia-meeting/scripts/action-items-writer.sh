#!/usr/bin/env bash
# action-items-writer.sh — gaia-meeting v2 action-items registry writer (E76-S3)
#
# AC2 / AC5 / FR-MTG-21 / ADR-086 / TC-MTG-AI-3 / TC-MTG-AI-4 / TC-MTG-AI-6
#
# Reads a drafted-items YAML payload (one entry per `- type: …` block), reads
# the existing canonical registry at `docs/planning-artifacts/action-items.yaml`
# (or any path passed via --registry), bumps the registry header to
# `schema_version: 2` if missing (idempotent), allocates daily-N IDs of the
# form `AI-{YYYY-MM-DD}-{N}` (N restarts at 1 each day, scanned from existing
# entries), resolves `target_command` from the eleven-type lookup table, and
# appends fully-rendered v2 entries at the tail of the registry. Pre-existing
# v1 entries (with `text` + `classification`) MUST remain byte-identical.
#
# Atomic write: writes to a sibling tempfile and `mv`s into place.
#
# Usage:
#   action-items-writer.sh \
#     --registry <path-to-action-items.yaml> \
#     --drafts   <path-to-drafts.yaml> \
#     --source-meeting <slug-or-source-ref> \
#     --date <YYYY-MM-DD>
#
# Exit codes:
#   0 = success
#   2 = invalid args or unknown action-item type encountered
#   3 = I/O error (registry unreadable / unwritable)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/lib/type-target-resolver.sh"

REGISTRY=""
DRAFTS=""
SOURCE_MEETING=""
DATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)        REGISTRY="$2"; shift 2 ;;
    --drafts)          DRAFTS="$2"; shift 2 ;;
    --source-meeting)  SOURCE_MEETING="$2"; shift 2 ;;
    --date)            DATE="$2"; shift 2 ;;
    *) echo "action-items-writer.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$REGISTRY" || -z "$DRAFTS" || -z "$SOURCE_MEETING" || -z "$DATE" ]]; then
  echo "action-items-writer.sh: --registry, --drafts, --source-meeting, --date are required" >&2
  exit 2
fi

if [[ ! -f "$DRAFTS" ]]; then
  echo "action-items-writer.sh: drafts file not found: $DRAFTS" >&2
  exit 3
fi

# 1) Determine the next daily-N for the given DATE by scanning existing IDs.
next_n=1
if [[ -f "$REGISTRY" ]]; then
  max_n=$(grep -E "^- id: AI-${DATE}-[0-9]+$" "$REGISTRY" | sed -E "s/^- id: AI-${DATE}-([0-9]+)$/\1/" | sort -n | tail -1 || true)
  if [[ -n "${max_n:-}" ]]; then
    next_n=$((max_n + 1))
  fi
fi

# 2) Parse drafts: very small YAML grammar — each draft block is delimited by
#    `- type: <value>` lines. Subsequent indented `key: value` lines belong to
#    the current block until the next `- type:` line or EOF.
#    We don't pull yq because adapters are not guaranteed.
declare -a draft_types draft_priorities draft_assignees draft_contexts draft_acceptances
cur_type=""; cur_priority=""; cur_assignee=""; cur_context=""; cur_acceptance=""

flush() {
  if [[ -n "$cur_type" ]]; then
    draft_types+=("$cur_type")
    draft_priorities+=("${cur_priority:-normal}")
    draft_assignees+=("${cur_assignee:-unassigned}")
    draft_contexts+=("${cur_context:-}")
    draft_acceptances+=("${cur_acceptance:-}")
  fi
  cur_type=""; cur_priority=""; cur_assignee=""; cur_context=""; cur_acceptance=""
}

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^-[[:space:]]+type:[[:space:]]+(.+)$ ]]; then
    flush
    cur_type="${BASH_REMATCH[1]}"
    # strip surrounding quotes/whitespace
    cur_type="${cur_type%\"}"; cur_type="${cur_type#\"}"
    cur_type="${cur_type%\'}"; cur_type="${cur_type#\'}"
    cur_type="${cur_type// /}"
  elif [[ "$line" =~ ^[[:space:]]+priority:[[:space:]]+(.+)$ ]]; then
    cur_priority="${BASH_REMATCH[1]}"
    cur_priority="${cur_priority//\"/}"; cur_priority="${cur_priority// /}"
  elif [[ "$line" =~ ^[[:space:]]+assignee:[[:space:]]+(.+)$ ]]; then
    cur_assignee="${BASH_REMATCH[1]}"
    cur_assignee="${cur_assignee%\"}"; cur_assignee="${cur_assignee#\"}"
  elif [[ "$line" =~ ^[[:space:]]+context_for_target:[[:space:]]+(.+)$ ]]; then
    cur_context="${BASH_REMATCH[1]}"
    cur_context="${cur_context%\"}"; cur_context="${cur_context#\"}"
  elif [[ "$line" =~ ^[[:space:]]+acceptance:[[:space:]]+(.+)$ ]]; then
    cur_acceptance="${BASH_REMATCH[1]}"
    cur_acceptance="${cur_acceptance%\"}"; cur_acceptance="${cur_acceptance#\"}"
  fi
done < "$DRAFTS"
flush

if [[ ${#draft_types[@]} -eq 0 ]]; then
  echo "action-items-writer.sh: no drafted items found in $DRAFTS" >&2
  exit 0  # nothing to write — not an error
fi

# 3) Validate every draft type via the resolver (fail-fast, no silent coercion).
declare -a draft_target_commands
for t in "${draft_types[@]}"; do
  tc="$("$RESOLVER" "$t")"  # exits non-zero on unknown — set -e propagates
  draft_target_commands+=("$tc")
done

# 4) Build the appended block.
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "${DATE}T00:00:00Z")"
appended="$(mktemp)"
trap 'rm -f "$appended"' EXIT

for i in "${!draft_types[@]}"; do
  t="${draft_types[$i]}"
  p="${draft_priorities[$i]}"
  a="${draft_assignees[$i]}"
  c="${draft_contexts[$i]}"
  ac="${draft_acceptances[$i]}"
  tc="${draft_target_commands[$i]}"
  id="AI-${DATE}-$((next_n + i))"
  {
    echo ""
    echo "- id: ${id}"
    echo "  created: \"${created_at}\""
    echo "  source_meeting: ${SOURCE_MEETING}"
    echo "  type: ${t}"
    echo "  priority: ${p}"
    echo "  status: open"
    echo "  target_command: \"${tc}\""
    echo "  assignee: \"${a}\""
    echo "  context_for_target: \"${c}\""
    echo "  acceptance: \"${ac}\""
  } >> "$appended"
done

# 5) Build the new registry contents atomically.
new_registry="$(mktemp)"
trap 'rm -f "$appended" "$new_registry"' EXIT

if [[ -f "$REGISTRY" ]]; then
  # Idempotent header bump: if `schema_version: 2` not present, insert at top
  # (after any leading comment block). Preserve all existing bytes thereafter.
  if grep -qE '^schema_version: 2$' "$REGISTRY"; then
    cp "$REGISTRY" "$new_registry"
  else
    # Find the line index of the first non-comment, non-blank line.
    insert_at=$(awk 'NR==1{} /^#/{next} /^[[:space:]]*$/{next} {print NR; exit}' "$REGISTRY")
    if [[ -z "${insert_at:-}" ]]; then
      cat "$REGISTRY" > "$new_registry"
      echo "schema_version: 2" >> "$new_registry"
    else
      head -n $((insert_at - 1)) "$REGISTRY" > "$new_registry"
      echo "schema_version: 2" >> "$new_registry"
      tail -n +"$insert_at" "$REGISTRY" >> "$new_registry"
    fi
  fi
else
  # Brand-new registry — minimal scaffold with header + items list.
  cat > "$new_registry" <<'YAML'
# Action Items — canonical registry (architecture §10.28.6, ADR-052, ADR-086)
schema_version: 2
items:
YAML
fi

cat "$appended" >> "$new_registry"

# Atomic move — same directory as REGISTRY for cross-fs safety.
mkdir -p "$(dirname "$REGISTRY")"
mv "$new_registry" "$REGISTRY"
trap 'rm -f "$appended"' EXIT

exit 0
