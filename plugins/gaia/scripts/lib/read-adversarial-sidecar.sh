#!/usr/bin/env bash
# read-adversarial-sidecar.sh — shared reader for adversarial-reviewer output.
#
# Story: E87-S12 (AF-2026-06-03-3) — downstream consumer migration.
# Anchor: ADR-131 (adversarial sidecar contract); consumes the sidecar emitted
#         by scripts/../skills/gaia-adversarial/scripts/write-adversarial-sidecar.sh
#         (E87-S11).
# Trace: FR-568 (sidecar emission), FR-569 (sidecar schema), ADR-131.
#
# Why this exists:
#   Four downstream consumers must read adversarial findings IDENTICALLY:
#     1. test-architect risk-tier mapping   (agents/test-architect.md)
#     2. sprint-review aggregator           (skills/gaia-sprint-review)
#     3. retro pattern-detector             (skills/gaia-retro Step 5b)
#     4. /gaia-action-items auto-file router (skills/gaia-action-items)
#   GAIA's established pattern for "N consumers parse the same artifact" is ONE
#   shared lib that every consumer sources — never N per-consumer re-inlinings
#   of the parse logic (cf. resolve-artifact-path.sh, heading-present.sh). This
#   helper IS that shared lib.
#
# Migration shape (ADDITIVE, back-compatible):
#   - PREFER the structured `.json` sidecar (sibling of the `.md`, same basename
#     with a `.json` extension). When present + valid JSON, extract `status`,
#     `summary`, `next`, and `findings[].{severity,id,title,location}` with jq.
#   - FALL BACK to a `.md` regex-parse when the sidecar is ABSENT (pre-E87-S11
#     reports have no sidecar — graceful degrade, never error).
#   The `source=` prefix tells the caller (and tests) which path was taken.
#
# Usage:
#   read-adversarial-sidecar.sh --md-path <path>
#
#   --md-path   path to the adversarial-review-<target>-<date>[-N].md report.
#               The `.json` sidecar is resolved as its sibling.
#
# Output (line-oriented, stable contract):
#   source=json|md
#   status=<PASS|WARNING|CRITICAL>
#   summary=<one line>                 (json path only; md path omits if absent)
#   finding=<severity>\t<id>\t<title>\t<location>   (zero or more, tab-separated)
#   next=<one line>                    (json path only; md path omits if absent)
#
# Exit codes:
#   0 — fields printed to stdout (sidecar OR .md parsed)
#   1 — neither the .json sidecar nor the .md report exists / unreadable
#   2 — usage error (no --md-path)
#
# POSIX discipline: bash with [ ] tests; macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="read-adversarial-sidecar.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  read-adversarial-sidecar.sh --md-path <path>

Prefers the structured .json sidecar (sibling of the .md); falls back to a
.md regex-parse when the sidecar is absent. Emits a stable line contract:
  source=json|md
  status=<PASS|WARNING|CRITICAL>
  [summary=...]
  finding=<severity>\t<id>\t<title>\t<location>   (zero or more)
  [next=...]
USAGE
}

# ---------- Arg parse ----------
MD_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --md-path)
      [ $# -ge 2 ] || { usage; exit 2; }
      MD_PATH="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      log "unknown flag: $1"; usage; exit 2 ;;
  esac
done

if [ -z "$MD_PATH" ]; then
  log "no --md-path provided"; exit 2
fi

case "$MD_PATH" in
  *.md) SIDECAR_PATH="${MD_PATH%.md}.json" ;;
  *)    die "--md-path must end in .md, got '$MD_PATH'" 2 ;;
esac

# ---------- PREFER the .json sidecar ----------
if [ -f "$SIDECAR_PATH" ]; then
  command -v jq >/dev/null 2>&1 || die "jq not found on PATH (required for sidecar branch)"
  if jq -e . "$SIDECAR_PATH" >/dev/null 2>&1; then
    printf 'source=json\n'
    printf 'status=%s\n'  "$(jq -r '.status // ""'  "$SIDECAR_PATH")"
    printf 'summary=%s\n' "$(jq -r '.summary // ""' "$SIDECAR_PATH")"
    # findings are already sorted (severity_rank,id) on disk by the emitter.
    jq -r '
      (.findings // [])[]
      | "finding=" + (.severity // "") + "\t" + (.id // "") + "\t"
        + (.title // "") + "\t" + (.location // "")
    ' "$SIDECAR_PATH"
    printf 'next=%s\n' "$(jq -r '.next // ""' "$SIDECAR_PATH")"
    exit 0
  fi
  # Sidecar present but unparseable → fall through to the .md branch (degrade).
  log "sidecar '$SIDECAR_PATH' is not valid JSON — falling back to .md parse"
fi

# ---------- FALL BACK to the .md regex-parse (back-compat, pre-E87-S11) ----------
if [ ! -f "$MD_PATH" ]; then
  die "neither sidecar '$SIDECAR_PATH' nor report '$MD_PATH' exists"
fi

printf 'source=md\n'

# Verdict: the first PASS|WARNING|CRITICAL token after the `## Verdict` heading.
STATUS=$(awk '
  /^## Verdict[[:space:]]*$/ { inv=1; next }
  inv && /^## / { inv=0 }
  inv {
    if (match($0, /PASS|WARNING|CRITICAL/)) {
      print substr($0, RSTART, RLENGTH); exit
    }
  }
' "$MD_PATH")
printf 'status=%s\n' "${STATUS:-}"

# Findings: each `#### F-xN — title` header, with severity taken from the most
# recent `### CRITICAL|WARNING|INFO` section header, and location from the
# following `- **Location:** ...` line. ID + title from the `#### ` header.
# A pending finding is flushed when its Location line is seen, OR when the next
# heading (#### / ### / ##) arrives first (location empty), OR at EOF.
awk '
  function flush() {
    if (have) { printf "finding=%s\t%s\t%s\t%s\n", cur_sev, cur_id, cur_title, cur_loc; have=0 }
  }
  /^### (CRITICAL|WARNING|INFO)[[:space:]]*$/ { flush(); sev=$2; next }
  /^## /  { flush(); next }
  /^#### / {
    flush()
    line=$0; sub(/^#### /, "", line); id=line; title=""
    if (match(line, / — /)) {
      id=substr(line, 1, RSTART-1); title=substr(line, RSTART+length(" — "))
    } else if (match(line, / - /)) {
      id=substr(line, 1, RSTART-1); title=substr(line, RSTART+length(" - "))
    }
    gsub(/[[:space:]]+$/, "", id); gsub(/^[[:space:]]+/, "", title)
    cur_id=id; cur_title=title; cur_sev=sev; cur_loc=""; have=1; next
  }
  have && /^- \*\*Location:\*\*/ {
    loc=$0; sub(/^- \*\*Location:\*\*[[:space:]]*/, "", loc)
    cur_loc=loc; flush(); next
  }
  END { flush() }
' "$MD_PATH"

exit 0
