#!/usr/bin/env bash
# resolve-epic-slug.sh — Canonical per-epic slug resolver
#
# Mission:
#   Single source of truth for the canonical per-epic directory name
#   (`epic-{epic-slug}/`). Every writer and reader — `/gaia-create-story`,
#   `transition-story-status.sh`, `/gaia-sprint-plan`, `pflag_scan_backlog`,
#   `validate-canonical-filename.sh`, `dead-reference-scan.sh`, and
#   `check-story-layout-sync.sh` — converges on this helper so the
#   heterogeneous flat-vs-nested state cannot recur.
#
# Modes:
#   SOURCED — exposes resolve_epic_slug <epic_key> <epics_file> as a function.
#             Sourcing this file produces zero stdout, zero stderr, and does
#             NOT auto-execute main.
#   CLI     — runs main "$@" only when the file is invoked as a script.
#             Flags: --epic-key <E#>, --epics-file <path>, -h|--help.
#             Exit codes: 0 success, 1 epic-not-found, 2 usage error.
#
# Locale invariance: LC_ALL=C is pinned in the prelude and re-exported on
# every external command that does case-folding or character-class matching
# so output is byte-identical on macOS BSD and Linux GNU runners.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Slug-derivation algorithm
#
# Steps (verified against the live `epic-E*/` tree):
#
#   1. Locate the line `^## {epic_key} — ` in <epics_file>.
#   2. Substring after the em-dash separator becomes the raw title.
#   3. Drop any parenthetical `(...)` clause — parenthetical text is
#      treated as a sub-clause that does NOT contribute to the canonical
#      slug.
#   4. Lowercase.
#   5. Replace word-joining punctuation with single spaces:
#      backticks, square brackets, slashes, colons, dots, underscores,
#      ampersands, plus signs, remaining em-dashes.
#   6. Strip every character not in `[a-z0-9 -]`.
#   7. Collapse runs of whitespace to single hyphens.
#   8. Strip leading and trailing hyphens.
#   9. Prefix with `epic-{epic_key}-`.
#  10. Truncate the assembled basename to 69 characters (no trailing-hyphen
#      strip — preserve the truncation tail verbatim, exactly as the live
#      directories do).
#
# A small minority of historic `epic-E*/` directory names diverge from the
# canonical algorithm output — historical drift is listed in the bats fixture
# inline so the byte-identical assertion stays clean.
#
# resolve_epic_slug <epic_key> <epics_file>
#
# Echoes the canonical slug on stdout; returns 0 on success, 1 if the epic
# heading is not found in <epics_file>.
resolve_epic_slug() {
  local epic_key="${1:-}"
  local epics_file="${2:-}"

  if [ -z "$epic_key" ] || [ -z "$epics_file" ]; then
    printf 'resolve_epic_slug: missing argument (epic_key=%q epics_file=%q)\n' \
      "$epic_key" "$epics_file" >&2
    return 1
  fi

  if [ ! -f "$epics_file" ]; then
    printf 'resolve_epic_slug: epics file not found: %s\n' "$epics_file" >&2
    return 1
  fi

  # Step 1+2 — locate the epic heading and capture the trailing title.
  # Accepts four heading forms (a)+(b)+(c)+(d) — the
  # natural shapes /gaia-create-epics emits in practice (verified live):
  #   (a) `## E{N} — Title`         — canonical em-dash form (U+2014)
  #   (b) `## Epic {N}: Title`      — Derek (pm)'s natural colon form
  #   (c) `## Epic E{N} -- Title`   — ASCII double-hyphen with Epic prefix
  #                                   (the form /gaia-create-epics actually emits)
  #   (d) `## Epic E{N} — Title`    — em-dash with Epic prefix variant
  # Derive the numeric suffix N from the canonical epic_key (e.g., "E1" → "1").
  local epic_num="${epic_key#E}"
  local heading title
  heading="$(LC_ALL=C grep -m1 "^## ${epic_key} — " "$epics_file" || true)"
  if [ -n "$heading" ]; then
    # Form (a): canonical em-dash form.
    title="$(printf '%s' "$heading" | LC_ALL=C sed "s/^## ${epic_key} — //")"
  else
    # Form (b): natural `## Epic N: Title` form.
    heading="$(LC_ALL=C grep -m1 "^## Epic ${epic_num}: " "$epics_file" || true)"
    if [ -n "$heading" ]; then
      title="$(printf '%s' "$heading" | LC_ALL=C sed "s/^## Epic ${epic_num}: //")"
    else
      # Form (c): ASCII double-hyphen with `Epic E{N}` prefix.
      heading="$(LC_ALL=C grep -m1 "^## Epic ${epic_key} -- " "$epics_file" || true)"
      if [ -n "$heading" ]; then
        title="$(printf '%s' "$heading" | LC_ALL=C sed "s/^## Epic ${epic_key} -- //")"
      else
        # Form (d): em-dash with `Epic E{N}` prefix.
        heading="$(LC_ALL=C grep -m1 "^## Epic ${epic_key} — " "$epics_file" || true)"
        if [ -z "$heading" ]; then
          printf 'resolve_epic_slug: epic key %s not found in %s (accepted heading forms: "## %s — Title", "## Epic %s: Title", "## Epic %s -- Title", "## Epic %s — Title")\n' \
            "$epic_key" "$epics_file" "$epic_key" "$epic_num" "$epic_key" "$epic_key" >&2
          return 1
        fi
        title="$(printf '%s' "$heading" | LC_ALL=C sed "s/^## Epic ${epic_key} — //")"
      fi
    fi
  fi

  # Step 3 — drop trailing parenthetical clause(s). The live tree treats
  # parenthetical sub-clauses as non-contributing metadata.
  # We match `(...)` greedily across the rest of the line.
  local s="$title"
  s="$(printf '%s' "$s" | LC_ALL=C sed 's/[[:space:]]*([^)]*)//g')"

  # Step 4 — lowercase.
  s="$(printf '%s' "$s" | LC_ALL=C tr 'A-Z' 'a-z')"

  # Step 5 — replace word-joining punctuation with single spaces. The set
  # is empirically tuned against the live tree:
  #   - backticks, square brackets, slashes, colons, dots, underscores,
  #     ampersands, plus signs, remaining em-dashes -> space.
  # NB: `]` placed first inside the bracket-class avoids closing the class
  # prematurely under POSIX BRE.
  s="$(printf '%s' "$s" | LC_ALL=C sed 's/[][`():/.\\_&+]/ /g')"
  # shellcheck disable=SC1003
  s="$(printf '%s' "$s" | LC_ALL=C sed $'s/\xe2\x80\x94/ /g')"

  # Step 6 — strip every character not in `[a-z0-9 -]`.
  s="$(printf '%s' "$s" | LC_ALL=C sed 's/[^a-z0-9 -]//g')"

  # Step 7 — collapse runs of whitespace to single hyphens (squeeze then
  # translate in a single pass).
  s="$(printf '%s' "$s" | LC_ALL=C tr -s ' ' '-')"

  # Step 8 — strip leading / trailing hyphens.
  s="$(printf '%s' "$s" | LC_ALL=C sed 's/^-*//;s/-*$//')"

  # Step 9 — prefix with `epic-{epic_key}-`.
  s="epic-${epic_key}-${s}"

  # Step 10 — truncate to 69 bytes. POSIX parameter-expansion substring is
  # byte-clean under LC_ALL=C and avoids a fork to head -c.
  s="${s:0:69}"

  printf '%s\n' "$s"
}

# ---------------------------------------------------------------------------
# CLI front-end (main)

_resolve_epic_slug_usage() {
  cat <<'USAGE'
Usage: resolve-epic-slug.sh --epic-key <E#> --epics-file <path>

Resolves the canonical per-epic directory basename (`epic-{epic-slug}`) for
the given epic key, reading the epic title from <epics_file>.

Options:
  --epic-key <E#>      Epic key (e.g. E79). Required.
  --epics-file <path>  Path to epics-and-stories.md. Required.
  -h, --help           Print this usage and exit 0.

Exit codes:
  0  Success — slug printed to stdout.
  1  Epic key not found in <epics_file>.
  2  Usage error (missing or unknown flag).
USAGE
}

main() {
  local epic_key="" epics_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --epic-key)
        epic_key="${2:-}"; shift 2 || { _resolve_epic_slug_usage >&2; return 2; }
        ;;
      --epic-key=*)
        epic_key="${1#--epic-key=}"; shift
        ;;
      --epics-file)
        epics_file="${2:-}"; shift 2 || { _resolve_epic_slug_usage >&2; return 2; }
        ;;
      --epics-file=*)
        epics_file="${1#--epics-file=}"; shift
        ;;
      -h|--help)
        _resolve_epic_slug_usage
        return 0
        ;;
      *)
        printf 'resolve-epic-slug.sh: unknown argument: %s\n' "$1" >&2
        _resolve_epic_slug_usage >&2
        return 2
        ;;
    esac
  done

  if [ -z "$epic_key" ] || [ -z "$epics_file" ]; then
    printf 'resolve-epic-slug.sh: --epic-key and --epics-file are required\n' >&2
    _resolve_epic_slug_usage >&2
    return 2
  fi

  resolve_epic_slug "$epic_key" "$epics_file"
}

# Sourceable + runnable dual-mode guard. The file auto-executes `main "$@"`
# only when invoked as a script — sourcing it produces zero side effects.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
