#!/usr/bin/env bash
# manual-test-review-dispatch.sh — per-story manual-test dispatch for the
# run-all-reviews (gaia-review-all) flow.
#
# The manual-test machinery (surface dispatch + run-record + the review-gate
# `manual-test` ledger gate + the advisory/gating consumer in
# transition-story-status.sh) all exist, but NOTHING in the per-story review
# flow ever dispatched a surface to PRODUCE a manual-test verdict. So a story
# with `manual_verification: true` reached `done` with an empty manual-test
# ledger entry — the advisory/gating gate had no verdict to act on, and a
# silently-broken (404/unwired) feature shipped green.
#
# This helper closes that gap: for a story whose frontmatter declares
# `manual_verification: true`, it dispatches the functional manual-test surface
# (reusing dispatch-surface.sh — it does NOT reimplement surface logic) and
# records the resulting verdict to the review-gate `manual-test` ledger gate
# (via review-gate.sh --plan-id). For a story that does not opt in, it is a
# clean no-op (exit 0, nothing recorded) so the common case is unaffected.
#
# Invocation:
#   manual-test-review-dispatch.sh --story <key> [--config <path>] [--surface <s>]
#   manual-test-review-dispatch.sh --help
#
# Exit codes:
#   0 — completed (verdict recorded, OR story did not opt in = no-op, OR the
#       surface was SKIPPED/PENDING which are PASSED-equivalent)
#   1 — usage error
#   3 — manual-test verdict was FAILED (the per-story review should surface
#       this; whether it BLOCKS is owned by the existing advisory/gating
#       consumer in transition-story-status.sh + review_gate.manual_test_mode)

set -uo pipefail

SCRIPT_NAME="manual-test-review-dispatch.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --story <key> [--config <path>] [--surface <browser|api|mobile|desktop>]

Dispatches the manual-test surface for a story that declares
'manual_verification: true' and records the verdict to the review-gate
'manual-test' ledger gate. No-op (exit 0) for stories that do not opt in.
EOF
}

STORY_KEY=""
CONFIG_PATH=""
SURFACE="api"   # the functional path by default (browser is visual-only)
PLAN_ID="manual-test-review"
STORY_FILE_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --story)      [ $# -ge 2 ] || die "flag --story requires a value"; STORY_KEY="$2"; shift 2 ;;
    --story-file) [ $# -ge 2 ] || die "flag --story-file requires a path"; STORY_FILE_OVERRIDE="$2"; shift 2 ;;
    --config)     [ $# -ge 2 ] || die "flag --config requires a value"; CONFIG_PATH="$2"; shift 2 ;;
    --surface)    [ $# -ge 2 ] || die "flag --surface requires a value"; SURFACE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$STORY_KEY" ] || die "usage: --story <key> is required"

# ---------- Resolve the story file ----------
# An explicit --story-file (used by tests and callers that already hold the
# path) takes precedence over the resolve-story-file.sh lookup.
STORY_FILE=""
if [ -n "$STORY_FILE_OVERRIDE" ]; then
  STORY_FILE="$STORY_FILE_OVERRIDE"
else
  RESOLVE="$SCRIPT_DIR/resolve-story-file.sh"
  if [ -x "$RESOLVE" ] || [ -f "$RESOLVE" ]; then
    STORY_FILE="$(bash "$RESOLVE" "$STORY_KEY" 2>/dev/null | head -1 || true)"
  fi
fi
if [ -z "$STORY_FILE" ] || [ ! -f "$STORY_FILE" ]; then
  log "story file for '$STORY_KEY' not found — nothing to dispatch (no-op)"
  exit 0
fi

# ---------- Read the manual_verification frontmatter flag ----------
# Self-contained one-field reader (same awk idiom as transition-story-status.sh
# read_frontmatter_field) to avoid sourcing that large script.
read_frontmatter_field() {
  local file="$1" field="$2"
  awk -v field="$field" '
    NR==1 && $0 != "---" { exit }
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm {
      if ($0 ~ "^"field"[[:space:]]*:") {
        v=$0; sub("^"field"[[:space:]]*:[[:space:]]*", "", v)
        # Strip an unquoted trailing "# comment" so an author who annotates an
        # opt-in (e.g. `manual_verification: true  # user-facing`) is honored —
        # otherwise the bare scalar comparison drops the flag and the required
        # verification is silently not enforced (a fail-open against intent).
        # ONLY for an UNQUOTED value — a quoted value carries `#` as literal data.
        if (v !~ /^[[:space:]]*["'\'']/) {
          sub(/[[:space:]]+#.*$/, "", v)
        }
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v; exit
      }
    }
  ' "$file"
}

MV_FLAG="$(read_frontmatter_field "$STORY_FILE" manual_verification 2>/dev/null || true)"
if [ "$MV_FLAG" != "true" ]; then
  log "story '$STORY_KEY' does not declare manual_verification: true — manual-test not required (no-op)"
  exit 0
fi

log "story '$STORY_KEY' declares manual_verification: true — resolving the '$SURFACE' manual-test target"

# ---------- Resolve the config path (for surface adapter + api command) ----------
if [ -z "$CONFIG_PATH" ]; then
  for c in ".gaia/config/project-config.yaml" "config/project-config.yaml"; do
    if [ -f "$c" ]; then CONFIG_PATH="$c"; break; fi
  done
fi

# ---------- Resolve a REAL functional target for the surface ----------
# CRITICAL: the api surface executes its --target as `bash -c "$TARGET"`, so the
# target MUST be a runnable functional command, NOT the story key. We reuse the
# project-supplied sprint_review.manual_test.api_command (the same key the
# sprint-review Track B api surface uses). If no real target can be resolved for
# a story that REQUIRES manual verification, the verification cannot run — that
# is UNVERIFIED (gate-blocking), never a vacuous PASSED.
surface_target=""
case "$SURFACE" in
  api)
    if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ] && command -v yq >/dev/null 2>&1; then
      surface_target="$(yq eval '.sprint_review.manual_test.api_command // ""' "$CONFIG_PATH" 2>/dev/null || echo "")"
      surface_target="$(printf '%s' "$surface_target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    fi
    ;;
  *)
    # Non-api surfaces (browser/mobile/desktop) take the story key as a slug
    # (they sanitize it to a URL/identifier and do NOT bash -c it).
    surface_target="$STORY_KEY"
    ;;
esac

# ---------- Determine the verdict (fail-CLOSED for an opt-in story) ----------
# Mapping for a manual_verification:true story:
#   real PASSED surface verdict          → PASSED   (verification actually ran + passed)
#   real FAILED surface verdict          → FAILED   (verification ran + failed)
#   no resolvable target / SKIPPED /
#     PENDING / adapter-error / absent    → UNVERIFIED (required but NOT verified — blocks)
# This is the inverse of a Track-B-style "SKIPPED is benign": here the story
# author asserted verification is REQUIRED, so the ABSENCE of execution is not a
# pass — it is an unmet requirement.
DISPATCH_SURFACE="${DISPATCH_SURFACE_BIN:-$SCRIPT_DIR/../skills/gaia-test-manual/scripts/dispatch-surface.sh}"
surface_verdict=""

if [ -z "$surface_target" ]; then
  log "no functional target resolved for the '$SURFACE' surface (e.g. sprint_review.manual_test.api_command unset) — verification could not run"
  surface_verdict="UNVERIFIED"
elif [ ! -f "$DISPATCH_SURFACE" ]; then
  log "WARNING: dispatch-surface.sh not found at $DISPATCH_SURFACE — verification could not run"
  surface_verdict="UNVERIFIED"
else
  evidence_dir=".gaia/memory/checkpoints/manual-test-review/${STORY_KEY}/${SURFACE}"
  mkdir -p "$evidence_dir"
  config_flags=()
  [ -n "$CONFIG_PATH" ] && config_flags=(--config "$CONFIG_PATH")

  log "dispatching the '$SURFACE' manual-test surface"
  surface_json="$(bash "$DISPATCH_SURFACE" --surface "$SURFACE" \
    --target "$surface_target" \
    --evidence-dir "$evidence_dir" \
    "${config_flags[@]}" 2>&1)"
  surface_rc=$?

  if [ "$surface_rc" -ne 0 ] && [ "$surface_rc" -ne 2 ]; then
    # Adapter error (not a clean SKIPPED, which is exit 2) — could not verify.
    log "dispatch-surface.sh exited $surface_rc — verification did not complete"
    surface_verdict="ERROR"
  else
    surface_verdict="$(printf '%s' "$surface_json" | grep -o '"verdict"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"verdict"[[:space:]]*:[[:space:]]*"//;s/"//')"
    [ -n "$surface_verdict" ] || surface_verdict="UNVERIFIED"
  fi
fi

# Map the surface verdict to the ledger vocabulary (PASSED | FAILED | UNVERIFIED).
case "$surface_verdict" in
  PASSED)         ledger_verdict="PASSED" ;;
  FAILED)         ledger_verdict="FAILED" ;;
  SKIPPED|PENDING|UNVERIFIED|ERROR|*) ledger_verdict="UNVERIFIED" ;;
esac

# ---------- Record the verdict to the review-gate manual-test ledger gate ----------
REVIEW_GATE="$SCRIPT_DIR/review-gate.sh"
if [ -f "$REVIEW_GATE" ]; then
  if bash "$REVIEW_GATE" update --story "$STORY_KEY" --gate "manual-test" \
       --verdict "$ledger_verdict" --plan-id "$PLAN_ID" >/dev/null 2>&1; then
    log "recorded manual-test verdict for '$STORY_KEY': $ledger_verdict (surface verdict: ${surface_verdict:-none})"
  else
    # The ledger write was rejected (e.g. the story file is not resolvable for
    # review-gate.sh). This fails SAFE: an absent ledger entry is treated as
    # non-PASSED by the transition consumer (blocks in gating, WARNs in
    # advisory), so a missing record never produces a green gate.
    log "WARNING: could not record manual-test verdict '$ledger_verdict' to the ledger for '$STORY_KEY' (treated as non-PASSED downstream)"
  fi
else
  log "WARNING: review-gate.sh not found at $REVIEW_GATE — verdict '$ledger_verdict' not recorded (treated as non-PASSED downstream)"
fi

# Exit codes communicate the outcome to the caller (run-all-reviews):
#   0 — PASSED (verification ran and passed)
#   3 — FAILED (verification ran and failed)
#   4 — UNVERIFIED (verification required but did not run / produced no pass)
# The BLOCK decision is owned by the advisory/gating consumer in
# transition-story-status.sh (review_gate.manual_test_mode), which now treats a
# non-PASSED verdict for an opt-in story as a gate failure.
case "$ledger_verdict" in
  PASSED)     exit 0 ;;
  FAILED)     exit 3 ;;
  *)          exit 4 ;;
esac
