#!/usr/bin/env bats
# e83-s6-revalidation-audit-trail.bats — E83-S6 day-1 self-test
#
# Verifies the audit-trail post-conditions of E83-S6 re-validation:
#
#   AC4/AC6 — action-items.yaml AI-10 and AI-11 carry an `audit_note_2026-05-DD`
#             field naming the re-validation outcome (DD ≥ 10).
#   AC7     — change-log AF-3 / AF-4 / AF-1 rows carry the canonical
#             `Re-validated 2026-05-DD under fail-closed contract (E83-S6)
#             — verdict: PASS|WARNING|CRITICAL` line.
#   AC8     — bats anti-pattern check (E83-S3 scanner) exits zero on every
#             new assessment-doc style audit-trail emission produced by
#             E83-S6 (i.e. the new audit notes in AI-10/AI-11 + change-log
#             updates + assessment-AF-2026-05-09-5.md closure note must NOT
#             exhibit any of the three smoking-gun strings).
#   TS#9    — assessment-AF-2026-05-09-5.md "Audit Trail" or "Next Steps"
#             section carries a final closure line naming all 3 verdicts and
#             referencing E83-S6.
#
# These checks are guarded by GAIA_PROJECT_ROOT_DOCS — when the project-root
# docs/ tree is not mounted (CI plugin-ci.yml only checks out gaia-framework/),
# the tests skip cleanly. Local dev / project-root contexts run them live.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-add-feature"
  SCANNER="$SKILL_DIR/scripts/assessment-doc-bypass-check.sh"

  PROJECT_DOCS="${GAIA_PROJECT_ROOT_DOCS:-}"
  AI_FILE="$PROJECT_DOCS/planning-artifacts/action-items.yaml"
  CHANGE_LOG="$PROJECT_DOCS/planning-artifacts/epics/01-change-log.md"
  CANARY_AF5="$PROJECT_DOCS/planning-artifacts/assessment-AF-2026-05-09-5.md"

  export LC_ALL=C
}

# AC6 — AI-10 carries an `audit_note_2026-05-DD` field where DD >= 10.
@test "AC6: action-items.yaml AI-10 carries audit_note for E83-S6 re-validation" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -f "$AI_FILE" ] || skip "action-items.yaml not present"

  # Extract the AI-10 block (from `- id: AI-2026-05-09-10` up to but not
  # including the next `- id:` line).
  block="$(awk '/^- id: AI-2026-05-09-10$/{flag=1} flag{print} /^- id:/ && !/AI-2026-05-09-10/ && NR>1 && flag{exit}' "$AI_FILE")"

  echo "$block" | grep -qE "audit_note_2026-05-(1[0-9]|2[0-9]|3[01]):"
  echo "$block" | grep -qE "E83-S6"
}

# AC6 — AI-11 carries an `audit_note_2026-05-DD` field where DD >= 10.
@test "AC6: action-items.yaml AI-11 carries audit_note for E83-S6 re-validation" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -f "$AI_FILE" ] || skip "action-items.yaml not present"

  block="$(awk '/^- id: AI-2026-05-09-11$/{flag=1} flag{print} /^- id:/ && !/AI-2026-05-09-11/ && NR>1 && flag{exit}' "$AI_FILE")"

  echo "$block" | grep -qE "audit_note_2026-05-(1[0-9]|2[0-9]|3[01]):"
  echo "$block" | grep -qE "E83-S6"
}

# AC4 — AI-10 status MUST be `resolved` when re-validation verdict is PASS or
# WARNING. (CRITICAL would imply revert; we verify the PASS/WARNING path.)
@test "AC4: AI-10 status transitioned to resolved (re-validation PASS/WARNING)" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -f "$AI_FILE" ] || skip "action-items.yaml not present"

  block="$(awk '/^- id: AI-2026-05-09-10$/{flag=1} flag{print} /^- id:/ && !/AI-2026-05-09-10/ && NR>1 && flag{exit}' "$AI_FILE")"

  # First `status:` line in the block MUST be `status: resolved`.
  first_status="$(echo "$block" | grep -m1 -E '^\s*status:')"
  echo "$first_status" | grep -qE 'status:\s*resolved'
}

@test "AC4: AI-11 status transitioned to resolved (re-validation PASS/WARNING)" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -f "$AI_FILE" ] || skip "action-items.yaml not present"

  block="$(awk '/^- id: AI-2026-05-09-11$/{flag=1} flag{print} /^- id:/ && !/AI-2026-05-09-11/ && NR>1 && flag{exit}' "$AI_FILE")"

  first_status="$(echo "$block" | grep -m1 -E '^\s*status:')"
  echo "$first_status" | grep -qE 'status:\s*resolved'
}

# AC7 — change-log carries the canonical re-validation line referencing E83-S6
# in some form. The canonical line format from the story AC is:
#   "Re-validated 2026-05-DD under fail-closed contract (E83-S6) — verdict: ..."
@test "AC7: change-log carries E83-S6 re-validation line for AF-3/AF-4/AF-1" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -f "$CHANGE_LOG" ] || skip "change-log not present"

  # The line must reference E83-S6 and "Re-validated" and a verdict word.
  grep -qE "Re-validated 2026-05-(1[0-9]|2[0-9]|3[01]) under fail-closed contract \(E83-S6\)" "$CHANGE_LOG"
  grep -qE "verdict: (PASS|WARNING|CRITICAL)" "$CHANGE_LOG"

  # Each of AF-3 / AF-4 / AF-1 must be named in the same row or the change-log
  # must contain a consolidated row that names all three. (We accept either
  # three separate row updates or one consolidated row, since AF-1 and AF-3
  # have no standalone change-log row.)
  grep -qE "AF-2026-05-09-3" "$CHANGE_LOG"
  grep -qE "AF-2026-05-09-4" "$CHANGE_LOG"
  grep -qE "AF-2026-05-09-1\b" "$CHANGE_LOG"
}

# AC8 — the assessment-doc bypass scanner exits zero on the canary AF-5 doc
# AFTER the closure note is appended (closure note MUST be paraphrased per
# AC#6 of E83-S3 — paraphrased smoking-gun discussion is allowed).
@test "AC8: scanner still exits zero on assessment-AF-2026-05-09-5.md after closure note" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -f "$CANARY_AF5" ] || skip "canary AF-5 doc not present"

  run "$SCANNER" "$CANARY_AF5"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# TS#9 — assessment-AF-2026-05-09-5.md carries a closure note for AI-12
# acceptance §4 referencing E83-S6 and naming all 3 verdicts.
@test "TS#9: assessment-AF-5 audit-trail closure note names AI-12 §4 + E83-S6 + 3 verdicts" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -f "$CANARY_AF5" ] || skip "canary AF-5 doc not present"

  grep -qE "AI-2026-05-09-12" "$CANARY_AF5"
  grep -qE "E83-S6" "$CANARY_AF5"
  # Must mention all three AFs by ID in the closure note.
  grep -qE "AF-2026-05-09-3" "$CANARY_AF5"
  grep -qE "AF-2026-05-09-4" "$CANARY_AF5"
  grep -qE "AF-2026-05-09-1\b" "$CANARY_AF5"
}

# AC8 — global re-run of E83-S3 scanner against the entire project-root corpus
# (with allowlist) MUST still report exactly 3 violations. E83-S6 MUST NOT
# introduce any new bypass-pattern strings into the corpus.
@test "AC8: full corpus scan with allowlist still reports exactly 3 violations" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set"
  [ -d "$PROJECT_DOCS/planning-artifacts" ] || skip "planning-artifacts not present"

  ALLOWLIST="$SKILL_DIR/tests/assessment-doc-bypass-allowlist.txt"
  run "$SCANNER" --allowlist "$ALLOWLIST" "$PROJECT_DOCS/planning-artifacts/assessment-AF-"*.md
  [ "$status" -ne 0 ]
  count="$(echo "$output" | grep -cE "^.+:[0-9]+:" || true)"
  [ "$count" -eq 3 ]
}
