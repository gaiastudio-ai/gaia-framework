#!/usr/bin/env bash
# brain-health.sh — the brain knowledge layer's health view: list every node the
# C2 four-source predicate classifies as UNLINKED (no governance traceability).
#
# WHAT IT DOES
#   Reads the committed brain-index.yaml manifest, and for every entry RE-DERIVES
#   the "unlinked" verdict by calling the harvester's four-source linked predicate
#   (frontmatter traces_to / frontmatter epic / an epics-prose Allocates row / a
#   traceability-matrix mapping). It then lists every unlinked node, sorted, with
#   a count. An unlinked node is a TRACEABILITY GAP — a passive quality signal a
#   human browses on demand, NEVER a failure: this view always exits 0 when the
#   manifest is readable.
#
# WHY RE-DERIVE (rather than read a stored flag)
#   The manifest entry schema is closed (additionalProperties:false) and does NOT
#   carry an `unlinked` field — the reindex sweep deliberately strips it. The C2
#   predicate is the single source of truth for "linked"; re-deriving through it
#   keeps this view pure-read, cannot drift from C2 (it IS C2), and needs no
#   schema change.
#
# SOURCING NOTE (the harvester's file-scope set -euo pipefail)
#   harvest-edges.sh runs `set -euo pipefail` + `export LC_ALL=C` at FILE SCOPE;
#   those execute the moment we source it. The four-source predicate returns
#   NON-ZERO for an unlinked node BY DESIGN. Under the inherited `set -e` a bare
#   `_is_node_linked ...` call for an unlinked node would abort this script. So we
#   source the harvester, then `set +e` around the predicate loop and test the
#   return code explicitly. We also source gaia-paths.sh FIRST so the path-helper
#   FUNCTIONS (e.g. canonicalize) are defined in THIS process — the env-var path
#   constants do not bring the functions across, and the harvester only re-sources
#   the helper lazily inside harvest_node_edges, not on the predicate path.
#
# Portability: bash 3.2 clean — no mapfile, no associative arrays, no GNU-only
# flags, no grep -P. LC_ALL=C. Sourceable AND executable.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Parse (key TAB path) pairs from the manifest. PyYAML primary, awk fallback.
# Args: $1 manifest  $2 out_pairs_file  $3 have_pyyaml
# ---------------------------------------------------------------------------
_bh_parse_pairs() {
  local manifest="$1" out="$2" have_pyyaml="${3:-0}"
  : > "$out"
  [ -r "$manifest" ] || return 0

  if [ "$have_pyyaml" = "1" ]; then
    python3 - "$manifest" "$out" <<'PYEOF' || true
import sys, yaml
manifest, out = sys.argv[1], sys.argv[2]
try:
    doc = yaml.safe_load(open(manifest)) or {}
except Exception:
    doc = {}
entries = doc.get("entries") or []
with open(out, "w") as f:
    for e in entries:
        key = e.get("key", "")
        path = e.get("path", "")
        if not key:
            continue
        key = str(key).replace("\t", " ").replace("\n", " ").replace("\r", " ")
        path = str(path).replace("\t", " ").replace("\n", " ").replace("\r", " ")
        f.write("%s\t%s\n" % (key, path))
PYEOF
    return 0
  fi

  # awk fallback: pull the `- key:` / `  path:` scalar pairs.
  awk '
    function unq(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"")
        v = substr(v, 2, length(v)-2)
      return v
    }
    /^- key:/ {
      if (key != "") print key "\t" path
      v=$0; sub(/^- key:[[:space:]]*/, "", v); key=unq(v); path=""
      next
    }
    key != "" && /^  path:/ {
      v=$0; sub(/^  path:[[:space:]]*/, "", v); path=unq(v)
      next
    }
    END { if (key != "") print key "\t" path }
  ' "$manifest" >> "$out" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# brain_health [--manifest <path>]
#   List the C2-unlinked nodes from the manifest. Always exit 0 when the manifest
#   is readable (an unlinked node is a quality signal, never a failure). A missing
#   manifest prints an explanatory line and still exits 0.
# ---------------------------------------------------------------------------
brain_health() {
  local manifest=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="$2"; shift 2 ;;
      *) printf 'brain-health.sh: unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  # --- Resolve canonical paths (functions + constants) ---
  local self_dir lib
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  lib="$self_dir/../lib/gaia-paths.sh"
  # shellcheck source=../lib/gaia-paths.sh
  . "$lib" || { printf 'brain-health.sh: could not source gaia-paths.sh\n' >&2; return 2; }

  local knowledge_dir="$GAIA_KNOWLEDGE_DIR"
  local artifacts_dir="$GAIA_ARTIFACTS_DIR"
  [ -n "$manifest" ] || manifest="$knowledge_dir/brain-index.yaml"

  # The shared edge sources for the predicate.
  local epics_file="$artifacts_dir/planning-artifacts/epics-and-stories.md"
  local matrix_file="$artifacts_dir/test-artifacts/strategy/traceability-matrix.md"

  # Project root for resolving each entry's relative path to an absolute path.
  local proj_root
  proj_root="$(_gaia_paths_canonicalize "${CLAUDE_PROJECT_ROOT:-$PWD}")"

  # --- Missing manifest → explanatory line, exit 0 ---
  if [ ! -r "$manifest" ]; then
    printf 'Brain health: no brain index manifest found at %s\n' "$manifest"
    printf 'Run /gaia-brain-reindex to build the index, then re-run this view.\n'
    return 0
  fi

  # --- Source the harvester for the C2 predicate (see SOURCING NOTE) ---
  local harvester="$self_dir/harvest-edges.sh"
  if [ -r "$harvester" ]; then
    # shellcheck source=harvest-edges.sh
    . "$harvester" || { printf 'brain-health.sh: could not source harvest-edges.sh\n' >&2; return 2; }
  else
    printf 'brain-health.sh: harvester not found at %s\n' "$harvester" >&2
    return 2
  fi

  # Probe PyYAML once for the manifest parse.
  local have_pyyaml=0
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    have_pyyaml=1
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/bh.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' 2>/dev/null || true" RETURN

  local pairs="$tmp/pairs.tsv"
  _bh_parse_pairs "$manifest" "$pairs" "$have_pyyaml"

  # --- Per-entry C2 re-derivation ---
  # The predicate returns NON-ZERO for an unlinked node by design; disable -e for
  # the loop and test the return code explicitly so an unlinked node never aborts.
  local unlinked_list="$tmp/unlinked.txt"
  : > "$unlinked_list"
  local key relpath abspath
  set +e
  while IFS="$(printf '\t')" read -r key relpath; do
    [ -n "$key" ] || continue
    # Resolve the entry path to an absolute file (best-effort; a missing file is
    # handled gracefully by the predicate, which no-ops on unreadable inputs).
    case "$relpath" in
      /*) abspath="$relpath" ;;
      *)  abspath="$proj_root/$relpath" ;;
    esac
    _is_node_linked "$key" "$epics_file" "$matrix_file" "$abspath"
    if [ "$?" -ne 0 ]; then
      printf '%s\t%s\n' "$key" "$relpath" >> "$unlinked_list"
    fi
  done < "$pairs"
  set -e

  # --- Render the deterministic, sorted report ---
  local count
  count="$(LC_ALL=C sort -u "$unlinked_list" | grep -c . || true)"
  [ -n "$count" ] || count=0

  printf 'Brain health — unlinked nodes (traceability gaps)\n'
  printf '\n'
  if [ "$count" -eq 0 ]; then
    printf 'No unlinked nodes — every indexed artifact carries a governance link.\n'
    printf '\n'
    printf 'Unlinked node count: 0\n'
    return 0
  fi

  printf 'The following %s node(s) carry no governance link (no traces_to, no\n' "$count"
  printf 'epic, no epics Allocates row, no traceability-matrix mapping). A gap here\n'
  printf 'is a signal to add traceability, not an error.\n'
  printf '\n'
  LC_ALL=C sort -u "$unlinked_list" | while IFS="$(printf '\t')" read -r key relpath; do
    [ -n "$key" ] || continue
    printf -- '- %s  (%s)\n' "$key" "$relpath"
  done
  printf '\n'
  printf 'Unlinked node count: %s\n' "$count"
  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  brain_health "$@"
  exit $?
fi
