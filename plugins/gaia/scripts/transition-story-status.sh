#!/usr/bin/env bash
# transition-story-status.sh — unified atomic story-status transitions.
#
# Atomically updates ALL FIVE locations a story status lives in, under flock,
# with rollback on partial failure:
#
#   1. Story file frontmatter (`status:` field) + body `**Status:**` line
#   2. sprint-status.yaml entry (delegated to sprint-state.sh)
#   3. epics-and-stories.md per-story `- **Status:** <state>` line
#   4. per-epic shard `- **Status:** <state>` line under `### Story <KEY>:`
#      (when a matching `*-e<EID>-*.md` shard exists in
#      ${PLANNING_ARTIFACTS}/epics/; missing shards are NOT a divergence —
#      see the per-epic shard contract C3)
#   5. story-index.yaml entry (created if absent)
#
# This script eliminates a long-standing class of bug where the four files drift
# out of sync because they were written by different scripts with no shared lock.
#
# Usage:
#   transition-story-status.sh <story_key> --to <new_status> [--from <expected_current>]
#                                          [--title <s>]    [--epic <s>]
#                                          [--priority <s>] [--risk <s>]
#                                          [--author <s>]   [--file <path>]
#   transition-story-status.sh --help
#
# State machine: see lib/story-state-machine.sh.
#
# Exit codes:
#   0  success (including idempotent self-transition no-op)
#   1  generic / usage error
#   2  story file missing
#   3  multiple story files match the glob
#   4  malformed frontmatter (missing or unparseable status)
#   5  epics-and-stories.md missing
#   6  lock contention (5s flock timeout)
#   7  invalid state transition
#   8  rollback after partial failure
#
# Config (env vars, all optional):
#   PROJECT_PATH              — defaults to "."
#   IMPLEMENTATION_ARTIFACTS  — smart-fallback: ${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts
#                                (when present) else ${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts
#   PLANNING_ARTIFACTS        — smart-fallback: ${PROJECT_PATH}/.gaia/artifacts/planning-artifacts
#                                (when present) else ${PROJECT_PATH}/.gaia/artifacts/planning-artifacts
#   MEMORY_PATH               — smart-fallback: ${PROJECT_PATH}/.gaia/memory (when present)
#                                else ${PROJECT_PATH}/_memory
#   SPRINT_STATUS_YAML        — overrides default yaml path (forwarded to sprint-state.sh)
#   EPICS_AND_STORIES         — overrides default planning artifact path
#   STORY_INDEX_YAML          — overrides per-epic index path resolution
#                               (default: ${IMPLEMENTATION_ARTIFACTS}/epic-{epic_key}-{slug}/stories/story-index.yaml,
#                                derived via lib/resolve-epic-slug.sh)
#   STORY_STATUS_LOCK         — overrides default lock path
#
# story-index.yaml metadata enrichment:
#   The script writes a 7-field metadata-rich entry to story-index.yaml plus
#   the existing `status:` field, in this canonical order on every write:
#     story_key, title, epic, priority, risk, author, file, status
#   Source precedence per field: explicit CLI flag > frontmatter value > "" empty.
#   Empty/missing optional fields render as "" (an empty quoted string) to keep
#   YAML quoting uniform — never `null`. Idempotency is byte-stable: re-running
#   with identical inputs yields a byte-identical entry block.
#
#   Consumer:        plugins/gaia/skills/gaia-create-story/SKILL.md
#   Source spec:     .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.9
#   Contract source: sole-writer discipline for story-index.yaml

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="transition-story-status.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
STATE_MACHINE_LIB="$LIB_DIR/story-state-machine.sh"
RESOLVE_EPIC_SLUG_LIB="$LIB_DIR/resolve-epic-slug.sh"

# shellcheck source=lib/story-state-machine.sh
. "$STATE_MACHINE_LIB"

# Sourced for resolve_epic_slug() used to derive the per-epic
# story-index.yaml location. The library is sourceable with zero side
# effects; the canonical-layout slug-derivation algorithm single-sources
# from this helper.
# shellcheck source=lib/resolve-epic-slug.sh
. "$RESOLVE_EPIC_SLUG_LIB"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# yaml_single_quote — render a free-text value as a complete single-quoted YAML
# scalar (issue-1403). Doubles inner single-quotes per the YAML escape so an
# embedded double-quote OR apostrophe in a title round-trips without corrupting
# story-index.yaml. Sibling of the same helper in sprint-state.sh.
yaml_single_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

# Script-level EXIT/INT/TERM trap for atomic-write tmp cleanup.
#
# Every tempfile-creating call site appends the resulting path to
# _GAIA_TMP_PATHS and captures its index. After a successful rename over the
# destination, the slot is cleared (set to empty) so the cleanup is
# idempotent and never targets the renamed final file. The trap covers cases
# the existing function-scoped RETURN traps and inline manual rm paths miss:
# SIGINT (Ctrl-C), SIGTERM (parent kill), OOM, and signal-during-awk.
#
# bash 3.2 compatible: plain array literal + `+=` + indexed assignment.
_GAIA_TMP_PATHS=()
_cleanup_tmps() {
  # Guard against bash 3.2 / `set -u` "unbound variable" on empty arrays.
  if [ "${#_GAIA_TMP_PATHS[@]}" -eq 0 ]; then return 0; fi
  local p
  for p in "${_GAIA_TMP_PATHS[@]}"; do
    if [ -n "$p" ] && [ -e "$p" ]; then
      rm -f "$p" 2>/dev/null || true
    fi
  done
}
trap '_cleanup_tmps' EXIT INT TERM

usage() {
  cat <<'USAGE'
Usage:
  transition-story-status.sh <story_key> --to <new_status> [--from <expected_current>]
                                         [--title <s>]    [--epic <s>]
                                         [--priority <s>] [--risk <s>]
                                         [--author <s>]   [--file <path>]
  transition-story-status.sh <story_key> --reconcile-only [other flags...]
  transition-story-status.sh --help

Atomically updates the story-file frontmatter, sprint-status.yaml,
epics-and-stories.md, the matching per-epic shard under
docs/planning-artifacts/epics/, and story-index.yaml under flock, rolling
back on any partial failure.

States: backlog | validating | ready-for-dev | in-progress | blocked | review | done

Optional metadata flags:
  --title --epic --priority --risk --author --file
    Override the corresponding field written to story-index.yaml. Each flag
    is optional; when omitted, the value falls back to the matching story
    frontmatter field (`title`, `epic`, `priority`, `risk`, `author`). The
    `--file` flag defaults to the resolved story file path when omitted.
    Precedence: explicit flag > frontmatter > "" (empty quoted string).

Reconcile flag:
  --reconcile-only
    Replay every writer at the current frontmatter status without
    triggering the idempotent self-transition no-op. Use to bring a drifted
    per-epic shard back into alignment with the story-file source of
    truth. Skips state-machine validation (no edge to validate). The flag
    is mutually-compatible with --from; --to is optional in this mode and
    defaults to the current frontmatter status.

Exit codes:
  0 success / no-op    1 generic / usage    2 story file missing
  3 multiple matches   4 malformed frontmatter   5 epics-and-stories.md missing
  6 lock contention    7 invalid transition      8 rollback after failure
USAGE
}

# ---------- Argument parsing ----------

if [ $# -lt 1 ]; then usage >&2; exit 1; fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

STORY_KEY="$1"; shift || true
NEW_STATUS=""
EXPECTED_FROM=""
# `--reconcile-only` forces a self-transition that replays every
# writer at the current frontmatter status, used to bring a drifted shard
# back into alignment with the story-file source of truth without violating
# the idempotent-self-transition contract (which short-circuits
# normal --to <same> calls). Only effect: skip the no-op short-circuit.
RECONCILE_ONLY=0

# Metadata enrichment flags. Each is "unset" by sentinel until proven
# otherwise so we can distinguish "explicit empty string" from "not provided".
# Sentinel: leading null-byte-like marker `__TSS_UNSET__` (no story field can
# legitimately equal this string; the resolver replaces it with the frontmatter
# fallback or the empty string).
TSS_UNSET="__TSS_UNSET__"
META_TITLE="$TSS_UNSET"
META_EPIC="$TSS_UNSET"
META_PRIORITY="$TSS_UNSET"
META_RISK="$TSS_UNSET"
META_AUTHOR="$TSS_UNSET"
META_FILE="$TSS_UNSET"

while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      [ $# -ge 2 ] || { err "--to requires a value"; exit 1; }
      NEW_STATUS="$2"; shift 2 ;;
    --from)
      [ $# -ge 2 ] || { err "--from requires a value"; exit 1; }
      EXPECTED_FROM="$2"; shift 2 ;;
    --title)
      [ $# -ge 2 ] || { err "--title requires a value"; exit 1; }
      META_TITLE="$2"; shift 2 ;;
    --epic)
      [ $# -ge 2 ] || { err "--epic requires a value"; exit 1; }
      META_EPIC="$2"; shift 2 ;;
    --priority)
      [ $# -ge 2 ] || { err "--priority requires a value"; exit 1; }
      META_PRIORITY="$2"; shift 2 ;;
    --risk)
      [ $# -ge 2 ] || { err "--risk requires a value"; exit 1; }
      META_RISK="$2"; shift 2 ;;
    --author)
      [ $# -ge 2 ] || { err "--author requires a value"; exit 1; }
      META_AUTHOR="$2"; shift 2 ;;
    --file)
      [ $# -ge 2 ] || { err "--file requires a value"; exit 1; }
      META_FILE="$2"; shift 2 ;;
    --reconcile-only)
      RECONCILE_ONLY=1
      shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 1 ;;
  esac
done

if [ -z "$NEW_STATUS" ] && [ "$RECONCILE_ONLY" != "1" ]; then
  err "missing required --to <new_status>"
  usage >&2
  exit 1
fi

if [ -n "$NEW_STATUS" ] && ! is_canonical_story_state "$NEW_STATUS"; then
  err "invalid target state: '$NEW_STATUS' (allowed: $(canonical_story_states_hint))"
  exit 1
fi

if [ -n "$EXPECTED_FROM" ] && ! is_canonical_story_state "$EXPECTED_FROM"; then
  err "invalid --from state: '$EXPECTED_FROM' (allowed: $(canonical_story_states_hint))"
  exit 1
fi

# ---------- Path resolution ----------
#
# Three-stage env-var precedence:
#   Stage 1: CLAUDE_PROJECT_ROOT — supplied by Claude Code when invoked from the
#            non-git project-root workspace (per CLAUDE.md §"Non-git project-root
#            workspace (supported mode)").
#   Stage 2: PROJECT_PATH — legacy in-tree gaia-framework invocation override.
#   Stage 3: '.' fallback — preserves the legacy CWD-relative behavior.

PROJECT_PATH="${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}"

# Smart-fallback — env-var > .gaia/<subdir>/ > legacy <subdir>/. Env-var overrides win.
if [ -z "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
  if [ -d "${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts" ]; then
    IMPLEMENTATION_ARTIFACTS="${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts"
  else
    IMPLEMENTATION_ARTIFACTS="${PROJECT_PATH}/docs/implementation-artifacts"
  fi
fi
if [ -z "${PLANNING_ARTIFACTS:-}" ]; then
  if [ -d "${PROJECT_PATH}/.gaia/artifacts/planning-artifacts" ]; then
    PLANNING_ARTIFACTS="${PROJECT_PATH}/.gaia/artifacts/planning-artifacts"
  else
    PLANNING_ARTIFACTS="${PROJECT_PATH}/docs/planning-artifacts"
  fi
fi
if [ -z "${MEMORY_PATH:-}" ]; then
  # .gaia/memory is the only memory tree; legacy _memory fallback removed
  # with the consolidation migration.
  MEMORY_PATH="${PROJECT_PATH}/.gaia/memory"
fi

# Resolve EPICS_AND_STORIES across the dual-layout invariant.
# Mirrors validate-gate.sh::check_file_nonempty resolution order:
#   1. Flat path        ${PLANNING_ARTIFACTS}/epics-and-stories.md
#   2. Sharded sibling  ${PLANNING_ARTIFACTS}/epics-and-stories/index.md
#   3. Legacy alias     ${PLANNING_ARTIFACTS}/epics/index.md
#                       (brownfield projects whose shard root pre-dates the dual-layout)
# If the caller pre-set EPICS_AND_STORIES, that override wins unconditionally.
# When NO layout exists on disk, fall back to the flat default so the existing
# "epics-and-stories.md not found" guard still fires with the same log line
# (preserves the log-parser contract from the original error path).
resolve_epics_and_stories_path() {
  local flat="${PLANNING_ARTIFACTS}/epics-and-stories.md"
  local sharded="${PLANNING_ARTIFACTS}/epics-and-stories/index.md"
  local legacy="${PLANNING_ARTIFACTS}/epics/index.md"
  if [ -f "$flat" ]; then
    printf '%s\n' "$flat"
    return 0
  fi
  if [ -f "$sharded" ]; then
    printf '%s\n' "$sharded"
    return 0
  fi
  if [ -f "$legacy" ]; then
    printf '%s\n' "$legacy"
    return 0
  fi
  printf '%s\n' "$flat"
}
EPICS_AND_STORIES="${EPICS_AND_STORIES:-$(resolve_epics_and_stories_path)}"
# STORY_INDEX_YAML is now resolved per-epic via resolve_epic_slug(),
# AFTER the story file is located (we need the `epic:` frontmatter field).
# The legacy flat path (`${IMPLEMENTATION_ARTIFACTS}/story-index.yaml`) is
# READ-ONLY-FALLBACK only — the writer never targets it. See
# resolve_story_index_path() and legacy_flat_index_lookup() below.
LEGACY_FLAT_STORY_INDEX="${IMPLEMENTATION_ARTIFACTS}/story-index.yaml"
STORY_STATUS_LOCK="${STORY_STATUS_LOCK:-${MEMORY_PATH}/.story-status.lock}"

# Forward SPRINT_STATUS_YAML untouched if caller pre-set it.

# ---------- Startup orphan-tmp sweep ----------
#
# Garbage-collect *.tmp.?????? files older than 60 minutes from the
# documented artifact directories. Catches orphans left by `kill -9`,
# OOM, or power loss (which bypass the script-level EXIT/INT/TERM trap).
#
# Bounded to the documented allowlist:
#   - "${PLANNING_ARTIFACTS}/epics"
#   - "${IMPLEMENTATION_ARTIFACTS}"
# Never /tmp, never $HOME, never ${PROJECT_PATH} root. The 60-minute
# threshold provides ~6x headroom over the tightest known concurrent run.
#
# Set GAIA_SKIP_ORPHAN_SWEEP=1 to disable (e.g. for forensic inspection).
# Errors are swallowed (2>/dev/null); zero stdout (AC7 silent GC).
if [ "${GAIA_SKIP_ORPHAN_SWEEP:-0}" != "1" ]; then
  find "${PLANNING_ARTIFACTS}/epics" "${IMPLEMENTATION_ARTIFACTS}" \
    -maxdepth 2 -name '*.tmp.??????' -mmin +60 -delete 2>/dev/null || true
fi

# ---------- Helpers ----------

# Locate the story file and filter by frontmatter `template: 'story'`. Mirrors
# sprint-state.sh's locator semantics so both scripts agree on which file is
# canonical when review-sibling files (e.g. -review.md) sit alongside.
locate_story_file() {
  local key="$1"
  local pattern="${IMPLEMENTATION_ARTIFACTS}/${key}-*.md"
  local epic_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/stories/${key}-*.md"
  # New per-story nested layout — epic-*/{key}-{slug}/story.md.
  # The directory name carries the key (boundary "${key}-"); the basename is
  # story.md. The existing `template: story` frontmatter filter below rejects any
  # E*-S*-*/story.md evidence-dir false-matches, so this glob is safe to add.
  local perstory_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/${key}-*/story.md"

  shopt -s nullglob
  # shellcheck disable=SC2206
  local matches=( $perstory_pattern $pattern $epic_pattern )
  shopt -u nullglob

  if [ "${#matches[@]}" -eq 0 ]; then
    err "no story file found for key '$key' (glob: $pattern)"
    exit 2
  fi

  local canonical=()
  local m
  for m in "${matches[@]}"; do
    if awk '
      /^---[[:space:]]*$/ { n++; if (n == 2) exit }
      n == 1 && /^template:[[:space:]]*["\x27]?story["\x27]?[[:space:]]*$/ { found = 1; exit }
      END { exit (found ? 0 : 1) }
    ' "$m"; then
      canonical+=( "$m" )
    fi
  done

  # Deduplicate canonical matches by realpath. After epic-grouped layout was
  # introduced, top-level legacy filenames may exist as symlinks to the
  # canonical epic-grouped path. Both resolve to the same inode, so they are
  # not ambiguous — collapse them. Prefer the non-symlink (canonical) path
  # when both forms appear.
  if [ "${#canonical[@]}" -gt 1 ]; then
    local dedup=()
    local seen_realpaths=""
    local rp
    # Pass 1: prefer non-symlink entries.
    for m in "${canonical[@]}"; do
      [ -L "$m" ] && continue
      rp=$(cd "$(dirname "$m")" && /bin/pwd -P)/$(basename "$m")
      case "$seen_realpaths" in
        *"|$rp|"*) ;;
        *) dedup+=( "$m" ); seen_realpaths="${seen_realpaths}|$rp|" ;;
      esac
    done
    # Pass 2: include symlinks only if their target wasn't already seen.
    for m in "${canonical[@]}"; do
      [ -L "$m" ] || continue
      rp=$(cd "$(dirname "$m")" && /bin/pwd -P)/$(basename "$(readlink "$m" || echo "$m")")
      # Use realpath via cd -P fallback
      if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath "$m")
      else
        rp=$(cd "$(dirname "$m")" && cd "$(dirname "$(readlink "$m")")" 2>/dev/null && /bin/pwd -P)/$(basename "$(readlink "$m")")
      fi
      case "$seen_realpaths" in
        *"|$rp|"*) ;;
        *) dedup+=( "$m" ); seen_realpaths="${seen_realpaths}|$rp|" ;;
      esac
    done
    canonical=( "${dedup[@]}" )
  fi

  if [ "${#canonical[@]}" -eq 0 ]; then
    # Fall back to the only match if it has any frontmatter — keeps non-template
    # fixtures working while still rejecting truly-multiple ambiguous matches.
    if [ "${#matches[@]}" -eq 1 ]; then
      printf '%s' "${matches[0]}"
      return 0
    fi
    err "no canonical story file for key '$key' (checked ${#matches[@]} candidates)"
    exit 3
  fi
  if [ "${#canonical[@]}" -gt 1 ]; then
    err "ambiguous canonical story files for key '$key': ${canonical[*]}"
    exit 3
  fi
  printf '%s' "${canonical[0]}"
}

# Read frontmatter `status:` value from a story file.
read_frontmatter_status() {
  local file="$1" status
  status=$(awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) exit
    }
    in_fm && /^status:[[:space:]]*/ {
      sub(/^status:[[:space:]]*/, "", $0)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$file")

  if [ -z "$status" ]; then
    err "story file '$file' is missing 'status:' in frontmatter"
    exit 4
  fi
  printf '%s' "$status"
}

# Read an arbitrary scalar frontmatter field by name, returning the unquoted
# value (or empty string if the field is absent / blank). Used by the
# metadata enrichment fallback path. Strips surrounding single/double quotes
# and whitespace; does not handle multiline / list values (the canonical
# fields used here — title, epic, priority, risk, author — are all scalars).
read_frontmatter_field() {
  local file="$1" field="$2" value
  value=$(awk -v field="$field" '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) exit
    }
    in_fm {
      pat = "^" field ":[[:space:]]*"
      if ($0 ~ pat) {
        v = $0
        sub(pat, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ' "$file")
  printf '%s' "$value"
}

# Resolve the canonical per-epic story-index.yaml path.
# Layout-aware: the index co-locates with the story-file tree.
#
# Inputs:
#   $1  story file path (used as the basename source for relative file:)
#   $2  epic_key from the story frontmatter (e.g., "E79")
#
# Output (stdout): the absolute path to the per-epic story-index.yaml. The
# subtree depends on the story-file layout so the index always sits at the
# COMMON PARENT of the per-epic story files:
#   - NEW per-story layout (epic-{slug}/{key}-{slug}/story.md, no `/stories/`
#     segment): `${IMPLEMENTATION_ARTIFACTS}/epic-{epic_key}-{slug}/story-index.yaml`
#     (epic root — a sibling of the per-story dirs it indexes).
#   - Legacy nested / flat: `${IMPLEMENTATION_ARTIFACTS}/epic-{epic_key}-{slug}/stories/story-index.yaml`
#     (unchanged — back-compat for projects already on the `stories/` layout).
#
# Honors the env override: if STORY_INDEX_YAML is pre-set by the caller,
# that wins unconditionally — preserves existing test fixtures and
# brownfield projects that explicitly opt out of per-epic resolution.
#
# On resolver failure (epic key not in epics-and-stories.md), prints a
# tagged stderr error and exits 1 — there is no implicit fallback to the
# flat path. The script MUST NEVER WRITE to the flat index.
resolve_story_index_path() {
  local story_file="$1" epic_key="$2"

  if [ -n "${STORY_INDEX_YAML:-}" ]; then
    printf '%s' "$STORY_INDEX_YAML"
    return 0
  fi

  if [ -z "$epic_key" ]; then
    err "story file '$story_file' is missing 'epic:' in frontmatter — cannot resolve per-epic story-index.yaml"
    exit 4
  fi

  if [ ! -f "$EPICS_AND_STORIES" ]; then
    err "epics-and-stories.md not found at '$EPICS_AND_STORIES' — cannot resolve per-epic story-index.yaml"
    exit 5
  fi

  local epic_slug
  if ! epic_slug="$(resolve_epic_slug "$epic_key" "$EPICS_AND_STORIES")"; then
    err "resolve_epic_slug failed for epic_key=$epic_key (epics_file=$EPICS_AND_STORIES)"
    exit 1
  fi

  # Layout discriminator: a story file whose basename is `story.md` and whose
  # path has NO `/stories/` segment is the new per-story layout; its index
  # belongs at the epic root. Everything else keeps the legacy `stories/`
  # index location. If an existing legacy index is already on disk for this
  # epic, prefer it (avoid stranding the prior index when a single epic mixes
  # layouts mid-migration).
  local epic_root="${IMPLEMENTATION_ARTIFACTS}/${epic_slug}"
  local legacy_index="${epic_root}/stories/story-index.yaml"
  local new_index="${epic_root}/story-index.yaml"

  if [ -f "$legacy_index" ]; then
    printf '%s' "$legacy_index"
    return 0
  fi

  case "$story_file" in
    */stories/*)
      printf '%s' "$legacy_index" ;;
    */story.md)
      printf '%s' "$new_index" ;;
    *)
      # Legacy flat `{key}-{slug}.md` (no epic subtree) — keep legacy location.
      printf '%s' "$legacy_index" ;;
  esac
}

# Compute the canonical `file:` pointer for a story entry.
# Layout-aware pointer.
#
# The pointer is RELATIVE to the directory holding story-index.yaml so a reader
# can resolve the story file from the index location:
#   - Legacy nested/flat: the bare basename (e.g. "E10-S3-foo.md"). The index
#     lives in `stories/` alongside the story files, so the basename suffices.
#   - New per-story layout (basename `story.md`, no `/stories/` segment): the
#     index lives at the epic root, one level ABOVE the per-story dirs, so the
#     pointer must include the per-story dir: "{key}-{slug}/story.md". A bare
#     "story.md" would be ambiguous (every story shares that basename).
compute_story_index_file_pointer() {
  local story_file="$1"
  local base
  base="$(basename "$story_file")"
  case "$story_file" in
    */stories/*)
      printf '%s' "$base" ;;
    */story.md)
      # Include the per-story directory name so the pointer is unambiguous.
      printf '%s/%s' "$(basename "$(dirname "$story_file")")" "$base" ;;
    *)
      printf '%s' "$base" ;;
  esac
}

# Read-only legacy-flat fallback lookup.
#
# Reads the legacy flat `docs/implementation-artifacts/story-index.yaml`
# (if present) and prints the matching entry block when <story_key> is
# found. NEVER writes. Emits a single-line stderr WARNING tagged
# `legacy-flat-fallback` whenever the fallback fires, so operators can
# track residual flat-index reads.
#
# Stdout: the matching entry block (header + child lines), or empty.
# Return: 0 on hit, 1 on miss (no warning), 2 on flat file absent.
#
# Steady state (after migration): the flat file is deleted; this helper
# returns 2 silently (NO error / NO warning).
legacy_flat_index_lookup() {
  local key="$1"
  local flat="${LEGACY_FLAT_STORY_INDEX:-${IMPLEMENTATION_ARTIFACTS}/story-index.yaml}"

  if [ ! -f "$flat" ]; then
    return 2
  fi

  local block
  block=$(awk -v target="$key" '
    BEGIN { in_entry = 0; in_stories = 0 }
    /^stories:[[:space:]]*$/ { in_stories = 1; next }
    in_stories && /^[A-Za-z]/ { in_stories = 0; in_entry = 0 }
    in_stories && /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      k = $0; sub(/^  /, "", k); sub(/:[[:space:]]*$/, "", k)
      in_entry = (k == target) ? 1 : 0
      if (in_entry) { print; next }
    }
    in_entry { print }
  ' "$flat")

  if [ -z "$block" ]; then
    return 1
  fi

  log "WARNING: legacy-flat-fallback fired for key=$key (read-only; migrate to per-epic index)"
  printf '%s\n' "$block"
  return 0
}

# Snapshot a file to "<file>.bak.<pid>" for rollback. Idempotent — re-snapshot
# overwrites prior snapshot. Returns the snapshot path on stdout. If the file
# does not yet exist, records a marker file recording the absence so rollback
# can rm -f the file the script created.
snapshot_for_rollback() {
  local file="$1"
  local snap="${file}.bak.tss.$$"
  # Ensure the parent dir exists. The snapshot marker file
  # (`${snap}.absent`) is created in the same dir as the target, which
  # for per-epic story-index.yaml may not yet exist on first transition.
  mkdir -p "$(dirname "$file")"
  if [ -e "$file" ]; then
    cp -p "$file" "$snap"
  else
    : > "${snap}.absent"
  fi
  printf '%s' "$snap"
}

# Apply a snapshot to its file. Used during rollback only.
restore_snapshot() {
  local file="$1" snap="$2"
  if [ -e "${snap}.absent" ]; then
    rm -f "$file" "${snap}.absent"
    return 0
  fi
  if [ -e "$snap" ]; then
    mv -f "$snap" "$file"
  fi
}

# Cleanup snapshots after successful run.
cleanup_snapshots() {
  local s
  for s in "$@"; do
    rm -f "$s" "${s}.absent" 2>/dev/null || true
  done
}

# Update the frontmatter `status:` field in the story file to NEW_STATUS.
# Tempfile + atomic rename. Body `> **Status:**` lines are also rewritten if
# present — sprint-state.sh insists on that line; we mirror its behaviour.
rewrite_frontmatter() {
  local file="$1" new_status="$2"
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v new_status="$new_status" '
    BEGIN { in_fm = 0; seen = 0; fm_done = 0; rewrote_fm = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    !fm_done && line ~ /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; print raw; next }
      if (in_fm) { in_fm = 0; fm_done = 1; print raw; next }
    }
    in_fm && !rewrote_fm && line ~ /^status:[[:space:]]*/ {
      crlf = ""
      if (raw ~ /\r$/) crlf = "\r"
      printf "status: %s%s\n", new_status, crlf
      rewrote_fm = 1
      next
    }
    fm_done && line ~ /^>[[:space:]]*\*\*Status:\*\*/ {
      crlf = ""
      if (raw ~ /\r$/) crlf = "\r"
      printf "> **Status:** %s%s\n", new_status, crlf
      next
    }
    { print raw }
    END {
      if (!rewrote_fm) exit 2
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    if [ $rc -eq 2 ]; then
      err "failed to locate frontmatter 'status:' in '$file'"
      exit 4
    fi
    err "awk rewrite of '$file' failed (rc=$rc)"
    exit 1
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    err "failed to mv tempfile over '$file'"
    exit 1
  fi
  # mv succeeded — clear the slot so the EXIT trap won't rm the renamed file.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Update the sprint-status.yaml status entry by delegating to sprint-state.sh,
# which already serialises yaml writes under its own flock + rewrites the body
# Status line. We pass the env vars through; sprint-state.sh reads its own
# layout from PROJECT_PATH / IMPLEMENTATION_ARTIFACTS / SPRINT_STATUS_YAML.
#
# We bypass sprint-state.sh's adjacency table because our own state-machine
# is a superset and we have already validated the edge. Doing two checks would
# reject perfectly-legal recovery transitions like `validating -> backlog`.
#
# Strategy: skip sprint-state.sh when (a) it is not present, or (b) its
# adjacency table would reject our edge — in both cases write the yaml entry
# directly using a small awk pass that mirrors sprint-state.sh's writer.
update_sprint_status_yaml() {
  local key="$1" new_status="$2"

  # Route sprint-status.yaml resolution through the shared resolver so the
  # canonical .gaia/state/ home is rung 1 and the legacy
  # .gaia/artifacts/implementation-artifacts/ home is a read-compat fallback.
  # The previous default (${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml)
  # never matched what sprint-state.sh writes on a fresh project — every
  # transition WARNED "sprint-status.yaml is missing" and the yaml surface was
  # silently NOT updated, requiring a manual `sprint-state.sh reconcile` to fix.
  local yaml="${SPRINT_STATUS_YAML:-}"
  if [ -z "$yaml" ]; then
    local _resolver="$LIB_DIR/resolve-artifact-path.sh"
    if [ -x "$_resolver" ]; then
      yaml="$("$_resolver" sprint_status --project-root "${PROJECT_PATH:-.}" --existing-only 2>/dev/null || true)"
      # No existing rung — fall back to the canonical default (the resolver's
      # rung-1 path) so the not-found / backlog-skip diagnostics below name the
      # canonical location, not a legacy one.
      [ -z "$yaml" ] && yaml="$("$_resolver" sprint_status --project-root "${PROJECT_PATH:-.}" 2>/dev/null)"
    fi
    # Last-resort defaults if the resolver is unavailable.
    [ -z "$yaml" ] && yaml="${PROJECT_PATH:-.}/.gaia/state/sprint-status.yaml"
    if [ ! -e "$yaml" ] && [ -e "${PROJECT_PATH}/sprint-status.yaml" ]; then
      yaml="${PROJECT_PATH}/sprint-status.yaml"
    fi
  fi

  if [ ! -s "$yaml" ]; then
    # The four-surface atomic transition degrades to three surfaces when
    # sprint-status.yaml is absent. That is LEGITIMATE for a
    # backlog story (sprint_id: null) in a fresh/no-sprint project — stay quiet.
    # But if the story HAS a sprint_id set, the missing yaml is real drift: the
    # story believes it belongs to a sprint whose status file is gone. Surface
    # that as a WARNING (stderr) rather than a silent skip, mirroring the
    # backlog-vs-drift discrimination already applied to the no-entry path below.
    local _sid=""
    if [ -n "${STORY_FILE:-}" ] && [ -f "${STORY_FILE:-}" ]; then
      _sid="$(read_frontmatter_field "$STORY_FILE" sprint_id)"
    fi
    case "$_sid" in
      ""|null|"~")
        log "sprint-status.yaml not found at '$yaml' — skipping yaml update (story is backlog: sprint_id unset)"
        ;;
      *)
        err "WARNING: story '$key' has sprint_id '$_sid' but sprint-status.yaml is missing at '$yaml' — yaml surface NOT updated (3 of 4 surfaces written); run /gaia-sprint-status to reconcile"
        ;;
    esac
    return 0
  fi

  # Direct in-place rewrite (the outer flock already serialises us against
  # other transition-story-status.sh invocations; sprint-state.sh's own lock
  # would only matter for non-transition writers).
  local tmp
  tmp=$(mktemp "${yaml}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v target="$key" -v new_status="$new_status" '
    BEGIN { in_entry = 0; rewrote = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      in_entry = (k == target) ? 1 : 0
      print raw
      next
    }
    in_entry && line ~ /^[^[:space:]]/ { in_entry = 0 }
    in_entry && !rewrote && line ~ /^[[:space:]]+status:[[:space:]]*/ {
      match(raw, /^[[:space:]]+/)
      indent = substr(raw, RSTART, RLENGTH)
      crlf = ""
      if (raw ~ /\r$/) crlf = "\r"
      printf "%sstatus: \"%s\"%s\n", indent, new_status, crlf
      rewrote = 1
      next
    }
    { print raw }
    END {
      if (!rewrote) exit 2
    }
  ' "$yaml" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    if [ $rc -eq 2 ]; then
      # Suppress the skip log when the story is legitimately in the backlog
      # (sprint_id: null in story frontmatter). Real drift (sprint_id SET but
      # no entry in sprint-status.yaml) still warns as before.
      local _sprint_id=""
      if [ -n "${STORY_FILE:-}" ] && [ -f "${STORY_FILE:-}" ]; then
        _sprint_id="$(read_frontmatter_field "$STORY_FILE" sprint_id)"
      fi
      case "$_sprint_id" in
        ""|null|"~") : ;;
        *) log "story '$key' not present in sprint-status.yaml — skipping yaml update" ;;
      esac
      return 0
    fi
    err "awk rewrite of '$yaml' failed (rc=$rc)"
    exit 1
  }

  if ! mv -f "$tmp" "$yaml"; then
    rm -f "$tmp"
    trap - RETURN
    err "failed to mv tempfile over '$yaml'"
    exit 1
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Update or insert the `- **Status:** <state>` line inside the story's block in
# epics-and-stories.md. The block starts at `### Story <key>:` and ends at the
# next `### Story` or top-level `## ` heading. Bytes outside the block are
# preserved verbatim.
update_epics_and_stories() {
  local key="$1" new_status="$2"
  local file="$EPICS_AND_STORIES"

  if [ ! -s "$file" ]; then
    err "epics-and-stories.md not found at '$file'"
    exit 5
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v target="$key" -v new_status="$new_status" '
    function emit_status_line() {
      printf "- **Status:** %s\n", new_status
      inserted = 1
    }
    BEGIN {
      in_block = 0
      saw_status = 0
      inserted = 0
      block_seen = 0
    }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    # Detect block boundaries.
    line ~ /^### Story / {
      # Closing previous block? If we were in target block and never saw a Status line, insert one.
      if (in_block && !saw_status) {
        emit_status_line()
      }
      # Open new block?
      if (index(line, "Story " target ":") > 0) {
        in_block = 1
        saw_status = 0
        block_seen = 1
      } else {
        in_block = 0
      }
      print raw
      next
    }
    # Top-level heading also closes the block.
    in_block && line ~ /^## / && line !~ /^### / {
      if (!saw_status) emit_status_line()
      in_block = 0
      print raw
      next
    }
    # Inside target block — replace existing **Status:** line.
    in_block && line ~ /^- \*\*Status:\*\*/ {
      crlf = ""
      if (raw ~ /\r$/) crlf = "\r"
      printf "- **Status:** %s%s\n", new_status, crlf
      saw_status = 1
      next
    }
    { print raw }
    END {
      # Block ran to EOF without explicit close — flush a Status line if needed.
      if (in_block && !saw_status) {
        emit_status_line()
      }
      if (!block_seen) {
        # Story not found in epics-and-stories.md — soft-warn via exit 3 so the
        # caller can decide. We treat absence as non-fatal but visible.
        exit 3
      }
    }
  ' "$file" > "$tmp" && local rc=0 || local rc=$?
  # Explicit `&&/||` capture defangs `set -e` so the soft-warn rc=3
  # path (story-not-found, block_seen=0) inside the awk END action is
  # reachable. Without this guard, awk's exit 3 cascades into the EXIT trap
  # and triggers rollback (rc=8) — making transitions on stories absent from
  # the epics index impossible, even though the helper documents that case
  # as soft-warn. `local` returns 0 unconditionally, so the `||` arm only
  # fires when awk itself failed.
  if [ $rc -ne 0 ]; then
    if [ $rc -eq 3 ]; then
      # Story not present in epics-and-stories.md — leave the file untouched.
      rm -f "$tmp"
      trap - RETURN
      log "story '$key' not present in epics-and-stories.md — skipping (no insert)"
      return 0
    fi
    rm -f "$tmp"
    trap - RETURN
    err "awk rewrite of '$file' failed (rc=$rc)"
    exit 1
  fi

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    err "failed to mv tempfile over '$file'"
    exit 1
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Glob the matching per-epic shard for a story key.
#
# Stdout: nothing on miss, 'OK\t<path>' on a unique match, 'MULTI\t<path1>;<path2>;...'
# on a multi-match. The single-source-of-truth helper for both the writer
# (update_per_epic_shard) and the read-only snapshot resolver
# (resolve_shard_path_for_key). Keeps the resolver math in one place.
_glob_shard_for_key() {
  local key="$1"
  local eid
  if [[ "$key" =~ ^E([0-9]+)-S[0-9]+$ ]]; then
    eid="${BASH_REMATCH[1]}"
  else
    return 0
  fi
  local shard_dir="${PLANNING_ARTIFACTS}/epics"
  if [ ! -d "$shard_dir" ]; then
    return 0
  fi
  shopt -s nullglob nocaseglob
  # shellcheck disable=SC2206
  local matches=( "$shard_dir"/*-e${eid}-*.md )
  shopt -u nocaseglob nullglob
  if [ "${#matches[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "${#matches[@]}" -eq 1 ]; then
    printf 'OK\t%s\n' "${matches[0]}"
    return 0
  fi
  local joined
  joined="$(printf '%s;' "${matches[@]}")"
  joined="${joined%;}"
  printf 'MULTI\t%s\n' "$joined"
}

# Mirror the per-story `- **Status:** <state>` line into the
# matching per-epic shard at `${PLANNING_ARTIFACTS}/epics/*-e<EID>-*.md`.
#
# Resolver:
#   1. Extract <EID> from STORY_KEY (regex `^E([0-9]+)-S[0-9]+$` → group 1).
#   2. Glob `${PLANNING_ARTIFACTS}/epics/*-e<EID>-*.md` (case-insensitive on
#      the `e<EID>` token).
#   3. Count matches:
#        0 → INFO line, exit 0 (monolith-only write succeeded — the shard is
#                                an optional artifact generated lazily by
#                                `/gaia-shard-doc`).
#        1 → proceed to the awk-based per-story status rewrite.
#        ≥ 2 → canonical error + rollback (a multi-match means two shards
#              both claim the same epic, which is a structural break in the
#              per-epic-shard contract; failing loud is the right behaviour).
#
# Inside the matching shard:
#   - If the shard does NOT contain a `### Story <STORY_KEY>:` block, emit
#     the same INFO line and exit 0 (graceful skip). Missing stories in a
#     shard are not divergence — they may pre-date the shard generation.
#   - Otherwise, rewrite the `- **Status:** <old>` line under the
#     `### Story <STORY_KEY>:` block to `- **Status:** <NEW_STATUS>`,
#     preserving every other byte. The block boundary is the next
#     `### Story` header or top-level `## ` heading.
update_per_epic_shard() {
  local key="$1" new_status="$2"
  local glob_out kind shard
  glob_out="$(_glob_shard_for_key "$key")"
  # Suppress the "no per-epic shard entry" log when the story is legitimately
  # in the backlog (sprint_id: null). For non-backlog stories the absence of
  # a shard is real drift and still warns.
  local _sprint_id=""
  if [ -n "${STORY_FILE:-}" ] && [ -f "${STORY_FILE:-}" ]; then
    _sprint_id="$(read_frontmatter_field "$STORY_FILE" sprint_id)"
  fi
  _is_backlog=0
  case "$_sprint_id" in
    ""|null|"~") _is_backlog=1 ;;
  esac

  if [ -z "$glob_out" ]; then
    [ "$_is_backlog" -eq 1 ] || log "info: ${key} has no optional per-epic shard under planning-artifacts/epics/ — status written to monolith + story-index only (not an error; the per-epic shard is an opt-in mirror)"
    return 0
  fi
  kind="${glob_out%%$'\t'*}"
  shard="${glob_out#*$'\t'}"
  if [ "$kind" = "MULTI" ]; then
    err "multiple shards match e<EID> for ${key} — refusing to write ambiguously: ${shard//;/ }"
    exit 1
  fi
  # Confirm the shard contains the `### Story <KEY>:` block.
  if ! grep -qE "^### Story ${key}:" "$shard"; then
    [ "$_is_backlog" -eq 1 ] || log "info: ${key} has no optional per-epic shard under planning-artifacts/epics/ — status written to monolith + story-index only (not an error; the per-epic shard is an opt-in mirror)"
    return 0
  fi

  # Rewrite the per-story Status line.
  local tmp
  tmp=$(mktemp "${shard}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v target="$key" -v new_status="$new_status" '
    BEGIN { in_block = 0; saw_status = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^### Story / {
      # Closing previous block: if we were inside the target block and never
      # saw a Status line, do nothing (the AC says rewrite when present;
      # missing Status lines fall under the no-block-found graceful path
      # already filtered by grep -qE above).
      if (index(line, "Story " target ":") > 0) {
        in_block = 1
        saw_status = 0
      } else {
        in_block = 0
      }
      print raw
      next
    }
    in_block && line ~ /^## / && line !~ /^### / {
      in_block = 0
      print raw
      next
    }
    in_block && line ~ /^- \*\*Status:\*\*/ {
      crlf = ""
      if (raw ~ /\r$/) crlf = "\r"
      printf "- **Status:** %s%s\n", new_status, crlf
      saw_status = 1
      next
    }
    { print raw }
  ' "$shard" > "$tmp" || {
    rm -f "$tmp"
    trap - RETURN
    err "awk rewrite of '$shard' failed"
    exit 1
  }

  if ! mv -f "$tmp" "$shard"; then
    rm -f "$tmp"
    trap - RETURN
    err "failed to mv tempfile over '$shard'"
    exit 1
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Resolve the matching per-epic shard path for a given story key.
# Read-only delegate to _glob_shard_for_key — used by the snapshot path so
# rollback can restore the shard if the writer touched it.
#
# Stdout: the absolute shard path on a unique match that also contains the
# `### Story <KEY>:` block; empty on zero-match, multi-match, or no-block
# (the writer handles those cases — the snapshot path only has work when
# there is exactly one shard with the relevant story block to back up).

resolve_shard_path_for_key() {
  local key="$1"
  local glob_out kind shard
  glob_out="$(_glob_shard_for_key "$key")"
  [ -z "$glob_out" ] && return 0
  kind="${glob_out%%$'\t'*}"
  shard="${glob_out#*$'\t'}"
  [ "$kind" = "OK" ] || return 0
  if grep -qE "^### Story ${key}:" "$shard"; then
    printf '%s' "$shard"
  fi
}

# Update or insert the story's metadata-rich entry in story-index.yaml.
#
# The entry block is the canonical 8-line form, in
# this order on every write (idempotency relies on stable ordering):
#
#   <key>:
#     story_key: "<story_key>"
#     title: "<title>"
#     epic: "<epic>"
#     priority: "<priority>"
#     risk: "<risk>"
#     author: "<author>"
#     file: "<file>"
#     status: "<status>"
#
# Empty/missing optional fields render as "" (empty quoted string) for diff
# stability and to avoid YAML coercion surprises (`null`, `true`, etc.).
#
# The rewrite branch replaces the entire existing entry block (every child
# indented line under the key) with the canonical 8-line form. This
# uniformly handles "fields previously absent", "fields with different
# values", and "stale fields no longer in the canonical schema".
update_story_index_yaml() {
  local key="$1" new_status="$2"
  local title="$3" epic="$4" priority="$5" risk="$6" author="$7" file_path="$8"
  local file="$STORY_INDEX_YAML"

  # issue-1403: pre-escape free-text fields (title, epic, author) into complete
  # single-quoted YAML scalars so an embedded " or ' cannot corrupt the file.
  local title_yaml epic_yaml author_yaml
  title_yaml="$(yaml_single_quote "$title")"
  epic_yaml="$(yaml_single_quote "$epic")"
  author_yaml="$(yaml_single_quote "$author")"

  if [ ! -e "$file" ]; then
    mkdir -p "$(dirname "$file")"
    {
      printf '# Auto-maintained by transition-story-status.sh.\n'
      printf 'last_updated: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'stories:\n'
      printf '  %s:\n' "$key"
      printf '    story_key: "%s"\n' "$key"
      printf '    title: %s\n' "$title_yaml"
      printf '    epic: %s\n' "$epic_yaml"
      printf '    priority: "%s"\n' "$priority"
      printf '    risk: "%s"\n' "$risk"
      printf '    author: %s\n' "$author_yaml"
      printf '    file: "%s"\n' "$file_path"
      printf '    status: "%s"\n' "$new_status"
    } > "$file"
    # Mirror to legacy flat (when present) on the create path too — otherwise
    # the very first transition would silently leave the legacy reader stale.
    legacy_flat_index_mirror_update "$key" "$new_status" \
      "$title_yaml" "$epic_yaml" "$priority" "$risk" "$author_yaml" "$file_path" || \
      log "WARNING: legacy-flat-index mirror update failed for key=$key (non-fatal)"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  # awk rewrite-or-append:
  #   - When in the target entry, suppress every child line (anything indented
  #     >= 4 spaces or blank) and emit the canonical 8-line block exactly once
  #     in place of the original header.
  #   - When the entry is not found, append the full block at EOF under
  #     `stories:`.
  # title/epic/author arrive PRE-ESCAPED as complete single-quoted YAML
  # scalars (issue-1403) — emit them verbatim (no surrounding quotes added).
  awk -v target="$key" \
      -v new_status="$new_status" \
      -v title="$title_yaml" \
      -v epic="$epic_yaml" \
      -v priority="$priority" \
      -v risk="$risk" \
      -v author="$author_yaml" \
      -v file_path="$file_path" '
    function emit_block(k, t, e, p, r, a, f, s) {
      printf "  %s:\n", k
      printf "    story_key: \"%s\"\n", k
      printf "    title: %s\n", t
      printf "    epic: %s\n", e
      printf "    priority: \"%s\"\n", p
      printf "    risk: \"%s\"\n", r
      printf "    author: %s\n", a
      printf "    file: \"%s\"\n", f
      printf "    status: \"%s\"\n", s
    }
    BEGIN { in_entry = 0; in_stories = 0; found = 0; emitted = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^stories:[[:space:]]*$/ { in_stories = 1; print raw; next }
    in_stories && line ~ /^[A-Za-z]/ {
      # Closing the stories: mapping. If we were inside the target entry,
      # nothing to flush — emit_block already ran on the matched header.
      in_stories = 0
      in_entry = 0
    }
    # Entry header: two-space indent, key name, colon.
    in_stories && line ~ /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      k = line
      sub(/^  /, "", k)
      sub(/:[[:space:]]*$/, "", k)
      if (k == target) {
        # Emit the canonical block in place of the original header; skip every
        # subsequent child line until the next header / non-entry line.
        in_entry = 1
        found = 1
        if (!emitted) {
          emit_block(target, title, epic, priority, risk, author, file_path, new_status)
          emitted = 1
        }
        next
      } else {
        in_entry = 0
        print raw
        next
      }
    }
    # Inside the matched entry — swallow every child line (4-space-or-deeper
    # indent OR blank line). A header (2-space indent) is handled above and
    # will end this entry naturally.
    in_entry {
      if (line ~ /^    / || line ~ /^[[:space:]]*$/) { next }
      # Defensive — any non-indented line inside stories: closes the entry.
      in_entry = 0
    }
    { print raw }
    END {
      # If entry not found anywhere, append a brand-new metadata-rich block.
      if (!found) {
        emit_block(target, title, epic, priority, risk, author, file_path, new_status)
      }
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    trap - RETURN
    err "awk rewrite of '$file' failed"
    exit 1
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    err "failed to mv tempfile over '$file'"
    exit 1
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN

  # Mirror the same update into the legacy flat
  # `${IMPLEMENTATION_ARTIFACTS}/story-index.yaml` when present, so the
  # documented `state/`-tier reader does not diverge from the canonical
  # per-epic index during the migration window. The legacy file is
  # *opt-in by presence*: if it does not exist we don't create it, and once
  # an operator deletes it the dual-write becomes a silent no-op (matches
  # `legacy_flat_index_lookup`'s "steady state — return 2" contract). Errors
  # during the mirror write are logged at WARNING level but do NOT fail the
  # canonical transition.
  legacy_flat_index_mirror_update "$key" "$new_status" \
    "$title_yaml" "$epic_yaml" "$priority" "$risk" "$author_yaml" "$file_path" || \
    log "WARNING: legacy-flat-index mirror update failed for key=$key (non-fatal)"
}

# legacy_flat_index_mirror_update — mirror an entry write into the legacy flat
# `${IMPLEMENTATION_ARTIFACTS}/story-index.yaml` ONLY if the flat file already
# exists. Does NOT create the flat file on absence (intentional: lets the
# legacy file age out naturally as projects complete the per-epic migration).
#
# Arguments mirror update_story_index_yaml — same canonical entry shape so
# both files stay byte-identical at the entry level.
#
# Return: 0 always (errors are mapped to log WARNING in the caller).
legacy_flat_index_mirror_update() {
  local key="$1" new_status="$2"
  local title_yaml="$3" epic_yaml="$4" priority="$5" risk="$6" author_yaml="$7" file_path="$8"
  local flat="${LEGACY_FLAT_STORY_INDEX:-${IMPLEMENTATION_ARTIFACTS}/story-index.yaml}"

  # Opt-in by presence: skip silently when the legacy flat file is absent.
  [ -f "$flat" ] || return 0

  # Idempotent skip when the canonical and legacy paths are the same file
  # (the flat path resolver collapses to the canonical path in legacy-layout
  # projects that never migrated). Without this guard we'd rewrite the file
  # twice in the same call.
  if [ -e "$STORY_INDEX_YAML" ] && [ "$flat" -ef "$STORY_INDEX_YAML" ]; then
    return 0
  fi

  local tmp
  tmp=$(mktemp "${flat}.tmp.XXXXXX") || return 0
  _GAIA_TMP_PATHS+=("$tmp")
  local _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  # Reuse the same awk rewrite-or-append shape as the canonical writer so the
  # entry blocks stay byte-identical.
  awk -v target="$key" \
      -v new_status="$new_status" \
      -v title="$title_yaml" \
      -v epic="$epic_yaml" \
      -v priority="$priority" \
      -v risk="$risk" \
      -v author="$author_yaml" \
      -v file_path="$file_path" '
    function emit_block(k, t, e, p, r, a, f, s) {
      printf "  %s:\n", k
      printf "    story_key: \"%s\"\n", k
      printf "    title: %s\n", t
      printf "    epic: %s\n", e
      printf "    priority: \"%s\"\n", p
      printf "    risk: \"%s\"\n", r
      printf "    author: %s\n", a
      printf "    file: \"%s\"\n", f
      printf "    status: \"%s\"\n", s
    }
    BEGIN { in_entry = 0; in_stories = 0; found = 0; emitted = 0 }
    { raw = $0; line = $0; sub(/\r$/, "", line) }
    line ~ /^stories:[[:space:]]*$/ { in_stories = 1; print raw; next }
    in_stories && line ~ /^[A-Za-z]/ { in_stories = 0; in_entry = 0 }
    in_stories && line ~ /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      k = line; sub(/^  /, "", k); sub(/:[[:space:]]*$/, "", k)
      if (k == target) {
        in_entry = 1; found = 1
        if (!emitted) {
          emit_block(target, title, epic, priority, risk, author, file_path, new_status)
          emitted = 1
        }
        next
      } else { in_entry = 0; print raw; next }
    }
    in_entry {
      if (line ~ /^    / || line ~ /^[[:space:]]*$/) { next }
      in_entry = 0
    }
    { print raw }
    END {
      if (!found) {
        emit_block(target, title, epic, priority, risk, author, file_path, new_status)
      }
    }
  ' "$flat" > "$tmp" || {
    rm -f "$tmp"
    trap - RETURN
    return 1
  }

  if ! mv -f "$tmp" "$flat"; then
    rm -f "$tmp"
    trap - RETURN
    return 1
  fi
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
  return 0
}

# ---------- Main flow ----------

# Resolve the story file (exit 2/3 on missing/multiple).
STORY_FILE="$(locate_story_file "$STORY_KEY")"

# Metadata resolution: explicit flag > frontmatter value > "" empty.
# Only read the frontmatter when at least one field is unset (small perf win;
# also avoids redundant disk reads when the caller supplies all six flags).
resolve_meta() {
  local var_value="$1" field="$2"
  if [ "$var_value" = "$TSS_UNSET" ]; then
    read_frontmatter_field "$STORY_FILE" "$field"
  else
    printf '%s' "$var_value"
  fi
}

META_TITLE="$(resolve_meta "$META_TITLE" title)"
META_EPIC="$(resolve_meta "$META_EPIC" epic)"
# issue-1405: the `epic:` frontmatter is widely written as the FULL epic TITLE
# (e.g. `E<n> — <Epic Title>`) rather than the bare key. resolve_epic_slug
# needs the bare `E<digits>` key (it does `epic_num="${epic_key#E}"` and greps
# `^## Epic <num>:`), so derive it here: prefer an explicit `epic_key:`
# frontmatter field, else take the leading `E<digits>` token of `epic:`. The
# full META_EPIC value is still used as the displayed `epic:` metadata in the
# index entry; only the slug-resolution key is normalized.
EPIC_KEY_FOR_SLUG="$(read_frontmatter_field "$STORY_FILE" epic_key 2>/dev/null || true)"
if [ -z "$EPIC_KEY_FOR_SLUG" ] || [ "$EPIC_KEY_FOR_SLUG" = "$TSS_UNSET" ]; then
  # Take the leading E<digits> token from META_EPIC (handles the bare-key form,
  # the `E<n> — Title` em-dash form, and the `E<n>: Title` colon form). Falls
  # back to META_EPIC verbatim when it does not start with the E<digits> shape
  # (lets a non-standard key still reach the resolver, preserving the prior
  # error path for genuinely bad input).
  case "$META_EPIC" in
    E[0-9]*) EPIC_KEY_FOR_SLUG="$(printf '%s' "$META_EPIC" | sed -E 's/^(E[0-9]+).*/\1/')" ;;
    *)       EPIC_KEY_FOR_SLUG="$META_EPIC" ;;
  esac
fi
META_PRIORITY="$(resolve_meta "$META_PRIORITY" priority)"
META_RISK="$(resolve_meta "$META_RISK" risk)"
META_AUTHOR="$(resolve_meta "$META_AUTHOR" author)"
# The `file:` pointer is RELATIVE to the per-epic `stories/` directory
# (bare basename), not the absolute or project-root-relative path. Caller
# may still override with --file for forensic / migration tooling.
if [ "$META_FILE" = "$TSS_UNSET" ]; then
  META_FILE="$(compute_story_index_file_pointer "$STORY_FILE")"
fi

# Resolve the per-epic story-index.yaml path. Uses the
# `epic:` frontmatter field (or the --epic flag override). The env
# override STORY_INDEX_YAML wins unconditionally for tests / brownfield.
STORY_INDEX_YAML="$(resolve_story_index_path "$STORY_FILE" "$EPIC_KEY_FOR_SLUG")"

# Acquire the cross-file lock.
mkdir -p "$(dirname "$STORY_STATUS_LOCK")"
exec 200>"$STORY_STATUS_LOCK"
if command -v flock >/dev/null 2>&1; then
  if ! flock -w 5 200; then
    err "lock contention on '$STORY_STATUS_LOCK' (5s timeout) — retry shortly"
    exit 6
  fi
fi

CURRENT_STATUS="$(read_frontmatter_status "$STORY_FILE")"

# `--reconcile-only` mode: replay every writer at the current frontmatter
# status without short-circuiting on the self-transition no-op.
# The flag's only effect is to skip the no-op exit below; the writer chain
# runs unchanged so a drifted shard can be brought back into alignment with
# the story-file source of truth. State-machine validation is skipped (a
# self-transition is not a state-machine edge).
if [ "$RECONCILE_ONLY" = "1" ]; then
  if [ -z "$NEW_STATUS" ]; then
    NEW_STATUS="$CURRENT_STATUS"
  fi
  log "reconcile-only mode — replaying current status to all writers"
fi

# --from check.
if [ -n "$EXPECTED_FROM" ] && [ "$CURRENT_STATUS" != "$EXPECTED_FROM" ]; then
  err "expected current status '$EXPECTED_FROM' but found '$CURRENT_STATUS'"
  exit 1
fi

# Idempotent self-transition. `--reconcile-only` deliberately bypasses this
# short-circuit so the shard writer fires.
if [ "$CURRENT_STATUS" = "$NEW_STATUS" ] && [ "$RECONCILE_ONLY" != "1" ]; then
  log "no-op (story already at $NEW_STATUS)"
  exit 0
fi

# State-machine validation. Reconcile-only is a no-edge replay.
if [ "$RECONCILE_ONLY" != "1" ] && ! validate_story_transition "$CURRENT_STATUS" "$NEW_STATUS"; then
  exit 7
fi

# Composite review-gate enforcement on review → done.
# Prior to this guard the raw `transition-story-status.sh --to done` succeeded
# even when all 6 Review Gate rows were UNVERIFIED, because the composite-gate
# check lived only inside `/gaia-dev-story` Step 16 + `/gaia-check-review-gate`.
# Folding the gate directly into the transition primitive closes the bypass:
# any caller (including direct CLI invocation, ad-hoc scripts, or a buggy
# skill) reaching for review → done is now refused unless the composite is
# COMPLETE. The escape hatch `GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=1`
# (operator-set, audit-trail discoverable) preserves the documented
# `/gaia-correct-course` composite-verdict escape path for genuine edge cases
# (third-party block, infra outage) so the guard doesn't strand recovery.
if [ "$RECONCILE_ONLY" != "1" ] \
   && [ "$CURRENT_STATUS" = "review" ] \
   && [ "$NEW_STATUS" = "done" ] \
   && [ "${GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE:-0}" != "1" ]; then
  _review_gate_script="$(cd "$(dirname "$0")" && pwd)/review-gate.sh"
  if [ -x "$_review_gate_script" ]; then
    _composite_rc=0
    bash "$_review_gate_script" review-gate-check --story "$STORY_KEY" >/dev/null 2>&1 || _composite_rc=$?
    if [ "$_composite_rc" -ne 0 ]; then
      log "ERROR: review → done refused — composite Review Gate is not COMPLETE (exit $_composite_rc from review-gate.sh review-gate-check)."
      log "       Run /gaia-check-review-gate for the per-gate breakdown, OR set"
      log "       GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=1 only when escorting a"
      log "       documented /gaia-correct-course composite-verdict escape hatch."
      exit 8
    fi
  fi
fi

# Snapshot every file we may touch so we can roll back on partial failure.
SNAP_STORY="$(snapshot_for_rollback "$STORY_FILE")"
SNAP_YAML=""
SNAP_EPICS="$(snapshot_for_rollback "$EPICS_AND_STORIES")"
SNAP_INDEX="$(snapshot_for_rollback "$STORY_INDEX_YAML")"

# Resolve and snapshot the per-epic shard if a unique match exists.
# Rollback restores the shard symmetrically with the four existing snapshots.
SHARD_PATH=""
SNAP_SHARD=""
SHARD_PATH="$(resolve_shard_path_for_key "$STORY_KEY")"
if [ -n "$SHARD_PATH" ] && [ -e "$SHARD_PATH" ]; then
  SNAP_SHARD="$(snapshot_for_rollback "$SHARD_PATH")"
fi

# Route the rollback-snapshot yaml resolution through the same shared resolver
# as update_sprint_status_yaml() so the snapshot and the writer can't disagree
# on canonical location.
YAML_PATH_FOR_SNAP="${SPRINT_STATUS_YAML:-}"
if [ -z "$YAML_PATH_FOR_SNAP" ]; then
  _resolver_snap="$LIB_DIR/resolve-artifact-path.sh"
  if [ -x "$_resolver_snap" ]; then
    YAML_PATH_FOR_SNAP="$("$_resolver_snap" sprint_status --project-root "${PROJECT_PATH:-.}" --existing-only 2>/dev/null || true)"
    [ -z "$YAML_PATH_FOR_SNAP" ] && YAML_PATH_FOR_SNAP="$("$_resolver_snap" sprint_status --project-root "${PROJECT_PATH:-.}" 2>/dev/null)"
  fi
  [ -z "$YAML_PATH_FOR_SNAP" ] && YAML_PATH_FOR_SNAP="${PROJECT_PATH:-.}/.gaia/state/sprint-status.yaml"
fi
if [ -e "$YAML_PATH_FOR_SNAP" ]; then
  SNAP_YAML="$(snapshot_for_rollback "$YAML_PATH_FOR_SNAP")"
fi

rollback() {
  log "rolling back partial transition for $STORY_KEY"
  restore_snapshot "$STORY_FILE" "$SNAP_STORY" 2>/dev/null || true
  if [ -n "$SNAP_YAML" ]; then
    restore_snapshot "$YAML_PATH_FOR_SNAP" "$SNAP_YAML" 2>/dev/null || true
  fi
  restore_snapshot "$EPICS_AND_STORIES" "$SNAP_EPICS" 2>/dev/null || true
  if [ -n "$SHARD_PATH" ] && [ -n "$SNAP_SHARD" ]; then
    restore_snapshot "$SHARD_PATH" "$SNAP_SHARD" 2>/dev/null || true
  fi
  restore_snapshot "$STORY_INDEX_YAML" "$SNAP_INDEX" 2>/dev/null || true
}

# Custom failure handler: roll back, then exit 8.
# Chain through _cleanup_tmps so any orphan tmp registered during
# rewrite_*/update_* helpers (between mktemp and a failed mv) is removed.
TSS_ROLLBACK_PENDING=1
trap '
  rc=$?
  if [ "${TSS_ROLLBACK_PENDING:-0}" = "1" ] && [ $rc -ne 0 ]; then
    rollback
    _cleanup_tmps
    exit 8
  fi
  _cleanup_tmps
' EXIT

# Each step below MUST be wrapped so a failure triggers rollback. We rely on
# `set -e` + the EXIT trap to short-circuit; no bare `exit 1` paths in the
# helpers escape rollback because the EXIT trap fires regardless.

rewrite_frontmatter "$STORY_FILE" "$NEW_STATUS"
update_sprint_status_yaml "$STORY_KEY" "$NEW_STATUS"
update_epics_and_stories "$STORY_KEY" "$NEW_STATUS"
# Fifth writer: per-epic shard. Sits between the monolith writer
# (update_epics_and_stories) and the story-index.yaml writer
# (update_story_index_yaml).
update_per_epic_shard "$STORY_KEY" "$NEW_STATUS"
update_story_index_yaml "$STORY_KEY" "$NEW_STATUS" \
  "$META_TITLE" "$META_EPIC" "$META_PRIORITY" "$META_RISK" "$META_AUTHOR" "$META_FILE"

# All five files written successfully — commit.
TSS_ROLLBACK_PENDING=0
# Restore the plain _cleanup_tmps EXIT trap so any later failure
# (e.g., during marker write) still cleans orphan tmps. Slots cleared above
# make this a no-op on the happy path.
trap '_cleanup_tmps' EXIT

cleanup_snapshots "$SNAP_STORY" "$SNAP_YAML" "$SNAP_EPICS" "$SNAP_SHARD" "$SNAP_INDEX"

# Write status-transition marker.
# The marker lets the pre-commit `check-status-discipline.sh` distinguish
# legitimate transitions from manual `status:` edits. Marker is consumed by
# the discipline check during the same commit cycle. Best-effort — never
# fails the transition if the .git directory is unavailable (e.g., CI tasks
# running outside a checkout). Marker freshness window is enforced by the
# consumer (default 300s).
write_status_transition_marker() {
  local marker_dir marker_path
  if [ -n "${STATUS_TRANSITION_MARKER:-}" ]; then
    marker_path="$STATUS_TRANSITION_MARKER"
    marker_dir="$(dirname "$marker_path")"
  else
    local git_root
    if git_root=$(git -C "${PROJECT_PATH:-$PWD}" rev-parse --show-toplevel 2>/dev/null); then
      marker_dir="$git_root/.git"
    elif [ -d "${PROJECT_PATH:-$PWD}/.git" ]; then
      marker_dir="${PROJECT_PATH:-$PWD}/.git"
    else
      return 0  # outside a checkout — silent best-effort
    fi
    marker_path="$marker_dir/gaia-status-transition.marker"
  fi
  mkdir -p "$marker_dir" 2>/dev/null || return 0
  {
    printf 'story_key=%s\n' "$STORY_KEY"
    printf 'timestamp=%s\n' "$(date -u +%s)"
    printf 'from=%s\n' "$CURRENT_STATUS"
    printf 'to=%s\n' "$NEW_STATUS"
  } > "$marker_path" 2>/dev/null || return 0
}
write_status_transition_marker

log "$STORY_KEY transitioned $CURRENT_STATUS -> $NEW_STATUS"
exit 0
