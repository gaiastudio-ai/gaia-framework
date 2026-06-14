#!/usr/bin/env bash
# brain-reliance-loader.sh — the workflow-entry brain-context loader. Given the
# stage a workflow is ENTERING (a "<skill>:<stage-id>" composite), it resolves
# that stage's declared reliances from the hand-authored reliance map and, for
# each required brain node, checks whether the node is present in a cleanly
# parsed brain index. It then decides whether the workflow may proceed.
#
# WHAT IT DOES
#   brain_reliance_loader <skill>:<stage-id>
#       [--map <path>] [--index <path>]
#
#   Reads two knowledge-store files:
#     - the reliance map (.gaia/knowledge/brain-reliance-map.yaml) — the single
#       stage -> required-node source of truth.
#     - the brain index (.gaia/knowledge/brain-index.yaml) — the manifest the
#       node lookup runs against, reusing the same parse idiom as the read-only
#       brain query (PyYAML primary, awk fallback).
#
# THE DECISION (and its load-bearing fail-direction asymmetry)
#   The loader draws a sharp line between two outcomes:
#
#   1. CLEANLY-MISSING MANDATORY -> HALT (non-zero exit).
#      The map parses, the stage is declared, the index parses cleanly, and a
#      node the stage marks MANDATORY is genuinely absent from that index. This
#      is a real governance gap, so the loader HALTs with a diagnostic naming
#      BOTH the missing node AND the entering stage.
#
#   2. MISSING OPTIONAL -> WARN, exit 0.
#      A node marked OPTIONAL is absent. The loader emits a WARNING and
#      continues; an optional reliance never blocks entry.
#
#   3. UN-EVALUABLE -> WARN, exit 0 (fail OPEN).
#      The check itself cannot be performed cleanly. A governance-artifact fault
#      must never wedge every workflow, so an un-evaluable check fails OPEN: it
#      warns and lets the workflow proceed. A check is UN-EVALUABLE when:
#        - the reliance map is absent or malformed (cannot be parsed), OR
#        - the brain index is absent or corrupt (cannot be cleanly parsed into
#          entries), OR
#        - the entering stage id is not present in the map (no reliance is
#          declared, so there is nothing to evaluate).
#
#   The distinction between UN-EVALUABLE (fail OPEN) and CLEANLY-MISSING (HALT)
#   is explicit and cleanly factored here on purpose: a separate fail-CLOSED
#   gate targets the SAME un-evaluable input but rejects it. Both directions
#   must read the same classification; only the action on it differs. Keep the
#   `_brl_classify_*` helpers and the UN-EVALUABLE / CLEANLY-MISSING branch
#   labels intact so both consumers can target them.
#
# READ-ONLY BOUNDARY
#   The loader reads only the knowledge store (the reliance map + the brain
#   index). It NEVER reads or writes the agent-sidecar memory tree — there is no
#   memory path literal anywhere in this script, and it never echoes the memory
#   env var.
#
# EXIT-CODE CONTRACT
#   0 — proceed. Either all MANDATORY reliances are satisfied (any OPTIONAL
#       misses were warned), OR the check was un-evaluable and failed OPEN.
#   1 — HALT. A cleanly-evaluated, genuinely-missing MANDATORY node.
#   2 — usage error (missing stage argument, unreadable explicit --map/--index).
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags, no grep -P. LC_ALL=C. set -euo pipefail. Sourceable
# (functions become available; no side effects) AND executable (the dispatcher
# runs only when executed directly).

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Parse the brain index into a flat list of entry keys, one per line. PyYAML
# primary, awk fallback — the same dual idiom the read-only query uses, so the
# node lookup compares like for like. A parse that yields zero rows from a
# non-empty index signals corruption to the caller (see _brl_index_keys usage).
# Args: $1 index-path  $2 keys_out  $3 have_pyyaml
# Returns: 0 always (the caller distinguishes "parsed but empty" from "could not
#          parse" via the sentinel rc written to keys_out's companion).
# ---------------------------------------------------------------------------
_brl_parse_index_keys() {
  local index="$1" keys_out="$2" have_pyyaml="${3:-0}"
  : > "$keys_out"

  if [ "$have_pyyaml" = "1" ]; then
    # rc 0 on a clean parse (even of zero entries); rc 1 when PyYAML raises on
    # malformed YAML. The caller treats a non-zero rc as "index un-evaluable".
    python3 - "$index" "$keys_out" <<'PYEOF'
import sys, yaml
index, keys_out = sys.argv[1], sys.argv[2]
try:
    doc = yaml.safe_load(open(index))
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
entries = doc.get("entries")
if entries is None:
    entries = []
if not isinstance(entries, list):
    sys.exit(1)
with open(keys_out, "w") as kf:
    for e in entries:
        if not isinstance(e, dict):
            continue
        key = e.get("key", "")
        if key:
            kf.write("%s\n" % str(key).replace("\n", " ").replace("\r", " "))
sys.exit(0)
PYEOF
    return $?
  fi

  # awk fallback: pull each `- key:` line from the manifest's stable
  # two-space-indented form. A read failure or a manifest with no key lines
  # yields an empty keys_out; the caller's corruption heuristic handles it.
  awk '
    function unq(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"")
        v = substr(v, 2, length(v)-2)
      return v
    }
    /^[[:space:]]*- key:/ {
      v=$0; sub(/^[[:space:]]*- key:[[:space:]]*/, "", v); k=unq(v)
      if (k != "") print k
    }
  ' "$index" > "$keys_out" 2>/dev/null || return 1
  return 0
}

# _brl_index_key_present <key> <keys-file> — 0 when the index carries the key.
_brl_index_key_present() {
  local key="$1" keysf="$2"
  grep -qxF "$key" "$keysf" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Parse the reliance map for ONE stage's requires list into a flat table:
#   brain_node \t obligation     (one row per reliance entry)
# PyYAML primary, awk fallback. Writes the table to $reqs_out.
# Args: $1 map-path  $2 stage  $3 reqs_out  $4 have_pyyaml
# Returns:
#   0 — map parsed cleanly AND the stage is declared (reqs_out holds its rows,
#       possibly zero if the stage's requires list is empty).
#   1 — map could not be parsed (malformed) — UN-EVALUABLE.
#   3 — map parsed cleanly but the stage is NOT declared — UN-EVALUABLE
#       (unknown stage id).
# ---------------------------------------------------------------------------
_brl_parse_stage_requires() {
  local map="$1" stage="$2" reqs_out="$3" have_pyyaml="${4:-0}"
  : > "$reqs_out"

  if [ "$have_pyyaml" = "1" ]; then
    python3 - "$map" "$stage" "$reqs_out" <<'PYEOF'
import sys, yaml
mapf, stage, reqs_out = sys.argv[1], sys.argv[2], sys.argv[3]
def clean(v):
    return str(v).replace("\t", " ").replace("\n", " ").replace("\r", " ")
try:
    doc = yaml.safe_load(open(mapf))
except Exception:
    sys.exit(1)                       # malformed map -> un-evaluable
if not isinstance(doc, dict):
    sys.exit(1)
stages = doc.get("stages")
if stages is None:
    stages = {}
if not isinstance(stages, dict):
    sys.exit(1)
if stage not in stages:
    sys.exit(3)                       # unknown stage id -> un-evaluable
decl = stages.get(stage) or {}
requires = []
if isinstance(decl, dict):
    requires = decl.get("requires") or []
if not isinstance(requires, list):
    sys.exit(1)
with open(reqs_out, "w") as rf:
    for r in requires:
        if not isinstance(r, dict):
            continue
        node = clean(r.get("brain_node", "") or "")
        oblig = clean(r.get("obligation", "") or "")
        if node:
            rf.write("%s\t%s\n" % (node, oblig))
sys.exit(0)
PYEOF
    return $?
  fi

  # awk fallback. Stream the map, tracking the current stage key and, while
  # inside the target stage's `requires:` list, pairing each `- brain_node:`
  # with the `obligation:` that follows it. The map's stable two-space-indented
  # form mirrors the brain index. A YAML parse error cannot be detected by awk,
  # so the awk path treats a present-but-unstructured map as best-effort; the
  # PyYAML path (preferred on any host with PyYAML) is the authoritative
  # malformed-map detector. Returns 3 when the stage key is never seen.
  local found
  found="$(awk -v want="$stage" '
    function unq(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"")
        v = substr(v, 2, length(v)-2)
      return v
    }
    /^  [^ ].*:[[:space:]]*$/ {                 # a stage key line (two-space indent)
      k=$0; sub(/:[[:space:]]*$/, "", k); k=unq(k)
      cur = k
      in_req = 0
      if (k == want) seen = 1
      next
    }
    cur == want && /^    requires:/ { in_req = 1; next }
    cur == want && in_req && /^      - brain_node:/ {
      v=$0; sub(/^      - brain_node:[[:space:]]*/, "", v); node=unq(v); oblig=""
      next
    }
    cur == want && in_req && /^        obligation:/ {
      v=$0; sub(/^        obligation:[[:space:]]*/, "", v); oblig=unq(v)
      if (node != "") { print node "\t" oblig; node="" }
      next
    }
    END { if (seen) print "__SEEN__" > "/dev/stderr" }
  ' "$map" 2>"$reqs_out.seen")" || return 1

  printf '%s' "$found" > "$reqs_out"
  # Normalize: drop a possible trailing empty line, keep tab rows only.
  if [ -s "$reqs_out" ]; then
    grep -F "$(printf '\t')" "$reqs_out" > "$reqs_out.tmp" 2>/dev/null || true
    mv "$reqs_out.tmp" "$reqs_out" 2>/dev/null || true
  fi

  if grep -qF '__SEEN__' "$reqs_out.seen" 2>/dev/null; then
    rm -f "$reqs_out.seen" 2>/dev/null || true
    return 0
  fi
  rm -f "$reqs_out.seen" 2>/dev/null || true
  return 3                                       # stage not declared -> un-evaluable
}

# _brl_warn MSG — emit an un-evaluable / optional WARNING to stderr.
_brl_warn() {
  printf 'brain-reliance-loader.sh: WARNING: %s\n' "$1" >&2
}

# _brl_halt NODE STAGE — emit the HALT diagnostic (names node + stage) to stderr.
_brl_halt() {
  printf 'brain-reliance-loader.sh: HALT: stage %s relies on MANDATORY brain node %s, which is absent from a cleanly-parsed brain index.\n' \
    "$2" "$1" >&2
}

# ---------------------------------------------------------------------------
# brain_reliance_loader <skill>:<stage-id> [--map <path>] [--index <path>]
# ---------------------------------------------------------------------------
brain_reliance_loader() {
  local stage="" map="" index=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --map)
        if [ "$#" -lt 2 ]; then
          printf 'brain-reliance-loader.sh: --map requires a path\n' >&2; return 2
        fi
        map="$2"; shift 2 ;;
      --index)
        if [ "$#" -lt 2 ]; then
          printf 'brain-reliance-loader.sh: --index requires a path\n' >&2; return 2
        fi
        index="$2"; shift 2 ;;
      --*) printf 'brain-reliance-loader.sh: unknown flag: %s\n' "$1" >&2; return 2 ;;
      *)
        if [ -z "$stage" ]; then stage="$1"; else
          printf 'brain-reliance-loader.sh: unexpected argument: %s\n' "$1" >&2; return 2
        fi
        shift ;;
    esac
  done

  if [ -z "$stage" ]; then
    printf 'brain-reliance-loader.sh: a stage id (<skill>:<stage-id>) is required\n' >&2
    return 2
  fi

  # --- Resolve canonical knowledge paths via the shared helper ---
  local self_dir lib
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  lib="$self_dir/../lib/gaia-paths.sh"
  # shellcheck source=../lib/gaia-paths.sh
  . "$lib" || { printf 'brain-reliance-loader.sh: could not source gaia-paths.sh\n' >&2; return 2; }

  local knowledge_dir="$GAIA_KNOWLEDGE_DIR"
  [ -n "$map" ]   || map="$knowledge_dir/brain-reliance-map.yaml"
  [ -n "$index" ] || index="$knowledge_dir/brain-index.yaml"

  # An explicit override that is set-but-unreadable is a usage error; a default
  # path that is simply absent is an UN-EVALUABLE condition handled below.
  : "$map" "$index"

  # Probe PyYAML once for both parses.
  local have_pyyaml=0
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    have_pyyaml=1
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/brl.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' 2>/dev/null || true" RETURN

  # =========================================================================
  # UN-EVALUABLE branch 1: reliance map absent or malformed -> fail OPEN.
  # =========================================================================
  if [ ! -r "$map" ]; then
    _brl_warn "reliance map not found at $map — check is un-evaluable; proceeding (fail-open)."
    return 0
  fi

  local reqs="$tmp/reqs.tsv"
  local stage_rc=0
  _brl_parse_stage_requires "$map" "$stage" "$reqs" "$have_pyyaml" || stage_rc=$?
  case "$stage_rc" in
    0) : ;;   # map parsed, stage declared
    3)
      # UN-EVALUABLE branch 2: unknown stage id (not declared in the map).
      _brl_warn "stage $stage is not declared in the reliance map — nothing to evaluate; proceeding (fail-open)."
      return 0
      ;;
    *)
      # UN-EVALUABLE branch 1 (malformed map).
      _brl_warn "reliance map at $map could not be parsed (malformed) — check is un-evaluable; proceeding (fail-open)."
      return 0
      ;;
  esac

  # A stage that declares no requirements is trivially satisfied.
  if [ ! -s "$reqs" ]; then
    return 0
  fi

  # =========================================================================
  # UN-EVALUABLE branch 3: brain index absent or corrupt -> fail OPEN.
  # The index lookup is what tells CLEANLY-MISSING apart from un-evaluable, so a
  # non-parseable index forces the whole check open BEFORE any HALT decision.
  # =========================================================================
  if [ ! -r "$index" ]; then
    _brl_warn "brain index not found at $index — node presence is un-evaluable; proceeding (fail-open)."
    return 0
  fi

  local keys="$tmp/keys.txt"
  local index_rc=0
  _brl_parse_index_keys "$index" "$keys" "$have_pyyaml" || index_rc=$?
  if [ "$index_rc" -ne 0 ]; then
    _brl_warn "brain index at $index could not be parsed (corrupt) — node presence is un-evaluable; proceeding (fail-open)."
    return 0
  fi

  # An index file that is non-empty yet yields zero keys is treated as corrupt
  # (un-evaluable), NOT as a clean index in which every MANDATORY node is
  # missing — the latter would mis-HALT on a garbled manifest. Only when the
  # index is genuinely empty-but-well-formed (the S1 ship state has no entries
  # yet) do we proceed to the clean lookup, where every node is cleanly absent.
  if [ ! -s "$keys" ] && [ -s "$index" ]; then
    # Distinguish a well-formed empty index from a corrupt one. The PyYAML path
    # already returned rc 0 only on a clean parse, so an empty keys file there
    # means a genuinely empty (but valid) entries list -> clean lookup. The awk
    # fallback cannot make that distinction, so it conservatively fails OPEN.
    if [ "$have_pyyaml" != "1" ]; then
      _brl_warn "brain index at $index yielded no entries under the fallback parser — node presence is un-evaluable; proceeding (fail-open)."
      return 0
    fi
  fi

  # =========================================================================
  # CLEANLY-MISSING decision. The map parsed, the stage is declared, and the
  # index parsed cleanly. Now every node lookup is a clean evaluation: a missing
  # MANDATORY node is a genuine governance gap (HALT); a missing OPTIONAL node
  # is a warning (continue).
  # =========================================================================
  local node oblig halt=0
  while IFS="$(printf '\t')" read -r node oblig; do
    [ -n "$node" ] || continue
    if _brl_index_key_present "$node" "$keys"; then
      continue
    fi
    # The node is cleanly missing. Branch on the obligation.
    case "$oblig" in
      MANDATORY)
        _brl_halt "$node" "$stage"
        halt=1
        ;;
      *)
        # OPTIONAL (or any non-MANDATORY obligation): warn and continue.
        _brl_warn "stage $stage relies on OPTIONAL brain node $node, which is absent — continuing."
        ;;
    esac
  done < "$reqs"

  if [ "$halt" -eq 1 ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  brain_reliance_loader "$@"
  exit $?
fi
