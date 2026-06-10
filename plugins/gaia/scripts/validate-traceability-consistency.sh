#!/usr/bin/env bash
# validate-traceability-consistency.sh — traceability ↔ story-registry consistency audit
#
# Purpose:
#   Detect a class of silent corruption that the framework had no integrity
#   check for: a traceability matrix that references story keys whose scope is
#   inconsistent with the canonical story registry (epics-and-stories.md).
#
#   A cascade sub-agent that regenerates a traceability story-detail section
#   can derive its story keys by sequentially numbering the things it is
#   mapping (e.g. one row per cloud service) instead of by looking up each
#   story by key in the registry. The result is a story-detail table whose
#   rows map test cases to the WRONG stories — the requirements→tests audit
#   trail breaks silently, and no gate catches it.
#
#   This audit asserts two things for every `E<N>-S<M>` referenced in the
#   traceability matrix:
#
#     (a) Registry existence — the key is registered as a `### Story E<N>-S<M>:`
#         entry in epics-and-stories.md. A reference to a key that does not
#         exist in the registry is an INVENTED key (the strongest signal of
#         positional/sequential keying). Emitted as a hard issue.
#
#     (b) Scope compatibility — when a referenced row embeds a descriptive
#         title or scope phrase alongside the key (the story-detail row shape),
#         that phrase must share at least one significant token with the
#         registry title for that key. Zero token overlap is a likely
#         mis-keying (the row describes a different story than the registry
#         records under that key). Emitted as a hard issue.
#
#   This is the sibling of the epic / story-key registry integrity audit
#   (validate-epic-registry.sh): that script asserts keys are UNIQUE and
#   epics are not ORPHANED; this script asserts the traceability matrix
#   REFERENCES keys CONSISTENTLY with the registry's scope. The two are
#   complementary — neither subsumes the other.
#
#   The audit is READ-ONLY and emits a structured report on stdout. It exits 0
#   when no issues are found and non-zero when any issue is detected in
#   `--severity halt` mode, so it composes cleanly with `set -e` in callers.
#
# Invocation:
#   validate-traceability-consistency.sh [--epics-file <path>]
#                                        [--matrix-file <path>]
#                                        [--format text|json]
#                                        [--severity warn|halt]
#
# Inputs:
#   --epics-file   Path to the canonical epics-and-stories.md. Default:
#                  resolved from the standard artifact layout
#                  (.gaia/artifacts/planning-artifacts/epics-and-stories.md
#                  with fallback to docs/planning-artifacts/...).
#   --matrix-file  Path to the traceability matrix. Default: resolved across
#                  the flat / strategy / docs placements the framework
#                  supports for traceability-matrix.md.
#   --format       text (default — human-readable) | json (machine-readable).
#   --severity     warn (default — exit 0 even when issues found, advisory
#                  wiring) | halt (exit 1 when any issue found, hard gate).
#
# Exit codes:
#   0 — no issues, OR issues found in `--severity warn` mode.
#   1 — issues found in `--severity halt` mode.
#   2 — usage error (missing/unknown flag, unreadable required input).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="validate-traceability-consistency.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<'USAGE'
validate-traceability-consistency.sh — traceability ↔ story-registry consistency audit

Usage:
  validate-traceability-consistency.sh [--epics-file <path>]
                                       [--matrix-file <path>]
                                       [--check existence|all]
                                       [--format text|json]
                                       [--severity warn|halt]
  validate-traceability-consistency.sh --help

Asserts every E<N>-S<M> referenced in the traceability matrix (a) exists as a
registered story in epics-and-stories.md and (b) where a story-detail table row
declares a scope cell, that scope shares at least one significant token with the
registry title for that key.

--check scope (default) gates only on [B] scope mismatches — the exact
signature of a mis-keyed story-detail row and the highest-signal check on a
mature matrix; [A] invented keys are shown as advisory (retired/orphan epics
inflate [A]). --check existence gates on [A] only; --check all gates on both.

Exit codes:
  0 — clean, OR issues found in `--severity warn` mode.
  1 — issues found in `--severity halt` mode.
  2 — usage error / unreadable input.
USAGE
}

EPICS_FILE=""
MATRIX_FILE=""
ARTIFACTS_DIR=""
FORMAT="text"
SEVERITY="warn"
CHECK="scope"

while [ $# -gt 0 ]; do
  case "$1" in
    --epics-file)    [ $# -ge 2 ] || die 2 "--epics-file requires a value"; EPICS_FILE="$2";   shift 2 ;;
    --matrix-file)   [ $# -ge 2 ] || die 2 "--matrix-file requires a value"; MATRIX_FILE="$2"; shift 2 ;;
    --artifacts-dir) [ $# -ge 2 ] || die 2 "--artifacts-dir requires a value"; ARTIFACTS_DIR="$2"; shift 2 ;;
    --format)        [ $# -ge 2 ] || die 2 "--format requires a value"; FORMAT="$2";          shift 2 ;;
    --severity)      [ $# -ge 2 ] || die 2 "--severity requires a value"; SEVERITY="$2";      shift 2 ;;
    --check)         [ $# -ge 2 ] || die 2 "--check requires a value"; CHECK="$2";            shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die 2 "unknown argument: $1" ;;
  esac
done

case "$FORMAT"   in text|json) : ;; *) die 2 "--format must be 'text' or 'json'" ;; esac
case "$SEVERITY" in warn|halt) : ;; *) die 2 "--severity must be 'warn' or 'halt'" ;; esac
case "$CHECK"    in scope|existence|all) : ;; *) die 2 "--check must be 'scope', 'existence', or 'all'" ;; esac

# ----- Defaults: resolve epics-file + matrix-file from PROJECT_ROOT -----

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"

resolve_default_epics_file() {
  local p
  for p in \
    "${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts/epics-and-stories.md" \
    "${PROJECT_ROOT}/docs/planning-artifacts/epics-and-stories.md"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

resolve_default_matrix_file() {
  local p
  for p in \
    "${PROJECT_ROOT}/.gaia/artifacts/test-artifacts/traceability-matrix.md" \
    "${PROJECT_ROOT}/.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md" \
    "${PROJECT_ROOT}/docs/test-artifacts/traceability-matrix.md" \
    "${PROJECT_ROOT}/docs/test-artifacts/strategy/traceability-matrix.md"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

if [ -z "$EPICS_FILE" ]; then
  EPICS_FILE="$(resolve_default_epics_file || true)"
  [ -n "$EPICS_FILE" ] || die 2 "epics-and-stories.md not found under \$PROJECT_ROOT; pass --epics-file"
fi
[ -r "$EPICS_FILE" ] || die 2 "epics-file unreadable: $EPICS_FILE"

if [ -z "$MATRIX_FILE" ]; then
  MATRIX_FILE="$(resolve_default_matrix_file || true)"
  [ -n "$MATRIX_FILE" ] || die 2 "traceability-matrix.md not found under \$PROJECT_ROOT; pass --matrix-file"
fi
[ -r "$MATRIX_FILE" ] || die 2 "matrix-file unreadable: $MATRIX_FILE"

resolve_default_artifacts_dir() {
  local d
  for d in \
    "${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" \
    "${PROJECT_ROOT}/docs/implementation-artifacts"; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

if [ -z "$ARTIFACTS_DIR" ]; then
  # Best-effort — a key counts as registered if it appears as a `### Story`
  # header OR as a materialized story file. Absence of the dir is fine
  # (greenfield / monolith-only projects); the header scan still applies.
  ARTIFACTS_DIR="$(resolve_default_artifacts_dir || true)"
fi

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# ----- Build the registry lookup: KEY <TAB> normalized-title --------------
# A story key is "registered" if it appears EITHER as a `### Story E<N>-S<M>:`
# header in epics-and-stories.md OR as a materialized story file under the
# implementation-artifacts tree (the framework shards stories into per-epic
# files and per-story dirs, so many live keys have no monolith header). This
# mirrors validate-epic-registry.sh's dual header+file discovery. Header
# titles carry scope text for the [B] check; file-only keys register with an
# empty title (existence-only — no scope check).
# Portable awk only (no GNU match(...,arr)).

REGISTRY="$TMPDIR_RUN/registry.tsv"
awk '
  /^### Story E[0-9]+-S[0-9]+:/ {
    key=$3; sub(/:$/,"",key)
    title=$0
    sub(/^### Story E[0-9]+-S[0-9]+:[[:space:]]*/,"",title)
    # normalize: lowercase + non-alnum -> space
    title=tolower(title)
    gsub(/[^a-z0-9]+/," ",title)
    gsub(/^ +| +$/,"",title)
    printf "%s\t%s\n", key, title
  }
' "$EPICS_FILE" > "$REGISTRY" 2>/dev/null || true

# Augment with materialized story files. The framework supports three layouts
# (per CLAUDE.md): flat `${dir}/<KEY>-*.md`, per-story-dir
# `${dir}/epic-*/<KEY>-*/story.md`, and per-epic-stories `${dir}/epic-*/stories/<KEY>-*.md`.
# We register file-only keys with an empty title (existence-only). Header keys
# already present keep their title; we de-dup at the end so a header title is
# never overwritten by an empty file title.
if [ -n "$ARTIFACTS_DIR" ] && [ -d "$ARTIFACTS_DIR" ]; then
  # shellcheck disable=SC2044
  find "$ARTIFACTS_DIR" -type f \( -name 'E*-S*.md' -o -name 'story.md' \) \
    \( -path "*/epic-*/stories/*" -o -path "*/epic-*/E*-S*-*/*" -o -path "${ARTIFACTS_DIR}/E*-S*-*.md" \) \
    2>/dev/null | while IFS= read -r f; do
      base="$(basename "$f" .md)"
      case "$base" in
        story) base="$(basename "$(dirname "$f")")" ;;
      esac
      if printf '%s' "$base" | grep -qE '^E[0-9]+-S[0-9]+'; then
        key="$(printf '%s' "$base" | sed -E 's/^(E[0-9]+-S[0-9]+).*$/\1/')"
        [ -n "$key" ] && printf '%s\t\n' "$key" >> "$REGISTRY"
      fi
    done
fi
: >> "$REGISTRY"

# De-dup: keep a non-empty title over an empty one for the same key, otherwise
# first wins. Produces one row per key.
DEDUP="$TMPDIR_RUN/registry-dedup.tsv"
awk -F'\t' '
  { k=$1; t=$2
    if (!(k in seen)) { seen[k]=1; title[k]=t; order[++n]=k }
    else if (title[k]=="" && t!="") { title[k]=t }
  }
  END { for (i=1; i<=n; i++) printf "%s\t%s\n", order[i], title[order[i]] }
' "$REGISTRY" > "$DEDUP" 2>/dev/null || true
mv "$DEDUP" "$REGISTRY"

# ----- Scan the matrix in a SINGLE awk pass -------------------------------
# Two finding classes, by design separated so callers can gate on the
# high-signal one and treat the fuzzy one as advisory:
#
#   [A] invented key — any `E<N>-S<M>` referenced ANYWHERE in the matrix
#       (outside frontmatter / fenced code) that has no registry entry. This
#       is the strongest signal of positional/sequential keying and is the
#       finding a hard gate halts on.
#
#   [B] scope mismatch — restricted to genuine STORY-DETAIL TABLE ROWS: a
#       markdown table row `| E<N>-S<M> | <scope> | ... |` whose FIRST cell is
#       exactly one story key. The second cell is the row's declared scope; if
#       it shares zero significant tokens with the registry title for that key
#       the row is likely mis-keyed. This check is deliberately scoped to the
#       row shape the cascade sub-agent generates (per the defect report) so it
#       does not fire on roll-up rows, coverage-summary deltas, changelog
#       prose, or rows that merely mention a key in passing. [B] is ADVISORY
#       by default (see --check) because token-overlap on a mature
#       heterogeneous matrix is heuristic, not authoritative.
#
# Single awk pass keeps this O(matrix) rather than O(matrix × keys) — the
# registry is loaded into an associative array once.

A_ISSUES="$TMPDIR_RUN/a.tsv"   # invented key (not in registry)
B_ISSUES="$TMPDIR_RUN/b.tsv"   # scope mismatch (zero token overlap) — advisory
: > "$A_ISSUES"
: > "$B_ISSUES"

# Stopwords stripped before token-overlap so generic words don't manufacture
# a spurious overlap.
STOPWORDS="the a an and or of to for in on with via fix add new gaia story stories epic test plan matrix support update step mode skill skills"

awk -v REG="$REGISTRY" -v STOP="$STOPWORDS" -v AOUT="$A_ISSUES" -v BOUT="$B_ISSUES" '
  BEGIN {
    # load registry: key -> normalized title
    while ((getline line < REG) > 0) {
      t = index(line, "\t")
      if (t == 0) continue
      k = substr(line, 1, t-1)
      v = substr(line, t+1)
      REGTITLE[k] = v
      HASKEY[k] = 1
    }
    close(REG)
    n = split(STOP, sa, " ")
    for (i=1; i<=n; i++) STOPW[sa[i]] = 1
    fm_seen = 0; in_fm = 0; in_code = 0
    delete SEEN_INVENTED
  }
  {
    line = $0
    # frontmatter: first two `---` fences bound it
    if (line ~ /^---[[:space:]]*$/) {
      if (fm_seen < 2) { fm_seen++; in_fm = (fm_seen==1)?1:0; next }
    }
    if (in_fm) next
    # fenced code block toggle
    if (line ~ /^```/) { in_code = !in_code; next }
    if (in_code) next
    if (line !~ /E[0-9]+-S[0-9]+/) next

    # ---- [A] existence: every distinct key on the line ----
    tmp = line
    while (match(tmp, /E[0-9]+-S[0-9]+/)) {
      key = substr(tmp, RSTART, RLENGTH)
      tmp = substr(tmp, RSTART + RLENGTH)
      if (!(key in HASKEY) && !(key SUBSEP NR in SEEN_INVENTED)) {
        # report each (key,line) once
        if (!(key in REPORTED_A) || REPORTED_A[key] != NR) {
          print "A\t" key "\t" NR >> AOUT
          REPORTED_A[key] = NR
        }
        SEEN_INVENTED[key SUBSEP NR] = 1
      }
    }

    # ---- [B] scope mismatch: story-detail table rows only ----
    # Match `| E<N>-S<M> | <scope> |` — first cell is exactly one key.
    if (line ~ /^[[:space:]]*\|[[:space:]]*E[0-9]+-S[0-9]+[[:space:]]*\|/) {
      # extract first-cell key
      c = line
      sub(/^[[:space:]]*\|[[:space:]]*/, "", c)
      key = c
      sub(/[[:space:]]*\|.*$/, "", key)          # key = first cell
      rest = c
      sub(/^[^|]*\|[[:space:]]*/, "", rest)       # rest starts at 2nd cell
      scope = rest
      sub(/[[:space:]]*\|.*$/, "", scope)         # scope = second cell

      # only meaningful when the key is registered (invented already in [A])
      if (key in HASKEY) {
        # normalize scope: drop ID families, lowercase, non-alnum -> space
        gsub(/E[0-9]+-S[0-9]+/, " ", scope)
        gsub(/[A-Z][A-Z0-9]*-[A-Z0-9]+(-[A-Z0-9]+)*/, " ", scope)
        scope = tolower(scope)
        gsub(/[^a-z0-9]+/, " ", scope)
        gsub(/^ +| +$/, "", scope)

        # significant scope tokens
        rt = REGTITLE[key]
        # file-only keys (registered via story file, no header title) carry no
        # scope text — existence-only, skip the [B] token comparison.
        if (rt == "") next
        sn = split(scope, st, " ")
        sigcount = 0; overlap = 0; sigjoin = ""
        rtpad = " " rt " "
        for (i=1; i<=sn; i++) {
          w = st[i]
          if (w == "" || length(w) <= 2 || (w in STOPW)) continue
          sigcount++
          sigjoin = (sigjoin == "") ? w : (sigjoin " " w)
          if (index(rtpad, " " w " ") > 0) overlap = 1
        }
        if (sigcount >= 2 && overlap == 0) {
          print "B\t" key "\t" NR "\t" rt "\t" sigjoin >> BOUT
        }
      }
    }
  }
' "$MATRIX_FILE"

# ----- Report -------------------------------------------------------------

A_COUNT=$(wc -l < "$A_ISSUES" | tr -d ' ')
B_COUNT=$(wc -l < "$B_ISSUES" | tr -d ' ')

# Which finding class gates the exit code depends on --check:
#   scope     (default) — gate on [B] scope mismatches only. This is the exact
#                         signature of the mis-keying defect and is the
#                         highest-signal / lowest-noise check on a mature
#                         matrix (retired/orphan epics inflate [A]). [A] is
#                         shown as advisory.
#   existence            — gate on [A] invented keys only. [B] advisory.
#   all                  — gate on both.
case "$CHECK" in
  scope)     GATE_COUNT=$B_COUNT ;;
  existence) GATE_COUNT=$A_COUNT ;;
  all)       GATE_COUNT=$((A_COUNT + B_COUNT)) ;;
esac
TOTAL=$((A_COUNT + B_COUNT))

emit_text() {
  if [ "$TOTAL" -eq 0 ]; then
    printf '%s: OK (0 invented keys, 0 scope mismatches)\n' "$SCRIPT_NAME"
    return 0
  fi
  printf '%s: %d invented key(s), %d scope mismatch(es) [check=%s]\n' \
    "$SCRIPT_NAME" "$A_COUNT" "$B_COUNT" "$CHECK"
  # [A] is HARD under existence/all, advisory under scope.
  case "$CHECK" in existence|all) a_tag="HARD" ;; *) a_tag="ADVISORY" ;; esac
  # [B] is HARD under scope/all, advisory under existence.
  case "$CHECK" in scope|all)     b_tag="HARD" ;; *) b_tag="ADVISORY" ;; esac
  if [ "$A_COUNT" -gt 0 ]; then
    printf '\n[A] traceability references a story key NOT in the registry (%d) — %s:\n' "$A_COUNT" "$a_tag"
    while IFS=$'\t' read -r _ key lineno; do
      [ -z "$key" ] && continue
      printf '  - %s  (matrix line %s) — not in epics-and-stories.md headers nor materialized story files\n' \
        "$key" "$lineno"
    done < "$A_ISSUES"
  fi
  if [ "$B_COUNT" -gt 0 ]; then
    printf '\n[B] story-detail row scope inconsistent with the registry (%d) — %s:\n' "$B_COUNT" "$b_tag"
    while IFS=$'\t' read -r _ key lineno rt sig; do
      [ -z "$key" ] && continue
      printf '  - %s  (matrix line %s)\n      registry scope: "%s"\n      matrix row says: "%s"\n' \
        "$key" "$lineno" "$rt" "$sig"
    done < "$B_ISSUES"
  fi
}

emit_json() {
  {
    printf '{\n'
    printf '  "script": "%s",\n' "$SCRIPT_NAME"
    printf '  "epics_file": "%s",\n' "$EPICS_FILE"
    printf '  "matrix_file": "%s",\n' "$MATRIX_FILE"
    printf '  "check": "%s",\n' "$CHECK"
    printf '  "total": %d,\n' "$TOTAL"
    printf '  "gate_count": %d,\n' "$GATE_COUNT"
    printf '  "invented_keys": [\n'
    first=1
    while IFS=$'\t' read -r _ key lineno; do
      [ -z "$key" ] && continue
      [ "$first" -eq 0 ] && printf ',\n'
      printf '    {"key": "%s", "matrix_line": %s}' "$key" "$lineno"
      first=0
    done < "$A_ISSUES"
    printf '\n  ],\n'
    printf '  "scope_mismatches": [\n'
    first=1
    while IFS=$'\t' read -r _ key lineno rt sig; do
      [ -z "$key" ] && continue
      [ "$first" -eq 0 ] && printf ',\n'
      # escape double-quotes in free text
      ert=$(printf '%s' "$rt" | sed 's/"/\\"/g')
      esig=$(printf '%s' "$sig" | sed 's/"/\\"/g')
      printf '    {"key": "%s", "matrix_line": %s, "registry_scope": "%s", "matrix_row": "%s"}' \
        "$key" "$lineno" "$ert" "$esig"
      first=0
    done < "$B_ISSUES"
    printf '\n  ]\n'
    printf '}\n'
  }
}

case "$FORMAT" in
  text) emit_text ;;
  json) emit_json ;;
esac

if [ "$GATE_COUNT" -gt 0 ] && [ "$SEVERITY" = "halt" ]; then
  exit 1
fi
exit 0
