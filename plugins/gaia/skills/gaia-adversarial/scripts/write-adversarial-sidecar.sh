#!/usr/bin/env bash
# write-adversarial-sidecar.sh — orchestrator-side adversarial JSON sidecar writer.
#
# Story: E87-S11 (AF-2026-06-03-3) — adversarial-reviewer JSON sidecar emission.
# Anchor: ADR-131 (adversarial sidecar contract); mirrors the ADR-105 writer-shift
#         pattern established by scripts/lib/write-val-envelope.sh.
# Trace: FR-568 (sidecar emission), NFR-96 (byte-identical determinism).
#
# Background:
#   The adversarial-reviewer (Sage) emits a Markdown report at
#   {planning_artifacts}/adversarial/adversarial-review-<target>-<date>[-N].md.
#   Downstream consumers (test-architect, sprint-review, retro, /gaia-action-items)
#   previously had to regex-parse the prose. This writer emits a structured
#   `.json` sidecar carrying the ADR-037 envelope findings so consumers read
#   machine-parseable data.
#
# Writer-shift (ADR-105 pattern):
#   Sage RETURNS the ADR-037 envelope in its reply; the orchestrator's MAIN TURN
#   invokes this helper to write the sidecar (the substrate content-integrity
#   guard false-fires on sub-agent writes). UNLIKE the Val sentinel, the
#   adversarial sidecar has NO `persona_sig` — it is critique, not a gate, so
#   there is no forgery surface to anchor; and it carries NO `sentinel_envelope`.
#
# Determinism (NFR-96 byte-identical):
#   - `timestamp` is OMITTED entirely (provenance recovered from the sibling
#     `.md` frontmatter `review_date`).
#   - keys emitted via `jq -S` (sorted).
#   - findings sorted by (severity_rank, id); rank CRITICAL=0, WARNING=1, INFO=2.
#   - LF line endings, UTF-8, pinned single trailing newline.
#   The same input envelope produces a byte-identical sidecar on repeated runs.
#
# Sidecar shape:
#   {
#     "review_type": "adversarial",
#     "status": "<PASS|WARNING|CRITICAL>",     # inherited ADR-037 verdict vocab
#     "target": "<resolved .md basename, .md stripped>",
#     "summary": "<envelope summary>",
#     "findings": [ {"severity","id","title","location"} ],   # sorted
#     "next": "<envelope next>"
#   }
#   (mirrors the persona envelope MINUS timestamp / persona_sig / sentinel_envelope)
#
# Contract:
#   write-adversarial-sidecar.sh --md-path <path> --envelope <json>
#   write-adversarial-sidecar.sh --md-path <path> --envelope-stdin
#
#   --md-path        the resolved adversarial-review-<target>-<date>[-N].md path.
#                    The .json sidecar is its sibling (same dir, .json extension,
#                    same collision index — atomic pairing per Val F1).
#   --envelope       the adversarial ADR-037 envelope JSON literal.
#   --envelope-stdin read the envelope JSON from stdin.
#
#   Required envelope fields: status (∈ {PASS,WARNING,CRITICAL}), summary, next.
#   `findings` is optional (defaults to []); each finding contributes
#   {severity,id,title,location}. `artifacts`/`timestamp`/`persona_sig`/
#   `sentinel_envelope` in the input are intentionally dropped.
#
# Exit codes:
#   0 — sidecar written; path printed to stdout
#   1 — malformed JSON, missing required field, out-of-vocab status, write failure
#   2 — usage error (no --md-path or no envelope)
#
# Atomic write idiom: sibling tempfile + mv (POSIX-atomic on same filesystem).
# POSIX discipline: bash with [ ] tests; macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="write-adversarial-sidecar.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  write-adversarial-sidecar.sh --md-path <path> --envelope <json>
  write-adversarial-sidecar.sh --md-path <path> --envelope-stdin

Writes the paired .json sidecar next to the resolved .md report. The envelope
JSON must contain: status (PASS|WARNING|CRITICAL), summary, next. Findings are
optional. timestamp / persona_sig / sentinel_envelope are dropped; the sidecar
is byte-identical-deterministic (jq -S, sorted findings, no timestamp).
USAGE
}

# ---------- Arg parse ----------
MD_PATH=""
ENVELOPE=""
ENVELOPE_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --md-path)
      [ $# -ge 2 ] || { usage; exit 2; }
      MD_PATH="$2"; shift 2 ;;
    --envelope)
      [ $# -ge 2 ] || { usage; exit 2; }
      ENVELOPE="$2"; shift 2 ;;
    --envelope-stdin)
      ENVELOPE_STDIN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      log "unknown flag: $1"; usage; exit 2 ;;
  esac
done

if [ -z "$MD_PATH" ]; then
  log "no --md-path provided"; exit 2
fi

if [ "$ENVELOPE_STDIN" -eq 1 ]; then
  ENVELOPE="$(cat)"
fi

if [ -z "$ENVELOPE" ]; then
  log "no envelope provided (use --envelope <json> or --envelope-stdin)"; exit 2
fi

# ---------- Validate JSON shape ----------
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

if ! printf '%s' "$ENVELOPE" | jq -e . >/dev/null 2>&1; then
  die "envelope is not valid JSON"
fi

# Required scalar fields.
for key in status summary next; do
  value=$(printf '%s' "$ENVELOPE" | jq -r --arg k "$key" '.[$k] // empty')
  if [ -z "$value" ]; then
    die "envelope missing required field: $key"
  fi
done

# Status MUST inherit the ADR-037 verdict vocab verbatim (reject STRONG/WEAK/MIXED).
STATUS=$(printf '%s' "$ENVELOPE" | jq -r '.status')
case "$STATUS" in
  PASS|WARNING|CRITICAL) : ;;
  *) die "envelope status '$STATUS' not in ADR-037 vocab {PASS,WARNING,CRITICAL}" ;;
esac

# ---------- Compute sidecar path (sibling of the .md, same index) ----------
case "$MD_PATH" in
  *.md) SIDECAR_PATH="${MD_PATH%.md}.json" ;;
  *)    die "--md-path must end in .md, got '$MD_PATH'" ;;
esac

# target = .md basename minus the .md extension (provenance discriminator).
TARGET=$(basename "${MD_PATH%.md}")

# ---------- Build the deterministic sidecar ----------
# Severity rank: CRITICAL=0, WARNING=1, INFO=2; unknown severities sort last (3).
# Sort findings by (severity_rank, id). Emit only the four sidecar finding keys.
# jq -S sorts object keys; pinned single trailing newline; no timestamp.
SIDECAR=$(printf '%s' "$ENVELOPE" | jq -S '
  def rank:
    if . == "CRITICAL" then 0
    elif . == "WARNING" then 1
    elif . == "INFO" then 2
    else 3 end;
  {
    review_type: "adversarial",
    status: .status,
    target: $target,
    summary: .summary,
    findings: (
      ((.findings // [])
        | map({severity: .severity, id: .id, title: .title, location: .location})
        | sort_by([(.severity | rank), (.id // "")]))
    ),
    next: .next
  }
' --arg target "$TARGET") || die "failed to build sidecar JSON"

# ---------- Atomic write (tempfile + mv) ----------
SIDECAR_DIR=$(dirname "$SIDECAR_PATH")
mkdir -p "$SIDECAR_DIR" || die "failed to create sidecar dir: $SIDECAR_DIR"

TMP_PATH="${SIDECAR_PATH}.tmp.$$"
printf '%s\n' "$SIDECAR" > "$TMP_PATH" || die "failed to write tempfile: $TMP_PATH"
mv "$TMP_PATH" "$SIDECAR_PATH" || die "failed to mv tempfile to sidecar path: $SIDECAR_PATH"

printf '%s\n' "$SIDECAR_PATH"
exit 0
