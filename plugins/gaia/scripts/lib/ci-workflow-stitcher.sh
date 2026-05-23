#!/usr/bin/env bash
# ci-workflow-stitcher.sh — Four-phase CI workflow stitching engine
# (E98-S2, FR-517, ADR-114 §Consequences).
#
# Sourceable, NOT executable. Exposes one function:
#
#   gaia_ci_stitch <managed-yml> [<output-path>]
#     Composes a stitched workflow from <managed-yml> + sibling overlays:
#       gaia-{base}.user-jobs.yml   (jobs YAML-merged into managed jobs:)
#       gaia-{base}.user-steps.yml  (steps_before_gaia / steps_after_gaia
#                                     spliced around the managed steps block)
#     Writes to <output-path> if given, else stdout.
#
# Four-phase stitching order (FR-517 / ADR-114 §(c) — non-negotiable):
#   (1) GAIA template scaffold (managed file as-read)
#   (2) user-steps.yml steps_before_gaia  → spliced BEFORE managed steps block
#   (3) gaia jobs ∪ user-jobs.yml entries → YAML union into jobs: map
#   (4) user-steps.yml steps_after_gaia   → spliced AFTER managed steps block
#
# Block-level insertion ONLY (per FR-517 / ADR-114 §Rationale): per-step
# insert_after / insert_before markers in overlay files are NOT honored — the
# stitcher splices the user-step entries verbatim at the block edges, even
# if the entries carry per-step marker keys (those keys flow through to the
# output as plain YAML, but the stitcher ignores them for placement).
#
# Determinism contract (TC-CCL-8 / ADR-114 §(c)):
#   Same inputs → byte-identical output. Sort key: alphabetical by overlay
#   filename, then declaration order within each overlay file. yq is invoked
#   with a stable pretty-print profile (-P) and LC_ALL=C is exported.
#
# Dependencies: yq v4.x (already used elsewhere in the framework — confirmed
# present in CI via the bats suite invocation).
#
# Source guard: _GAIA_CI_WORKFLOW_STITCHER_LOADED=1 after first source;
# subsequent sources are no-ops.

if [ "${_GAIA_CI_WORKFLOW_STITCHER_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_CI_WORKFLOW_STITCHER_LOADED=1

LC_ALL=C
export LC_ALL

# Internal: locate the prefix-detection helper (E98-S1) for overlay classification
# and the protected-jobs assertion (E98-S3) for the FR-517 union-step guard.
_GAIA_STITCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$_GAIA_STITCHER_DIR/ci-prefix-detection.sh"
# shellcheck disable=SC1091
. "$_GAIA_STITCHER_DIR/assert-protected-jobs.sh"

# Internal: extract a YAML list under a top-level key from a user-steps.yml
# file. Stops at the next top-level key or EOF. Emits the indented list
# entries on stdout (without the key itself).
_gaia_stitcher_extract_steps_block() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  awk -v k="$key" '
    BEGIN { in_block = 0 }
    $0 ~ "^"k":" {
      in_block = 1
      if ($0 ~ /:[[:space:]]*\[\]/) { in_block = 0 }
      next
    }
    in_block && /^[A-Za-z_][A-Za-z0-9_-]*:/ { in_block = 0 }
    in_block && /^[^ \t#]/ && !/^$/ { in_block = 0 }
    in_block { print }
  ' "$file"
}

# Internal: splice steps_before_gaia / steps_after_gaia entries around the
# managed steps block. Operates on a managed-workflow YAML stream on stdin.
# Awk-based for comment preservation; yq's eval-all loses comments in nested
# merges, so the splice is line-surgical instead.
#
# Algorithm: find the first `steps:` key that opens a sequence (one
# top-level steps block per job is the convention; multi-job stitching of
# per-job step overlays is OUT OF SCOPE for FR-517 block-level edges —
# splice into the first managed steps block of the file).
_gaia_stitcher_splice_steps() {
  local before="$1"   # path to a file containing steps_before_gaia entries (may be empty)
  local after="$2"   # path to a file containing steps_after_gaia entries (may be empty)

  # Helper: detect the leading-whitespace count of the FIRST non-blank line in
  # a file. Used to re-indent overlay entries to match the managed steps block.
  _gss_src_indent() {
    local f="$1"
    [ -s "$f" ] || { echo "0"; return; }
    awk '/^[ \t]*[^ \t#]/ { match($0, /^[ \t]*/); print RLENGTH; exit }' "$f"
  }

  local src_before src_after
  src_before=$(_gss_src_indent "$before")
  src_after=$(_gss_src_indent "$after")

  awk -v bf="$before" -v af="$after" \
      -v src_bf="$src_before" -v src_af="$src_after" '
    # Re-indent overlay lines to target indent. Source indent (src) is the
    # leading-whitespace count of the first non-blank line in the overlay
    # file; target is the entry indent inside the managed steps block.
    function emit_file(path, src, target,    line, cur, delta, pad) {
      if (path == "" ) return
      delta = target - src
      pad = ""
      if (delta > 0) {
        for (i = 0; i < delta; i++) pad = pad " "
      }
      while ((getline line < path) > 0) {
        if (line ~ /^[ \t]*$/) { print line; continue }
        if (delta == 0) { print line }
        else if (delta > 0) { print pad line }
        else {
          # Negative delta: strip up to -delta leading spaces (only spaces;
          # tabs left untouched to avoid corrupting them).
          cut = -delta
          # Compute actual leading spaces on this line.
          match(line, /^[ ]*/)
          have = RLENGTH
          if (have >= cut) print substr(line, cut + 1)
          else print substr(line, have + 1)
        }
      }
      close(path)
    }
    BEGIN {
      seen_steps = 0
      in_steps = 0
      steps_indent = -1
      entry_indent = -1
    }
    # First steps: key opens the managed steps block.
    !seen_steps && /^[ \t]+steps:[ \t]*$/ {
      print
      # Compute the leading indent of the "steps:" key so we can detect end.
      match($0, /^[ \t]+/)
      steps_indent = RLENGTH
      # Assume entry indent is steps_indent + 2 (YAML convention). The first
      # in-block list line will refine this if it differs.
      entry_indent = steps_indent + 2
      seen_steps = 1
      in_steps = 1
      pending_before = 1
      next
    }
    # First in-block line — refine entry_indent from the first list marker.
    in_steps && pending_before {
      if ($0 ~ /^[ \t]*-[ \t]/) {
        match($0, /^[ \t]*/)
        entry_indent = RLENGTH
      }
      # Now splice the before-block at the refined entry indent.
      emit_file(bf, src_bf, entry_indent)
      pending_before = 0
    }
    # Track end of the steps block: next non-blank line with leading whitespace
    # less than or equal to steps_indent indicates the block has ended.
    in_steps {
      # Blank line — emit and continue (still inside block).
      if ($0 ~ /^[ \t]*$/) { print; next }
      match($0, /^[ \t]*/)
      cur_indent = RLENGTH
      if (cur_indent <= steps_indent) {
        # End of block — splice steps_after_gaia at the entry indent.
        emit_file(af, src_af, entry_indent)
        in_steps = 0
        print
        next
      }
    }
    { print }
    END {
      # If the file ended while still inside the steps block, splice after.
      if (in_steps) emit_file(af, src_af, entry_indent)
    }
  '
}

# Internal: emit YAML union of two `jobs:` maps. The managed workflow's
# jobs: stays as-is; the user-jobs.yml's top-level jobs: is merged in via
# yq eval-all '. as $i ireduce ({}; . * $i)' (last-writer-wins on key collision,
# but per FR-517 collision detection is E98-S3's responsibility — this stitcher
# does a straightforward union and trusts the validator).
#
# Input: managed-workflow path + user-jobs.yml path.
# Output (stdout): managed-workflow YAML with jobs: replaced by the union.
_gaia_stitcher_union_jobs() {
  local managed="$1"
  local jobs_ovl="$2"
  if [ -z "$jobs_ovl" ] || [ ! -f "$jobs_ovl" ]; then
    cat "$managed"
    return 0
  fi
  # yq eval-all '. as $item ireduce ({}; . * $item)' merges all docs.
  # The union pulls overlay top-level keys into the managed doc — which
  # includes the overlay's `jobs:` map being unioned into the managed
  # workflow's `jobs:` map (last-writer-wins on key collision; collision
  # detection is E98-S3's job per FR-517).
  #
  # File-based union (no shell-quoted YAML scalar round-trip — that was
  # version-fragile per pre-merge review): yq processes both files in one
  # pass with `eval-all` and the ireduce merge accumulator. Exit-status is
  # propagated explicitly to the caller via the explicit return; previous
  # implementation swallowed failures via the fallback branch.
  if ! yq eval-all '
    . as $item ireduce ({}; . * $item)
  ' "$managed" "$jobs_ovl"; then
    printf 'ci-workflow-stitcher.sh: yq union failed for %s + %s\n' \
      "$managed" "$jobs_ovl" >&2
    return 1
  fi
}

gaia_ci_stitch() {
  local managed="${1:-}"
  local output="${2:-}"

  if [ -z "$managed" ]; then
    printf 'ci-workflow-stitcher.sh: gaia_ci_stitch requires a managed-yml path\n' >&2
    return 2
  fi
  if [ ! -f "$managed" ]; then
    printf 'ci-workflow-stitcher.sh: managed file not found: %s\n' "$managed" >&2
    return 2
  fi

  # Phase 0: classify the managed file via the E98-S1 prefix-detection helper.
  local cls
  cls="$(gaia_ci_classify "$managed")"
  case "$cls" in
    generated) ;;
    *)
      # Only `generated` files are stitcher candidates. Others (overlay,
      # user-authored, unprefixed) are passed through unchanged — the
      # stitcher refuses to compose them.
      if [ -n "$output" ]; then
        cp "$managed" "$output"
      else
        cat "$managed"
      fi
      return 0
      ;;
  esac

  # Phase 0b: enumerate overlay files via filename convention. Per the
  # gaia_ci_classify contract (E98-S1), both shapes resolve to `overlay`;
  # we re-derive the path here from the managed-file basename so the
  # enumeration is deterministic.
  local dir base name
  dir="$(cd "$(dirname "$managed")" && pwd)"
  base="$(basename "$managed")"
  name="${base%.*}"
  local jobs_ovl="$dir/${name}.user-jobs.yml"
  local steps_ovl="$dir/${name}.user-steps.yml"
  [ -f "$jobs_ovl" ]  || jobs_ovl=""
  [ -f "$steps_ovl" ] || steps_ovl=""

  # Fast path: no overlays → emit managed file unchanged.
  if [ -z "$jobs_ovl" ] && [ -z "$steps_ovl" ]; then
    if [ -n "$output" ]; then
      cp "$managed" "$output"
    else
      cat "$managed"
    fi
    return 0
  fi

  # Phase 3 pre-check: protected-jobs assertion (E98-S3 / FR-517 / ADR-114 §(d)).
  # Runs BEFORE any temp-dir creation or YAML manipulation so the fail-closed
  # contract holds: no partial regeneration, no output file written when a
  # user-jobs overlay declares a protected GAIA-template job name.
  if [ -n "$jobs_ovl" ]; then
    if ! assert_protected_jobs "$jobs_ovl"; then
      return 1
    fi
  fi

  # Create a per-invocation temp directory using mktemp (works regardless of
  # TEST_TMP — bats sets that, real callers don't). Cleaned up on return.
  local tmp_dir
  tmp_dir="$(mktemp -d -t gaia-stitcher.XXXXXXXXXX)"
  if [ -z "$tmp_dir" ] || [ ! -d "$tmp_dir" ]; then
    printf 'ci-workflow-stitcher.sh: mktemp failed\n' >&2
    return 1
  fi

  # Phase 3 (compute first, since phases 2/4 splice INTO the jobs-unioned
  # stream): YAML-union the user-jobs.yml into the managed jobs: map.
  local tmp_unioned="$tmp_dir/unioned.yml"
  if [ -n "$jobs_ovl" ]; then
    _gaia_stitcher_union_jobs "$managed" "$jobs_ovl" > "$tmp_unioned"
  else
    cp "$managed" "$tmp_unioned"
  fi

  # Phases 2 + 4: splice steps_before_gaia / steps_after_gaia around the
  # managed steps block. The splicer extracts the two blocks from the
  # user-steps overlay first, then streams the unioned workflow through awk.
  local tmp_before="$tmp_dir/before.yml"
  local tmp_after="$tmp_dir/after.yml"
  : > "$tmp_before"
  : > "$tmp_after"
  if [ -n "$steps_ovl" ]; then
    _gaia_stitcher_extract_steps_block "$steps_ovl" "steps_before_gaia" > "$tmp_before"
    _gaia_stitcher_extract_steps_block "$steps_ovl" "steps_after_gaia"  > "$tmp_after"
  fi

  if [ -n "$output" ]; then
    _gaia_stitcher_splice_steps "$tmp_before" "$tmp_after" < "$tmp_unioned" > "$output"
  else
    _gaia_stitcher_splice_steps "$tmp_before" "$tmp_after" < "$tmp_unioned"
  fi

  # Cleanup
  rm -rf "$tmp_dir" 2>/dev/null || true
  return 0
}
