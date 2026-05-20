#!/usr/bin/env bash
# review-summary-gen.sh — Deterministic V1-locked review-summary writer (E58-S2)
#
# Reads the current Review Gate table for a story (via review-gate.sh status)
# and writes the V1 V1 reference schema schema (lines 80-135) to
# `${IMPLEMENTATION_ARTIFACTS}/{key}-review-summary.md` (or to the path supplied
# via --output). The schema is frozen — YAML frontmatter + 6 reviewer sections
# in canonical order + final aggregate Gate Status table — and re-runs are
# byte-identical when gate state is unchanged.
#
# Refs: FR-RAR-2, AF-2026-04-28-7, NFR-RAR-1
# Brief: docs/planning-artifacts/epics-and-stories.md §E58
# Schema source: V1 V1 reference schema lines 80-135 (immutable).
#
# Invocation contract (stable for E58-S5 / E58-S6 wiring):
#
#   review-summary-gen.sh --story <key> [--output <path>] [--synopsis-file <path>]
#   review-summary-gen.sh --help
#
# Output (stdout, exit 0): exactly one line — the absolute path of the written
# summary file. Stderr carries warnings (e.g. duplicate synopsis keys) and
# errors. Stdin is unused.
#
# Canonical reviewer order (V1, immutable):
#   code-review | qa-tests | security-review | test-automate | test-review | review-perf
#
# Canonical gate-name vocabulary (review-gate.sh, exact case):
#   "Code Review" | "QA Tests" | "Security Review"
#   "Test Automation" | "Test Review" | "Performance Review"
#
# Canonical verdict vocabulary (review-gate.sh, exact case):
#   PASSED | FAILED | UNVERIFIED
#
# Aggregate overall_status (V1):
#   any FAILED         → FAILED
#   any UNVERIFIED     → INCOMPLETE
#   else               → PASSED
#
# Exit codes:
#   0 — success; absolute path of written file emitted to stdout
#   1 — story not found (no matching story file via review-gate.sh status)
#   2 — write failure: gate table empty / malformed, non-writable output dir,
#       or any other rewrite failure. Atomic temp+rename ensures no half-
#       written file is ever observable.
#
# Determinism contract (AC3, TC-RAR-17):
#   The `date` field in YAML frontmatter is derived from the story file's
#   mtime (the gate state lives inside that file). NEVER from `date +%s`.
#   This guarantees re-runs with unchanged gate state produce byte-identical
#   output.
#
# POSIX discipline: macOS /bin/bash 3.2 compatible. Uses jq (required for
# review-gate.sh status JSON parsing) and awk / sed / printf / mv. No Python,
# no Node, no curl. Forces `LC_ALL=C` regardless of caller environment.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="review-summary-gen.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- Canonical vocabulary ----------

# Six canonical gate names in V1 row order.
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# Six canonical short-names (frontmatter `reviewers:` list, V1 order).
CANONICAL_SHORT_NAMES=(
  "code-review"
  "qa-tests"
  "security-review"
  "test-automate"
  "test-review"
  "review-perf"
)

# Per-reviewer report relpath template (V1 V1 reference schema lines 73-78).
# Index-aligned with CANONICAL_GATES / CANONICAL_SHORT_NAMES.
CANONICAL_REPORT_RELPATHS=(
  "docs/implementation-artifacts/{key}-code-review.md"
  "docs/test-artifacts/{key}-qa-tests.md"
  "docs/implementation-artifacts/{key}-security-review.md"
  "docs/test-artifacts/{key}-test-automation.md"
  "docs/test-artifacts/{key}-test-review.md"
  "docs/implementation-artifacts/{key}-performance-review.md"
)

# ---------- Helpers ----------

_log()           { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_die_not_found() { _log "$*"; exit 1; }
_die_write()     { _log "$*"; exit 2; }

usage() {
  cat <<'USAGE'
Usage:
  review-summary-gen.sh --story <key> [--output <path>] [--synopsis-file <path>]
  review-summary-gen.sh --help

Reads the current Review Gate table for <key> via review-gate.sh status and
writes the V1-locked review-summary.md schema to:
  - the path given by --output, OR
  - ${IMPLEMENTATION_ARTIFACTS}/<key>-review-summary.md (default).

--synopsis-file <path>
  KEY=VALUE lines, one reviewer per line, with KEY in:
    code-review | qa-tests | security-review | test-automate | test-review | review-perf
  Missing/empty entries fall back to the literal "See report".
  On duplicate keys, last-occurrence wins; a warning is emitted to stderr.

Exit codes:
  0 — success; absolute path of written file emitted to stdout
  1 — story not found
  2 — write failure: gate table empty/malformed, non-writable output dir, etc.
USAGE
}

# Resolve the absolute path of a file regardless of whether it exists yet.
# Portable across macOS /bin/bash 3.2 (no `realpath -m`).
_abspath() {
  local p="$1"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$(pwd)" "$p" ;;
  esac
}

# Stable date stamp: derived from the story file's mtime (NOT $(date)).
# Format: YYYY-MM-DD (UTC, locale-stable per LC_ALL=C).
_story_mtime_date() {
  local story_file="$1"
  # GNU date and BSD date both support `-r FILE` for stat-based mtime,
  # but BSD date uses `-r SECONDS` differently. Use stat for portability.
  local mtime
  if mtime=$(stat -f '%m' "$story_file" 2>/dev/null); then
    : # BSD stat (macOS)
  else
    mtime=$(stat -c '%Y' "$story_file" 2>/dev/null) || return 1
  fi
  # UTC date for cross-host stability.
  if date -u -r "$mtime" '+%Y-%m-%d' 2>/dev/null; then
    return 0
  fi
  date -u -d "@$mtime" '+%Y-%m-%d' 2>/dev/null
}

# ---------- Argument parsing ----------

STORY_KEY=""
OUTPUT_PATH=""
SYNOPSIS_FILE=""

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          _log "--story requires a value"
          usage >&2
          exit 2
        fi
        STORY_KEY="$2"
        shift 2
        ;;
      --output)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          _log "--output requires a value"
          usage >&2
          exit 2
        fi
        OUTPUT_PATH="$2"
        shift 2
        ;;
      --synopsis-file)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          _log "--synopsis-file requires a value"
          usage >&2
          exit 2
        fi
        SYNOPSIS_FILE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        _log "unknown flag: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  if [ -z "$STORY_KEY" ]; then
    _log "--story <key> is required"
    usage >&2
    exit 2
  fi
}

# ---------- Synopsis-file parser ----------
#
# Parses KEY=VALUE lines into two parallel arrays SYN_KEYS / SYN_VALS,
# applying last-occurrence-wins semantics and emitting a warning to stderr
# on each duplicate key. Unknown keys are ignored (defensive — V1 only knows
# the six canonical reviewer slugs).

SYN_KEYS=()
SYN_VALS=()

_canonical_short_name() {
  local k="$1" s
  for s in "${CANONICAL_SHORT_NAMES[@]}"; do
    if [ "$s" = "$k" ]; then
      printf 'yes'
      return 0
    fi
  done
  printf 'no'
}

_load_synopsis_file() {
  local file="$1"
  [ -z "$file" ] && return 0
  if [ ! -f "$file" ]; then
    _log "synopsis-file not found: $file"
    return 0
  fi

  local line key value seen_idx i
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and # comments.
    case "$line" in
      ''|'#'*) continue ;;
    esac
    # KEY=VALUE split on the first '='.
    if [[ "$line" != *"="* ]]; then
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    # Trim surrounding whitespace from key.
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [ -z "$key" ] && continue
    # Reject non-canonical keys silently.
    if [ "$(_canonical_short_name "$key")" != "yes" ]; then
      continue
    fi
    # Last-wins: walk SYN_KEYS for prior occurrence.
    seen_idx=-1
    i=0
    while [ $i -lt ${#SYN_KEYS[@]} ]; do
      if [ "${SYN_KEYS[$i]}" = "$key" ]; then
        seen_idx=$i
        break
      fi
      i=$((i + 1))
    done
    if [ $seen_idx -ge 0 ]; then
      _log "warning: duplicate synopsis key '$key' — last-occurrence wins"
      SYN_VALS[$seen_idx]="$value"
    else
      SYN_KEYS+=("$key")
      SYN_VALS+=("$value")
    fi
  done < "$file"
}

_synopsis_for() {
  local short="$1"
  local i=0
  while [ $i -lt ${#SYN_KEYS[@]} ]; do
    if [ "${SYN_KEYS[$i]}" = "$short" ]; then
      local v="${SYN_VALS[$i]}"
      if [ -n "$v" ]; then
        printf '%s' "$v"
        return 0
      fi
    fi
    i=$((i + 1))
  done
  printf 'See report'
}

# ---------- Gate-state reader ----------
#
# Calls review-gate.sh status --story <key> and parses the resulting JSON
# into six verdict slots in canonical row order. Distinguishes the three
# upstream failure modes:
#   - "no story file found" / "story not found" → exit 1 (caller-friendly)
#   - missing canonical row / fewer rows / awk parse failure → exit 2
#   - unknown failure → exit 2

REVIEW_GATE="${REVIEW_GATE_SCRIPT:-$SCRIPT_DIR/review-gate.sh}"

VERDICTS=()  # parallel to CANONICAL_GATES

_load_gate_state() {
  local key="$1"
  local stderr_file
  stderr_file="$(mktemp -t review-summary-gen.XXXXXX)"
  trap 'rm -f "${stderr_file:-}"' EXIT

  local json status_rc=0
  set +e
  json="$("$REVIEW_GATE" status --story "$key" 2>"$stderr_file")"
  status_rc=$?
  set -e

  if [ $status_rc -ne 0 ]; then
    local err
    err="$(cat "$stderr_file")"
    if [[ "$err" =~ (no\ story\ file\ found|story\ not\ found) ]]; then
      _die_not_found "story not found: $key"
    fi
    # Surface upstream stderr for malformed-table / missing-row / etc.
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
    _die_write "gate table empty or malformed for story $key (review-gate.sh status exit=$status_rc)"
  fi

  # Extract verdicts in canonical order.
  local g v
  for g in "${CANONICAL_GATES[@]}"; do
    v="$(printf '%s' "$json" | jq -r --arg g "$g" '.gates[$g] // empty')"
    if [ -z "$v" ]; then
      _die_write "gate table empty: missing canonical row '$g' for story $key"
    fi
    case "$v" in
      PASSED|FAILED|UNVERIFIED) ;;
      *) _die_write "malformed gate row: '$g' has non-canonical verdict '$v'" ;;
    esac
    VERDICTS+=("$v")
  done
}

# ---------- Aggregate overall_status ----------

_compute_overall_status() {
  local v
  for v in "${VERDICTS[@]}"; do
    if [ "$v" = "FAILED" ]; then
      printf 'FAILED'
      return 0
    fi
  done
  for v in "${VERDICTS[@]}"; do
    if [ "$v" = "UNVERIFIED" ]; then
      printf 'INCOMPLETE'
      return 0
    fi
  done
  printf 'PASSED'
}

# ---------- Renderer ----------

_render_summary() {
  local key="$1" date="$2" overall="$3" out="$4"

  local tmp="${out}.tmp.$$"

  # Substitute {key} into report relpaths.
  local relpaths=()
  local r
  for r in "${CANONICAL_REPORT_RELPATHS[@]}"; do
    relpaths+=("${r//\{key\}/$key}")
  done

  # Reviewer-section H2 headings — V1 schema.
  local headings=(
    "Code Review"
    "QA Tests"
    "Security Review"
    "Test Automation"
    "Test Review"
    "Performance Review"
  )

  {
    printf -- '---\n'
    printf 'story_key: %s\n' "$key"
    printf 'date: %s\n' "$date"
    printf 'overall_status: %s\n' "$overall"
    # reviewers list rendered as inline YAML flow sequence (V1 form).
    printf 'reviewers: [code-review, qa-tests, security-review, test-automate, test-review, review-perf]\n'
    printf -- '---\n'
    printf '\n'
    printf '# Review Summary: %s\n' "$key"
    printf '\n'
    printf '> Aggregate of the 6-review gate for %s. This file does NOT regenerate reviews — it consolidates existing verdicts from the 6 individual review reports.\n' "$key"
    printf '\n'

    local i=0
    while [ $i -lt 6 ]; do
      local heading="${headings[$i]}"
      local verdict="${VERDICTS[$i]}"
      local relpath="${relpaths[$i]}"
      local short="${CANONICAL_SHORT_NAMES[$i]}"
      local synopsis
      synopsis="$(_synopsis_for "$short")"

      printf '## %s\n' "$heading"
      printf '**Verdict:** %s\n' "$verdict"
      printf '**Report:** [%s](%s)\n' "$relpath" "$relpath"
      printf '**Synopsis:** %s\n' "$synopsis"
      printf '\n'
      i=$((i + 1))
    done

    printf '## Aggregate Gate Status\n'
    printf '\n'
    printf '| Review | Verdict | Report |\n'
    printf '|---|---|---|\n'
    i=0
    while [ $i -lt 6 ]; do
      printf '| %s | %s | [link](%s) |\n' \
        "${headings[$i]}" "${VERDICTS[$i]}" "${relpaths[$i]}"
      i=$((i + 1))
    done
    printf '\n'
    printf '**Overall Status:** %s\n' "$overall"
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    _die_write "write failure: $out"
  }

  # Atomic rename. Same filesystem (tempfile is sibling of $out) so mv is
  # rename(2). Guarantees AC-EC3 (concurrent writers) via last-writer-wins.
  if ! mv -f "$tmp" "$out" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    _die_write "write failure: $out"
  fi
}

# ---------- Locate the story file (for mtime + default output dir) ----------
#
# Reuses review-gate.sh's locate semantics by calling it once with `status`
# already done above; here we replicate the glob logic to fetch the absolute
# story file path. Single-source-of-truth would have us shell out, but
# re-globbing is simpler and matches review-gate.sh's logic exactly.

STORY_FILE=""

_locate_story_file() {
  local key="$1"
  local project_path="${PROJECT_PATH:-.}"
  local impl_artifacts="${IMPLEMENTATION_ARTIFACTS:-${project_path}/docs/implementation-artifacts}"
  local pattern="${impl_artifacts}/${key}-*.md"
  local epic_pattern="${impl_artifacts}/epic-*/stories/${key}-*.md"

  shopt -s nullglob
  # shellcheck disable=SC2206
  local matches=( $pattern $epic_pattern )
  shopt -u nullglob

  if [ ${#matches[@]} -eq 0 ]; then
    _die_not_found "story not found: $key"
  fi

  # Filter for canonical story files (template: 'story' frontmatter).
  local canonical=()
  local m
  for m in "${matches[@]}"; do
    if awk '
      /^---[[:space:]]*$/ { n++; if (n == 2) exit }
      n == 1 && /^template:[[:space:]]*["\x27]?story["\x27]?[[:space:]]*$/ { found = 1; exit }
      END { exit (found ? 0 : 1) }
    ' "$m"; then
      canonical+=( "$m" )
    fi
  done
  if [ ${#canonical[@]} -eq 0 ]; then
    _die_not_found "story not found: $key"
  fi
  # Prefer non-symlink when multiple match (post-E53-S225 transition shims).
  for m in "${canonical[@]}"; do
    if [ ! -L "$m" ]; then
      STORY_FILE="$m"
      return 0
    fi
  done
  STORY_FILE="${canonical[0]}"
}

# ---------- Main ----------

main() {
  parse_args "$@"

  # Locate story file (also produces a clean exit-1 on missing story before
  # we even probe the gate table).
  _locate_story_file "$STORY_KEY"

  # Read gate state.
  _load_gate_state "$STORY_KEY"

  # Load synopses (optional).
  _load_synopsis_file "$SYNOPSIS_FILE"

  # Resolve output path.
  local out_path
  if [ -n "$OUTPUT_PATH" ]; then
    out_path="$OUTPUT_PATH"
  else
    local project_path="${PROJECT_PATH:-.}"
    local impl_artifacts="${IMPLEMENTATION_ARTIFACTS:-${project_path}/docs/implementation-artifacts}"
    out_path="${impl_artifacts}/${STORY_KEY}-review-summary.md"
  fi
  out_path="$(_abspath "$out_path")"

  # Verify the parent directory is writable BEFORE building the tempfile,
  # so AC-EC5 (non-writable output dir) yields exit 2 with no partial file.
  local out_dir
  out_dir="$(dirname "$out_path")"
  if [ ! -d "$out_dir" ]; then
    if ! mkdir -p "$out_dir" 2>/dev/null; then
      _die_write "write failure: $out_path"
    fi
  fi
  if [ ! -w "$out_dir" ]; then
    _die_write "write failure: $out_path"
  fi

  # Stable date — gate state lives in the story file, so its mtime is the
  # canonical "last gate-state change" proxy.
  local stamp
  stamp="$(_story_mtime_date "$STORY_FILE")" || stamp="1970-01-01"

  # Compute overall_status.
  local overall
  overall="$(_compute_overall_status)"

  # Render + atomic write.
  _render_summary "$STORY_KEY" "$stamp" "$overall" "$out_path"

  # Stdout: absolute path.
  printf '%s\n' "$out_path"
}

main "$@"
