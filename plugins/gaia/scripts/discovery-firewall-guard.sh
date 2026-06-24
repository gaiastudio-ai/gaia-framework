#!/usr/bin/env bash
# discovery-firewall-guard.sh — build-time fail-closed firewall guard.
#
# Proves the sprint-plan skill surface has ZERO read paths to the
# discovery board. Greps the full sprint-plan surface (SKILL.md + every
# sourced script) for board references and exits non-zero on ANY hit.
#
# Fail-closed on OWN absence / mis-scope: if the SKILL.md or the
# script directory cannot be resolved, the guard exits non-zero with a
# diagnostic. A vacuous always-green guard is worse than none.
#
# Usage:
#   discovery-firewall-guard.sh [--surface-root <path>]
#
# --surface-root defaults to the plugin root (auto-detected from this
# script's location: scripts/ -> parent = plugin root).
#
# Exit codes:
#   0 — surface is clean, no board references found
#   1 — board reference found, or structural mis-scope detected

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="discovery-firewall-guard.sh"

_log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_die() { _log "FAIL — $*"; exit 1; }

# ---------- argument parsing ----------

SURFACE_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --surface-root)
      [ -n "${2:-}" ] || _die "--surface-root requires a value"
      SURFACE_ROOT="$2"
      shift 2
      ;;
    --help|-h)
      printf 'Usage: %s [--surface-root <path>]\n' "$SCRIPT_NAME"
      exit 0
      ;;
    *)
      _die "unknown argument: $1"
      ;;
  esac
done

# Default: derive plugin root from this script's location.
if [ -z "$SURFACE_ROOT" ]; then
  SURFACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

# ---------- structural validation (fail-closed on mis-scope) ----------

if [ ! -d "$SURFACE_ROOT" ]; then
  _die "surface root does not exist: $SURFACE_ROOT"
fi

SKILL_DIR="$SURFACE_ROOT/skills/gaia-sprint-plan"
SKILL_MD="$SKILL_DIR/SKILL.md"
SKILL_SCRIPTS="$SKILL_DIR/scripts"

if [ ! -f "$SKILL_MD" ]; then
  _die "sprint-plan SKILL.md not found at $SKILL_MD — guard cannot scope the surface (fail-closed)"
fi

if [ ! -d "$SKILL_SCRIPTS" ]; then
  _die "sprint-plan scripts dir not found at $SKILL_SCRIPTS — guard cannot scope the surface (fail-closed)"
fi

# ---------- collect the full sprint-plan surface ----------
#
# The surface is: SKILL.md + every .sh under its scripts/ dir + every
# script in the top-level scripts/ (and scripts/lib/) that the SKILL.md
# references. After seeding, we transitively follow source/dot directives
# and script invocations to a fixed point so that scripts sourced by the
# sprint-plan skill's own scripts are never invisible to the guard.

SURFACE_FILES=()

# 1. SKILL.md itself.
SURFACE_FILES+=("$SKILL_MD")

# 2. Sprint-plan skill scripts.
while IFS= read -r -d '' f; do
  SURFACE_FILES+=("$f")
done < <(find "$SKILL_SCRIPTS" -name '*.sh' -type f -print0 2>/dev/null)

# 3. Top-level scripts referenced by SKILL.md.
#    Extract script basenames from the SKILL.md and resolve them under
#    SURFACE_ROOT/scripts/ (flat) and SURFACE_ROOT/scripts/lib/ (nested).
SCRIPTS_DIR="$SURFACE_ROOT/scripts"
SCRIPTS_LIB_DIR="$SURFACE_ROOT/scripts/lib"

if [ -d "$SCRIPTS_DIR" ]; then
  # Extract all *.sh references from SKILL.md.
  _skillmd_unresolved=()
  while IFS= read -r basename; do
    candidate="$SCRIPTS_DIR/$basename"
    candidate_lib="$SCRIPTS_LIB_DIR/$basename"
    candidate_skill="$SKILL_SCRIPTS/$basename"
    if [ -f "$candidate" ]; then
      SURFACE_FILES+=("$candidate")
    elif [ -f "$candidate_lib" ]; then
      SURFACE_FILES+=("$candidate_lib")
    elif [ -f "$candidate_skill" ]; then
      # Already collected by the find above — no need to add again.
      :
    else
      _skillmd_unresolved+=("$basename")
    fi
  done < <(grep -oE '[a-z][a-z0-9_-]+\.sh' "$SKILL_MD" | sort -u)
  # Fail closed: every .sh basename extracted from SKILL.md must resolve
  # to a real file. An unresolvable reference could conceal a board read.
  if [ "${#_skillmd_unresolved[@]}" -gt 0 ]; then
    _log "FAIL — unresolvable .sh reference(s) extracted from SKILL.md (fail-closed)"
    for ref in "${_skillmd_unresolved[@]}"; do
      _log "  unresolved: $ref (referenced in ${SKILL_MD#"$SURFACE_ROOT"/})"
    done
    _log "Cannot verify these scripts are board-free. Add the script or remove the reference."
    exit 1
  fi
fi

# Deduplicate (realpath may differ but basename collision is safe).
declare -A _seen
DEDUPED_FILES=()
for f in "${SURFACE_FILES[@]}"; do
  real="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  if [ -z "${_seen[$real]:-}" ]; then
    _seen[$real]=1
    DEDUPED_FILES+=("$real")
  fi
done
SURFACE_FILES=("${DEDUPED_FILES[@]}")

# ---------- transitive closure of source/invocation references ----------
#
# Iterate the surface. For each .sh file, extract source/dot directives
# and direct *.sh invocations. Resolve basenames to real files under
# scripts/ or scripts/lib/. Add new discoveries and repeat until no new
# files are found (fixed point). Unresolvable references fail closed.

# _resolve_script_ref — resolve a .sh reference to a real file.
# Accepts a bare basename (foo.sh) or a relative path (brain/foo.sh).
# Searches: scripts/<ref>, scripts/lib/<ref> (basename only), and the
# skill's own scripts/ dir. Returns 0 and prints the real path if found;
# returns 1 if not.
_resolve_script_ref() {
  local ref="$1"
  local candidate
  # 1. Try as-given under scripts/ (handles both bare and relative paths).
  candidate="$SCRIPTS_DIR/$ref"
  if [ -f "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  # 2. Try under scripts/lib/ (basename only — lib/ is flat).
  local bn
  bn="$(basename "$ref")"
  candidate="$SCRIPTS_LIB_DIR/$bn"
  if [ -f "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

# _extract_script_refs — emit .sh references (bare basenames or relative
# paths) found in a shell script's non-comment lines. Captures:
#   source "path/foo.sh", . "path/foo.sh", "$VAR/foo.sh",
#   "${VAR}/foo.sh", brain/foo.sh, lib/bar.sh, bare foo.sh.
_extract_script_refs() {
  local file="$1"
  # Skip non-.sh files (SKILL.md etc.) — they were handled by the
  # basename extraction above.
  case "$file" in *.sh) ;; *) return 0 ;; esac
  [ -r "$file" ] || return 0
  # Extract all *.sh references (with optional relative-path prefix)
  # from non-comment lines.
  grep -v '^\s*#' "$file" 2>/dev/null \
    | grep -oE '[a-z][a-z0-9_/-]*\.sh' \
    | sort -u
}

unresolved_refs=()
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  new_files=()
  for f in "${SURFACE_FILES[@]}"; do
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      # Try to resolve against scripts/ and scripts/lib/.
      resolved=$(_resolve_script_ref "$ref") || true
      if [ -z "$resolved" ]; then
        # Try relative to the referencing file's directory.
        rel_candidate="$(dirname "$f")/$ref"
        if [ -f "$rel_candidate" ]; then
          resolved="$rel_candidate"
        fi
      fi
      if [ -z "$resolved" ]; then
        # Check if the basename is already in the surface (self-ref or
        # already-collected skill script).
        bn_check="$(basename "$ref")"
        skill_candidate="$SKILL_SCRIPTS/$bn_check"
        if [ -f "$skill_candidate" ]; then
          continue  # already collected by the find above
        fi
        # Check the _seen set for any path ending in this basename.
        already_seen=0
        for seen_path in "${!_seen[@]}"; do
          if [ "$(basename "$seen_path")" = "$bn_check" ]; then
            already_seen=1
            break
          fi
        done
        if [ "$already_seen" -eq 1 ]; then
          continue
        fi
        # Genuinely unresolvable.
        unresolved_refs+=("$ref (referenced in ${f#"$SURFACE_ROOT"/})")
        continue
      fi
      real="$(cd "$(dirname "$resolved")" && pwd)/$(basename "$resolved")"
      if [ -z "${_seen[$real]:-}" ]; then
        _seen[$real]=1
        new_files+=("$real")
        changed=1
      fi
    done < <(_extract_script_refs "$f")
  done
  SURFACE_FILES+=("${new_files[@]}")
done

# Fail closed on unresolvable references — a reference we cannot resolve
# could be hiding a board read.
if [ "${#unresolved_refs[@]}" -gt 0 ]; then
  _log "FAIL — unresolvable source/invocation reference(s) in the sprint-plan surface (fail-closed)"
  for ref in "${unresolved_refs[@]}"; do
    _log "  unresolved: $ref"
  done
  _log "Cannot verify these files are board-free. Fix the reference or add the script."
  exit 1
fi

if [ "${#SURFACE_FILES[@]}" -eq 0 ]; then
  _die "surface file list is empty — guard mis-scoped (fail-closed)"
fi

# ---------- board-reference patterns ----------
#
# Match: the state-file path, the writer script name, the skill name,
# and the underscore variant.

PATTERNS=(
  'discovery-board\.yaml'
  'discovery-board\.sh'
  'gaia-discover'
  'discovery_board'
  'discovery-board'
)

# Build a single ERE alternation for grep.
PATTERN_ERE=""
for p in "${PATTERNS[@]}"; do
  if [ -z "$PATTERN_ERE" ]; then
    PATTERN_ERE="$p"
  else
    PATTERN_ERE="$PATTERN_ERE|$p"
  fi
done

# ---------- scan ----------

violations=0
violation_details=""

for f in "${SURFACE_FILES[@]}"; do
  if [ ! -r "$f" ]; then
    _die "surface file not readable: $f — cannot verify it is board-free (fail-closed)"
  fi
  if hits=$(grep -inE "$PATTERN_ERE" "$f" 2>/dev/null); then
    violations=$((violations + 1))
    rel="${f#"$SURFACE_ROOT"/}"
    violation_details="${violation_details}  ${rel}:\n"
    while IFS= read -r line; do
      violation_details="${violation_details}    ${line}\n"
    done <<< "$hits"
  fi
done

if [ "$violations" -gt 0 ]; then
  _log "FAIL — discovery-board reference(s) found in the sprint-plan surface"
  printf '%b' "$violation_details" >&2
  _log "The sprint-plan surface MUST have zero read paths to the discovery board."
  _log "Files scanned: ${#SURFACE_FILES[@]}"
  exit 1
fi

# ---------- pass ----------

_log "PASS — sprint-plan surface clean (${#SURFACE_FILES[@]} files scanned, 0 board references)"
exit 0
