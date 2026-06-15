#!/usr/bin/env bash
# gaia-brain-query.sh — the READ half of the brain knowledge layer. From a seed
# story key it walks the committed manifest's typed edges and returns that node's
# GOVERNANCE ENVELOPE — the related nodes grouped by direction — in a single
# read-only invocation. It is the query counterpart to the reindex sweep (the
# sole writer): this script NEVER writes anything and reads only the knowledge
# store (the manifest) plus the artifact / state roots (for the read-time
# content-hash freshness check).
#
# WHAT IT DOES
#   gaia_brain_query <key> [--manifest <path>] [--envelope | --search <terms> | --health]
#
#   --envelope (DEFAULT): from the seed key, return the related nodes grouped by
#     direction —
#       UP      — the governance chain ABOVE the node: the requirements it
#                 implements, the decisions that govern it, and its PARENT epic.
#       DOWN    — the artifacts BELOW the node: the tests that verify it and the
#                 reviews that gated it.
#       LATERAL — the design artifacts that sit ALONGSIDE the node.
#     UP is a bounded transitive walk up the parent-epic / requirement / decision
#     chain (depth-capped, cycle-guarded). DOWN and LATERAL are a single hop from
#     the seed. The render is deterministic — sorted by direction, then by the
#     canonical edge-type rank, then by target.
#   --health: delegate to the brain-health view (the unlinked-node report) as a
#     clean subprocess.
#   --search <terms>: a thin grep over the indexed synopses. (See the SCOPE note.)
#
# READ-TIME CONTENT-HASH FALL-THROUGH
#   When the query surfaces a node's synopsis, it recomputes the sha256 of the
#   node's canonical file and compares it to the hash the manifest stamped at
#   index time. On a MISMATCH (the file changed since the last reindex) or a
#   MISSING file, the node is marked STALE and the canonical PATH is surfaced so
#   the caller can read the current bytes — the possibly-out-of-date stored
#   synopsis is NOT served as if it were current. The query surfaces the path,
#   never the file bytes, so its output stays bounded regardless of file size.
#
# READ-ONLY BOUNDARY
#   The query reads the knowledge store (the manifest) and the artifact / state
#   roots (canonical files, for the freshness check). It NEVER reads or writes the
#   agent-sidecar memory tree — there is no memory path literal anywhere in this
#   script, and it never echoes the memory env var. The boundary holds in both
#   directions: the ground-truth refresh likewise never reads the knowledge store.
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags, no grep -P. LC_ALL=C. set -euo pipefail. Sourceable
# (functions become available; no side effects) AND executable (the dispatcher
# runs only when executed directly).

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# sha256 of a file → bare hex digest. Dual idiom (Linux sha256sum / macOS
# shasum) mirrors the reindex writer so the read-time check compares like for
# like.
# ---------------------------------------------------------------------------
_bq_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

# ---------------------------------------------------------------------------
# _bq_node_is_fresh <abs-or-rel-path> <stored-hash> <root-canonical> <mem-subtree>
#   0 (fresh) when the file exists, resolves UNDER the project root but NOT
#   inside the agent-sidecar memory subtree, AND its recomputed sha256 equals
#   the stored hash; non-zero (NOT fresh / unverifiable) otherwise.
#
#   A relative path is resolved against <root-canonical> (falling back to
#   ${CLAUDE_PROJECT_ROOT:-$PWD} when that arg is empty, e.g. a direct unit
#   call). An empty stored hash is treated as not-fresh (we cannot prove
#   freshness).
#
#   READ-ONLY BOUNDARY HARDENING (defense in depth): the manifest is written by
#   a trusted process, but the read-only boundary is this script's core security
#   contract, so we never trust a manifest `path` blindly. Before opening the
#   canonical file we CANONICALIZE the resolved path (collapsing any `..`
#   traversal) and verify it is UNDER the project root and OUTSIDE the memory
#   subtree. A path that escapes the root or lands inside memory is treated as
#   STALE/unverifiable and is NEVER opened — the caller falls through to
#   surfacing the path, exactly as for a content-hash mismatch.
# ---------------------------------------------------------------------------
_bq_node_is_fresh() {
  local path="$1" stored="$2" root_canon="${3:-}" mem_subtree="${4:-}" abspath
  [ -n "$stored" ] || return 1
  local root="${root_canon:-${CLAUDE_PROJECT_ROOT:-$PWD}}"
  case "$path" in
    /*) abspath="$path" ;;
    *)  abspath="$root/$path" ;;
  esac

  # Canonicalize and enforce the read-only boundary BEFORE any file read.
  local canon
  canon="$(_gaia_paths_canonicalize "$abspath" 2>/dev/null || true)"
  [ -n "$canon" ] || return 1
  # Must resolve under the project root.
  _gaia_paths_under_root "$canon" "$root" || return 1
  # Must NOT resolve inside the agent-sidecar memory subtree.
  if [ -n "$mem_subtree" ] && _gaia_paths_under_root "$canon" "$mem_subtree"; then
    return 1
  fi

  [ -f "$canon" ] || return 1
  local actual
  actual="$(_bq_sha256_file "$canon")"
  [ "$actual" = "$stored" ]
}

# ---------------------------------------------------------------------------
# Edge-type → governance direction. The seven closed-enum edge types map to the
# three envelope directions:
#   UP      = implements + traces-to + governed-by  (requirements + decisions)
#             + parent-`decomposes` (the EPIC the story belongs to).
#   DOWN    = verified-by + reviewed-in             (tests + reviews).
#   LATERAL = designs                                (design artifacts).
#
# DELIBERATE parent-`decomposes` UP-CLASSIFICATION (divergence note): the edge
# model's literal grouping lists `decomposes` under the lateral/sibling family,
# because the harvester emits `decomposes` for BOTH the parent epic AND sibling
# stories (from blocks / depends_on). For the governance ENVELOPE we classify the
# parent-EPIC decomposes edge as UP — the epic genuinely sits up the governance
# chain from the story. We DELIBERATELY traverse ONLY the parent-epic decomposes
# edge as UP, never the child/sibling decomposes edges (those would descend into
# sibling sub-stories and bloat the envelope). The parent-epic edge is recognised
# by its EPIC token shape (E<n>, no -S<n> suffix); a sibling story token
# (E<n>-S<n>) is excluded from the UP walk.
# ---------------------------------------------------------------------------
_bq_edge_direction() {
  case "$1" in
    implements|traces-to|governed-by) printf 'UP' ;;
    decomposes)                       printf 'UP' ;;  # parent-epic only; see note
    verified-by|reviewed-in)          printf 'DOWN' ;;
    designs)                          printf 'LATERAL' ;;
    *)                                printf '' ;;
  esac
}

# _bq_edge_type_rank <type> — stable numeric rank for deterministic ordering,
# matching the harvester's canonical enum order.
_bq_edge_type_rank() {
  case "$1" in
    implements)  echo 1 ;;
    traces-to)   echo 2 ;;
    decomposes)  echo 3 ;;
    governed-by) echo 4 ;;
    verified-by) echo 5 ;;
    reviewed-in) echo 6 ;;
    designs)     echo 7 ;;
    *)           echo 9 ;;
  esac
}

# _bq_direction_rank <direction> — stable order UP < DOWN < LATERAL.
_bq_direction_rank() {
  case "$1" in
    UP)      echo 1 ;;
    DOWN)    echo 2 ;;
    LATERAL) echo 3 ;;
    *)       echo 9 ;;
  esac
}

# _bq_is_epic_token <token> — 0 when the token is an EPIC key (E<n> with no
# -S<n> story suffix). Drives the parent-epic-only UP traversal of decomposes.
_bq_is_epic_token() {
  case "$1" in
    E[0-9]*-S[0-9]*) return 1 ;;   # story token — NOT an epic
    E[0-9]*)         return 0 ;;   # epic token
    *)               return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Parse the manifest into three flat, line-indexed lookup files (bash 3.2 has no
# associative arrays). PyYAML primary, awk fallback. Writes:
#   $2 = records  (key \t path \t content_hash \t synopsis \t tags)  one row per entry
#   $3 = edges    (seedkey \t type \t target)                        one row per edge
# Tags column is a comma-joined string of the entry's `tags` array values.
# Args: $1 manifest  $2 records_out  $3 edges_out  $4 have_pyyaml
# ---------------------------------------------------------------------------
_bq_parse_manifest() {
  local manifest="$1" rec_out="$2" edge_out="$3" have_pyyaml="${4:-0}"
  : > "$rec_out"
  : > "$edge_out"
  [ -r "$manifest" ] || return 0

  if [ "$have_pyyaml" = "1" ]; then
    python3 - "$manifest" "$rec_out" "$edge_out" <<'PYEOF' || true
import sys, yaml
manifest, rec_out, edge_out = sys.argv[1], sys.argv[2], sys.argv[3]
def clean(v):
    return str(v).replace("\t", " ").replace("\n", " ").replace("\r", " ")
try:
    doc = yaml.safe_load(open(manifest)) or {}
except Exception:
    doc = {}
entries = doc.get("entries") or []
with open(rec_out, "w") as rf, open(edge_out, "w") as ef:
    for e in entries:
        key = e.get("key", "")
        if not key:
            continue
        key = clean(key)
        path = clean(e.get("path", "") or "")
        trust = e.get("trust") or {}
        ch = clean(trust.get("content_hash", "") or "")
        syn = e.get("synopsis", "")
        syn = clean("" if syn is None else syn)
        st = clean(e.get("source_type", "") or "")
        tags = ",".join(clean(t) for t in (e.get("tags") or []))
        rf.write("%s\t%s\t%s\t%s\t%s\t%s\n" % (key, path, ch, syn, st, tags))
        for ed in (e.get("edges") or []):
            t = clean(ed.get("type", "") or "")
            tgt = clean(ed.get("target", "") or "")
            if t and tgt:
                ef.write("%s\t%s\t%s\n" % (key, t, tgt))
PYEOF
    return 0
  fi

  # awk fallback: stream the manifest, tracking the current entry's scalar fields
  # and its nested edges list. The manifest shape is the reindex writer's stable
  # two-space-indented form.
  awk '
    function unq(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"")
        v = substr(v, 2, length(v)-2)
      return v
    }
    function flush_rec() {
      if (key != "") print key "\t" path "\t" chash "\t" syn "\t" st "\t" tags > recf
    }
    /^- key:/ {
      flush_rec()
      v=$0; sub(/^- key:[[:space:]]*/, "", v); key=unq(v)
      path=""; chash=""; syn=""; st=""; tags=""; in_edges=0; in_tags=0; cur_type=""
      next
    }
    key != "" && /^  source_type:/ { v=$0; sub(/^  source_type:[[:space:]]*/, "", v); st=unq(v); in_tags=0; next }
    key != "" && /^  path:/        { v=$0; sub(/^  path:[[:space:]]*/, "", v); path=unq(v); in_tags=0; next }
    key != "" && /^  synopsis:/    { v=$0; sub(/^  synopsis:[[:space:]]*/, "", v); syn=unq(v); in_tags=0; next }
    key != "" && /^    content_hash:/ { v=$0; sub(/^    content_hash:[[:space:]]*/, "", v); chash=unq(v); in_tags=0; next }
    key != "" && /^  tags:/        { in_tags=1; in_edges=0; next }
    key != "" && /^  edges:/       { in_edges=1; in_tags=0; next }
    key != "" && /^  trust:/       { in_edges=0; in_tags=0; next }
    key != "" && /^  fetched_at:/  { in_tags=0; next }
    in_tags && /^  - / {
      v=$0; sub(/^  - [[:space:]]*/, "", v); v=unq(v)
      if (tags == "") tags = v; else tags = tags "," v
      next
    }
    in_edges && /^    - type:/     { v=$0; sub(/^    - type:[[:space:]]*/, "", v); cur_type=unq(v); next }
    in_edges && /^      target:/   {
      v=$0; sub(/^      target:[[:space:]]*/, "", v); tgt=unq(v)
      if (cur_type != "" && tgt != "") print key "\t" cur_type "\t" tgt > edgef
      next
    }
    END { flush_rec() }
  ' recf="$rec_out" edgef="$edge_out" "$manifest" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Lookups over the flat record/edge tables (no associative arrays).
# ---------------------------------------------------------------------------

# _bq_record_field <key> <records-file> <field-index 2..4> — echo the field
# (path=2, content_hash=3, synopsis=4) for the first matching record, or empty.
_bq_record_field() {
  local key="$1" recf="$2" idx="$3"
  awk -F'\t' -v k="$key" -v i="$idx" '$1 == k { print $i; exit }' "$recf"
}

# _bq_key_exists <key> <records-file> — 0 when a record carries the key.
_bq_key_exists() {
  local key="$1" recf="$2"
  awk -F'\t' -v k="$key" 'BEGIN{f=1} $1 == k {f=0; exit} END{exit f}' "$recf"
}

# _bq_edges_for <key> <edges-file> — echo `type \t target` for the key's edges.
_bq_edges_for() {
  local key="$1" edgef="$2"
  awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $3 }' "$edgef"
}

# ---------------------------------------------------------------------------
# UP transitive walk. From the seed, follow ONLY the UP edges — requirements
# (implements), traces-to, decisions (governed-by), and the parent-EPIC
# decomposes edge — up the governance chain. Depth-capped + visited-set guarded
# so a cycle or a deep chain always terminates. DOWN / LATERAL are single-hop, so
# only UP needs the transitive walk.
#
# Emits `direction \t type \t target` lines for every UP edge discovered.
# Args: $1 seed-key  $2 edges-file  $3 visited-file (sorted scratch)
# ---------------------------------------------------------------------------
_BQ_UP_DEPTH_CAP=4

_bq_walk_up() {
  local seed="$1" edgef="$2" visited="$3"
  local frontier next depth=0
  : > "$visited"
  frontier="$seed"

  while [ -n "$frontier" ] && [ "$depth" -lt "$_BQ_UP_DEPTH_CAP" ]; do
    next=""
    local node
    # Iterate the current frontier (newline-separated).
    while IFS= read -r node; do
      [ -n "$node" ] || continue
      # Cycle guard: skip an already-visited node.
      if grep -qxF "$node" "$visited" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$node" >> "$visited"
      # Walk this node's UP edges.
      local etype target dir
      while IFS="$(printf '\t')" read -r etype target; do
        [ -n "$etype" ] || continue
        dir="$(_bq_edge_direction "$etype")"
        [ "$dir" = "UP" ] || continue
        # decomposes is UP ONLY for the parent epic; a sibling-story decomposes
        # target is excluded (it would descend into sibling sub-stories).
        if [ "$etype" = "decomposes" ]; then
          _bq_is_epic_token "$target" || continue
        fi
        printf 'UP\t%s\t%s\n' "$etype" "$target"
        # Enqueue the target for the next depth level so the chain (story → epic
        # → requirement → decision) is followed transitively.
        next="$next$target"$'\n'
      done < <(_bq_edges_for "$node" "$edgef")
    done < <(printf '%s\n' "$frontier")
    frontier="$next"
    depth=$((depth + 1))
  done
}

# ---------------------------------------------------------------------------
# Render the governance envelope for a seed key.
# ---------------------------------------------------------------------------
_bq_render_envelope() {
  local seed="$1" recf="$2" edgef="$3" tmproot="$4" root_canon="$5" mem_subtree="$6"

  # --- Unknown key: report unresolved, exit 0 (never an error) ---
  if ! _bq_key_exists "$seed" "$recf"; then
    printf 'Brain query — governance envelope for %s\n\n' "$seed"
    printf 'Unresolved reference: no manifest entry for %s.\n' "$seed"
    printf 'Run /gaia-brain-reindex if this key should be indexed.\n'
    return 0
  fi

  local seed_path seed_hash seed_syn
  seed_path="$(_bq_record_field "$seed" "$recf" 2)"
  seed_hash="$(_bq_record_field "$seed" "$recf" 3)"
  seed_syn="$(_bq_record_field "$seed" "$recf" 4)"

  # --- Seed header with C1 read-time freshness ---
  printf 'Brain query — governance envelope for %s\n\n' "$seed"
  if _bq_node_is_fresh "$seed_path" "$seed_hash" "$root_canon" "$mem_subtree"; then
    printf 'Node: %s\n' "$seed"
    [ -n "$seed_syn" ] && printf '  %s\n' "$seed_syn"
  else
    printf 'Node: %s  [stale: read canonical %s]\n' "$seed" "$seed_path"
  fi
  printf '\n'

  # --- Collect the envelope edges ---
  # UP = bounded transitive walk; DOWN / LATERAL = single hop from the seed.
  # Scratch files live UNDER the caller-owned temp root ($tmproot). We do NOT
  # install our own RETURN trap here: a nested RETURN trap would CLOBBER the
  # outer gaia_brain_query cleanup trap and leak the outer temp dir. The outer
  # function owns all cleanup for the whole invocation.
  local tmp="$tmproot/render"
  mkdir -p "$tmp"

  local collected="$tmp/collected.tsv"   # direction \t type \t target
  : > "$collected"
  local visited="$tmp/visited.txt"

  # UP (transitive). The walk starts AT the seed but emits only the seed's own
  # UP edges and those of the nodes it reaches — never the seed itself.
  _bq_walk_up "$seed" "$edgef" "$visited" >> "$collected" || true

  # DOWN + LATERAL: single hop from the seed.
  local etype target dir
  while IFS="$(printf '\t')" read -r etype target; do
    [ -n "$etype" ] || continue
    dir="$(_bq_edge_direction "$etype")"
    case "$dir" in
      DOWN|LATERAL) printf '%s\t%s\t%s\n' "$dir" "$etype" "$target" >> "$collected" ;;
    esac
  done < <(_bq_edges_for "$seed" "$edgef")

  # --- Render each direction group, deterministically sorted ---
  # Sort key: direction-rank, edge-type-rank, target. Build a sortable table.
  local sortable="$tmp/sortable.tsv"   # drank \t erank \t direction \t type \t target
  : > "$sortable"
  while IFS="$(printf '\t')" read -r dir etype target; do
    [ -n "$dir" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(_bq_direction_rank "$dir")" "$(_bq_edge_type_rank "$etype")" \
      "$dir" "$etype" "$target" >> "$sortable"
  done < "$collected"

  local sorted="$tmp/sorted.tsv"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n -k5,5 "$sortable" 2>/dev/null \
    | LC_ALL=C uniq > "$sorted" || true

  local d
  for d in UP DOWN LATERAL; do
    printf '%s:\n' "$d"
    local n
    n="$(awk -F'\t' -v dd="$d" '$3 == dd' "$sorted" | grep -c . || true)"
    [ -n "$n" ] || n=0
    if [ "$n" -eq 0 ]; then
      printf '  (no %s edges)\n' "$d"
    else
      awk -F'\t' -v dd="$d" '$3 == dd { print $3 "  " $4 "  " $5 }' "$sorted" \
        | while IFS= read -r line; do
            printf '  %s\n' "$line"
          done
    fi
    printf '\n'
  done

  return 0
}

# ---------------------------------------------------------------------------
# gaia_brain_query <key> [--manifest <path>] [--envelope|--search <terms>|--health]
# ---------------------------------------------------------------------------
gaia_brain_query() {
  local key="" manifest="" mode="envelope" search_terms="" category_tag=""
  # First positional non-flag arg is the seed key.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest)
        if [ "$#" -lt 2 ]; then
          printf 'gaia-brain-query.sh: --manifest requires a path\n' >&2; return 2
        fi
        manifest="$2"; shift 2 ;;
      --envelope) mode="envelope"; shift ;;
      --health)   mode="health"; shift ;;
      --search)
        # Guard the $2 access BEFORE touching it: under `set -u` a bare
        # `--search` with no trailing term would otherwise abort with an
        # unbound-variable crash instead of the friendly usage error below.
        mode="search"
        if [ "$#" -lt 2 ]; then
          printf 'gaia-brain-query.sh: --search requires a term\n' >&2; return 2
        fi
        search_terms="$2"; shift 2 ;;
      --category)
        mode="category"
        if [ "$#" -lt 2 ]; then
          printf 'gaia-brain-query.sh: --category requires a tag\n' >&2; return 2
        fi
        category_tag="$2"; shift 2 ;;
      --*) printf 'gaia-brain-query.sh: unknown flag: %s\n' "$1" >&2; return 2 ;;
      *)
        if [ -z "$key" ]; then key="$1"; else
          printf 'gaia-brain-query.sh: unexpected argument: %s\n' "$1" >&2; return 2
        fi
        shift ;;
    esac
  done

  # --- Resolve canonical paths (functions + constants) ---
  local self_dir lib
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  lib="$self_dir/../lib/gaia-paths.sh"
  # shellcheck source=../lib/gaia-paths.sh
  . "$lib" || { printf 'gaia-brain-query.sh: could not source gaia-paths.sh\n' >&2; return 2; }

  # --- --health: delegate to the brain-health view as a clean subprocess ---
  # Clear the path-helper source guard for the child: this process has already
  # sourced gaia-paths.sh and exported _GAIA_PATHS_LOADED, but the helper
  # FUNCTIONS do not cross the process boundary (only the env-var constants do).
  # A child that inherits the guard would short-circuit its own re-source and
  # never define _gaia_paths_canonicalize. Unset it so the child fully re-sources.
  if [ "$mode" = "health" ]; then
    local health="$self_dir/brain-health.sh"
    if [ -r "$health" ]; then
      ( unset _GAIA_PATHS_LOADED; bash "$health" )
      return $?
    fi
    printf 'gaia-brain-query.sh: brain-health view not found at %s\n' "$health" >&2
    return 2
  fi

  local knowledge_dir="$GAIA_KNOWLEDGE_DIR"
  local artifacts_dir="$GAIA_ARTIFACTS_DIR"
  local state_dir="$GAIA_STATE_DIR"
  : "$artifacts_dir" "$state_dir"  # the read roots for the C1 freshness check
  [ -n "$manifest" ] || manifest="$knowledge_dir/brain-index.yaml"

  # Read-only boundary anchors for the C1 freshness check (SEC hardening):
  #   - root_canon  = the canonical project root; every canonical file MUST
  #                   resolve under it.
  #   - mem_subtree = the agent-sidecar tree, a sibling of the knowledge dir;
  #                   the freshness check MUST NOT open anything under it. We
  #                   derive it from the knowledge dir's parent + the sidecar
  #                   subdir name so neither the runtime-tree boundary literal
  #                   nor the sidecar env-var name lives in this source (the
  #                   read-only-boundary static guard).
  local root_canon mem_subtree sidecar_subdir
  root_canon="$(_gaia_paths_canonicalize "${CLAUDE_PROJECT_ROOT:-$PWD}" 2>/dev/null || true)"
  sidecar_subdir="memory"
  mem_subtree="$(_gaia_paths_canonicalize "$(dirname "$knowledge_dir")/$sidecar_subdir" 2>/dev/null || true)"

  # --- Missing manifest → explanatory line, exit 0 ---
  if [ ! -r "$manifest" ]; then
    printf 'Brain query: no brain index manifest found at %s\n' "$manifest"
    printf 'Run /gaia-brain-reindex to build the index, then re-run this query.\n'
    return 0
  fi

  # Probe PyYAML once for the manifest parse.
  local have_pyyaml=0
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    have_pyyaml=1
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/bq-main.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' 2>/dev/null || true" RETURN

  local recf="$tmp/records.tsv"
  local edgef="$tmp/edges.tsv"
  _bq_parse_manifest "$manifest" "$recf" "$edgef" "$have_pyyaml"

  # --- --search: a thin grep over the indexed synopses ---
  if [ "$mode" = "search" ]; then
    if [ -z "$search_terms" ]; then
      printf 'gaia-brain-query.sh: --search requires a term\n' >&2
      return 2
    fi
    printf 'Brain query — synopsis search for: %s\n\n' "$search_terms"
    local matched
    matched="$(awk -F'\t' -v q="$search_terms" '
      index(tolower($1 " " $4), tolower(q)) { print "  " $1 "  " $4 }
    ' "$recf" || true)"
    if [ -z "$matched" ]; then
      printf '  (no matching synopses)\n'
    else
      printf '%s\n' "$matched" | LC_ALL=C sort -u
    fi
    return 0
  fi

  # --- --category: filter lesson entries by category tag ---
  # Records TSV columns: key(1) path(2) content_hash(3) synopsis(4) source_type(5) tags(6)
  if [ "$mode" = "category" ]; then
    if [ -z "$category_tag" ]; then
      printf 'gaia-brain-query.sh: --category requires a tag\n' >&2
      return 2
    fi
    printf 'Brain query — lesson entries with category: %s\n\n' "$category_tag"
    local cat_matched
    cat_matched="$(awk -F'\t' -v cat="$category_tag" '
      $5 == "lesson" {
        n = split($6, arr, ",")
        for (i = 1; i <= n; i++) {
          if (arr[i] == cat) { print "  " $1 "  " $4; break }
        }
      }
    ' "$recf" || true)"
    if [ -z "$cat_matched" ]; then
      printf '  (no lesson entries with category: %s)\n' "$category_tag"
    else
      printf '%s\n' "$cat_matched" | LC_ALL=C sort -u
    fi
    return 0
  fi

  # --- --envelope (default) ---
  if [ -z "$key" ]; then
    printf 'gaia-brain-query.sh: a seed key is required for the envelope query\n' >&2
    return 2
  fi
  _bq_render_envelope "$key" "$recf" "$edgef" "$tmp" "$root_canon" "$mem_subtree"
  return $?
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  gaia_brain_query "$@"
  exit $?
fi
