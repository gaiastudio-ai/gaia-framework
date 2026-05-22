#!/usr/bin/env bash
# verify-fr-mtg-32-33-amendment.sh — E76-S16 verification gate
#
# Verifies that the FR-MTG-32 / FR-MTG-33 prose updates landed by the
# AF-2026-05-10-1 cascade are present in the supplied PRD shard. The
# canonical shard is at:
#
#   .gaia/artifacts/planning-artifacts/prd/04-functional-requirements/
#     40-4-39-gaia-meeting-peer-to-peer-multi-agent-discussion-skill-af-2026-05-05-1.md
#
# Per the story's Technical Notes (ADR-042 scripts-over-LLM): pure
# deterministic `grep` assertions, no LLM judgment.
#
# Checks (one per AC in E76-S16 §Acceptance Criteria):
#   1. FR-MTG-32 carries the "amended AF-2026-05-10-1" marker.
#   2. FR-MTG-32 body contains the canonical 4 explicit options
#      "[c]ontinue / [p]ause / [w]rap-up / [a]bort" AND the [i]nterject
#      auto-Other binding.
#   3. FR-MTG-33 carries the "amended AF-2026-05-10-1" marker.
#   4. FR-MTG-33 body documents `yield-gate.sh` as side-effect-only under
#      the new contract (still writes session state, no longer emits the
#      YIELD-STOP sentinel).
#   5. No new FR-MTG-3[4-9] IDs were allocated by AF-2026-05-10-1
#      (in-place revision invariant — both FRs retain their existing IDs).
#   6. Exactly one definition row each for FR-MTG-32 and FR-MTG-33
#      (`^- **FR-MTG-3[23] —` pattern).
#   7. FR-MTG-32 amended body cites the [i]nterject -> auto-Other binding
#      rationale (interject already requires a quoted-text payload per
#      FR-MTG-33 `--interject "<text>"` semantics).
#
# Usage:
#   verify-fr-mtg-32-33-amendment.sh FILE
#
# Exit codes:
#   0 — all checks pass.
#   1 — at least one check failed (per-failure messages on stderr).
#   2 — usage error (no file specified or file not found).
#
# Output format on failure (stderr): one line per failed check:
#   {file}: FAIL: {check-name}: {detail}

set -euo pipefail

PROG="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: $PROG FILE

Verify that the FR-MTG-32 / FR-MTG-33 amendment markers, 5-option
mapping, yield-gate.sh side-effect-only language, no-new-FR-ID
invariant, single-definition-row, and [i]nterject auto-Other
rationale are all present in the supplied PRD shard.

Exits 0 on full pass, 1 on any failure, 2 on usage error.
EOF
}

if [ $# -lt 1 ] || [ $# -gt 1 ]; then
  usage
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

FILE="$1"

if [ ! -f "$FILE" ]; then
  echo "$PROG: not a file: $FILE" >&2
  exit 2
fi

failures=0

fail() {
  echo "$FILE: FAIL: $1: $2" >&2
  failures=$((failures + 1))
}

# --- Check 1 — FR-MTG-32 amendment marker ----------------------------------
# Match the FR-MTG-32 definition row and confirm "amended AF-2026-05-10-1"
# appears within the same line (the amendment marker convention used in
# all FR-MTG-* definition headings).

if ! grep -E '^\- \*\*FR-MTG-32 ' "$FILE" | grep -qF "amended AF-2026-05-10-1"; then
  fail "FR-MTG-32 amendment marker" "definition row missing 'amended AF-2026-05-10-1'"
fi

# --- Check 2 — FR-MTG-32 5-option mapping ----------------------------------
# Confirm the canonical 4 explicit options + [i]nterject auto-Other are all
# present in the FR-MTG-32 body. The grep is line-anchored to the FR-MTG-32
# definition row so we don't accidentally match cross-references in
# FR-MTG-10 etc.

fr32_line="$(grep -nE '^\- \*\*FR-MTG-32 ' "$FILE" | head -1 | cut -d: -f1 || true)"
if [ -z "$fr32_line" ]; then
  fail "FR-MTG-32 body" "definition row not found"
else
  fr32_body="$(awk -v s="$fr32_line" 'NR == s' "$FILE")"
  if ! printf '%s' "$fr32_body" | grep -qF "[c]ontinue"; then
    fail "FR-MTG-32 5-option mapping" "missing [c]ontinue option"
  fi
  if ! printf '%s' "$fr32_body" | grep -qF "[p]ause"; then
    fail "FR-MTG-32 5-option mapping" "missing [p]ause option"
  fi
  if ! printf '%s' "$fr32_body" | grep -qF "[w]rap-up"; then
    fail "FR-MTG-32 5-option mapping" "missing [w]rap-up option"
  fi
  if ! printf '%s' "$fr32_body" | grep -qF "[a]bort"; then
    fail "FR-MTG-32 5-option mapping" "missing [a]bort option"
  fi
  if ! printf '%s' "$fr32_body" | grep -qF "[i]nterject"; then
    fail "FR-MTG-32 5-option mapping" "missing [i]nterject auto-Other option"
  fi
fi

# --- Check 3 — FR-MTG-33 amendment marker ----------------------------------

if ! grep -E '^\- \*\*FR-MTG-33 ' "$FILE" | grep -qF "amended AF-2026-05-10-1"; then
  fail "FR-MTG-33 amendment marker" "definition row missing 'amended AF-2026-05-10-1'"
fi

# --- Check 4 — FR-MTG-33 yield-gate.sh side-effect-only language -----------
# Confirm the FR-MTG-33 body documents yield-gate.sh as side-effect-only
# under AF-2026-05-10-1 — language must indicate (a) yield-gate.sh retains
# session-state writes AND (b) the YIELD-STOP sentinel emission is removed.

fr33_line="$(grep -nE '^\- \*\*FR-MTG-33 ' "$FILE" | head -1 | cut -d: -f1 || true)"
if [ -z "$fr33_line" ]; then
  fail "FR-MTG-33 body" "definition row not found"
else
  fr33_body="$(awk -v s="$fr33_line" 'NR == s' "$FILE")"
  # Look for evidence that the YIELD-STOP emission is removed and
  # session-state writes are retained.
  if ! printf '%s' "$fr33_body" | grep -qF "yield-gate.sh"; then
    fail "FR-MTG-33 yield-gate.sh language" "FR-MTG-33 body does not mention yield-gate.sh"
  fi
  # Either explicit "side-effect-only" OR ("YIELD-STOP" and ("removed" or "no longer"))
  has_side_effect_only=0
  if printf '%s' "$fr33_body" | grep -qF "side-effect-only"; then
    has_side_effect_only=1
  fi
  has_yieldstop_removed=0
  if printf '%s' "$fr33_body" | grep -qF "YIELD-STOP"; then
    if printf '%s' "$fr33_body" | grep -qE "(removed|no longer)"; then
      has_yieldstop_removed=1
    fi
  fi
  if [ "$has_side_effect_only" -eq 0 ] && [ "$has_yieldstop_removed" -eq 0 ]; then
    fail "FR-MTG-33 yield-gate.sh language" "no side-effect-only / YIELD-STOP-removed language"
  fi
  if ! printf '%s' "$fr33_body" | grep -qE "(session.?state|session-state)"; then
    fail "FR-MTG-33 yield-gate.sh language" "no session-state retention language"
  fi
fi

# --- Check 5 — no new FR-MTG-3[4-9] IDs allocated --------------------------
# AC #3: AF-2026-05-10-1 is in-place revision only — no new FR IDs.

if grep -qE 'FR-MTG-3[4-9]' "$FILE"; then
  matches="$(grep -nE 'FR-MTG-3[4-9]' "$FILE" | head -3 | tr '\n' ';')"
  fail "no new FR-MTG-3[4-9] IDs" "found new FR ID(s): $matches"
fi

# --- Check 6 — exactly one definition row each -----------------------------

fr32_def_count="$(grep -cE '^\- \*\*FR-MTG-32 ' "$FILE" || true)"
if [ "$fr32_def_count" -ne 1 ]; then
  fail "FR-MTG-32 definition row count" "expected 1, found $fr32_def_count (duplicate FR-MTG-32 definition row)"
fi

fr33_def_count="$(grep -cE '^\- \*\*FR-MTG-33 ' "$FILE" || true)"
if [ "$fr33_def_count" -ne 1 ]; then
  fail "FR-MTG-33 definition row count" "expected 1, found $fr33_def_count (duplicate FR-MTG-33 definition row)"
fi

# --- Check 7 — [i]nterject -> auto-Other rationale present ----------------
# AC #6: FR-MTG-32 amended body must cite the [i]nterject -> auto-Other
# binding rationale.

if [ -n "${fr32_body:-}" ]; then
  if ! printf '%s' "$fr32_body" | grep -qE 'interject.*auto.?Other|auto.?Other.*interject|interject.*Other slot|Other slot.*interject'; then
    fail "interject auto-Other rationale" "FR-MTG-32 body missing [i]nterject -> auto-Other binding rationale"
  fi
fi

# ---------------------------------------------------------------------------

if [ "$failures" -gt 0 ]; then
  echo "$FILE: $failures check(s) failed" >&2
  exit 1
fi
exit 0
