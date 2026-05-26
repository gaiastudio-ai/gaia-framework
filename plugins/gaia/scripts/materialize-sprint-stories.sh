#!/usr/bin/env bash
# materialize-sprint-stories.sh — batch story materializer for /gaia-create-story --for-sprint (E107-S3)
#
# The DETERMINISTIC core of `/gaia-create-story --for-sprint <id>`: given a
# sprint's selected story keys, materialize ONLY the ones that lack a file, in
# one invocation, so an operator does not run /gaia-create-story 40 times
# (fixes Test02 F-9 / Test01 E2). Create-if-missing + idempotent.
#
# Scope (Val W1): story ELABORATION — filling the {CONTENT_PLACEHOLDER} bodies
# (real ACs/tasks/test-scenarios) — is LLM/subagent work (gaia-create-story
# SKILL.md Step 3), NOT scriptable. This script does the scriptable parts:
#   * idempotency check (skip a key that already has a file)
#   * scaffold a skeleton into the E105-S1 per-story layout
#     (epic-{epic-slug}/{key}-{story-slug}/story.md) with priority_flag: null
#   * --refresh re-scaffolds a rolled-over story BUT guards against clobbering
#     an in-progress/review/done story (only refresh backlog/ready-for-dev)
#   * emit an ELABORATION MANIFEST: the newly-scaffolded keys whose
#     {CONTENT_PLACEHOLDER} bodies the main-turn LLM loop must fill, after which
#     each is transitioned to ready-for-dev via transition-story-status.sh.
#
# Refs: ADR-128, ADR-127/E105-S1, FR-559, feedback_priority_flag_never_auto_set
#
# Invocation:
#   materialize-sprint-stories.sh --keys "K1,K2,..." --epics <epics-and-stories.md>
#       --impl-root <implementation-artifacts-dir>
#       [--refresh] [--manifest <path>]
#   materialize-sprint-stories.sh --help
#
# Exit codes:
#   0 — materialization complete (possibly all skipped)
#   1 — bad arguments

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="materialize-sprint-stories.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SLUGIFY="$SCRIPT_DIR/../skills/gaia-create-story/scripts/slugify.sh"
SCAFFOLD="$SCRIPT_DIR/../skills/gaia-create-story/scripts/scaffold-story.sh"
TEMPLATE="$SCRIPT_DIR/../skills/gaia-create-story/story-template.md"
RESOLVE_STORY="$SCRIPT_DIR/resolve-story-file.sh"
RESOLVE_EPIC_SLUG="$SCRIPT_DIR/lib/resolve-epic-slug.sh"  # E107-S3 Val W-1: canonical epic-dir SSOT

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
materialize-sprint-stories.sh — batch materializer for /gaia-create-story --for-sprint

Usage:
  materialize-sprint-stories.sh --keys "K1,K2,..." --epics <epics-and-stories.md>
      --impl-root <impl-artifacts-dir> [--refresh] [--manifest <path>]

Materializes ONLY the missing selected stories into the per-story layout
(epic-{slug}/{key}-{slug}/story.md), priority_flag: null. Idempotent
(create-if-missing). --refresh re-scaffolds a rolled-over story but never
clobbers an in-progress/review/done one. Emits an elaboration manifest of the
newly-scaffolded keys for the main-turn LLM loop to fill + transition to
ready-for-dev. The {CONTENT_PLACEHOLDER} bodies are LLM-filled, not scripted.
USAGE
  exit 0
fi

KEYS=""
EPICS=""
IMPL_ROOT=""
REFRESH=0
MANIFEST=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --keys) KEYS="${2:-}"; shift 2 ;;
    --epics) EPICS="${2:-}"; shift 2 ;;
    --impl-root) IMPL_ROOT="${2:-}"; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$KEYS" ] || die "--keys \"K1,K2,...\" is required (try --help)"
[ -n "$EPICS" ] || die "--epics <epics-and-stories.md> is required (try --help)"
[ -r "$EPICS" ] || die "epics file not found/readable: $EPICS"
[ -n "$IMPL_ROOT" ] || die "--impl-root <dir> is required (try --help)"
mkdir -p "$IMPL_ROOT"
[ -x "$SCAFFOLD" ] || die "scaffold-story.sh not found/executable at $SCAFFOLD"
[ -f "$TEMPLATE" ] || die "story-template.md not found at $TEMPLATE"

# Extract a labelled field (`- **Label:** value`) from a story's epics block.
_epics_field() { # $1 = story key ; $2 = label (e.g. Epic, Priority, Size, Risk)
  awk -v key="$1" -v lbl="$2" '
    $0 ~ ("^### Story " key ":") { in_block=1; next }
    in_block && /^### Story / { in_block=0 }
    in_block && $0 ~ ("^- \\*\\*" lbl ":\\*\\*") {
      line=$0
      sub("^- \\*\\*" lbl ":\\*\\*[[:space:]]*", "", line)
      print line; exit
    }
  ' "$EPICS"
}

# Extract the story title from the `### Story <key>: <title>` heading.
_epics_title() { # $1 = story key
  awk -v key="$1" '
    $0 ~ ("^### Story " key ":") {
      line=$0; sub("^### Story " key ":[[:space:]]*", "", line); print line; exit
    }
  ' "$EPICS"
}

# normalize the comma-separated key list
keys_norm="$(printf '%s' "$KEYS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '^E[0-9]+-S[0-9]+$' || true)"
[ -n "$keys_norm" ] || die "no valid story keys parsed from --keys (expected E#-S# form)"

: > "${MANIFEST:-/dev/null}"   # truncate the manifest if one was requested
materialized=0
skipped=0
refreshed=0
guarded=0

while IFS= read -r key; do
  [ -n "$key" ] || continue

  # epic-dir name from the CANONICAL resolver (Val W-1 / E79-S1 SSOT) — reads the
  # `## {epic_key} — ` H2 title, drops parentheticals, truncates to 69 chars, and
  # already includes the `epic-` prefix. transition-story-status.sh + the tier-0
  # resolver converge on this exact directory, so the materializer must use it
  # rather than rolling its own slug (which would diverge on parenthetical/long
  # epic names and break AC3's ready-for-dev transition). Fall back to numeric.
  epic_num="${key%%-*}"                 # E900
  epic_dir="$(bash "$RESOLVE_EPIC_SLUG" --epic-key "$epic_num" --epics-file "$EPICS" 2>/dev/null || true)"
  [ -n "$epic_dir" ] || epic_dir="epic-${epic_num}"

  title="$(_epics_title "$key")"
  story_slug="$(bash "$SLUGIFY" --title "$title" 2>/dev/null || true)"
  [ -n "$story_slug" ] || story_slug="story"
  story_dir="${IMPL_ROOT}/${epic_dir}/${key}-${story_slug}"
  story_file="${story_dir}/story.md"

  # idempotency: does a file already exist for this key (any layout)?
  existing=""
  if [ -x "$RESOLVE_STORY" ]; then
    existing="$(IMPLEMENTATION_ARTIFACTS="$IMPL_ROOT" bash "$RESOLVE_STORY" "$key" 2>/dev/null || true)"
  fi
  [ -z "$existing" ] && [ -f "$story_file" ] && existing="$story_file"

  if [ -n "$existing" ]; then
    if [ "$REFRESH" -eq 1 ]; then
      # --refresh guard: never clobber an in-progress/review/done story
      cur_status="$(awk '/^status:[[:space:]]*/{sub(/^status:[[:space:]]*/,""); gsub(/["\x27]/,""); print; exit}' "$existing" 2>/dev/null)"
      case "$cur_status" in
        in-progress|review|done)
          log "guarded: $key is '$cur_status' — refusing to --refresh (would clobber work)"
          guarded=$((guarded + 1))
          continue
          ;;
      esac
      # re-scaffold the skeleton (backlog/ready-for-dev are safe to re-elaborate)
      : # fall through to scaffold below, overwriting $existing
      story_file="$existing"
      story_dir="$(dirname "$story_file")"
      refreshed=$((refreshed + 1))
    else
      log "skipped: $key already materialized at $existing"
      skipped=$((skipped + 1))
      continue
    fi
  else
    materialized=$((materialized + 1))
  fi

  # build a minimal frontmatter (priority_flag: null per feedback_priority_flag_never_auto_set;
  # status: backlog — the main-turn loop transitions to ready-for-dev via
  # transition-story-status.sh after filling the {CONTENT_PLACEHOLDER} bodies).
  priority="$(_epics_field "$key" "Priority")"; [ -n "$priority" ] || priority="P2"
  size="$(_epics_field "$key" "Size")"; size="${size%% *}"; [ -n "$size" ] || size="M"
  risk="$(_epics_field "$key" "Risk")"; [ -n "$risk" ] || risk="medium"
  fm="$(printf 'key: "%s"\ntitle: "%s"\nepic: "%s"\nstatus: backlog\npriority: "%s"\nsize: "%s"\nrisk: "%s"\nsprint_id: null\npriority_flag: null\n' \
    "$key" "$title" "$epic_num" "$priority" "$size" "$risk")"

  mkdir -p "${story_dir}/reviews"
  printf '%s' "$fm" | bash "$SCAFFOLD" --template "$TEMPLATE" --output "$story_file" --frontmatter - >/dev/null 2>&1 \
    || die "scaffold failed for $key"

  # record the key in the elaboration manifest (main-turn LLM fills the bodies)
  [ -n "$MANIFEST" ] && printf '%s\t%s\n' "$key" "$story_file" >> "$MANIFEST"
  printf 'materialized: %s -> %s\n' "$key" "$story_file"
done <<EOF
$keys_norm
EOF

printf '\nsummary: materialized=%d skipped=%d refreshed=%d guarded=%d\n' \
  "$materialized" "$skipped" "$refreshed" "$guarded"
if [ -n "$MANIFEST" ] && [ -s "$MANIFEST" ]; then
  printf 'elaboration manifest written to %s — fill {CONTENT_PLACEHOLDER} bodies then transition each to ready-for-dev via transition-story-status.sh\n' "$MANIFEST"
fi
exit 0
