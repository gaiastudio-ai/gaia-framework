#!/usr/bin/env bash
# ground-truth-stale-check.sh — single source of truth for the
# "is the validator-sidecar ground-truth stale?" predicate.
#
# Sourceable, NOT executable. Exposes ONE function:
#
#   check_ground_truth_staleness
#       Prints "STALE" or "FRESH" to stdout. Returns 0 in both cases (the
#       verdict is the stdout token, not the exit code — callers branch on the
#       printed word). A non-zero return is reserved for a genuine internal
#       error (none currently emitted; the predicate biases STALE rather than
#       erroring).
#
# Why a shared helper:
#   Every lifecycle ceremony that wants to decide "should I refresh ground
#   truth?" must decide it IDENTICALLY. Re-inlining a `find -newer` snippet in
#   each finalize.sh guarantees drift (the same divergence that bit the
#   H2-heading check before it was consolidated into one shared lib, and the
#   artifact-path resolver before it was centralised). The find-newer predicate
#   lives ONLY here.
#
# Compared roots (DELIBERATELY narrow):
#   - planning-artifacts tree
#   - implementation-artifacts tree
#   NOT test-artifacts, NOT runtime state. Ground truth tracks the planning and
#   implementation surface that downstream agents reason over; test artifacts
#   and mutable sprint state churn for unrelated reasons and would cause noisy
#   false-stale verdicts.
#
# Fail-safe bias — "uncertain → stale":
#   When the comparison cannot be made unambiguously (ground-truth.md absent,
#   a compared source has an mtime EQUAL to ground-truth.md, or a path cannot
#   be resolved) the predicate reports STALE. This is intentional: a false
#   STALE only costs a cheap incremental refresh (a no-op when nothing actually
#   changed), whereas a false FRESH silently corrupts every downstream agent
#   that trusts the sidecar. Always bias STALE when ambiguous.
#
# No content hash:
#   A sha256-of-file-listing trailer was considered and rejected as
#   over-engineering. mtime comparison via `find -newer` is sufficient and
#   cheap. Do not add a content-hash layer.
#
# On a STALE verdict the predicate writes a self-clearing marker at the TOP
# LEVEL of the memory dir (`<memory>/.ground-truth-stale`) so the maxdepth-1
# stale-flag scanner discovers it and the agent-load backstop can act on it.
# The write is atomic (mktemp + mv) and idempotent. The predicate is READ-ONLY
# with respect to the compared input files — it never touches their mtimes.
#
# Portability: bash 3.2 (macOS default), LC_ALL=C, BSD+GNU `find` (no GNU-only
# `-printf`).
#
# Environment / overrides:
#   MEMORY_PATH                 validator-sidecar lives under here; resolved as
#                               ${MEMORY_PATH:-${CLAUDE_PROJECT_ROOT:-.}/.gaia/memory}
#   GAIA_GT_SIDECAR_AGENT       sidecar agent name (default: validator)
#   GAIA_GT_FILENAME            ground-truth filename (default: ground-truth.md)
#   GAIA_GT_PLANNING_ROOT       planning compared root override (for fixtures)
#   GAIA_GT_IMPL_ROOT           implementation compared root override (fixtures)
#   CLAUDE_PROJECT_ROOT         project root (base for default roots + memory)

# Idempotent source guard — re-sourcing must not redefine or re-run anything.
if [ "${_GAIA_GT_STALE_CHECK_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317  # reached only when this file is executed, not sourced
  return 0 2>/dev/null || exit 0
fi
_GAIA_GT_STALE_CHECK_LOADED=1

# _gts_memory_path — mirror of memory-loader.sh::_gaia_resolve_memory_path and
# check-stale-flag-registry.sh: honour MEMORY_PATH, else CLAUDE_PROJECT_ROOT.
_gts_memory_path() {
  printf '%s' "${MEMORY_PATH:-${CLAUDE_PROJECT_ROOT:-.}/.gaia/memory}"
}

# check_ground_truth_staleness — the predicate. See file header for contract.
check_ground_truth_staleness() {
  # LC_ALL=C is set function-locally so a `source` of this file never mutates
  # the caller's locale beyond the call.
  local LC_ALL=C
  local mem agent gt_name gt_file planning_root impl_root marker
  local root

  mem="$(_gts_memory_path)"
  agent="${GAIA_GT_SIDECAR_AGENT:-validator}"
  gt_name="${GAIA_GT_FILENAME:-ground-truth.md}"
  gt_file="${mem}/${agent}-sidecar/${gt_name}"
  marker="${mem}/.ground-truth-stale"

  planning_root="${GAIA_GT_PLANNING_ROOT:-${CLAUDE_PROJECT_ROOT:-.}/.gaia/artifacts/planning-artifacts}"
  impl_root="${GAIA_GT_IMPL_ROOT:-${CLAUDE_PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}"

  # UNCERTAIN: no ground-truth.md to compare against → fail-safe STALE.
  if [ ! -f "$gt_file" ]; then
    _gts_write_marker "$marker"
    printf 'STALE\n'
    return 0
  fi

  # STALE: any tracked source strictly newer than ground-truth.md, under either
  # compared root. `find -newer` is strict (mtime > gt), so equal mtimes (e.g. a
  # CI checkout that stamps everything identically) do NOT register as newer —
  # which is exactly the ambiguous tie the fail-safe handles below. Missing /
  # empty roots simply yield no matches (not an error).
  for root in "$planning_root" "$impl_root"; do
    [ -d "$root" ] || continue
    if [ -n "$(find "$root" -type f -newer "$gt_file" 2>/dev/null | head -n 1)" ]; then
      _gts_write_marker "$marker"
      printf 'STALE\n'
      return 0
    fi
  done

  # UNCERTAIN (tie): a compared source whose mtime EQUALS ground-truth.md cannot
  # be ordered by `find -newer`. Treat an exact tie as ambiguous → STALE. We
  # detect a tie as "ground-truth.md is itself newer than nothing under a root
  # AND a same-mtime sibling exists": probe with a strict reverse `-newer` from
  # each source is costly, so instead detect the tie directly — a file that is
  # neither older (gt -newer source) nor newer (source -newer gt) is equal.
  for root in "$planning_root" "$impl_root"; do
    [ -d "$root" ] || continue
    # Files strictly OLDER than gt_file (gt is newer than them).
    # Any tracked file that is NOT strictly older and NOT strictly newer is a
    # mtime tie → ambiguous → STALE.
    if _gts_has_mtime_tie "$root" "$gt_file"; then
      _gts_write_marker "$marker"
      printf 'STALE\n'
      return 0
    fi
  done

  # FRESH: ground-truth.md is the newest of all compared paths. No marker.
  printf 'FRESH\n'
  return 0
}

# _gts_has_mtime_tie ROOT GT_FILE — return 0 if some tracked file under ROOT has
# an mtime EXACTLY equal to GT_FILE's. `find -newer` is strict and cannot order
# an exact mtime tie, so the caller handles the tie separately via this probe.
#
# Portable tie detection: compare numeric epoch-second mtimes via `stat` (both
# BSD and GNU provide it, with different flags — see _gts_mtime). Read GT's
# mtime once, then scan ROOT for any file with the identical mtime. Bounded and
# bash-3.2 safe (no mapfile; here-doc fed `while read`).
_gts_has_mtime_tie() {
  local root="$1" gt="$2"
  local gt_mtime f f_mtime
  gt_mtime="$(_gts_mtime "$gt")" || return 1
  [ -n "$gt_mtime" ] || return 1
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    f_mtime="$(_gts_mtime "$f")" || continue
    if [ "$f_mtime" = "$gt_mtime" ]; then
      return 0
    fi
  done <<EOF
$(find "$root" -type f 2>/dev/null)
EOF
  return 1
}

# _gts_mtime PATH — print the epoch-seconds mtime of PATH, portably.
#
# Portability hazard: `stat -f %m` is the BSD/macOS mtime idiom, but on GNU
# coreutils `-f` means `--file-system` and SUCCEEDS (exit 0) printing the wrong
# value (a filesystem field), so a naive `stat -f %m || stat -c %Y` never falls
# through on Linux and poisons the comparison. Probe GNU FIRST (`-c %Y`) and
# only fall back to BSD (`-f %m`) when GNU stat is absent. Validate that the
# result is all-digits before accepting it, so a wrong-flavour success that
# prints non-numeric text is rejected and the next form is tried.
_gts_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"
  case "$m" in
    ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" ;;
  esac
  case "$m" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$m"
}

# _gts_write_marker MARKER_PATH — atomically write the stale marker.
# mktemp + mv so a concurrent reader never sees a half-written marker, and so a
# second run is idempotent (mv overwrites in place, same content). Creates the
# memory dir if absent. The marker is intentionally a small self-describing
# stamp; it is self-clearing (consumed + removed by the refresh ceremony).
_gts_write_marker() {
  local marker="$1"
  local dir tmp
  dir="$(dirname "$marker")"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "${dir}/.ground-truth-stale.XXXXXX" 2>/dev/null)" || {
    # mktemp failure must not break the predicate; fall back to a direct write.
    printf 'ground-truth-stale\n' > "$marker" 2>/dev/null || true
    return 0
  }
  printf 'ground-truth-stale\n' > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}

# shellcheck disable=SC2317  # reached only when this file is executed, not sourced
return 0 2>/dev/null || true
