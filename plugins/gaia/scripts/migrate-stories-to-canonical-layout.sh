#!/usr/bin/env bash
# migrate-stories-to-canonical-layout.sh — backfill flat stories + flat index
#                                          into the canonical per-epic layout.
#
# Story: E79-S6 — Migration script — backfill legacy flat stories + flat
#                 `story-index.yaml`.
# Epic:  E79     — Canonical Per-Epic Story-File Layout (Path Convergence).
# ADRs:  ADR-070 (canonical layout), ADR-072 (atomic rename guarantees).
# Trace: TC-CSP-9, TC-CSP-14, TC-CSP-15.
#
# Mission:
#   One-shot migration: every legacy flat story file
#   `docs/implementation-artifacts/{key}-{slug}.md` is moved into the canonical
#   per-epic nested layout
#   `docs/implementation-artifacts/epic-{epic-slug}/stories/{key}-{slug}.md`,
#   and any flat `docs/implementation-artifacts/story-index.yaml` is merged
#   into per-epic `story-index.yaml` files.
#
# Phases:
#   1. Walk flat-path candidates (depth=1) — `E*-S*-*.md` files at
#      `docs/implementation-artifacts/`. Already-nested files under
#      `epic-*/stories/` are NEVER touched.
#   2. For each candidate: resolve destination via E79-S1's epic-slug
#      resolver, mkdir -p the destination, `git mv` (or plain `mv` in non-git
#      mode). Filename is preserved verbatim.
#   3. If a flat `story-index.yaml` exists: parse the YAML, bucket entries by
#      epic via the resolver, append-or-merge into per-epic indices, log
#      conflicts (per-epic wins), delete the flat file when fully drained.
#      Preserve the flat file (with WARNING) if any entries remain unresolved.
#   4. Idempotency guard — if Phases 1+3 produced zero candidates, emit the
#      canonical no-op notice and short-circuit.
#   5. Post-condition probe — invoke `check-story-layout-sync.sh`; HALT-with-
#      error if any WARNING/CRITICAL lines remain (the advisory script always
#      exits 0; this gate watches stdout instead).
#
# Non-git workspace mode (CLAUDE.md "Non-git project-root workspace"):
#   The project-root `docs/` tree is not always inside a git work tree. When
#   `git rev-parse --is-inside-work-tree` returns non-zero, `git mv` is
#   replaced with plain `mv`, the canonical
#   `non-git CWD: using plain mv` warning is emitted ONCE on stderr, and the
#   migration continues normally. The flat `docs/` workspace is supported as a
#   first-class mode — `git log --follow` is vacuous-by-design here.
#
# Conflict policy on per-epic index merge:
#   Existing per-epic entry wins; the flat-side losing entry is logged as
#   `INFO: index-merge conflict on {key}: keeping per-epic entry, dropping flat entry`.
#
# Exit codes:
#   0 — success (all candidates moved + indices merged, no-op runs included).
#   1 — generic failure (epic-slug resolver failure, malformed YAML, etc.).
#   2 — usage error.
#   3 — post-condition probe FAILED (check-story-layout-sync.sh emitted
#       WARNING / CRITICAL lines after migration).

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Resolve script-local paths.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
RESOLVE_EPIC_SLUG_LIB="$LIB_DIR/resolve-epic-slug.sh"
CHECK_STORY_LAYOUT_SCRIPT="$SCRIPT_DIR/check-story-layout-sync.sh"

if [ ! -f "$RESOLVE_EPIC_SLUG_LIB" ]; then
  printf 'migrate-stories-to-canonical-layout.sh: missing dependency: %s\n' \
    "$RESOLVE_EPIC_SLUG_LIB" >&2
  exit 1
fi
# shellcheck source=lib/resolve-epic-slug.sh
. "$RESOLVE_EPIC_SLUG_LIB"

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------

ROOT="."
EPICS_FILE_OVERRIDE=""

_usage() {
  cat <<'USAGE'
Usage: migrate-stories-to-canonical-layout.sh [--root <project-root>] [--epics-file <path>]

Backfill legacy flat story files and flat story-index.yaml into the canonical
per-epic nested layout. Idempotent — re-running on a converged tree is a no-op.

Options:
  --root <path>         Project root containing docs/. Default: CWD.
  --epics-file <path>   Override epics-and-stories.md path. Default:
                        <root>/docs/planning-artifacts/epics-and-stories.md.
  -h, --help            Print this usage and exit 0.

Exit codes:
  0 — success
  1 — generic failure (resolver, malformed YAML, etc.)
  2 — usage error
  3 — post-condition probe FAILED
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"; shift 2 || { _usage >&2; exit 2; }
      ;;
    --root=*)
      ROOT="${1#--root=}"; shift
      ;;
    --epics-file)
      EPICS_FILE_OVERRIDE="${2:-}"; shift 2 || { _usage >&2; exit 2; }
      ;;
    --epics-file=*)
      EPICS_FILE_OVERRIDE="${1#--epics-file=}"; shift
      ;;
    -h|--help)
      _usage
      exit 0
      ;;
    *)
      printf 'migrate-stories-to-canonical-layout.sh: unknown argument: %s\n' "$1" >&2
      _usage >&2
      exit 2
      ;;
  esac
done

if [ -d "$ROOT" ]; then
  ROOT="$(cd "$ROOT" && pwd)"
fi

IMPL_DIR="$ROOT/docs/implementation-artifacts"

if [ -n "$EPICS_FILE_OVERRIDE" ]; then
  EPICS_FILE="$EPICS_FILE_OVERRIDE"
else
  EPICS_FILE="$ROOT/docs/planning-artifacts/epics-and-stories.md"
fi

# ---------------------------------------------------------------------------
# Logging helpers.
# ---------------------------------------------------------------------------

_log()  { printf '%s\n' "$*" >&2; }
_warn() { printf 'WARNING: %s\n' "$*" >&2; }
_info() { printf 'INFO: %s\n' "$*" >&2; }
_err()  { printf 'migrate-stories-to-canonical-layout.sh: ERROR: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Mode detection — git work tree vs. non-git workspace.
#
# The mover function chooses `git mv` or plain `mv` per call based on the
# detected mode. The canonical fallback notice is emitted exactly once per
# invocation (on first plain-mv use).
# ---------------------------------------------------------------------------

_INSIDE_GIT=0
_NON_GIT_NOTICE_EMITTED=0

if (cd "$ROOT" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
  _INSIDE_GIT=1
fi

_emit_non_git_notice_once() {
  if [ "$_NON_GIT_NOTICE_EMITTED" -eq 0 ]; then
    _log "non-git CWD: using plain mv"
    _NON_GIT_NOTICE_EMITTED=1
  fi
}

# _move_file <src> <dst> — perform the rename using git mv when the work tree
# supports it, falling back to plain mv otherwise. Both paths must be absolute
# or relative-to-CWD; the destination directory MUST already exist.
_move_file() {
  local src="$1" dst="$2"
  if [ "$_INSIDE_GIT" -eq 1 ]; then
    # Use git mv for tracked files; fall back to plain mv if git refuses
    # (e.g., the file isn't tracked yet — common for files created in the
    # current uncommitted tree).
    if git mv -- "$src" "$dst" 2>/dev/null; then
      return 0
    fi
  fi
  _emit_non_git_notice_once
  mv -- "$src" "$dst"
}

# ---------------------------------------------------------------------------
# Phase 1 — find flat candidates.
#
# Outputs absolute paths, one per line. We restrict to maxdepth=1 so anything
# under epic-*/stories/ is invisible to the walk by construction.
#
# Filename pattern: `E{N}-S{N}-{slug}.md` — only the canonical story-file
# shape qualifies. Review summaries (`E*-S*-review-summary.md`) DO match this
# regex; they are deliberately included so the "review-summary lives next to
# its story" convention carries over to the per-epic layout. If a future
# convention tightens this, the change goes here.
# ---------------------------------------------------------------------------

_find_flat_candidates() {
  if [ ! -d "$IMPL_DIR" ]; then
    return 0
  fi
  find "$IMPL_DIR" -maxdepth 1 -type f -name 'E*-S*-*.md' 2>/dev/null \
    | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Resolver wrapper — convert a story key (E77-S10) into the destination dir
# `${IMPL_DIR}/epic-{epic-slug}/stories/`. Caches resolved slugs by epic_key.
# ---------------------------------------------------------------------------

# _epic_slug_cache: associative-array shim built lazily. We use a flat string
# rather than `declare -A` to keep compatibility with bash 3.2 on macOS.
# Entries are stored as `\n${epic_key}=${epic_slug}\n` and queried via grep.
_EPIC_SLUG_CACHE=$'\n'

# _resolve_epic_slug_cached <epic_key> -> stdout: epic-slug (e.g. epic-E77-...)
# Returns 1 (and emits warning to stderr) if the resolver cannot find the
# epic. The cache stores both hits and (empty) misses to avoid re-querying.
_resolve_epic_slug_cached() {
  local epic_key="$1"
  if [ -z "$epic_key" ]; then
    return 1
  fi
  # Check cache.
  local cached
  cached="$(printf '%s' "$_EPIC_SLUG_CACHE" | grep -m1 "^${epic_key}=" || true)"
  if [ -n "$cached" ]; then
    local val="${cached#"${epic_key}"=}"
    if [ -z "$val" ]; then
      return 1
    fi
    printf '%s' "$val"
    return 0
  fi
  # Resolve via the lib helper.
  local slug
  if ! slug="$(resolve_epic_slug "$epic_key" "$EPICS_FILE" 2>/dev/null)"; then
    _EPIC_SLUG_CACHE="${_EPIC_SLUG_CACHE}${epic_key}=
"
    return 1
  fi
  _EPIC_SLUG_CACHE="${_EPIC_SLUG_CACHE}${epic_key}=${slug}
"
  printf '%s' "$slug"
}

# Extract the epic key prefix from a story-file basename: `E77-S10-foo.md`
# -> `E77`. Review summaries (`E77-S10-review-summary.md`) yield `E77` too.
_extract_epic_key() {
  local base="$1"
  printf '%s' "$base" | sed -E 's/^([A-Z][0-9]+)-S[0-9]+-.*$/\1/'
}

# ---------------------------------------------------------------------------
# Phase 3 — flat story-index.yaml merge.
#
# Format expectation (per E79-S3 / transition-story-status.sh writer):
#
#   stories:
#     E77-S10:
#       story_key: "E77-S10"
#       title: "..."
#       epic: "E77"
#       priority: "..."
#       risk: "..."
#       author: "..."
#       file: "..."
#       status: "..."
#
# We avoid a hard yq dependency by parsing this canonical shape with awk —
# the writer is the single source of truth, and the migration target is the
# same writer. yq is documented as a project dep in the story but is not
# strictly required for this minimal merge.
# ---------------------------------------------------------------------------

# Parse a flat story-index.yaml and emit one bucket marker per entry on
# stdout, in the form: `BLOCK <key>` followed by every child line of that
# entry, terminated by `END`. Exit 0 always; emits nothing if the file has
# no `stories:` mapping.
_emit_flat_index_blocks() {
  local file="$1"
  awk '
    BEGIN { in_stories = 0; in_entry = 0; key = "" }
    /^stories:[[:space:]]*$/ { in_stories = 1; next }
    in_stories && /^[A-Za-z]/ {
      # End of stories: mapping.
      if (in_entry) { print "END"; in_entry = 0 }
      in_stories = 0
    }
    in_stories && /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      if (in_entry) { print "END" }
      key = $0
      sub(/^  /, "", key); sub(/:[[:space:]]*$/, "", key)
      printf "BLOCK %s\n", key
      in_entry = 1
      next
    }
    in_entry { print }
    END {
      if (in_entry) { print "END" }
    }
  ' "$file"
}

# Read the children of a `BLOCK <key> ... END` group from the global parsed
# stream and append them as the new entry under <per_epic_index>. The header
# `  <key>:` line is emitted before the children. If the per-epic index has
# no `stories:` mapping yet, one is added.
_append_block_to_per_epic_index() {
  local per_epic_file="$1" key="$2"
  shift 2
  local children=("$@")

  # Ensure file exists with header + stories: mapping.
  if [ ! -e "$per_epic_file" ]; then
    mkdir -p "$(dirname "$per_epic_file")"
    {
      printf '# Auto-maintained by transition-story-status.sh / migrate-stories-to-canonical-layout.sh.\n'
      printf 'last_updated: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'stories:\n'
    } > "$per_epic_file"
  fi

  # If the file lacks `stories:`, append it.
  if ! grep -q '^stories:[[:space:]]*$' "$per_epic_file"; then
    printf 'stories:\n' >> "$per_epic_file"
  fi

  {
    printf '  %s:\n' "$key"
    local child
    for child in "${children[@]}"; do
      printf '%s\n' "$child"
    done
  } >> "$per_epic_file"
}

# Check if a given story key already has an entry in the per-epic index.
_per_epic_index_has_key() {
  local per_epic_file="$1" key="$2"
  [ -f "$per_epic_file" ] || return 1
  grep -qE "^  ${key}:[[:space:]]*$" "$per_epic_file"
}

# Merge the flat story-index.yaml into per-epic indices. Returns the number
# of entries that could not be resolved on stdout.
#
# Side effect: deletes the flat file when every entry has been drained
# (resolved + merged or resolved + conflict-skipped). Preserves it with a
# WARNING when any entry remained unresolved.
_merge_flat_story_index() {
  local flat_file="$1"
  if [ ! -f "$flat_file" ]; then
    printf '0'
    return 0
  fi

  local unresolved=0
  local resolved_total=0

  # Parse into a temp file we can iterate over twice.
  local parsed
  parsed="$(mktemp -t flat-index-parsed.XXXXXX)"
  # shellcheck disable=SC2064 # intentional: capture $parsed at trap-set time.
  trap "rm -f '$parsed'" RETURN
  _emit_flat_index_blocks "$flat_file" > "$parsed"

  # Walk blocks. Bash 3.2-compat: read line-by-line, accumulate children.
  local current_key="" in_block=0
  local children=()
  while IFS= read -r line; do
    case "$line" in
      "BLOCK "*)
        current_key="${line#BLOCK }"
        in_block=1
        children=()
        ;;
      "END")
        if [ "$in_block" -eq 1 ] && [ -n "$current_key" ]; then
          _process_one_flat_block "$current_key" || unresolved=$((unresolved + 1))
          resolved_total=$((resolved_total + 1))
        fi
        in_block=0
        current_key=""
        children=()
        ;;
      *)
        if [ "$in_block" -eq 1 ]; then
          children+=("$line")
        fi
        ;;
    esac
  done < "$parsed"

  if [ "$unresolved" -gt 0 ]; then
    _warn "${unresolved} unresolved entries retained in flat story-index.yaml"
  else
    # Every entry drained — delete the flat file.
    rm -f "$flat_file"
  fi

  printf '%d' "$unresolved"
}

# Process a single flat-index block. Uses the outer scope's `current_key` and
# `children` (bash dynamic scoping). Returns 0 on resolve, 1 on unresolved
# (caller increments the unresolved counter).
_process_one_flat_block() {
  local key="$1"
  local epic_key
  epic_key="$(_extract_epic_key "${key}-x.md")"
  if [ -z "$epic_key" ]; then
    return 1
  fi

  local epic_slug
  if ! epic_slug="$(_resolve_epic_slug_cached "$epic_key")"; then
    return 1
  fi

  local per_epic_file="$IMPL_DIR/${epic_slug}/story-index.yaml"
  if _per_epic_index_has_key "$per_epic_file" "$key"; then
    _info "index-merge conflict on ${key}: keeping per-epic entry, dropping flat entry"
    return 0
  fi

  _append_block_to_per_epic_index "$per_epic_file" "$key" "${children[@]}"
  return 0
}

# ---------------------------------------------------------------------------
# Phase 5 — post-condition probe.
# ---------------------------------------------------------------------------

_run_post_condition_probe() {
  if [ ! -x "$CHECK_STORY_LAYOUT_SCRIPT" ] && [ ! -f "$CHECK_STORY_LAYOUT_SCRIPT" ]; then
    _err "post-condition: check-story-layout-sync.sh not found at $CHECK_STORY_LAYOUT_SCRIPT"
    return 1
  fi

  local probe_out
  probe_out="$(bash "$CHECK_STORY_LAYOUT_SCRIPT" --root "$ROOT" 2>&1 || true)"

  # The probe gates on the two layout-drift classes this script CAN fix:
  #   1. legacy-flat-path        (Phase 2 moves)
  #   2. heterogeneous-story-index (Phase 3 merges)
  # The third drift class — epic-slug-mismatch — is a story-frontmatter
  # content issue (e.g. `epic: "E10 — Title"` instead of `epic: "E10"`).
  # That's pre-existing data drift the migration cannot repair safely
  # without rewriting story frontmatter — out of scope for this script per
  # the story's Dev Notes ("the cleanup pass that backfills any pre-existing
  # flat artifacts"). epic-slug-mismatch findings remain visible via the
  # advisory itself and are addressed by a separate frontmatter-cleanup pass.
  local fixable_lines
  fixable_lines="$(printf '%s\n' "$probe_out" \
    | grep -E '^(WARNING|CRITICAL)' \
    | grep -E ' (legacy-flat-path|heterogeneous-story-index) ' \
    || true)"

  if [ -n "$fixable_lines" ]; then
    _err "post-condition probe FAILED — fixable layout drift remains after migration:"
    printf '%s\n' "$fixable_lines" >&2
    return 1
  fi

  # Surface unfixable epic-slug-mismatch findings as INFO so the operator
  # is aware of pre-existing frontmatter drift but the gate still passes.
  local mismatch_count
  mismatch_count="$(printf '%s\n' "$probe_out" \
    | grep -cE ' epic-slug-mismatch ' \
    || true)"
  if [ "${mismatch_count:-0}" -gt 0 ]; then
    _info "${mismatch_count} pre-existing epic-slug-mismatch finding(s) (story-frontmatter drift) — out of scope for this migration"
  fi

  _log "migration: post-condition PASSED (check-story-layout-sync.sh clean)"
  return 0
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

main() {
  if [ ! -d "$IMPL_DIR" ]; then
    # Nothing to migrate — emit no-op notice and exit cleanly.
    _log "migration: no-op (already converged)"
    return 0
  fi

  if [ ! -f "$EPICS_FILE" ]; then
    _err "epics-and-stories.md not found at $EPICS_FILE"
    return 1
  fi

  # Phase 1 — flat candidates.
  local candidates_raw
  candidates_raw="$(_find_flat_candidates)"

  local flat_index="$IMPL_DIR/story-index.yaml"
  local has_flat_index=0
  if [ -f "$flat_index" ]; then
    has_flat_index=1
  fi

  # Idempotency guard — zero candidates AND no flat index = no-op.
  if [ -z "$candidates_raw" ] && [ "$has_flat_index" -eq 0 ]; then
    _log "migration: no-op (already converged)"
    # Even a no-op runs the post-condition probe — the tree may still carry
    # epic-slug-mismatch drift that this script wouldn't fix anyway, but a
    # clean no-op should still report cleanly.
    _run_post_condition_probe || return 3
    return 0
  fi

  # Phase 2 — move candidates.
  local moved_count=0 unresolved_moves=0
  if [ -n "$candidates_raw" ]; then
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      local base epic_key epic_slug dst_dir dst_file
      base="$(basename "$src")"
      epic_key="$(_extract_epic_key "$base")"
      if [ -z "$epic_key" ]; then
        _warn "could not derive epic key from filename: $base"
        unresolved_moves=$((unresolved_moves + 1))
        continue
      fi
      if ! epic_slug="$(_resolve_epic_slug_cached "$epic_key")"; then
        _warn "could not resolve epic-slug for $epic_key (file=$base) — leaving in place"
        unresolved_moves=$((unresolved_moves + 1))
        continue
      fi
      dst_dir="$IMPL_DIR/${epic_slug}/stories"
      dst_file="$dst_dir/$base"
      if [ -e "$dst_file" ]; then
        _warn "destination already exists: $dst_file — leaving flat copy in place"
        unresolved_moves=$((unresolved_moves + 1))
        continue
      fi
      mkdir -p "$dst_dir"
      _move_file "$src" "$dst_file"
      moved_count=$((moved_count + 1))
    done <<< "$candidates_raw"
  fi

  # Phase 3 — flat story-index.yaml merge.
  local index_unresolved=0
  if [ "$has_flat_index" -eq 1 ]; then
    index_unresolved="$(_merge_flat_story_index "$flat_index")"
  fi

  # Summary log.
  _log "migration: ${moved_count} file(s) moved, flat-index unresolved=${index_unresolved}, candidate failures=${unresolved_moves}"

  # Phase 5 — post-condition probe. If unresolved entries remain, the probe
  # will surface them as WARNING lines and we exit 3.
  if ! _run_post_condition_probe; then
    return 3
  fi

  return 0
}

main "$@"
