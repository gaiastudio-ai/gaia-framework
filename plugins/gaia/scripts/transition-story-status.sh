#!/usr/bin/env bash
# transition-story-status.sh — E54-S3 unified atomic story-status transitions.
#
# Atomically updates ALL FOUR locations a story status lives in, under flock,
# with rollback on partial failure:
#
#   1. Story file frontmatter (`status:` field) + body `**Status:**` line
#   2. sprint-status.yaml entry (delegated to sprint-state.sh)
#   3. epics-and-stories.md per-story `- **Status:** <state>` line
#   4. story-index.yaml entry (created if absent)
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
#   IMPLEMENTATION_ARTIFACTS  — defaults to ${PROJECT_PATH}/docs/implementation-artifacts
#   PLANNING_ARTIFACTS        — defaults to ${PROJECT_PATH}/docs/planning-artifacts
#   MEMORY_PATH               — defaults to ${PROJECT_PATH}/_memory
#   SPRINT_STATUS_YAML        — overrides default yaml path (forwarded to sprint-state.sh)
#   EPICS_AND_STORIES         — overrides default planning artifact path
#   STORY_INDEX_YAML          — overrides default index path
#   STORY_STATUS_LOCK         — overrides default lock path
#
# story-index.yaml metadata enrichment (E63-S10 / Work Item 6.9):
#   The script writes a 7-field metadata-rich entry to story-index.yaml plus
#   the existing `status:` field, in this canonical order on every write:
#     story_key, title, epic, priority, risk, author, file, status
#   Source precedence per field: explicit CLI flag > frontmatter value > "" empty.
#   Empty/missing optional fields render as "" (an empty quoted string) to keep
#   YAML quoting uniform — never `null`. Idempotency is byte-stable: re-running
#   with identical inputs yields a byte-identical entry block.
#
#   Consumer:        plugins/gaia/skills/gaia-create-story/SKILL.md (E63-S11)
#   Source spec:     docs/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.9
#   Contract source: ADR-074 contract C3 — sole-writer discipline for story-index.yaml
#
# Refs: AF-2026-04-28-3, AF-2026-04-28-7, FR-338, NFR-056, ADR-042, ADR-074.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="transition-story-status.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
STATE_MACHINE_LIB="$LIB_DIR/story-state-machine.sh"

# shellcheck source=lib/story-state-machine.sh
. "$STATE_MACHINE_LIB"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# E64-S5 — script-level EXIT/INT/TERM trap for atomic-write tmp cleanup.
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
  transition-story-status.sh --help

Atomically updates the story-file frontmatter, sprint-status.yaml,
epics-and-stories.md, and story-index.yaml under flock, rolling back on any
partial failure.

States: backlog | validating | ready-for-dev | in-progress | blocked | review | done

Optional metadata flags (E63-S10 / Work Item 6.9):
  --title --epic --priority --risk --author --file
    Override the corresponding field written to story-index.yaml. Each flag
    is optional; when omitted, the value falls back to the matching story
    frontmatter field (`title`, `epic`, `priority`, `risk`, `author`). The
    `--file` flag defaults to the resolved story file path when omitted.
    Precedence: explicit flag > frontmatter > "" (empty quoted string).

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

# E63-S10 metadata enrichment flags. Each is "unset" by sentinel until proven
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
    -h|--help) usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 1 ;;
  esac
done

if [ -z "$NEW_STATUS" ]; then
  err "missing required --to <new_status>"
  usage >&2
  exit 1
fi

if ! is_canonical_story_state "$NEW_STATUS"; then
  err "invalid target state: '$NEW_STATUS' (allowed: $(canonical_story_states_hint))"
  exit 1
fi

if [ -n "$EXPECTED_FROM" ] && ! is_canonical_story_state "$EXPECTED_FROM"; then
  err "invalid --from state: '$EXPECTED_FROM' (allowed: $(canonical_story_states_hint))"
  exit 1
fi

# ---------- Path resolution ----------

PROJECT_PATH="${PROJECT_PATH:-.}"
IMPLEMENTATION_ARTIFACTS="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_PATH}/docs/implementation-artifacts}"
PLANNING_ARTIFACTS="${PLANNING_ARTIFACTS:-${PROJECT_PATH}/docs/planning-artifacts}"
MEMORY_PATH="${MEMORY_PATH:-${PROJECT_PATH}/_memory}"
EPICS_AND_STORIES="${EPICS_AND_STORIES:-${PLANNING_ARTIFACTS}/epics-and-stories.md}"
STORY_INDEX_YAML="${STORY_INDEX_YAML:-${IMPLEMENTATION_ARTIFACTS}/story-index.yaml}"
STORY_STATUS_LOCK="${STORY_STATUS_LOCK:-${MEMORY_PATH}/.story-status.lock}"

# Forward SPRINT_STATUS_YAML untouched if caller pre-set it.

# ---------- Helpers ----------

# Locate the story file and filter by frontmatter `template: 'story'`. Mirrors
# sprint-state.sh's locator semantics so both scripts agree on which file is
# canonical when review-sibling files (e.g. -review.md) sit alongside.
locate_story_file() {
  local key="$1"
  local pattern="${IMPLEMENTATION_ARTIFACTS}/${key}-*.md"
  local epic_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/stories/${key}-*.md"

  shopt -s nullglob
  # shellcheck disable=SC2206
  local matches=( $pattern $epic_pattern )
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

  # E53-S231 — deduplicate canonical matches by realpath. After E53-S225
  # introduced epic-grouped layout, top-level legacy filenames may exist as
  # symlinks to the canonical epic-grouped path. Both resolve to the same
  # inode, so they are not ambiguous — collapse them. Prefer the non-symlink
  # (canonical) path when both forms appear.
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
# value (or empty string if the field is absent / blank). Used by the E63-S10
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

# Snapshot a file to "<file>.bak.<pid>" for rollback. Idempotent — re-snapshot
# overwrites prior snapshot. Returns the snapshot path on stdout. If the file
# does not yet exist, records a marker file recording the absence so rollback
# can rm -f the file the script created.
snapshot_for_rollback() {
  local file="$1"
  local snap="${file}.bak.tss.$$"
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
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
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
  # E64-S5: mv succeeded — clear the slot so the EXIT trap won't rm the renamed file.
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

  local yaml="${SPRINT_STATUS_YAML:-${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml}"
  if [ -z "${SPRINT_STATUS_YAML:-}" ]; then
    if [ ! -e "$yaml" ] && [ -e "${PROJECT_PATH}/sprint-status.yaml" ]; then
      yaml="${PROJECT_PATH}/sprint-status.yaml"
    fi
  fi

  if [ ! -s "$yaml" ]; then
    # sprint-status.yaml may not exist in fresh-project flows; skip silently.
    log "sprint-status.yaml not found at '$yaml' — skipping yaml update"
    return 0
  fi

  # Direct in-place rewrite (the outer flock already serialises us against
  # other transition-story-status.sh invocations; sprint-state.sh's own lock
  # would only matter for non-transition writers).
  local tmp
  tmp=$(mktemp "${yaml}.tmp.XXXXXX")
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
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
      log "story '$key' not present in sprint-status.yaml — skipping yaml update"
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
  # E64-S5: mv succeeded — clear the slot.
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
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
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
  ' "$file" > "$tmp"
  local rc=$?
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
  # E64-S5: mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Update or insert the story's metadata-rich entry in story-index.yaml.
#
# E63-S10 / Work Item 6.9 — the entry block is the canonical 8-line form, in
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

  if [ ! -e "$file" ]; then
    mkdir -p "$(dirname "$file")"
    {
      printf '# Auto-maintained by transition-story-status.sh.\n'
      printf 'last_updated: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'stories:\n'
      printf '  %s:\n' "$key"
      printf '    story_key: "%s"\n' "$key"
      printf '    title: "%s"\n' "$title"
      printf '    epic: "%s"\n' "$epic"
      printf '    priority: "%s"\n' "$priority"
      printf '    risk: "%s"\n' "$risk"
      printf '    author: "%s"\n' "$author"
      printf '    file: "%s"\n' "$file_path"
      printf '    status: "%s"\n' "$new_status"
    } > "$file"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
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
  awk -v target="$key" \
      -v new_status="$new_status" \
      -v title="$title" \
      -v epic="$epic" \
      -v priority="$priority" \
      -v risk="$risk" \
      -v author="$author" \
      -v file_path="$file_path" '
    function emit_block(k, t, e, p, r, a, f, s) {
      printf "  %s:\n", k
      printf "    story_key: \"%s\"\n", k
      printf "    title: \"%s\"\n", t
      printf "    epic: \"%s\"\n", e
      printf "    priority: \"%s\"\n", p
      printf "    risk: \"%s\"\n", r
      printf "    author: \"%s\"\n", a
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
  # E64-S5: mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# ---------- Main flow ----------

# Resolve the story file (exit 2/3 on missing/multiple).
STORY_FILE="$(locate_story_file "$STORY_KEY")"

# E63-S10 metadata resolution: explicit flag > frontmatter value > "" empty.
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
META_PRIORITY="$(resolve_meta "$META_PRIORITY" priority)"
META_RISK="$(resolve_meta "$META_RISK" risk)"
META_AUTHOR="$(resolve_meta "$META_AUTHOR" author)"
if [ "$META_FILE" = "$TSS_UNSET" ]; then
  META_FILE="$STORY_FILE"
fi

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

# --from check.
if [ -n "$EXPECTED_FROM" ] && [ "$CURRENT_STATUS" != "$EXPECTED_FROM" ]; then
  err "expected current status '$EXPECTED_FROM' but found '$CURRENT_STATUS'"
  exit 1
fi

# Idempotent self-transition.
if [ "$CURRENT_STATUS" = "$NEW_STATUS" ]; then
  log "no-op (story already at $NEW_STATUS)"
  exit 0
fi

# State-machine validation.
if ! validate_story_transition "$CURRENT_STATUS" "$NEW_STATUS"; then
  exit 7
fi

# Snapshot every file we may touch so we can roll back on partial failure.
SNAP_STORY="$(snapshot_for_rollback "$STORY_FILE")"
SNAP_YAML=""
SNAP_EPICS="$(snapshot_for_rollback "$EPICS_AND_STORIES")"
SNAP_INDEX="$(snapshot_for_rollback "$STORY_INDEX_YAML")"

YAML_PATH_FOR_SNAP="${SPRINT_STATUS_YAML:-${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml}"
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
  restore_snapshot "$STORY_INDEX_YAML" "$SNAP_INDEX" 2>/dev/null || true
}

# Custom failure handler: roll back, then exit 8.
# E64-S5: chain through _cleanup_tmps so any orphan tmp registered during
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
update_story_index_yaml "$STORY_KEY" "$NEW_STATUS" \
  "$META_TITLE" "$META_EPIC" "$META_PRIORITY" "$META_RISK" "$META_AUTHOR" "$META_FILE"

# All four files written successfully — commit.
TSS_ROLLBACK_PENDING=0
# E64-S5: restore the plain _cleanup_tmps EXIT trap so any later failure
# (e.g., during marker write) still cleans orphan tmps. Slots cleared above
# make this a no-op on the happy path.
trap '_cleanup_tmps' EXIT

cleanup_snapshots "$SNAP_STORY" "$SNAP_YAML" "$SNAP_EPICS" "$SNAP_INDEX"

# Write status-transition marker (E59-S5 / ADR-074 contract C3).
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
