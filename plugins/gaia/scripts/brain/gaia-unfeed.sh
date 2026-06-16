#!/usr/bin/env bash
# gaia-unfeed.sh — sanctioned removal of an ingested Brain document.
#
# WHAT IT DOES
#   The inverse of gaia-feed.sh: deletes the ingested file under
#   .gaia/knowledge/ingested/<slug>.md and de-registers the matching
#   source_type: ingested entry from brain-index.yaml. Only ingested entries
#   are eligible — project-artifact and lesson entries are never touched.
#
# USAGE
#   gaia_unfeed <slug>
#
# SOURCEABLE + EXECUTABLE
#   When sourced, exports gaia_unfeed() and its _gu_ helper functions.
#   When executed directly, dispatches gaia_unfeed() with CLI args.
#
# SECURITY
#   Two-layer containment:
#     1. Character-level slug guard (_gic_slug_containment_guard) rejects path
#        separators and traversal sequences (/ and ..).
#     2. Realpath verification: the resolved deletion target is asserted to be
#        a child of the canonicalised .gaia/knowledge/ingested/ directory before
#        any unlink. A symlink-escape is caught here. The realpath check runs
#        twice — once at entry and again immediately before the unlink — to
#        close the TOCTOU window.
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags. LC_ALL=C. set -euo pipefail.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
_gu_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source gaia-paths.sh for GAIA_KNOWLEDGE_DIR etc.
# shellcheck source=../lib/gaia-paths.sh
. "$_gu_self_dir/../lib/gaia-paths.sh" || {
  printf 'gaia-unfeed.sh: could not source gaia-paths.sh\n' >&2
  return 1 2>/dev/null || exit 1
}

# Source the shared ingestion library (slug guards).
# shellcheck source=lib/ingest-common.sh
. "$_gu_self_dir/lib/ingest-common.sh" || {
  printf 'gaia-unfeed.sh: could not source ingest-common.sh\n' >&2
  return 1 2>/dev/null || exit 1
}

# Source the shared atomic index writer.
# shellcheck source=lib/brain-index-write.sh
. "$_gu_self_dir/lib/brain-index-write.sh" || {
  printf 'gaia-unfeed.sh: could not source brain-index-write.sh\n' >&2
  return 1 2>/dev/null || exit 1
}

# Sibling validator (used by the shared writer, but also allow test override).
_GU_VALIDATE="${_GU_VALIDATE:-$_gu_self_dir/validate-brain-index.sh}"
export _GU_VALIDATE

# Override the shared writer's validator path if the caller set _GU_VALIDATE.
if [ -n "${_GU_VALIDATE:-}" ]; then
  _BIW_VALIDATE_OVERRIDE="$_GU_VALIDATE"
  export _BIW_VALIDATE_OVERRIDE
  # Re-source the writer to pick up the override (it has an idempotent guard,
  # so we need to reset it).
  _BIW_LOADED=0
  . "$_gu_self_dir/lib/brain-index-write.sh"
fi

# MOC renderer (best-effort).
_GU_RENDER_MOC="${_GU_RENDER_MOC:-$_gu_self_dir/render-moc.sh}"

# ---------------------------------------------------------------------------
# _gu_realpath_containment_check — verify the resolved path of a file is
# a child of the canonicalised ingested directory. This catches symlink
# escapes that the character-level guard cannot detect.
# Returns 0 if contained, 1 if not.
# ---------------------------------------------------------------------------
_gu_realpath_containment_check() {
  local target_file="$1"
  local ingested_dir="$2"

  # Resolve the ingested directory to its canonical form.
  local canon_root
  if [ -d "$ingested_dir" ]; then
    canon_root="$(cd "$ingested_dir" 2>/dev/null && pwd -P)"
  else
    printf 'gaia-unfeed.sh: ingested directory does not exist: %s\n' "$ingested_dir" >&2
    return 1
  fi

  # Resolve the target file. If it is a symlink, resolve through the link.
  local canon_target
  if [ -L "$target_file" ]; then
    # Resolve symlink: read the link target and canonicalize.
    local link_target
    link_target="$(readlink "$target_file" 2>/dev/null || true)"
    if [ -z "$link_target" ]; then
      printf 'gaia-unfeed.sh: cannot resolve symlink: %s\n' "$target_file" >&2
      return 1
    fi
    # Make absolute if relative.
    case "$link_target" in
      /*) : ;;
      *)  link_target="$(dirname "$target_file")/$link_target" ;;
    esac
    # Canonicalize the resolved link target.
    local link_dir
    link_dir="$(dirname "$link_target")"
    if [ -d "$link_dir" ]; then
      canon_target="$(cd "$link_dir" 2>/dev/null && pwd -P)/$(basename "$link_target")"
    else
      canon_target="$link_target"
    fi
  elif [ -f "$target_file" ]; then
    local target_dir
    target_dir="$(dirname "$target_file")"
    if [ -d "$target_dir" ]; then
      canon_target="$(cd "$target_dir" 2>/dev/null && pwd -P)/$(basename "$target_file")"
    else
      canon_target="$target_file"
    fi
  else
    # File does not exist — construct canonical path from the directory.
    local target_dir
    target_dir="$(dirname "$target_file")"
    if [ -d "$target_dir" ]; then
      canon_target="$(cd "$target_dir" 2>/dev/null && pwd -P)/$(basename "$target_file")"
    else
      canon_target="${canon_root}/$(basename "$target_file")"
    fi
  fi

  # Assert the resolved target is a prefix-child of the ingested root.
  case "$canon_target" in
    "${canon_root}/"*)
      return 0
      ;;
    *)
      printf 'gaia-unfeed.sh: containment violation — resolved path escapes ingested root\n' >&2
      printf '  ingested root: %s\n' "$canon_root" >&2
      printf '  resolved path: %s\n' "$canon_target" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _gu_has_ingested_entry — check if an ingested entry exists for the slug.
# Prints "yes" and returns 0 if found, "no" and returns 1 if not.
# ---------------------------------------------------------------------------
_gu_has_ingested_entry() {
  local manifest="$1"
  local slug="$2"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$manifest" "$slug" <<'PYEOF'
import sys, yaml
manifest_path = sys.argv[1]
slug = sys.argv[2]
with open(manifest_path) as f:
    doc = yaml.safe_load(f) or {}
for e in (doc.get("entries") or []):
    if e.get("key") == slug and e.get("source_type") == "ingested":
        print("yes")
        sys.exit(0)
print("no")
sys.exit(1)
PYEOF
  else
    # Awk fallback: look for key + source_type pattern.
    if awk -v slug="$slug" '
      /key:/ && $0 ~ "\"" slug "\"" { found_key=1; next }
      found_key && /source_type: ingested/ { print "yes"; exit 0 }
      found_key && /^  - key:/ { found_key=0 }
      END { if (!found_key) exit 1 }
    ' "$manifest" 2>/dev/null; then
      return 0
    else
      printf 'no\n'
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# _gu_render_moc — best-effort MOC re-render after removal.
# ---------------------------------------------------------------------------
_gu_render_moc() {
  local manifest="$1"
  local output_path="$2"

  if [ ! -x "$_GU_RENDER_MOC" ] && [ ! -f "$_GU_RENDER_MOC" ]; then
    printf 'gaia-unfeed.sh: warning — render-moc.sh not available; MOC not re-rendered\n' >&2
    return 0
  fi

  local render_rc=0
  env -u _GAIA_PATHS_LOADED bash "$_GU_RENDER_MOC" "$manifest" "$output_path" || render_rc=$?
  if [ "$render_rc" -ne 0 ]; then
    printf 'gaia-unfeed.sh: warning — MOC re-render failed (exit %d); removal was successful\n' "$render_rc" >&2
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Main entry point: gaia_unfeed
# ---------------------------------------------------------------------------
gaia_unfeed() {
  local slug="${1:-}"

  if [ -z "$slug" ]; then
    printf 'gaia-unfeed.sh: usage: gaia_unfeed <slug>\n' >&2
    return 1
  fi

  # --- Security layer 1: slug containment guard (character-level) ---
  local ingested_dir="$GAIA_KNOWLEDGE_DIR/ingested"
  _gic_slug_containment_guard "$slug" "$ingested_dir" || return $?

  # --- Resolve paths ---
  local manifest="$GAIA_KNOWLEDGE_DIR/brain-index.yaml"
  local target_file="$ingested_dir/${slug}.md"

  if [ ! -f "$manifest" ]; then
    printf 'gaia-unfeed.sh: brain-index.yaml not found at %s\n' "$manifest" >&2
    return 1
  fi

  # --- Security layer 2: realpath containment check ---
  # Even if the slug passed the character-level guard, the resolved file path
  # must stay inside the ingested directory (catches symlink escapes).
  if [ -e "$target_file" ] || [ -L "$target_file" ]; then
    _gu_realpath_containment_check "$target_file" "$ingested_dir" || {
      printf 'gaia-unfeed.sh: refusing to delete — path escapes containment boundary\n' >&2
      return 1
    }
  fi

  # --- Check if an ingested entry exists for this slug ---
  local has_entry
  has_entry="$(_gu_has_ingested_entry "$manifest" "$slug" 2>/dev/null || true)"

  if [ "$has_entry" != "yes" ]; then
    printf 'gaia-unfeed.sh: nothing to remove — no ingested entry for slug: %s\n' "$slug" >&2
    return 0
  fi

  # --- Atomic de-registration (shared helper) ---
  local dereg_rc=0
  _biw_deregister_entry "$manifest" "$slug" || dereg_rc=$?

  case "$dereg_rc" in
    0)
      # De-registration succeeded; now delete the file.
      ;;
    2)
      # No matching ingested entry (should not reach here given the check above,
      # but handle defensively).
      printf 'gaia-unfeed.sh: nothing to remove — no ingested entry for slug: %s\n' "$slug" >&2
      return 0
      ;;
    *)
      # Validation or other failure — do NOT delete the file.
      printf 'gaia-unfeed.sh: index de-registration failed; file NOT deleted\n' >&2
      return 1
      ;;
  esac

  # --- Delete the ingested file ---
  # Re-check containment immediately before unlink to close the TOCTOU window
  # between the initial check and this point (a concurrent process could have
  # swapped the file for an out-of-bounds symlink in the interim).
  if [ -f "$target_file" ] || [ -L "$target_file" ]; then
    _gu_realpath_containment_check "$target_file" "$ingested_dir" || {
      printf 'gaia-unfeed.sh: refusing to delete — path escapes containment boundary (re-check at unlink time)\n' >&2
      printf 'gaia-unfeed.sh: WARNING — index was already de-registered but file was NOT deleted\n' >&2
      return 1
    }
    rm -f "$target_file"
    printf 'gaia-unfeed.sh: deleted: %s\n' "$target_file" >&2
  else
    printf 'gaia-unfeed.sh: ingested file already absent: %s\n' "$target_file" >&2
  fi

  # --- Best-effort MOC re-render ---
  local moc_path="$GAIA_KNOWLEDGE_DIR/brain-index.md"
  _gu_render_moc "$manifest" "$moc_path"

  printf 'gaia-unfeed.sh: removal complete for: %s\n' "$slug" >&2
  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  gaia_unfeed "$@"
  exit $?
fi
