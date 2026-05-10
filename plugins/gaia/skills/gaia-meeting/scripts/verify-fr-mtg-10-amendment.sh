#!/usr/bin/env bash
# verify-fr-mtg-10-amendment.sh — E76-S19 verification gate
#
# Verifies that the FR-MTG-10 user-as-attendee ADD prose AND the
# threat-model T-MTG-5 row landed by the AF-2026-05-10-2 cascade are
# present in the supplied PRD shard and threat-model file. The
# canonical sources are:
#
#   docs/planning-artifacts/prd/04-functional-requirements/
#     40-4-39-gaia-meeting-peer-to-peer-multi-agent-discussion-skill-af-2026-05-05-1.md
#   docs/planning-artifacts/threat-model.md
#
# Per the story's Technical Notes (ADR-042 scripts-over-LLM): pure
# deterministic `grep` assertions, no LLM judgment.
#
# Checks (one per AC in E76-S19 §Acceptance Criteria):
#   1. FR-MTG-10 carries the "amended AF-2026-05-10-2" marker.
#   2. FR-MTG-10 body documents the user-as-attendee path — must contain
#      `user-as-first-class-attendee`, `user_attendance`, `AskUserQuestion`,
#      and FR-MTG-32 cross-reference (or E76-S18) AND the
#      "NEVER auto-included" round-robin invariant.
#   3. No new FR-MTG-3[4-9] / FR-MTG-4[0-9]+ IDs were allocated by
#      AF-2026-05-10-2 (in-place ADD invariant — pre-existing FR-MTG-4 is
#      NOT a new ID and must not be flagged; the regex is anchored on
#      ID values >= 34).
#   4. Threat-model contains a T-MTG-5 row in the canonical 5-col format
#      `STRIDE | Threat ID | Threat | Applicable? | Details`.
#   5. T-MTG-5 Details cell contains positive-verification language —
#      "no new threat surface" + all 4 verification dimensions
#      (non-LLM, AskUserQuestion, write boundary, NFR-048). Matching is
#      case-insensitive (the canonical row uses lowercase
#      "no new threat surface" and capitalized "Write boundary").
#
# Usage:
#   verify-fr-mtg-10-amendment.sh PRD_SHARD THREAT_MODEL
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
Usage: $PROG PRD_SHARD THREAT_MODEL

Verify that the FR-MTG-10 amendment marker, user-as-attendee body
language, no-new-FR-ID invariant, T-MTG-5 row presence, 5-col format,
and verification-dimension language are all present in the supplied
PRD shard and threat-model file.

Exits 0 on full pass, 1 on any failure, 2 on usage error.
EOF
}

if [ $# -lt 2 ] || [ $# -gt 2 ]; then
  usage
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

SHARD="$1"
THREAT_MODEL="$2"

if [ ! -f "$SHARD" ]; then
  echo "$PROG: not a file: $SHARD" >&2
  exit 2
fi

if [ ! -f "$THREAT_MODEL" ]; then
  echo "$PROG: not a file: $THREAT_MODEL" >&2
  exit 2
fi

failures=0

fail() {
  echo "$1: FAIL: $2: $3" >&2
  failures=$((failures + 1))
}

# --- Check 1 — FR-MTG-10 amendment marker ----------------------------------
# Match the FR-MTG-10 definition row and confirm "amended AF-2026-05-10-2"
# appears within the same line (the amendment marker convention used
# across all FR-MTG-* definition headings).

if ! grep -E '^\- \*\*FR-MTG-10 ' "$SHARD" | grep -qF "amended AF-2026-05-10-2"; then
  fail "$SHARD" "FR-MTG-10 amendment marker" "definition row missing 'amended AF-2026-05-10-2'"
fi

# --- Check 2 — FR-MTG-10 user-as-attendee body language --------------------
# Confirm the FR-MTG-10 body contains the canonical user-as-attendee
# elements. The grep is line-anchored to the FR-MTG-10 definition row so
# we don't accidentally match cross-references in adjacent FRs.

fr10_line="$(grep -nE '^\- \*\*FR-MTG-10 ' "$SHARD" | head -1 | cut -d: -f1 || true)"
if [ -z "$fr10_line" ]; then
  fail "$SHARD" "FR-MTG-10 body" "definition row not found"
else
  fr10_body="$(awk -v s="$fr10_line" 'NR == s' "$SHARD")"

  # 2a. user-as-first-class-attendee phrase
  if ! printf '%s' "$fr10_body" | grep -qF "user-as-first-class-attendee"; then
    fail "$SHARD" "FR-MTG-10 user-as-attendee body" "missing 'user-as-first-class-attendee' phrase"
  fi

  # 2b. user_attendance session-state flag
  if ! printf '%s' "$fr10_body" | grep -qF "user_attendance"; then
    fail "$SHARD" "FR-MTG-10 user-as-attendee body" "missing 'user_attendance' session-state flag"
  fi

  # 2c. AskUserQuestion composition (any reference is sufficient — the
  # FR-MTG-32 / E76-S18 cross-reference may sit in a sibling sentence).
  if ! printf '%s' "$fr10_body" | grep -qF "AskUserQuestion"; then
    fail "$SHARD" "FR-MTG-10 user-as-attendee body" "missing 'AskUserQuestion' composition reference"
  fi

  # 2d. FR-MTG-32 OR E76-S18 cross-reference (the AC body language allows
  # either disjunct — the canonical PRD prose cites FR-MTG-32 amendment).
  if ! printf '%s' "$fr10_body" | grep -qE "FR-MTG-32|E76-S18"; then
    fail "$SHARD" "FR-MTG-10 user-as-attendee body" "missing 'FR-MTG-32' or 'E76-S18' cross-reference"
  fi

  # 2e. NEVER auto-included round-robin invariant (no-fabricated-user-turns
  # carve-out per E76-S20 / E76-S8).
  if ! printf '%s' "$fr10_body" | grep -qF "NEVER auto-included"; then
    fail "$SHARD" "FR-MTG-10 user-as-attendee body" "missing 'NEVER auto-included' round-robin invariant"
  fi

  # 2f. invitee --invitees keyword (token preservation language)
  if ! printf '%s' "$fr10_body" | grep -qF -- "--invitees"; then
    fail "$SHARD" "FR-MTG-10 user-as-attendee body" "missing '--invitees' token preservation reference"
  fi
fi

# --- Check 3 — no new FR-MTG-3[4-9] / FR-MTG-4[0-9]+ IDs allocated --------
# AC #3: AF-2026-05-10-2 is in-place ADD only — no new FR IDs >= 34.
# Pre-existing FR-MTG-4 is intentionally excluded (it is the
# Research-phase FR present long before AF-2026-05-10-2).
# Word-boundary match on `FR-MTG-` followed by an integer >= 34. We use
# explicit alternation rather than {n,} numerics for portability across
# BSD/GNU grep.

# Find any FR-MTG-3[4-9] or FR-MTG-[4-9][0-9]+ followed by a non-digit
# (prevents FR-MTG-4 from matching FR-MTG-40+, and prevents FR-MTG-32
# from leaking through). The trailing class `[^0-9]|$` enforces the
# right-boundary.
if grep -qE '(FR-MTG-3[4-9]|FR-MTG-[4-9][0-9])([^0-9]|$)' "$SHARD"; then
  matches="$(grep -nE '(FR-MTG-3[4-9]|FR-MTG-[4-9][0-9])([^0-9]|$)' "$SHARD" | head -3 | tr '\n' ';')"
  fail "$SHARD" "no new FR-MTG-* IDs" "found new FR ID(s) at/after FR-MTG-34: $matches"
fi

# --- Check 4 — T-MTG-5 row presence ----------------------------------------

if ! grep -qE '^\| .* \| T-MTG-5 \|' "$THREAT_MODEL"; then
  fail "$THREAT_MODEL" "T-MTG-5 row presence" "no row matching '^| .* | T-MTG-5 |' found"
fi

# --- Check 5 — T-MTG-5 row in canonical 5-col format -----------------------
# A 5-col markdown table row has the shape `| c1 | c2 | c3 | c4 | c5 |`.
# Naively counting `|` characters fails when a cell embeds a literal `|`
# inside backtick-quoted code (e.g., `user_attendance: true | false`).
# Strip backtick spans before counting, then expect 6 separator pipes.

t5_line="$(grep -E '^\| .* \| T-MTG-5 \|' "$THREAT_MODEL" | head -1 || true)"
if [ -n "$t5_line" ]; then
  # Strip backtick-quoted spans (both single and triple) to remove
  # embedded `|` characters from code cells.
  t5_stripped="$(printf '%s' "$t5_line" | sed -E 's/`[^`]*`//g')"
  pipe_count="$(printf '%s' "$t5_stripped" | tr -cd '|' | wc -c | tr -d ' ')"
  if [ "$pipe_count" -ne 6 ]; then
    fail "$THREAT_MODEL" "T-MTG-5 5-col format" "expected 6 separator pipes (5 columns), found $pipe_count after stripping code spans"
  fi
fi

# --- Check 6 — T-MTG-5 verification-dimension language ---------------------
# AC #5: Details cell must contain "no new threat surface" + 4
# verification dimensions (non-LLM, AskUserQuestion, write boundary,
# NFR-048). Match case-insensitively — the canonical row uses lowercase
# "no new threat surface" and capitalized "Write boundary".

if [ -n "$t5_line" ]; then
  if ! printf '%s' "$t5_line" | grep -qiF "no new threat surface"; then
    fail "$THREAT_MODEL" "T-MTG-5 positive-verification" "missing 'no new threat surface' language"
  fi
  if ! printf '%s' "$t5_line" | grep -qF "non-LLM"; then
    fail "$THREAT_MODEL" "T-MTG-5 verification dimension (a)" "missing 'non-LLM' (no prompt-injection)"
  fi
  if ! printf '%s' "$t5_line" | grep -qF "AskUserQuestion"; then
    fail "$THREAT_MODEL" "T-MTG-5 verification dimension (b)" "missing 'AskUserQuestion' (substrate-enforced halt)"
  fi
  if ! printf '%s' "$t5_line" | grep -qiF "write boundary"; then
    fail "$THREAT_MODEL" "T-MTG-5 verification dimension (c)" "missing 'write boundary' (unchanged)"
  fi
  if ! printf '%s' "$t5_line" | grep -qF "NFR-048"; then
    fail "$THREAT_MODEL" "T-MTG-5 verification dimension (d)" "missing 'NFR-048' (fork allowlist preserved)"
  fi
fi

# ---------------------------------------------------------------------------

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
exit 0
