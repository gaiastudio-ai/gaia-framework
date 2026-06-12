#!/usr/bin/env bash
# harvest-edges.sh — the seven-edge harvester LIBRARY for the brain knowledge
# layer. Given a node key and the locations of the four source artifacts, it
# derives that node's typed governance edges and the four-source "is this node
# linked?" verdict, then emits a single-node manifest fragment on stdout:
#
#   edges:
#     - type: <edge-type>
#       target: <target>
#     ...
#   unlinked: false
#
# or, for a node with zero links across all four sources:
#
#   edges: []
#   unlinked: true
#
# SCOPE: this is the harvester the reindex sweep CALLS. It does NOT write the
# manifest, walk the artifact tree, compute content hashes, or do atomic writes
# — that is the sweep's job. It takes the four source locations as flags (so it
# is unit-testable in isolation) and, when a flag is omitted, defaults to the
# real paths resolved through the canonical path helper.
#
# The seven closed-enum edge types and their CORRECTED source map:
#   implements   <- epics-prose `- **Allocates:**` bullets (requirement-shaped
#                   tokens only) + traceability-matrix requirement-to-story
#                   column. NEVER from frontmatter (`implements:` exists in 0
#                   story files — the forbidden trap).
#   traces-to    <- frontmatter `traces_to:` tokens.
#   decomposes   <- frontmatter `epic:` + `blocks:` + `depends_on:`.
#   governed-by  <- the decision-shaped subset of `traces_to:` PLUS the
#                   decision-shaped tokens found in the Allocates bullet.
#   verified-by  <- the per-STORY matrix verification row (the row whose FIRST
#                   cell is exactly the node key) — its test tokens.
#   reviewed-in  <- type-FIRST review-report filenames in the node's reviews/
#                   dir, anchored to the `-<KEY>.md` suffix.
#   designs      <- UX artifact references to the node key.
# Any other type is dropped with a warning and never emitted.
#
# Scope note on `verified-by` (per-story vs roll-up matrix shape): the matrix
# carries two row shapes — a per-STORY shape whose first cell is the story key,
# and a per-EPIC roll-up shape whose cells carry story-RANGES (e.g. a range like
# Sx..Sy) and test-prefix ranges. This harvester reads ONLY the per-STORY shape
# (first-cell == node key). A node documented only in a roll-up row degrades to
# no verified-by edges, which is acceptable under the never-drop rule (the node
# is still emitted; the missing edge surfaces as part of the unlinked/health
# analysis downstream). Parsing the roll-up ranges is intentionally out of scope
# here to keep the extraction deterministic and section-format-independent.
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only grep/awk flags. LC_ALL=C. set -euo pipefail. Sourceable
# (functions become available; no side effects) AND executable (the __main
# dispatcher runs only when the file is executed directly).

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Closed enum of the seven edge types + a stable type-rank for deterministic
# ordering. The rank order is the canonical enum order.
# ---------------------------------------------------------------------------

# _is_valid_edge_type <type> — 0 if the type is one of the seven, else non-zero.
_is_valid_edge_type() {
  case "$1" in
    implements|traces-to|decomposes|governed-by|verified-by|reviewed-in|designs)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# _edge_type_rank <type> — echo a stable numeric rank for the type (for sort).
_edge_type_rank() {
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

# ---------------------------------------------------------------------------
# Edge accumulator. Edges are collected as `rank\ttype\ttarget` lines in a
# temp file, then sorted + de-duped + rendered. bash 3.2: no arrays-of-structs.
# ---------------------------------------------------------------------------

_HE_ACC=""   # path to the accumulator temp file (set in harvest_node_edges)

# _emit_edge <type> <target> — validate and record one edge. An unknown type is
# refused (non-zero) and warned to stderr; a valid edge is appended to the
# accumulator. Empty target is ignored.
_emit_edge() {
  local etype="$1" target="$2"
  if ! _is_valid_edge_type "$etype"; then
    printf 'harvest-edges.sh: WARNING: dropping unknown edge type %s\n' "$etype" >&2
    return 1
  fi
  [ -n "$target" ] || return 0
  if [ -n "${_HE_ACC:-}" ]; then
    printf '%s\t%s\t%s\n' "$(_edge_type_rank "$etype")" "$etype" "$target" >> "$_HE_ACC"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Token-shape predicates (load-bearing regex carve-outs).
# A requirement-shaped token is FR-<n> or NFR-<n>. A decision-shaped token is
# ADR-<n>. These shapes drive the implements-vs-governed-by routing.
# ---------------------------------------------------------------------------

_is_requirement_token() {
  case "$1" in
    FR-[0-9]*|NFR-[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

_is_decision_token() {
  case "$1" in
    ADR-[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# _strip_gloss <token> — strip a trailing parenthetical gloss and surrounding
# whitespace, leaving the bare token. e.g. "FR-NNN (some policy)" -> "FR-NNN".
_strip_gloss() {
  # Cut at the first space or open-paren, then trim.
  local t="$1"
  t="${t%%(*}"          # drop from first '(' onward
  t="${t%% *}"          # drop from first ' ' onward
  printf '%s' "$t"
}

# ---------------------------------------------------------------------------
# Allocates-bullet harvest (epics prose). Emits implements edges for
# requirement-shaped tokens and governed-by edges for decision-shaped tokens
# found in the node's own `### Story <KEY>:` block.
# ---------------------------------------------------------------------------

# _allocates_tokens <key> <epics-file> — echo the bare allocation tokens for the
# node's own heading block, one per line. Whole-key heading match.
_allocates_tokens() {
  local key="$1" epics="$2"
  [ -n "$epics" ] && [ -r "$epics" ] || return 0
  awk -v key="$key" '
    # A "### Story <KEY>:" heading opens a block. We are "in" the block only for
    # the matching key, and leave it at the next "### Story" heading.
    /^### Story / {
      # Field 3 is the node key followed by a colon (e.g. "<KEY>:"). Strip it.
      hk = $3
      sub(/:$/, "", hk)
      inblock = (hk == key) ? 1 : 0
      next
    }
    inblock && /^- \*\*Allocates:\*\*/ {
      line = $0
      sub(/^- \*\*Allocates:\*\*[[:space:]]*/, "", line)
      # Split on commas; print each comma-separated token (gloss-stripping is
      # done by the caller via _strip_gloss for whitespace/paren handling).
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+/, "", parts[i])
        print parts[i]
      }
    }
  ' "$epics"
}

_harvest_implements_governed_from_epics() {
  local key="$1" epics="$2"
  local raw tok
  _allocates_tokens "$key" "$epics" | while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    tok="$(_strip_gloss "$raw")"
    [ -n "$tok" ] || continue
    if _is_requirement_token "$tok"; then
      _emit_edge implements "$tok" || true
    elif _is_decision_token "$tok"; then
      _emit_edge governed-by "$tok" || true
    fi
  done
}

# ---------------------------------------------------------------------------
# Matrix harvest. §1 requirement rows carry the node key in their story column;
# emit an implements edge for the requirement (column 1). The per-STORY
# verification row (first cell == node key) carries the test tokens for
# verified-by. Whole-token key matching throughout.
# ---------------------------------------------------------------------------

# _matrix_implements <key> <matrix-file> — emit implements edges from the
# requirement-to-story column. A requirement row is `| FR-n | desc | <stories> | ...`.
_matrix_implements_from_matrix() {
  local key="$1" matrix="$2"
  [ -n "$matrix" ] && [ -r "$matrix" ] || return 0
  local reqtok
  awk -v key="$key" -F'|' '
    # A requirement row: cell 2 is the requirement id, cell 4 is the Story(s)
    # comma-list. (Leading "|" makes cell 1 empty.)
    {
      req = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", req)
      stories = $4
    }
    req ~ /^(FR|NFR)-[0-9]/ {
      # Whole-token match of key in the comma-separated story list.
      n = split(stories, parts, ",")
      for (i = 1; i <= n; i++) {
        s = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        if (s == key) { print req; break }
      }
    }
  ' "$matrix" | while IFS= read -r reqtok; do
    [ -n "$reqtok" ] || continue
    _emit_edge implements "$reqtok" || true
  done
}

# _harvest_verified_by <key> <matrix-file> — emit verified-by edges from the
# per-STORY verification row (first cell == node key). Test tokens are TC-shaped
# or T-number-shaped.
_harvest_verified_by() {
  local key="$1" matrix="$2"
  [ -n "$matrix" ] && [ -r "$matrix" ] || return 0
  local tok
  awk -v key="$key" -F'|' '
    {
      c1 = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", c1)
    }
    c1 == key {
      # Scan every remaining cell for test-shaped tokens.
      for (col = 3; col <= NF; col++) {
        cell = $col
        m = split(cell, toks, ",")
        for (j = 1; j <= m; j++) {
          tk = toks[j]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", tk)
          if (tk ~ /^TC-[A-Z0-9]/ || tk ~ /^T[0-9]+$/ || tk ~ /^TB-[0-9]/) {
            print tk
          }
        }
      }
    }
  ' "$matrix" | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    _emit_edge verified-by "$tok" || true
  done
}

# ---------------------------------------------------------------------------
# Review-filename harvest. Type-FIRST review reports anchored to the `-<KEY>.md`
# suffix, with the review-type token matched as a whole path component. Excludes
# review-summary, bare *-review (not an allowlisted type), execution-evidence
# json, and legacy key-first *-review-summary forms.
# ---------------------------------------------------------------------------

_harvest_reviewed_in() {
  local key="$1" reviews_dir="$2"
  [ -n "$reviews_dir" ] && [ -d "$reviews_dir" ] || return 0
  local f base stem
  # Only top-level *.md files in the reviews dir.
  for f in "$reviews_dir"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename -- "$f")"
    # Must end with -<KEY>.md.
    case "$base" in
      *"-$key".md) : ;;
      *) continue ;;
    esac
    # The review-type token is the allowlisted component immediately preceding
    # the -<KEY>.md suffix. Match `(^|-)<type>-<KEY>.md`.
    case "$base" in
      *"code-review-$key".md \
      |*"qa-tests-$key".md \
      |*"security-review-$key".md \
      |*"test-automate-review-$key".md \
      |*"test-review-$key".md \
      |*"performance-review-$key".md)
        # Exclude the legacy key-first review-summary form defensively (it does
        # not end with an allowlisted type anyway, but be explicit).
        case "$base" in
          *review-summary*) continue ;;
        esac
        stem="${base%.md}"
        _emit_edge reviewed-in "$stem" || true
        ;;
      *)
        # Not an allowlisted type (e.g. bare `...-review-<KEY>.md`,
        # `...-review-summary.md`) — skip.
        :
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# UX harvest. Emit a designs edge for each whole-token reference to the node key
# in the UX artifact.
# ---------------------------------------------------------------------------

_harvest_designs() {
  local key="$1" ux="$2"
  [ -n "$ux" ] && [ -r "$ux" ] || return 0
  # Whole-token search: the key bounded by non-key-character (or line edge).
  # grep -E with word-ish boundaries that work on bash 3.2 / BSD grep: surround
  # with a class of separators. We test for at least one occurrence; one edge.
  if awk -v key="$key" '
        {
          line = $0
          # Replace the key with a marker only when it is a whole token: it must
          # not be immediately followed by a key continuation char [0-9A-Za-z-].
          # Walk matches.
          rest = line
          while (match(rest, key)) {
            after = substr(rest, RSTART + length(key), 1)
            before = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
            if (after !~ /[0-9A-Za-z-]/ && before !~ /[0-9A-Za-z-]/) { found = 1 }
            rest = substr(rest, RSTART + length(key))
          }
        }
        END { exit (found ? 0 : 1) }
      ' "$ux"; then
    _emit_edge designs "$key" || true
  fi
}

# ---------------------------------------------------------------------------
# Frontmatter harvest. traces-to <- traces_to tokens; decomposes <- epic +
# blocks + depends_on; governed-by <- decision-shaped subset of traces_to.
# Prefer python3+PyYAML (structured, mirrors validate-brain-index.sh) with a
# grep/sed inline-list fallback for hosts without PyYAML.
# ---------------------------------------------------------------------------

_has_pyyaml() {
  # Additive once-per-sweep cache. A long full sweep calls this helper many
  # times per node; the bare probe forks python3 twice on every call, which
  # dominates the per-node cost. When the reindex sweep has already probed the
  # host ONCE and exported the result, honor it and skip the fork. When the
  # cache env is UNSET, fall through to the exact original probe so callers that
  # do not set it (every existing direct invocation) see byte-identical
  # behavior.
  case "${GAIA_BRAIN_PYYAML:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1
}

# _frontmatter_field <file> <field> — echo the tokens of an inline-list or
# scalar frontmatter field, one per line. PyYAML primary; grep/sed fallback.
_frontmatter_field() {
  local file="$1" field="$2"
  [ -n "$file" ] && [ -r "$file" ] || return 0
  if _has_pyyaml; then
    python3 - "$file" "$field" <<'PYEOF'
import sys, yaml
path, field = sys.argv[1], sys.argv[2]
text = open(path).read()
# Extract the leading YAML frontmatter block delimited by --- ... ---.
fm = ""
if text.startswith("---"):
    end = text.find("\n---", 3)
    if end != -1:
        fm = text[3:end]
doc = yaml.safe_load(fm) if fm.strip() else {}
doc = doc or {}
val = doc.get(field)
if val is None:
    sys.exit(0)
if isinstance(val, (list, tuple)):
    for v in val:
        if v is not None and str(v) != "":
            sys.stdout.write(str(v) + "\n")
else:
    s = str(val)
    if s != "":
        sys.stdout.write(s + "\n")
PYEOF
    return 0
  fi
  # ---- grep/sed fallback (inline-list + scalar) ----
  # Operate only on the leading frontmatter block (between the first two `---`).
  awk -v field="$field" '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    infm {
      # match `field: ...`
      if ($0 ~ "^" field "[[:space:]]*:") {
        val = $0
        sub("^" field "[[:space:]]*:[[:space:]]*", "", val)
        # Inline list form: [a, b, c]
        if (val ~ /^\[/) {
          gsub(/^\[|\]$/, "", val)
          n = split(val, parts, ",")
          for (i = 1; i <= n; i++) {
            t = parts[i]
            gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", t)
            if (t != "") print t
          }
        } else {
          # Scalar — strip quotes.
          gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", val)
          if (val != "") print val
        }
      }
    }
  ' "$file"
}

_harvest_frontmatter() {
  local file="$1"
  [ -n "$file" ] && [ -r "$file" ] || return 0
  local tok
  # traces-to + governed-by (decision-shaped subset) from traces_to.
  _frontmatter_field "$file" "traces_to" | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    _emit_edge traces-to "$tok" || true
    if _is_decision_token "$tok"; then
      _emit_edge governed-by "$tok" || true
    fi
  done
  # decomposes from epic.
  _frontmatter_field "$file" "epic" | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    _emit_edge decomposes "$tok" || true
  done
  # decomposes from blocks + depends_on.
  _frontmatter_field "$file" "blocks" | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    _emit_edge decomposes "$tok" || true
  done
  _frontmatter_field "$file" "depends_on" | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    _emit_edge decomposes "$tok" || true
  done
}

# ---------------------------------------------------------------------------
# C2 four-source linked predicate. LINKED if ANY of:
#   1. frontmatter traces_to non-empty
#   2. frontmatter epic present
#   3. an epics-prose Allocates row references the key (node has its own block
#      with an Allocates bullet that yielded tokens)
#   4. a matrix Story mapping references the key
# ---------------------------------------------------------------------------

_node_has_frontmatter_traces() {
  local file="$1"
  [ -n "$(_frontmatter_field "$file" "traces_to")" ]
}

_node_has_frontmatter_epic() {
  local file="$1"
  [ -n "$(_frontmatter_field "$file" "epic")" ]
}

_node_has_epics_allocation() {
  local key="$1" epics="$2"
  [ -n "$(_allocates_tokens "$key" "$epics")" ]
}

_node_has_matrix_mapping() {
  local key="$1" matrix="$2"
  [ -n "$matrix" ] && [ -r "$matrix" ] || return 1
  awk -v key="$key" -F'|' '
    # Requirement-to-story rows: key in the story comma-list of a requirement
    # row (cell 4). OR a per-story row whose first cell is the key.
    {
      c1 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c1)
      if (c1 == key) { found = 1 }
      stories = $4
      req = c1
      if (req ~ /^(FR|NFR)-[0-9]/) {
        n = split(stories, parts, ",")
        for (i = 1; i <= n; i++) {
          s = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
          if (s == key) { found = 1 }
        }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$matrix"
}

_is_node_linked() {
  local key="$1" epics="$2" matrix="$3" frontmatter="$4"
  if _node_has_frontmatter_traces "$frontmatter"; then return 0; fi
  if _node_has_frontmatter_epic "$frontmatter"; then return 0; fi
  if _node_has_epics_allocation "$key" "$epics"; then return 0; fi
  if _node_has_matrix_mapping "$key" "$matrix"; then return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# Orchestrator. Accumulate all edges, apply C2, render the fragment.
# Deterministic: sort by (type-rank, target) + de-dup. NEVER drops a node and
# NEVER returns non-zero for an unlinked node.
# ---------------------------------------------------------------------------

harvest_node_edges() {
  local key="" epics="" matrix="" frontmatter="" reviews_dir="" ux=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)         key="$2"; shift 2 ;;
      --epics)       epics="$2"; shift 2 ;;
      --matrix)      matrix="$2"; shift 2 ;;
      --frontmatter) frontmatter="$2"; shift 2 ;;
      --reviews-dir) reviews_dir="$2"; shift 2 ;;
      --ux)          ux="$2"; shift 2 ;;
      *) printf 'harvest-edges.sh: unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  if [ -z "$key" ]; then
    printf 'harvest-edges.sh: --key is required\n' >&2
    return 2
  fi

  # Default the four source locations to the real, path-helper-resolved paths
  # when a flag was omitted. Sourcing gaia-paths.sh is deferred to here so the
  # library is sourceable with no side effects.
  if [ -z "$epics" ] || [ -z "$matrix" ] || [ -z "$frontmatter" ] \
     || [ -z "$reviews_dir" ] || [ -z "$ux" ]; then
    local _self_dir _lib
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    _lib="$_self_dir/../lib/gaia-paths.sh"
    if [ -r "$_lib" ]; then
      # shellcheck source=../lib/gaia-paths.sh
      . "$_lib" || true
    fi
    [ -n "$epics" ] || epics="${GAIA_ARTIFACTS_DIR:-}/planning-artifacts/epics-and-stories.md"
    [ -n "$matrix" ] || matrix="${GAIA_ARTIFACTS_DIR:-}/test-artifacts/strategy/traceability-matrix.md"
    # frontmatter / reviews-dir / ux are node-specific; without an explicit flag
    # they have no deterministic default here (the sweep supplies them). Leave
    # empty — the parsers no-op on empty/unreadable inputs.
  fi

  # Accumulate edges into a temp file.
  _HE_ACC="$(mktemp "${TMPDIR:-/tmp}/he-acc.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$_HE_ACC' 2>/dev/null || true" RETURN

  _harvest_implements_governed_from_epics "$key" "$epics"
  _matrix_implements_from_matrix "$key" "$matrix"
  _harvest_verified_by "$key" "$matrix"
  _harvest_reviewed_in "$key" "$reviews_dir"
  _harvest_designs "$key" "$ux"
  _harvest_frontmatter "$frontmatter"

  # Apply C2. If unlinked, the node ships an empty edge set.
  local linked=1
  if _is_node_linked "$key" "$epics" "$matrix" "$frontmatter"; then
    linked=0
  fi

  # Render. Sort by (rank, target), de-dup identical (rank,type,target) lines so
  # the same edge harvested from two sources collapses to one. An unlinked node
  # always renders `edges: []` (by C2 it carries no edges anyway).
  local sorted=""
  if [ "$linked" -eq 0 ]; then
    sorted="$(LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k3,3 "$_HE_ACC" 2>/dev/null | LC_ALL=C uniq || true)"
  fi

  # A linked node with no harvested edges, and an unlinked node, both render the
  # empty edge list; only the unlinked verdict differs.
  if [ -z "$sorted" ]; then
    printf 'edges: []\n'
    if [ "$linked" -eq 0 ]; then
      printf 'unlinked: false\n'
    else
      printf 'unlinked: true\n'
    fi
    return 0
  fi

  printf 'edges:\n'
  # Each accumulator line is `rank\ttype\ttarget`.
  printf '%s\n' "$sorted" | while IFS="$(printf '\t')" read -r _rank etype target; do
    [ -n "$etype" ] || continue
    printf '  - type: %s\n' "$etype"
    printf '    target: %s\n' "$target"
  done
  printf 'unlinked: false\n'
  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------

__main() {
  harvest_node_edges "$@"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  __main "$@"
  exit $?
fi
