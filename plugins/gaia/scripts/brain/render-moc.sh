#!/usr/bin/env bash
# render-moc.sh — render the brain knowledge layer's human-browsable
# Map-of-Content (MOC) from the brain-index.yaml manifest.
#
# WHAT IT DOES
#   A pure function of the on-disk manifest. Given a brain-index.yaml and an
#   output path, it emits an Obsidian-native markdown index that groups entries
#   by artifact type in a fixed canonical order, key-sorts entries within each
#   group, and renders for each entry an Obsidian [[wikilink]] (target relative
#   to .gaia/knowledge/), a synopsis, its tags, and an edge summary.
#
# DETERMINISM (the central contract)
#   The render is a PURE function of the manifest bytes — re-rendering the same
#   manifest produces byte-identical output. There is NO timestamp, NO wall
#   clock, NO $RANDOM, NO hash-map iteration order. Grouping order is a fixed
#   canonical list; within-group order is an LC_ALL=C key sort. This is what lets
#   the sweep regenerate the MOC every run and have a no-op re-sweep leave the
#   MOC unchanged.
#
# WHY OBSIDIAN-NATIVE
#   The .gaia/ tree is openable as an Obsidian vault; brain-index.md is the vault
#   MOC. Links use the [[target|alias]] form so the readable label is the entry
#   key and the link is the artifact's path. Targets are computed relative to
#   .gaia/knowledge/ (strip the stored path's leading .gaia/, prepend ../) so a
#   click opens the real artifact in place. Obsidian is NOT a runtime dependency
#   — the YAML manifest is the programmatic SSOT; this MOC is a derived human
#   convenience.
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags, no grep -P. LC_ALL=C. set -euo pipefail. Sourceable
# (functions become available; no side effects) AND executable (the dispatcher
# runs only when executed directly).

set -euo pipefail
LC_ALL=C
export LC_ALL

# Fixed canonical artifact-type order for the MOC sections. Mirrors the lifecycle
# (planning inputs → architecture → decomposition → build → verify → creative →
# research → runtime state → uncategorized). This order is STABLE across renders
# — it is a literal list, never derived from hash-map iteration. Any tag not in
# this list is bucketed under "artifact" (the trailing catch-all) so no entry is
# ever dropped from the MOC.
_RMOC_TYPE_ORDER="planning prd architecture epics implementation test creative research state artifact"

# Human-readable section heading for a type tag.
_rmoc_type_title() {
  case "$1" in
    planning)       printf 'Planning' ;;
    prd)            printf 'Product Requirements' ;;
    architecture)   printf 'Architecture' ;;
    epics)          printf 'Epics & Stories' ;;
    implementation) printf 'Implementation' ;;
    test)           printf 'Test' ;;
    creative)       printf 'Creative' ;;
    research)       printf 'Research' ;;
    state)          printf 'State' ;;
    *)              printf 'Other Artifacts' ;;
  esac
}

# ---------------------------------------------------------------------------
# Parse the manifest into a flat, tab-delimited records file. One line per entry:
#   tag \t key \t wikilink_target \t synopsis \t tags_csv \t edge_summary
# Uses python3+PyYAML when present (robust), else a line-based awk fallback. The
# fallback degrades the edge summary to a count (it cannot always reconstruct the
# nested edge list reliably) but renders a valid MOC with the correct entry set.
#
# Args: $1 manifest  $2 out_records_file
# ---------------------------------------------------------------------------
_rmoc_parse() {
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

def clean(s):
    # Collapse to a single line; tabs/newlines/CR would corrupt the TSV.
    s = "" if s is None else str(s)
    return s.replace("\t", " ").replace("\r", " ").replace("\n", " ")

def wikilink_target(path):
    p = clean(path)
    # Strip a leading ./, then the .gaia/ prefix, then prepend ../ so the link
    # resolves from .gaia/knowledge/.
    if p.startswith("./"):
        p = p[2:]
    if p.startswith(".gaia/"):
        p = p[len(".gaia/"):]
    return "../" + p

def edge_summary(edges):
    edges = edges or []
    if not edges:
        return "no edges"
    # Deterministic: count per type, then render in a fixed type order.
    order = ["implements", "traces-to", "decomposes", "governed-by",
             "verified-by", "reviewed-in", "designs"]
    counts = {}
    for e in edges:
        t = clean(e.get("type", ""))
        if not t:
            continue
        counts[t] = counts.get(t, 0) + 1
    parts = []
    for t in order:
        if t in counts:
            parts.append("%s x%d" % (t, counts[t]))
    # Any unknown type (defensive) appended in sorted order.
    for t in sorted(counts):
        if t not in order:
            parts.append("%s x%d" % (t, counts[t]))
    n = sum(counts.values())
    return "%d edge%s (%s)" % (n, "" if n == 1 else "s", ", ".join(parts))

rows = []
for e in entries:
    key = clean(e.get("key", ""))
    if not key:
        continue
    tags = e.get("tags") or []
    tags = [clean(t) for t in tags if clean(t)]
    tag = tags[0] if tags else "artifact"
    tags_csv = ", ".join(tags)
    target = wikilink_target(e.get("path", ""))
    syn = clean(e.get("synopsis", ""))
    es = edge_summary(e.get("edges"))
    rows.append("\t".join([tag, key, target, syn, tags_csv, es]))

with open(out, "w") as f:
    for r in rows:
        f.write(r + "\n")
PYEOF
    return 0
  fi

  # ---- awk fallback (line-based, no PyYAML) ----
  # Parse the deterministic block shape the sweep emits:
  #   - key: "..."
  #     path: "..."
  #     tags: ["a", "b"]
  #     synopsis: "..."
  #     edges:        (or  edges: [])
  #       - type: ...
  #     ... (trust block follows)
  # The edge summary degrades to a raw count of `- type:` lines per entry.
  awk '
    function flush() {
      if (have) {
        # Default tag if none parsed.
        if (tag == "") tag = "artifact"
        es = (ecount > 0) ? (ecount " edge" (ecount==1?"":"s")) : "no edges"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", tag, key, target, syn, tagscsv, es
      }
      have=0; key=""; target=""; syn=""; tag=""; tagscsv=""; ecount=0
    }
    function unq(v) {
      # strip surrounding whitespace then surrounding double quotes
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"")
        v = substr(v, 2, length(v)-2)
      return v
    }
    /^- key:/ {
      flush()
      have=1
      v=$0; sub(/^- key:[[:space:]]*/, "", v); key=unq(v)
      next
    }
    have && /^  path:/ {
      v=$0; sub(/^  path:[[:space:]]*/, "", v); p=unq(v)
      sub(/^\.\//, "", p)
      sub(/^\.gaia\//, "", p)
      target = "../" p
      next
    }
    have && /^  tags:/ {
      v=$0; sub(/^  tags:[[:space:]]*/, "", v)
      gsub(/^\[|\]$/, "", v)
      # split on comma, strip quotes/space, join with ", "
      n=split(v, parts, ",")
      out=""; first=""
      for (i=1;i<=n;i++) {
        t=parts[i]; gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", t)
        if (t=="") continue
        if (first=="") first=t
        out = (out=="") ? t : out ", " t
      }
      tag=first; tagscsv=out
      next
    }
    have && /^  synopsis:/ {
      v=$0; sub(/^  synopsis:[[:space:]]*/, "", v); syn=unq(v)
      next
    }
    have && /^    - type:/ { ecount++; next }
    END { flush() }
  ' "$manifest" >> "$out" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# render_moc <manifest.yaml> <out.md>
#   Render the MOC deterministically from the manifest. Writes atomically via a
#   sibling tempfile + rename. Returns non-zero (without touching the target) on
#   a missing manifest or an unwritable output directory.
# ---------------------------------------------------------------------------
render_moc() {
  local manifest="$1" out="$2"
  if [ -z "$manifest" ] || [ -z "$out" ]; then
    printf 'render-moc.sh: usage: render_moc <manifest.yaml> <out.md>\n' >&2
    return 2
  fi
  if [ ! -r "$manifest" ]; then
    printf 'render-moc.sh: manifest not readable: %s\n' "$manifest" >&2
    return 2
  fi

  # Probe PyYAML once (robust parse). Falls back to awk when absent.
  local have_pyyaml=0
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    have_pyyaml=1
  fi

  # Scratch dir for the records + section bodies.
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rmoc.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' 2>/dev/null || true" RETURN

  local records="$tmp/records.tsv"
  _rmoc_parse "$manifest" "$records" "$have_pyyaml"

  # Stage the MOC body in a sibling tempfile of the target so the final rename is
  # atomic on the same store. The MOC is plain markdown (NOT schema-validated),
  # so a plain .tmp suffix is fine — the .yaml-suffix workaround the sweep needs
  # does NOT apply here.
  local out_dir
  out_dir="$(dirname -- "$out")"
  mkdir -p "$out_dir" 2>/dev/null || {
    printf 'render-moc.sh: cannot create output dir: %s\n' "$out_dir" >&2
    return 1
  }
  local body
  body="$(mktemp "${out}.tmp.XXXXXX")" || {
    printf 'render-moc.sh: cannot stage output tempfile next to %s\n' "$out" >&2
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' 2>/dev/null || true; rm -f '$body' 2>/dev/null || true" RETURN

  # --- Header (stable, no timestamp) ---
  {
    printf '# Brain Index — Map of Content\n'
    printf '\n'
    printf 'A rendered map of the project knowledge layer. Entries are grouped by\n'
    printf 'artifact type; each links to the artifact in place. This file is\n'
    printf 'regenerated from the manifest on every reindex — do not edit by hand.\n'
    printf '\n'
  } > "$body"

  # --- Empty manifest → a valid MOC with a no-entries line ---
  if [ ! -s "$records" ]; then
    printf '_No entries in the brain index yet._\n' >> "$body"
    mv "$body" "$out" || {
      printf 'render-moc.sh: atomic rename failed\n' >&2
      return 1
    }
    return 0
  fi

  # --- Emit each type section in the fixed canonical order ---
  local tag title section_file
  for tag in $_RMOC_TYPE_ORDER; do
    section_file="$tmp/section-$tag.txt"
    # Select this tag's records, key-sorted (LC_ALL=C). The catch-all "artifact"
    # bucket also absorbs any tag NOT named in the canonical order list.
    if [ "$tag" = "artifact" ]; then
      awk -F'\t' -v order="$_RMOC_TYPE_ORDER" '
        BEGIN { n=split(order, a, " "); for (i=1;i<=n;i++) known[a[i]]=1 }
        { if (!($1 in known) || $1=="artifact") print }
      ' "$records" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 > "$section_file"
    else
      awk -F'\t' -v t="$tag" '$1==t' "$records" \
        | LC_ALL=C sort -t "$(printf '\t')" -k2,2 > "$section_file"
    fi
    [ -s "$section_file" ] || continue

    title="$(_rmoc_type_title "$tag")"
    {
      printf '## %s\n' "$title"
      printf '\n'
    } >> "$body"

    # Render each entry line. Fields: tag key target synopsis tags_csv edge_summary
    while IFS="$(printf '\t')" read -r _t key target syn tags_csv edges; do
      [ -n "$key" ] || continue
      # The Obsidian wikilink: [[target|key]] — alias is the readable key.
      printf -- '- [[%s|%s]]' "$target" "$key" >> "$body"
      if [ -n "$syn" ]; then
        printf -- ' — %s' "$syn" >> "$body"
      fi
      printf '\n' >> "$body"
      if [ -n "$tags_csv" ]; then
        printf -- '  - tags: %s\n' "$tags_csv" >> "$body"
      fi
      if [ -n "$edges" ]; then
        printf -- '  - edges: %s\n' "$edges" >> "$body"
      fi
    done < "$section_file"
    printf '\n' >> "$body"
  done

  # --- Atomic rename (sibling tempfile → target on the same store) ---
  mv "$body" "$out" || {
    printf 'render-moc.sh: atomic rename failed\n' >&2
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  render_moc "$@"
  exit $?
fi
