#!/usr/bin/env bash
# check-monolith-shard-sync.sh — detect monolith-vs-shard drift.
#
# Story: E53-S243 — Document and enforce monolith-vs-shard sync contract.
#
# Compares per-section content hashes between each monolith document
# (`prd.md`, `architecture.md`, `epics-and-stories.md`) and the union of
# its shard files. Emits WARNING lines on stdout when drift is detected,
# naming the section and the diverging file paths. ALWAYS exits 0
# (advisory check per the AF-2026-05-04-1 Batch D triage decision).
#
# Documented exceptions (no false-positive WARNING):
#   1. Change Log direction — the monolith Change Log is the source of
#      truth. The `01-change-log.md` shard mirrors it. Drift between the
#      two is expected when an entry has been written to the monolith
#      but not yet mirrored.
#   2. `_preamble.md` partial mirror — `_preamble.md` deliberately
#      contains only the monolith frontmatter, not the body. The check
#      MUST NOT compare it as a shard.
#   3. Missing shard directory — when a monolith exists but its shard
#      directory does not, emit an INFO line and continue (graceful
#      skip). A shard-only directory without a monolith is also tolerated.
#   4. Marker-shard + sibling-directory (sub-sharded) pair (E53-S249) —
#      a second-tier sharding model where a single H2 grows into its own
#      sibling directory of per-H3 child files. The parent shard
#      `<NN>-<slug>.md` retains a stub heading `## <N>. <title> — Sub-
#      Sharded` plus a pointer paragraph; the sibling directory
#      `<NN>-<slug>/` holds the actual per-H3 content. Recognised by
#      _is_marker_shard_pair() (both the marker shard AND the sibling
#      directory present, with ≥1 child *.md). When the pair is detected,
#      the `— Sub-Sharded` suffix is stripped before title matching, and
#      the body-hash divergence check is skipped (the marker shard is a
#      stub by design — body divergence is the expected state, not drift).
#      Single-half states (marker shard without dir, or dir without
#      marker shard) keep the WARNING — they may signal corruption.
#      Per-H3 child drift detection within the sibling directory is
#      TC-MSS-SUBSHARD-4-DEFERRED (out of scope for E53-S249).

set -euo pipefail

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------

ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      shift
      ROOT="${1:-.}"
      shift
      ;;
    -h|--help)
      cat <<USAGE
Usage: check-monolith-shard-sync.sh [--root <project-root>]

Compare each monolith document to its shard set and emit WARNING lines on
drift. Always exits 0 (advisory).

Monoliths checked:
  docs/planning-artifacts/prd/prd.md           vs docs/planning-artifacts/prd/<NN>-*.md
  docs/planning-artifacts/architecture/architecture.md vs docs/planning-artifacts/architecture/<NN>-*.md
  docs/planning-artifacts/epics/epics-and-stories.md   vs docs/planning-artifacts/epics/<NN>-*.md

Documented exceptions: Change Log monolith-as-source-of-truth and the
\`_preamble.md\` partial-mirror are NOT flagged.
USAGE
      exit 0
      ;;
    *)
      printf 'check-monolith-shard-sync: unknown arg: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

# Resolve to absolute path so `cd` semantics inside helpers are stable.
if [[ -d "$ROOT" ]]; then
  ROOT="$(cd "$ROOT" && pwd)"
fi

# ---------------------------------------------------------------------------
# sha256 helper — works on macOS (`shasum -a 256`) and GNU (`sha256sum`).
# ---------------------------------------------------------------------------

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# Normalize a content blob before hashing: strip leading/trailing blank
# lines and collapse trailing whitespace per line. This makes the
# comparison resilient to noise that does not change semantic content.
_normalize() {
  # Trim trailing whitespace on each line, drop leading/trailing blank
  # lines. Implemented in awk for portability.
  awk '
    { sub(/[[:space:]]+$/, "") }
    NF { found = 1 }
    found {
      buf[++n] = $0
      if (NF) last = n
    }
    END {
      for (i = 1; i <= last; i++) print buf[i]
    }
  '
}

# ---------------------------------------------------------------------------
# Section extraction.
# ---------------------------------------------------------------------------
#
# Extract H2 sections from a monolith file as `<title>\t<sha256>` lines.
# H2 boundary = lines starting with `## `. The first section is everything
# from the first `## ` line through (but not including) the next `## ` line.
# Frontmatter / preamble before the first `## ` is skipped (it is mirrored
# by `_preamble.md` per the partial-mirror exception).
_extract_h2_sections() {
  local file="$1"
  awk '
    /^## / {
      if (capturing) {
        # Emit prior section.
        print "__SECTION_BEGIN__"
        print title
        for (i = 1; i <= n; i++) print buf[i]
        print "__SECTION_END__"
      }
      title = substr($0, 4)
      capturing = 1
      n = 0
      next
    }
    capturing {
      buf[++n] = $0
    }
    END {
      if (capturing) {
        print "__SECTION_BEGIN__"
        print title
        for (i = 1; i <= n; i++) print buf[i]
        print "__SECTION_END__"
      }
    }
  ' "$file"
}

# Hash a shard file's content (ignoring leading H2 line so the hash matches
# the monolith section body). Returns `<title>\t<sha256>` for the FIRST H2
# in the shard, or empty if the shard has no H2.
_shard_section_hash() {
  local shard="$1"
  awk -v shard="$shard" '
    /^## / && !found {
      title = substr($0, 4)
      found = 1
      next
    }
    found {
      print
    }
  ' "$shard" | _normalize | _sha256
}

_shard_first_title() {
  local shard="$1"
  awk '
    /^## / { sub(/^## /, ""); print; exit }
  ' "$shard"
}

_section_body_hash() {
  # Stdin = section body. Returns sha256 of normalized body.
  _normalize | _sha256
}

# ---------------------------------------------------------------------------
# Sub-shard awareness helpers (E53-S249 / AF-2026-05-10-5).
# ---------------------------------------------------------------------------
#
# Marker-shard + sibling-directory pattern (introduced by E53-S235):
# a single H2 section that has grown unwieldy is split into a sibling
# directory of per-H3 child files. The parent shard `<NN>-<slug>.md`
# retains a stub heading `## <N>. <title> — Sub-Sharded` plus a one-line
# pointer paragraph. The sibling directory `<NN>-<slug>/` holds the
# actual content split per H3.
#
# This is recognised as a second-tier sharding model: both forward-pass
# WARNINGs (monolith H2 not in shards) and reverse-pass WARNINGs
# (shard H2 not in monolith) are suppressed when the marker-pair AND
# the title-after-stripping match. Single-half states (marker shard
# without dir, or dir without marker shard) keep the WARNING — they
# may signal corruption.
#
# The `— Sub-Sharded` token is U+2014 EM DASH + space; ASCII hyphen
# would silently fail (live fixtures use the em-dash).

# Strip the `— Sub-Sharded` suffix from a title. Idempotent.
_strip_sub_sharded_suffix() {
  local title="$1"
  printf '%s' "${title% — Sub-Sharded}"
}

# Returns 0 if both the marker shard (<shard_dir>/<NN-slug>.md) AND its
# sibling directory (<shard_dir>/<NN-slug>/) exist and the directory
# has at least one child *.md file. Otherwise returns 1.
_is_marker_shard_pair() {
  local shard_path="$1"  # e.g., prd/04-functional-requirements.md
  [[ -f "$shard_path" ]] || return 1
  local shard_base="${shard_path%.md}"  # strip .md -> prd/04-functional-requirements
  [[ -d "$shard_base" ]] || return 1
  # Confirm at least one *.md child.
  local first_child
  first_child=$(find "$shard_base" -mindepth 1 -maxdepth 1 -type f -name '*.md' -print -quit 2>/dev/null)
  [[ -n "$first_child" ]]
}

# ---------------------------------------------------------------------------
# Per-monolith comparison.
# ---------------------------------------------------------------------------
#
# Args:
#   $1 = monolith file path
#   $2 = shard directory path
#   $3 = label for messages (e.g. "prd", "architecture", "epics")
_compare_monolith() {
  local monolith="$1"
  local shard_dir="$2"
  local label="$3"

  if [[ ! -f "$monolith" ]]; then
    return 0
  fi
  if [[ ! -d "$shard_dir" ]]; then
    printf 'INFO: %s — monolith %s exists but shard dir %s missing\n' \
      "$label" "$monolith" "$shard_dir"
    return 0
  fi

  # Build the shard title -> file map. We skip:
  #   - `_preamble.md`   (partial-mirror exception)
  #   - `index.md`       (auto-generated index)
  #   - non-`NN-*.md` files (not numbered shards)
  # Each shard's "title" is the first H2 in the file. If two shards share
  # the same title (rare), the later one wins — drift detection is still
  # informative.
  local title_to_shard_titles=()
  local title_to_shard_paths=()
  local title_to_marker_pair=()  # E53-S249: parallel array — "1" if shard is marker-pair, "0" otherwise
  local shard
  while IFS= read -r shard; do
    [[ -z "$shard" ]] && continue
    local base
    base="$(basename "$shard")"
    if [[ "$base" == "_preamble.md" ]] || [[ "$base" == "index.md" ]]; then
      continue
    fi
    # Skip filenames that are not `NN-...`.
    if ! [[ "$base" =~ ^[0-9]+ ]]; then
      continue
    fi
    local stitle
    stitle="$(_shard_first_title "$shard")"
    [[ -z "$stitle" ]] && continue
    # E53-S249: normalize "<title> — Sub-Sharded" -> "<title>" when the
    # marker-shard + sibling-directory pair is present. The normalized
    # title is what we store in the map so both forward-pass and reverse-
    # pass title matching resolve correctly against the monolith H2.
    local is_pair="0"
    if _is_marker_shard_pair "$shard"; then
      is_pair="1"
      stitle="$(_strip_sub_sharded_suffix "$stitle")"
    fi
    title_to_shard_titles+=("$stitle")
    title_to_shard_paths+=("$shard")
    title_to_marker_pair+=("$is_pair")
  done < <(find "$shard_dir" -mindepth 1 -maxdepth 1 -type f -name '*.md' | sort)

  # Walk the monolith H2 sections.
  local in_section=0 cur_title="" cur_body=""
  local extract_output
  extract_output="$(_extract_h2_sections "$monolith")"

  # Process the extract output line-by-line (it uses sentinel markers).
  local IFS_BAK="$IFS"
  IFS=$'\n'
  local lines=()
  local line
  while IFS= read -r line; do
    lines+=("$line")
  done <<< "$extract_output"
  IFS="$IFS_BAK"

  local i=0
  while [[ $i -lt ${#lines[@]} ]]; do
    local L="${lines[$i]}"
    if [[ "$L" == "__SECTION_BEGIN__" ]]; then
      i=$((i + 1))
      cur_title="${lines[$i]}"
      i=$((i + 1))
      cur_body=""
      while [[ $i -lt ${#lines[@]} ]] && [[ "${lines[$i]}" != "__SECTION_END__" ]]; do
        if [[ -n "$cur_body" ]]; then
          cur_body+=$'\n'
        fi
        cur_body+="${lines[$i]}"
        i=$((i + 1))
      done
      i=$((i + 1))  # skip __SECTION_END__

      # Documented exception: Change Log direction (monolith is source of
      # truth). Skip drift checks for any section whose title contains
      # "Change Log".
      if [[ "$cur_title" == *"Change Log"* ]]; then
        continue
      fi

      # Find the matching shard for this section title.
      local matched_idx=-1
      local k
      for k in "${!title_to_shard_titles[@]}"; do
        if [[ "${title_to_shard_titles[$k]}" == "$cur_title" ]]; then
          matched_idx=$k
          break
        fi
      done

      if [[ $matched_idx -eq -1 ]]; then
        # Section in monolith with no matching shard. Architecture has
        # known multi-H2-per-shard aggregation, so this is INFO-level
        # for architecture and a WARNING for the other docs.
        if [[ "$label" == "architecture" ]]; then
          # For architecture we expect aggregation — silent skip.
          continue
        fi
        printf 'WARNING: %s — section "%s" present in %s but no matching shard\n' \
          "$label" "$cur_title" "$monolith"
        continue
      fi

      local shard_path="${title_to_shard_paths[$matched_idx]}"

      # E53-S249: marker-shard + sibling-directory pair — the marker shard
      # is a stub (`## <title> — Sub-Sharded` + pointer paragraph) by
      # design. The actual content lives in the sibling directory's child
      # files. Body divergence between the monolith H2 and the marker
      # shard is the EXPECTED state, not drift. Skip the body-hash
      # comparison for marker pairs. (Per-H3 child drift detection within
      # the sibling directory is TC-MSS-SUBSHARD-4-DEFERRED — out of
      # scope for this story.)
      if [[ "${title_to_marker_pair[$matched_idx]}" == "1" ]]; then
        continue
      fi

      # Hash monolith section body.
      local mono_hash
      mono_hash="$(printf '%s\n' "$cur_body" | _section_body_hash)"

      # Hash shard body (post first H2).
      local shard_hash
      shard_hash="$(_shard_section_hash "$shard_path")"

      if [[ "$mono_hash" != "$shard_hash" ]]; then
        printf 'WARNING: %s — section "%s" diverges between %s and %s\n' \
          "$label" "$cur_title" "$monolith" "$shard_path"
      fi
    else
      i=$((i + 1))
    fi
  done

  # Reverse pass: shards with no matching monolith section.
  local k
  for k in "${!title_to_shard_titles[@]}"; do
    local stitle="${title_to_shard_titles[$k]}"
    local spath="${title_to_shard_paths[$k]}"
    # Skip Change Log shard (documented exception).
    if [[ "$stitle" == *"Change Log"* ]]; then
      continue
    fi
    # Look for a matching H2 in the monolith.
    if ! grep -Fq "## $stitle" "$monolith"; then
      printf 'WARNING: %s — section "%s" present in shard %s but absent from %s\n' \
        "$label" "$stitle" "$spath" "$monolith"
    fi
  done
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

# AF-2026-05-21-25: resolve artifacts dir canonical-first (.gaia/) with legacy
# (docs/) fallback for pre-ADR-111 projects.
if [ -d "$ROOT/.gaia/artifacts/planning-artifacts" ]; then
  _ARTIFACTS_DIR="$ROOT/.gaia/artifacts/planning-artifacts"
else
  _ARTIFACTS_DIR="$ROOT/docs/planning-artifacts"
fi

# PRD.
_compare_monolith \
  "$_ARTIFACTS_DIR/prd/prd.md" \
  "$_ARTIFACTS_DIR/prd" \
  "prd"

# Architecture.
_compare_monolith \
  "$_ARTIFACTS_DIR/architecture/architecture.md" \
  "$_ARTIFACTS_DIR/architecture" \
  "architecture"

# Epics.
_compare_monolith \
  "$_ARTIFACTS_DIR/epics/epics-and-stories.md" \
  "$_ARTIFACTS_DIR/epics" \
  "epics"

# ---------------------------------------------------------------------------
# E59-S6 — per-story status drift between monolith and per-epic shard.
#
# Walks every `### Story <KEY>:` block in the epics monolith, resolves the
# matching `*-e<EID>-*.md` shard via the canonical glob, parses the
# `- **Status:** <state>` line in each, and emits a WARNING when the values
# differ. Stays advisory (always exit 0) and additive: the existing 12
# prd/architecture WARNINGs are preserved unchanged. Per-story status
# WARNINGs fire only when the shard exists AND contains the matching
# `### Story <KEY>:` block — missing shards are NOT divergence.
#
# Refs: AF-2026-05-08-6, ADR-070, ADR-074 contract C3, TC-TSS-SHARD-6.
# ---------------------------------------------------------------------------

_check_per_story_status_drift() {
  # Resolve the monolith across the dual layout (E64-S4): the canonical
  # path is `{artifacts_dir}/epics/epics-and-stories.md`, but
  # legacy projects keep it flat at `{artifacts_dir}/epics-and-stories.md`.
  # AF-2026-05-21-25: probe canonical .gaia/artifacts/ first, then legacy docs/.
  # Mirror the resolver order in transition-story-status.sh to stay in sync.
  local monolith=""
  local artifacts_dirs=("$ROOT/.gaia/artifacts/planning-artifacts" "$ROOT/docs/planning-artifacts")
  for d in "${artifacts_dirs[@]}"; do
    if [[ -f "$d/epics-and-stories.md" ]]; then
      monolith="$d/epics-and-stories.md"; break
    elif [[ -f "$d/epics-and-stories/index.md" ]]; then
      monolith="$d/epics-and-stories/index.md"; break
    elif [[ -f "$d/epics/epics-and-stories.md" ]]; then
      monolith="$d/epics/epics-and-stories.md"; break
    elif [[ -f "$d/epics/index.md" ]]; then
      monolith="$d/epics/index.md"; break
    fi
  done
  if [[ -z "$monolith" ]]; then
    return 0
  fi
  # Shard dir lives under the same artifacts root as the resolved monolith.
  local monolith_root="${monolith%/*}"
  monolith_root="${monolith_root%/epics*}"
  local shard_dir="$monolith_root/epics"
  if [[ ! -d "$shard_dir" ]]; then
    return 0
  fi

  # Extract every `### Story <KEY>: <title>` line plus its first per-story
  # `- **Status:** <state>` line within the same block. Block boundary is
  # the next `### Story` heading or a top-level `## ` heading.
  awk '
    BEGIN { in_block = 0; key = ""; status = "" }
    /^### Story / {
      if (in_block && key != "" && status != "") {
        printf "%s\t%s\n", key, status
      }
      key = $0
      sub(/^### Story /, "", key)
      sub(/:.*$/, "", key)
      status = ""
      in_block = 1
      next
    }
    /^## / && !/^### / {
      if (in_block && key != "" && status != "") {
        printf "%s\t%s\n", key, status
      }
      in_block = 0
      key = ""
      status = ""
      next
    }
    in_block && /^- \*\*Status:\*\*/ {
      if (status == "") {
        status = $0
        sub(/^- \*\*Status:\*\*[[:space:]]*/, "", status)
        sub(/[[:space:]]+$/, "", status)
      }
      next
    }
    END {
      if (in_block && key != "" && status != "") {
        printf "%s\t%s\n", key, status
      }
    }
  ' "$monolith" | while IFS=$'\t' read -r mkey mstatus; do
    [[ -z "$mkey" ]] && continue
    # Extract numeric EID from key (e.g., E76-S7 -> 76).
    local eid
    if [[ "$mkey" =~ ^E([0-9]+)-S[0-9]+$ ]]; then
      eid="${BASH_REMATCH[1]}"
    else
      continue
    fi
    # Glob `*-e<EID>-*.md` (case-insensitive on the e<EID> token).
    shopt -s nullglob nocaseglob
    local matches=( "$shard_dir"/*-e${eid}-*.md )
    shopt -u nocaseglob nullglob
    if [[ "${#matches[@]}" -ne 1 ]]; then
      # Zero-match: missing shard is not divergence (per AC4 wording).
      # Multi-match: structural break — out of scope for this advisory walk
      # (transition-story-status.sh fails loud on multi-match writes).
      continue
    fi
    local shard="${matches[0]}"
    # Read the per-story Status line under `### Story <KEY>:` block in the
    # shard. If the shard does NOT contain the block, NOT divergence.
    local sstatus
    sstatus="$(awk -v target="$mkey" '
      BEGIN { in_block = 0 }
      /^### Story / {
        in_block = (index($0, "Story " target ":") > 0)
        next
      }
      in_block && /^## / && !/^### / { in_block = 0; next }
      in_block && /^- \*\*Status:\*\*/ {
        v = $0
        sub(/^- \*\*Status:\*\*[[:space:]]*/, "", v)
        sub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    ' "$shard")"
    if [[ -z "$sstatus" ]]; then
      # Shard does not contain the per-story block — graceful skip.
      continue
    fi
    if [[ "$mstatus" != "$sstatus" ]]; then
      printf 'WARNING: epics-shard — story %s status diverges between monolith and %s (monolith=%s, shard=%s)\n' \
        "$mkey" "$shard" "$mstatus" "$sstatus"
    fi
  done
}

_check_per_story_status_drift

# Special case: PRD monolith may live at docs/planning-artifacts/prd.md
# (legacy layout) with no shard directory. Honor the missing-shard-dir
# graceful skip path.
if [[ -f "$ROOT/docs/planning-artifacts/prd.md" ]] && [[ ! -d "$ROOT/docs/planning-artifacts/prd" ]]; then
  printf 'INFO: prd — monolith %s/docs/planning-artifacts/prd.md exists but no shard dir\n' "$ROOT"
fi

exit 0
