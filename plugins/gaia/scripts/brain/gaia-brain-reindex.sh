#!/usr/bin/env bash
# gaia-brain-reindex.sh — the reindex sweep: the SOLE writer of the brain
# knowledge layer's manifest at .gaia/knowledge/brain-index.yaml.
#
# WHAT IT DOES
#   A full, correct-by-construction sweep. It walks the two source roots
#   (artifacts + state), and for each discovered file it:
#     1. computes the sha256 content hash,
#     2. short-circuits when the prior manifest already carries that exact hash
#        (carrying the prior synopsis + edges forward verbatim — no regen, no
#        harvester re-invocation),
#     3. otherwise generates a deterministic synopsis and harvests typed edges,
#     4. assembles the entry per the brain-index schema,
#   then writes the whole manifest ATOMICALLY (sibling tempfile → validate →
#   rename). No partial manifest is ever visible to a concurrent reader, and a
#   validation failure leaves the prior manifest byte-identical.
#
# READ-ONLY BOUNDARY (enforced BY CONSTRUCTION)
#   The sweep enumerates ONLY the artifacts and state roots. It NEVER reads or
#   writes the agent-sidecar memory tree, the config tree, the custom tree, or
#   the knowledge tree itself. The two source roots are the only directories the
#   walk ever descends — there is no memory path literal anywhere in this script.
#   Writes land ONLY under the knowledge store.
#
# SYNOPSIS GENERATOR
#   The synopsis is a DETERMINISTIC extract — the first H1/H2 heading plus the
#   first prose line, with the filename stem as a fallback. This is
#   deterministic-by-budget: the performance contract forbids spawning a
#   subagent per artifact, and a per-file model call cannot meet the sweep's
#   time budget. An LLM-generated synopsis is the documented later extension —
#   do NOT regress this to a model call. The content-hash short-circuit
#   machinery is generator-agnostic, so swapping the generator later is additive.
#
# PERFORMANCE
#   Two fixes keep a large sweep within budget:
#     - probe the host's structured-YAML reader ONCE and export the result, so
#       the harvester does not re-fork it per field per node;
#     - pre-slice the shared epics-and-stories and traceability-matrix files
#       ONCE per sweep into tiny per-key fragments, so the per-node harvester
#       reads a small slice instead of re-scanning the whole large file.
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
# shasum) mirrors the established checkpoint writer.
# ---------------------------------------------------------------------------
_brx_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

# ---------------------------------------------------------------------------
# Stable, fixed-length scratch-file name for an entry key. The per-entry
# synopsis/edge carry-forward files are named by the entry key. Flattening the
# key path into a single filename (slash -> "__") overflows the 255-byte OS
# filename limit for deeply nested artifacts (epic-/story-/reviews- paths), so
# the sweep aborts mid-harvest with "File name too long". Hash the key to a
# fixed 64-char hex digest instead — collision-resistant and always well under
# the limit. Writer (preload) and reader (loop) MUST agree on this naming, so
# both route through this helper.
# ---------------------------------------------------------------------------
_brx_keyfile() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    # Last-resort fallback: flatten but truncate to a safe length to avoid the
    # overflow (no backend present — collisions are unlikely at this scale).
    printf '%s' "$1" | tr '/' '_' | cut -c1-200
  fi
}

# ---------------------------------------------------------------------------
# YAML-string escape for a single-line double-quoted scalar. Backslash and
# double-quote are the only two characters that must be escaped inside a
# double-quoted YAML scalar; we also strip CR and collapse any stray newline.
# ---------------------------------------------------------------------------
_brx_yaml_escape() {
  # Pure-bash escape (no fork) — this runs several times per node, so the
  # fork-free path matters on a large sweep. Escape backslash then double-quote,
  # and drop CR/LF.
  local s="$1"
  s="${s//\\/\\\\}"   # backslash -> double backslash
  s="${s//\"/\\\"}"   # double-quote -> escaped quote
  s="${s//$'\r'/}"    # strip CR
  s="${s//$'\n'/ }"   # collapse LF to space
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Deterministic synopsis extract (P1). First H1/H2 heading + first prose line;
# fallback to the filename stem. NO model call (deterministic-by-budget; the
# performance contract forbids per-artifact subagent spawning). The LLM synopsis
# is the documented later extension — do NOT regress this to a model call.
# ---------------------------------------------------------------------------
_brx_synopsis() {
  local file="$1"
  local heading="" prose=""
  # First markdown heading (H1 or H2), stripped of leading #'s.
  heading="$(awk '
    /^#{1,2} / { sub(/^#{1,2}[[:space:]]*/, ""); print; exit }
  ' "$file" 2>/dev/null || true)"
  # First non-empty, non-heading, non-frontmatter prose line.
  prose="$(awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { infm = 0; next }
    infm { next }
    /^#/ { next }
    /^[[:space:]]*$/ { next }
    { print; exit }
  ' "$file" 2>/dev/null || true)"

  local syn=""
  if [ -n "$heading" ] && [ -n "$prose" ]; then
    syn="$heading — $prose"
  elif [ -n "$heading" ]; then
    syn="$heading"
  elif [ -n "$prose" ]; then
    syn="$prose"
  else
    # Fallback: filename stem.
    local base
    base="$(basename -- "$file")"
    syn="${base%.*}"
  fi
  printf '%s' "$syn"
}

# ---------------------------------------------------------------------------
# Story-key derivation. A file is a story when its name (or its parent dir, for
# the per-story nested layout) matches the E<n>-S<n> shape. Echoes the key, or
# nothing for a non-story file.
# ---------------------------------------------------------------------------
_brx_story_key_for() {
  local path="$1"
  local base parent
  base="$(basename -- "$path")"
  if [ "$base" = "story.md" ]; then
    # Per-story nested layout: the parent directory name carries the key.
    parent="$(basename -- "$(dirname -- "$path")")"
    case "$parent" in
      E[0-9]*-S[0-9]*-*|E[0-9]*-S[0-9]*)
        # Strip the trailing -slug to leave E<n>-S<n>.
        printf '%s' "$parent" | sed -E 's/^(E[0-9]+-S[0-9]+).*/\1/'
        return 0 ;;
    esac
    return 0
  fi
  case "$base" in
    E[0-9]*-S[0-9]*-*.md|E[0-9]*-S[0-9]*.md)
      printf '%s' "$base" | sed -E 's/^(E[0-9]+-S[0-9]+).*/\1/'
      return 0 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Generic path-derived key for a non-story artifact: the project-root-relative
# path with separators turned into slashes already; we use the basename stem
# plus a short parent qualifier to reduce collisions, but the path stays the
# stable identity. We key non-story artifacts on their relative path so two
# files with the same stem under different dirs never collide.
# ---------------------------------------------------------------------------
_brx_generic_key_for() {
  local relpath="$1"
  # Use the relative path with the .md/.yaml extension stripped, slashes kept.
  printf '%s' "$relpath" | sed -E 's/\.(md|yaml|yml|json)$//'
}

# ---------------------------------------------------------------------------
# Artifact-type tag bucket from the relative path.
# ---------------------------------------------------------------------------
_brx_tag_for() {
  local relpath="$1"
  case "$relpath" in
    *planning-artifacts/architecture/*) printf 'architecture' ;;
    *planning-artifacts/prd/*)          printf 'prd' ;;
    *planning-artifacts/epics*)         printf 'epics' ;;
    *planning-artifacts/*)              printf 'planning' ;;
    *implementation-artifacts/*)        printf 'implementation' ;;
    *test-artifacts/*)                  printf 'test' ;;
    *creative-artifacts/*)              printf 'creative' ;;
    *research-artifacts/*)              printf 'research' ;;
    state/*|*/state/*)                  printf 'state' ;;
    *)                                  printf 'artifact' ;;
  esac
}

# ---------------------------------------------------------------------------
# Prior-manifest lookups. We pre-load the prior manifest into flat, line-indexed
# lookups keyed by entry key (bash 3.2 has no associative arrays):
#   - a key->content_hash TSV (drives the short-circuit decision),
#   - one file per key holding the prior synopsis bytes,
#   - one file per key holding the prior rendered edges block.
# The per-node hash + short-circuit decision is then computed in ONE awk join
# over (hashmap, prior-hash TSV, deduped list) — see the sweep body — so there
# is no per-node lookup fork in the hot loop.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Pre-load the prior manifest into the flat lookups. Uses python3+PyYAML when
# available (robust), else a line-based awk fallback. Writes:
#   $1 = hash lookup  (key \t hash)
#   $2 = synopsis dir (one file per key, raw synopsis bytes)
#   $3 = edges dir    (one file per key, raw rendered edges block)
# ---------------------------------------------------------------------------
_brx_preload_prior() {
  local manifest="$1" hashlk="$2" syndir="$3" edgedir="$4" have_pyyaml="${5:-0}"
  : > "$hashlk"
  mkdir -p "$syndir" "$edgedir"
  [ -r "$manifest" ] || return 0

  if [ "$have_pyyaml" = "1" ]; then
    python3 - "$manifest" "$hashlk" "$syndir" "$edgedir" <<'PYEOF' || true
import sys, yaml, os, hashlib
manifest, hashlk, syndir, edgedir = sys.argv[1:5]
try:
    doc = yaml.safe_load(open(manifest)) or {}
except Exception:
    doc = {}
entries = doc.get("entries") or []
with open(hashlk, "w") as hf:
    for e in entries:
        key = e.get("key", "")
        if not key:
            continue
        trust = e.get("trust") or {}
        ch = trust.get("content_hash", "") or ""
        hf.write("%s\t%s\n" % (key, ch))
        syn = e.get("synopsis", "")
        if syn is None:
            syn = ""
        with open(os.path.join(syndir, hashlib.sha256(key.encode("utf-8")).hexdigest()), "w") as sf:
            sf.write(str(syn))
        # Re-render the edges block verbatim for carry-forward.
        edges = e.get("edges") or []
        unlinked = e.get("unlinked")
        lines = []
        if edges:
            lines.append("  edges:")
            for ed in edges:
                # Edge targets are harvested prose (epic/story titles) and may
                # contain a `: ` that YAML would read as a mapping separator if
                # emitted bare. This carry-forward block is cat'd verbatim into
                # the manifest by _brx_render_entry, so quote+escape the target
                # exactly as the harvest path does (a JSON-encoded string is a
                # valid YAML double-quoted scalar).
                import json as _json
                lines.append("    - type: %s" % ed.get("type", ""))
                lines.append("      target: %s" % _json.dumps(str(ed.get("target", ""))))
        else:
            lines.append("  edges: []")
        with open(os.path.join(edgedir, hashlib.sha256(key.encode("utf-8")).hexdigest()), "w") as ef:
            ef.write("\n".join(lines) + "\n")
PYEOF
    return 0
  fi

  # Fallback: line-based extraction of key + content_hash only. Without PyYAML
  # we cannot reliably round-trip nested edges, so the carry-forward of edges is
  # skipped (the changed/short-circuit decision still works off the hash; a
  # short-circuited node simply re-harvests its edges — correctness preserved,
  # only the harvester-skip optimization is lost on PyYAML-less hosts).
  awk -F': ' '
    /^- key:/ || /^  - key:/ {
      key=$2; gsub(/"/,"",key); gsub(/^[[:space:]]+|[[:space:]]+$/,"",key)
    }
    /content_hash:/ {
      h=$2; gsub(/"/,"",h); gsub(/^[[:space:]]+|[[:space:]]+$/,"",h)
      if (key != "") print key "\t" h
    }
  ' "$manifest" > "$hashlk" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Pre-slice the shared epics + matrix files ONCE per sweep. Each per-key slice
# is the node's own `### Story <KEY>:` block (epics) and every matrix line that
# references the key. The per-node harvester reads the tiny slice via
# --epics/--matrix instead of re-scanning the whole large file.
# ---------------------------------------------------------------------------
_brx_preslice_epics() {
  local epics="$1" outdir="$2"
  mkdir -p "$outdir"
  [ -r "$epics" ] || return 0
  awk -v outdir="$outdir" '
    /^### Story / {
      hk = $3; sub(/:$/, "", hk)
      # Normalize to E<n>-S<n>.
      if (hk ~ /^E[0-9]+-S[0-9]+/) {
        cur = hk
        file = outdir "/" cur ".md"
      } else {
        cur = ""
        file = ""
      }
    }
    {
      if (cur != "" && file != "") print $0 >> file
    }
  ' "$epics"
}

_brx_preslice_matrix() {
  local matrix="$1" outdir="$2"
  mkdir -p "$outdir"
  [ -r "$matrix" ] || return 0
  # For every line, find each E<n>-S<n> token it mentions and append the line to
  # that key's slice. A line that mentions several keys is appended to each.
  awk -v outdir="$outdir" '
    {
      line = $0
      rest = line
      # Walk E<n>-S<n> tokens.
      while (match(rest, /E[0-9]+-S[0-9]+/)) {
        tok = substr(rest, RSTART, RLENGTH)
        # Whole-token boundary: char after must not continue the key.
        after = substr(rest, RSTART + RLENGTH, 1)
        if (after !~ /[0-9]/) {
          print line >> (outdir "/" tok ".md")
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$matrix"
}

# ---------------------------------------------------------------------------
# Render a single entry to the manifest tempfile. Args:
#   $1 key  $2 relpath  $3 tag  $4 synopsis  $5 content_hash  $6 edges-block-file
# The edges-block-file holds the pre-rendered `  edges:`..lines (indented two
# spaces under the entry). trust is fixed for project-artifact entries.
# ---------------------------------------------------------------------------
_brx_render_entry() {
  local key="$1" relpath="$2" tag="$3" synopsis="$4" chash="$5" edgesfile="$6" out="$7"
  {
    printf -- '- key: "%s"\n' "$(_brx_yaml_escape "$key")"
    printf '  source_type: project-artifact\n'
    printf '  path: "%s"\n' "$(_brx_yaml_escape "$relpath")"
    printf '  tags: ["%s"]\n' "$(_brx_yaml_escape "$tag")"
    printf '  synopsis: "%s"\n' "$(_brx_yaml_escape "$synopsis")"
    cat "$edgesfile"
    printf '  trust:\n'
    printf '    confidence: 1.0\n'
    printf '    content_hash: "%s"\n' "$chash"
    printf '    source_url: null\n'
    printf '    fetched_at: null\n'
    printf '    expires_at: null\n'
  } >> "$out"
}

# ---------------------------------------------------------------------------
# The sweep.
# ---------------------------------------------------------------------------
brain_reindex() {
  # --- Arg parse: optional validator override (test seam) ---
  local validator_override=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --validator) validator_override="$2"; shift 2 ;;
      *) printf 'gaia-brain-reindex.sh: unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  # --- Resolve canonical paths ---
  local self_dir lib
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  lib="$self_dir/../lib/gaia-paths.sh"
  # shellcheck source=../lib/gaia-paths.sh
  . "$lib" || { printf 'gaia-brain-reindex.sh: could not source gaia-paths.sh\n' >&2; return 2; }

  local artifacts_dir="$GAIA_ARTIFACTS_DIR"
  local state_dir="$GAIA_STATE_DIR"
  local knowledge_dir="$GAIA_KNOWLEDGE_DIR"
  local out_manifest="$knowledge_dir/brain-index.yaml"

  local validator="$self_dir/validate-brain-index.sh"
  [ -n "$validator_override" ] && validator="$validator_override"

  local harvester="$self_dir/harvest-edges.sh"

  # --- Project root for relative paths ---
  # Canonicalize so it matches the canonicalized source-root paths the helper
  # produced (otherwise the relative-path strip below silently no-ops on hosts
  # where /tmp is a symlink to /private/tmp, etc.).
  local proj_root
  proj_root="$(_gaia_paths_canonicalize "${CLAUDE_PROJECT_ROOT:-$PWD}")"

  # --- One sweep scratch dir + cleanup trap ---
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/brx.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' 2>/dev/null || true" RETURN

  # --- PERF FIX 1: structured-YAML reader policy for the per-node harvest ---
  # The harvester's frontmatter reader prefers python3+PyYAML and forks it once
  # per field per node. On a 500-node sweep that fork cost dominates and blows
  # the time budget (~85ms/field vs ~1ms for the awk fallback). The harvester's
  # awk fallback parses the inline-list and scalar frontmatter shapes the
  # governance fields use (traces_to, epic, blocks, depends_on), so for the
  # sweep we PIN the cache flag to the awk path. This honors the carry-forward
  # performance advisory ("prefer the awk fallback") and keeps the once-per-node
  # cost bounded. We still record whether PyYAML is present (PYYAML_PRESENT) for
  # the prior-manifest preload, which DOES need a robust structured read but runs
  # exactly once per sweep, not per node.
  local PYYAML_PRESENT=0
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    PYYAML_PRESENT=1
  fi
  # Pin the per-node harvest reader to the fast awk path (cache value 0 → the
  # harvester's _has_pyyaml() short-circuits to "no PyYAML" → awk fallback).
  GAIA_BRAIN_PYYAML=0
  export GAIA_BRAIN_PYYAML

  # --- PERF FIX 2: pre-slice the shared epics + matrix ONCE ---
  local epics_file="$artifacts_dir/planning-artifacts/epics-and-stories.md"
  local matrix_file="$artifacts_dir/test-artifacts/strategy/traceability-matrix.md"
  local epics_slices="$tmp/epics-slices"
  local matrix_slices="$tmp/matrix-slices"
  _brx_preslice_epics "$epics_file" "$epics_slices"
  _brx_preslice_matrix "$matrix_file" "$matrix_slices"

  # --- Pre-load the prior manifest (drives the C1 short-circuit) ---
  local prior_hash_lk="$tmp/prior-hash.tsv"
  local prior_syn_dir="$tmp/prior-syn"
  local prior_edge_dir="$tmp/prior-edge"
  _brx_preload_prior "$out_manifest" "$prior_hash_lk" "$prior_syn_dir" "$prior_edge_dir" "$PYYAML_PRESENT"

  # --- Enumerate the source roots (ONLY artifacts + state) ---
  # Three-tier story discovery is subsumed by the full walk: every story file in
  # every layout is a regular file under artifacts/, so the walk finds them all.
  # We de-dupe story keys to the highest-precedence layout below.
  local filelist="$tmp/files.txt"
  : > "$filelist"
  local root
  for root in "$artifacts_dir" "$state_dir"; do
    [ -d "$root" ] || continue
    find "$root" -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) -print >> "$filelist" 2>/dev/null || true
  done

  # --- PERF: batch all content hashes in ONE digest invocation ---
  # Hashing each file with a separate sha256 fork dominates the per-node cost on
  # a large sweep. sha256sum / shasum both accept many files at once and emit
  # "<hash>  <path>" lines; we run a single fork over the whole filelist and
  # build an abspath->hash lookup. (xargs splits into a few batches only when the
  # arg list exceeds the OS limit — still O(1) forks per ~thousands of files.)
  local hashmap="$tmp/hashmap.tsv"   # abspath \t hash
  : > "$hashmap"
  if [ -s "$filelist" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      tr '\n' '\0' < "$filelist" | xargs -0 sha256sum 2>/dev/null \
        | sed 's/^\([0-9a-f]*\) [ *]\(.*\)$/\2\t\1/' > "$hashmap" || true
    elif command -v shasum >/dev/null 2>&1; then
      tr '\n' '\0' < "$filelist" | xargs -0 shasum -a 256 2>/dev/null \
        | sed 's/^\([0-9a-f]*\) [ *]\(.*\)$/\2\t\1/' > "$hashmap" || true
    fi
  fi

  # --- Build the entry list, with story-key de-dup by layout precedence ---
  # Precedence: per-story nested (story.md) > legacy nested (stories/) > flat.
  # We assign a rank to each story file and keep only the lowest rank per key.
  local entries_tsv="$tmp/entries.tsv"   # rank \t key \t path
  : > "$entries_tsv"

  local path relpath key rank
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Project-root-relative path.
    case "$path" in
      "$proj_root"/*) relpath="${path#"$proj_root"/}" ;;
      *)              relpath="$path" ;;
    esac
    # Strip a leading .gaia/ so the stored path is project-root-relative under
    # the canonical tree (path: .gaia/artifacts/... stays intact otherwise).

    key="$(_brx_story_key_for "$path")"
    if [ -n "$key" ]; then
      # Determine layout rank for de-dup.
      case "$path" in
        */story.md)        rank=0 ;;  # per-story nested
        */stories/*)       rank=1 ;;  # legacy nested
        *)                 rank=2 ;;  # flat
      esac
      printf '%s\t%s\t%s\n' "$rank" "$key" "$relpath" >> "$entries_tsv"
    else
      # Non-story artifact: generic path-derived key, rank 5 (always kept).
      key="$(_brx_generic_key_for "$relpath")"
      printf '5\t%s\t%s\n' "$key" "$relpath" >> "$entries_tsv"
    fi
  done < "$filelist"

  # De-dup: keep the lowest-rank row per key. Sort by key then rank, keep first.
  local deduped="$tmp/deduped.tsv"   # key \t path
  LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k1,1n "$entries_tsv" | awk -F'\t' '
    $2 != lastkey { print $2 "\t" $3; lastkey=$2 }
  ' > "$deduped"

  # --- PERF: precompute the per-node hash + short-circuit decision in ONE awk
  # join over (hashmap, prior-hash lookup, deduped list). This removes the two
  # per-node awk forks (hash lookup + prior-hash lookup) from the hot loop, which
  # otherwise make a large sweep O(N) extra forks. The plan rows are:
  #   key \t relpath \t hash \t decision   (decision ∈ carry|build)
  # "carry" => the prior manifest already carries this exact hash AND a
  # round-tripped prior synopsis+edges exist => short-circuit. "build" => new or
  # changed => regenerate synopsis + (for story keys) harvest edges.
  local plan="$tmp/plan.tsv"
  awk -F'\t' -v root="$proj_root" '
    FNR==NR && FILENAME==ARGV[1] { hash[$1]=$2; next }          # hashmap: abspath -> hash
    FILENAME==ARGV[2] { prior[$1]=$2; next }                    # prior:   key     -> hash
    {                                                            # deduped: key \t relpath
      key=$1; rel=$2
      abspath=root "/" rel
      h=hash[abspath]
      decision="build"
      # Mark carry when the prior manifest holds this key at a matching hash.
      # The carry-forward scratch files are named by a sha256 of the key, which
      # awk cannot reproduce; the bash loop verifies their presence and falls
      # back to a rebuild if either is missing, so the existence check is not
      # duplicated here.
      if (key in prior && prior[key]!="" && prior[key]==h) decision="carry"
      print key "\t" rel "\t" h "\t" decision
    }
  ' "$hashmap" "$prior_hash_lk" "$deduped" > "$plan"

  # --- Assemble the manifest into a SIBLING tempfile (atomic-write target) ---
  mkdir -p "$knowledge_dir"
  local manifest_tmp
  manifest_tmp="$(mktemp "${out_manifest}.tmp.XXXXXX")"
  # The validator (and the shared schema primitive it delegates to) dispatches the
  # instance->JSON conversion on the file EXTENSION — only *.yaml / *.yml / *.md /
  # *.json are recognized; anything else returns "could not convert" (rc=2). A
  # bare mktemp template leaves the staging file with a `.tmp.XXXXXX` suffix, so on
  # a host WITH a JSON-schema backend (ajv or python3+jsonschema — i.e. Linux CI)
  # the pre-rename validation of the tempfile trips that rc=2 and the whole sweep
  # returns non-zero. On a backend-less host (stock macOS) the validator SKIPs
  # before the extension dispatch, masking the bug. Give the staging file a `.yaml`
  # extension so the validator recognizes it. We add the suffix with a portable
  # rename rather than baking it into the mktemp template, because BSD mktemp does
  # NOT honor a suffix after the XXXXXX placeholder (it would emit a fixed,
  # un-randomized name) — only GNU mktemp does. The rename keeps the file a sibling
  # of the manifest on the same store (atomic-rename contract intact) and still
  # matches the `*.tmp.*` cleanup glob.
  mv "$manifest_tmp" "${manifest_tmp}.yaml"
  manifest_tmp="${manifest_tmp}.yaml"
  # Ensure the sibling tempfile is removed on any pre-rename failure.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' 2>/dev/null || true; rm -f '$manifest_tmp' 2>/dev/null || true" RETURN

  {
    printf 'schema_version: 1\n'
    printf 'entries:\n'
  } > "$manifest_tmp"

  # Stable empty review-dir + absent UX file used as the FALLBACK harvest inputs
  # for a node that has no review reports / no UX artifacts on disk. They are
  # NON-EMPTY argument values, which keeps the harvester from entering its
  # default-source-resolution branch (the branch that re-sources gaia-paths.sh
  # per call). The dir has no matching review files and the UX path does not
  # exist, so both parsers no-op cleanly. A node WITH artifacts on disk is given
  # its real reviews dir / the pre-sliced UX file instead (see below).
  local empty_reviews="$tmp/empty-reviews"
  local absent_ux="$tmp/absent-ux.md"
  mkdir -p "$empty_reviews"

  # --- Pre-slice the UX artifact tree ONCE per sweep ---
  # `designs` edges are harvested from the project's UX artifacts (the design
  # surface lives under creative-artifacts/ux/). The harvester takes ONE readable
  # UX file via --ux and emits a designs edge for each node referenced in it, so
  # we concatenate every UX artifact into a single sweep-scoped slice ONCE — the
  # same pre-slice idiom used for the shared epics + matrix files. Every story
  # node's harvest then reads this one slice instead of re-walking the UX tree.
  # When no UX tree exists the slice is absent and the harvest falls back to the
  # absent-UX path, so a project with no design artifacts simply emits no designs
  # edges (absence is correct, not an error).
  local ux_dir="$artifacts_dir/creative-artifacts/ux"
  local ux_slice="$tmp/ux-slice.md"
  if [ -d "$ux_dir" ]; then
    : > "$ux_slice"
    local _uxf
    find "$ux_dir" -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r _uxf; do
          [ -r "$_uxf" ] || continue
          cat "$_uxf" >> "$ux_slice"
          printf '\n' >> "$ux_slice"
        done
  fi

  # Iterate the precomputed plan in deterministic key order.
  local abspath chash decision tag synopsis edgesfile keysafe
  while IFS="$(printf '\t')" read -r key relpath chash decision; do
    [ -n "$key" ] || continue
    abspath="$proj_root/$relpath"
    [ -f "$abspath" ] || continue
    # Defensive: if the batch hash missed this path, compute it now.
    [ -n "$chash" ] || chash="$(_brx_sha256_file "$abspath")"
    tag="$(_brx_tag_for "$relpath")"
    keysafe="$(_brx_keyfile "$key")"
    edgesfile="$tmp/edges-$keysafe.txt"

    # C1 SHORT-CIRCUIT (decision=carry): prior manifest carries this key with a
    # matching hash → carry the prior synopsis + edges forward verbatim. Skip
    # synopsis regen AND skip the harvester. The carry-file existence is verified
    # here (not in the awk planner, which cannot reproduce the sha256 filename) —
    # if either carry-file is missing the entry safely falls through to a rebuild.
    if [ "$decision" = "carry" ] \
       && [ -f "$prior_syn_dir/$keysafe" ] && [ -f "$prior_edge_dir/$keysafe" ]; then
      synopsis="$(cat "$prior_syn_dir/$keysafe")"
      cp "$prior_edge_dir/$keysafe" "$edgesfile"
    else
      # Changed or new → regenerate the deterministic synopsis + harvest edges.
      synopsis="$(_brx_synopsis "$abspath")"
      # Harvest typed edges. Only STORY-shaped keys carry governance edges (they
      # are the nodes referenced by the epics Allocates bullets, the matrix rows,
      # and story frontmatter). A non-story artifact has no key in any edge
      # source, so it renders an empty edge block WITHOUT a harvester fork —
      # avoiding N wasted subprocess spawns on a large sweep.
      local frag=""
      case "$key" in
        E[0-9]*-S[0-9]*)
          local ep="" mx=""
          [ -f "$epics_slices/$key.md" ] && ep="$epics_slices/$key.md"
          [ -f "$matrix_slices/$key.md" ] && mx="$matrix_slices/$key.md"
          # Per-node reviews-dir discovery: a story's review reports live in a
          # `reviews/` dir sibling of the story file. Point the harvester at that
          # real dir when it exists so it harvests a reviewed-in edge for each
          # type-first, key-suffixed report; otherwise fall back to the stable
          # empty dir (no reports → no edges, which is correct).
          local rdir="$empty_reviews"
          local _story_reviews="$(dirname -- "$abspath")/reviews"
          [ -d "$_story_reviews" ] && rdir="$_story_reviews"
          # UX source: the sweep-scoped UX slice (every design artifact, sliced
          # once above) when present, else the absent-UX fallback.
          local uxsrc="$absent_ux"
          [ -f "$ux_slice" ] && uxsrc="$ux_slice"
          # Clear the path-helper guard for the harvester subprocess: it may
          # re-source gaia-paths.sh, and the helper FUNCTIONS do not cross the
          # process boundary. The non-empty reviews-dir / ux args keep it out of
          # its per-call default-resolution branch.
          frag="$( ( unset _GAIA_PATHS_LOADED; "$harvester" --key "$key" \
            --epics "$ep" --matrix "$mx" --frontmatter "$abspath" \
            --reviews-dir "$rdir" --ux "$uxsrc" ) 2>/dev/null \
            || printf 'edges: []\nunlinked: true\n')"
          ;;
        *)
          frag="edges: []"
          ;;
      esac
      # Re-indent the harvester fragment two spaces under the entry, and keep
      # only the edges: portion (drop the unlinked: line — it is not a schema
      # field on the entry; unlinked status is recomputed by health tooling).
      printf '%s\n' "$frag" | awk '
        /^unlinked:/ { next }
        { print "  " $0 }
      ' > "$edgesfile"
    fi

    _brx_render_entry "$key" "$relpath" "$tag" "$synopsis" "$chash" "$edgesfile" "$manifest_tmp"
  done < "$plan"

  # --- Validate the tempfile BEFORE the rename ---
  # The validator is a separate process that re-sources gaia-paths.sh to obtain
  # its helper FUNCTIONS (which do not cross the process boundary — only the
  # exported env vars do). gaia-paths.sh short-circuits when _GAIA_PATHS_LOADED
  # is already set in the env, so a child that inherits our exported guard would
  # skip defining those functions. Clear the guard for the child so it fully
  # re-sources the helper.
  local vrc=0
  ( unset _GAIA_PATHS_LOADED; "$validator" "$manifest_tmp" ) >/dev/null 2>&1 || vrc=$?
  case "$vrc" in
    0) : ;;                                  # valid → rename
    3) : ;;                                  # SKIP (no backend) → proceed
    *) printf 'gaia-brain-reindex.sh: manifest validation failed (rc=%s); prior manifest left intact\n' "$vrc" >&2
       rm -f "$manifest_tmp" 2>/dev/null || true
       return 1 ;;
  esac

  # --- Atomic rename (sibling tempfile → manifest on the same store) ---
  mv "$manifest_tmp" "$out_manifest" || {
    printf 'gaia-brain-reindex.sh: atomic rename failed\n' >&2
    rm -f "$manifest_tmp" 2>/dev/null || true
    return 1
  }

  # --- Render the human-browsable MOC from the now-committed manifest ---
  # BEST-EFFORT: the YAML manifest is the single source of truth; the brain-index.md
  # MOC is a derived convenience. A render failure is logged and swallowed so the
  # sweep's primary outcome (the committed manifest) is never blocked by it. The
  # render is a pure function of the manifest, called strictly AFTER the atomic
  # rename so it can never affect the manifest write.
  local renderer="$self_dir/render-moc.sh"
  if [ -r "$renderer" ]; then
    # shellcheck source=render-moc.sh
    if . "$renderer" 2>/dev/null; then
      render_moc "$out_manifest" "$knowledge_dir/brain-index.md" 2>/dev/null \
        || printf 'gaia-brain-reindex.sh: MOC render failed (best-effort); manifest is intact\n' >&2
    else
      printf 'gaia-brain-reindex.sh: could not source render-moc.sh (best-effort); manifest is intact\n' >&2
    fi
  fi

  printf '%s\n' "$out_manifest"
  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  brain_reindex "$@"
  exit $?
fi
