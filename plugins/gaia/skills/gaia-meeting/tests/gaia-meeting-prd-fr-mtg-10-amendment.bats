#!/usr/bin/env bats
# gaia-meeting-prd-fr-mtg-10-amendment.bats — E76-S19 verification gate
#
# Verifies the FR-MTG-10 user-as-attendee ADD prose AND the threat-model
# T-MTG-5 row landed by the AF-2026-05-10-2 cascade. Per E76-S19 the
# canonical sources of truth are:
#
#   docs/planning-artifacts/prd/04-functional-requirements/
#     40-4-39-gaia-meeting-peer-to-peer-multi-agent-discussion-skill-af-2026-05-05-1.md
#   docs/planning-artifacts/threat-model.md
#
# This bats file exercises the verification script
# `verify-fr-mtg-10-amendment.sh` against bundled fixtures so the gate is
# hermetic and runnable from gaia-public/ alone (project-root `docs/`
# lives outside the gaia-public git tree).
#
# Test cases (AC mapping per E76-S19 §Test Scenarios):
#   TC-MTG-AMD10-1 — canonical fixture (amendment marker + body language +
#                    T-MTG-5 row + 5-col format + verification dimensions)
#                    PASSes.
#   TC-MTG-AMD10-2 — fixture missing FR-MTG-10 amendment marker FAILs.
#   TC-MTG-AMD10-3 — fixture missing user-as-attendee body language FAILs.
#   TC-MTG-AMD10-4 — fixture with new FR-MTG-3[4-9] / FR-MTG-4[0-9] ID FAILs
#                    (in-place ADD invariant — pre-existing FR-MTG-4 not
#                    counted; only IDs >= 34 fail).
#   TC-MTG-AMD10-5 — fixture missing T-MTG-5 row FAILs.
#   TC-MTG-AMD10-6 — fixture with T-MTG-5 row in wrong column count FAILs.
#   TC-MTG-AMD10-7 — fixture missing T-MTG-5 verification-dimension language
#                    FAILs.
#   TC-MTG-AMD10-8 — canonical project-root PRD shard + threat-model PASS.
#   TC-MTG-AMD10-9 — PRD monolith negative-control passes (zero matches).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  SCRIPT="$SKILL_DIR/scripts/verify-fr-mtg-10-amendment.sh"
  FIXTURES_DIR="$SKILL_DIR/tests/fixtures/fr-mtg-10"

  export LC_ALL=C

  # Project-root artifacts (outside gaia-public/) — used by the canonical
  # tests only when the running tree is the live GAIA-Framework workspace.
  # Skipped otherwise so CI runs against gaia-public/ in isolation stay
  # green.
  PROJECT_ROOT_DOCS="$(cd "$REPO_ROOT/.." 2>/dev/null && pwd)"
  CANONICAL_SHARD="$PROJECT_ROOT_DOCS/docs/planning-artifacts/prd/04-functional-requirements/40-4-39-gaia-meeting-peer-to-peer-multi-agent-discussion-skill-af-2026-05-05-1.md"
  CANONICAL_THREAT_MODEL="$PROJECT_ROOT_DOCS/docs/planning-artifacts/threat-model.md"
  PRD_MONOLITH="$PROJECT_ROOT_DOCS/docs/planning-artifacts/prd/prd.md"
}

# --- Script existence -------------------------------------------------------

@test "verify-fr-mtg-10-amendment.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

# --- TC-MTG-AMD10-1 — canonical fixture passes ------------------------------

@test "TC-MTG-AMD10-1: canonical fixture (FR-MTG-10 amend + T-MTG-5 row) passes" {
  run "$SCRIPT" "$FIXTURES_DIR/canonical-shard.md" "$FIXTURES_DIR/canonical-threat-model.md"
  [ "$status" -eq 0 ]
}

# --- TC-MTG-AMD10-2 — missing FR-MTG-10 marker fails ------------------------

@test "TC-MTG-AMD10-2: fixture missing FR-MTG-10 amendment marker fails" {
  run "$SCRIPT" "$FIXTURES_DIR/missing-fr10-marker.md" "$FIXTURES_DIR/canonical-threat-model.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FR-MTG-10"* ]]
  [[ "$output" == *"amended AF-2026-05-10-2"* ]]
}

# --- TC-MTG-AMD10-3 — missing user-as-attendee body language fails ----------

@test "TC-MTG-AMD10-3: fixture missing user-as-attendee body language fails" {
  run "$SCRIPT" "$FIXTURES_DIR/missing-user-attendee-body.md" "$FIXTURES_DIR/canonical-threat-model.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"user-as-first-class-attendee"* || "$output" == *"user_attendance"* || "$output" == *"AskUserQuestion"* ]]
}

# --- TC-MTG-AMD10-4 — new FR-MTG-3[4-9] / FR-MTG-4[0-9] ID present fails ----

@test "TC-MTG-AMD10-4: fixture with new FR-MTG-34 ID fails (in-place ADD invariant)" {
  run "$SCRIPT" "$FIXTURES_DIR/new-fr-id.md" "$FIXTURES_DIR/canonical-threat-model.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FR-MTG-34"* || "$output" == *"new FR-MTG"* ]]
}

# --- TC-MTG-AMD10-5 — missing T-MTG-5 row fails -----------------------------

@test "TC-MTG-AMD10-5: fixture missing T-MTG-5 row fails" {
  run "$SCRIPT" "$FIXTURES_DIR/canonical-shard.md" "$FIXTURES_DIR/missing-tmtg5-row.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"T-MTG-5"* ]]
}

# --- TC-MTG-AMD10-6 — T-MTG-5 row in wrong column count fails ---------------

@test "TC-MTG-AMD10-6: fixture with T-MTG-5 in 4-col format fails" {
  run "$SCRIPT" "$FIXTURES_DIR/canonical-shard.md" "$FIXTURES_DIR/tmtg5-wrong-cols.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"5-col"* || "$output" == *"column"* || "$output" == *"T-MTG-5"* ]]
}

# --- TC-MTG-AMD10-7 — missing verification-dimension language fails ---------

@test "TC-MTG-AMD10-7: fixture missing T-MTG-5 verification dimensions fails" {
  run "$SCRIPT" "$FIXTURES_DIR/canonical-shard.md" "$FIXTURES_DIR/tmtg5-missing-dimensions.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-LLM"* || "$output" == *"AskUserQuestion"* || "$output" == *"NFR-048"* || "$output" == *"write boundary"* || "$output" == *"no new threat surface"* ]]
}

# --- TC-MTG-AMD10-8 — canonical project-root artifacts pass -----------------

@test "TC-MTG-AMD10-8: project-root PRD shard + threat-model contain all amendment markers" {
  if [ ! -f "$CANONICAL_SHARD" ] || [ ! -f "$CANONICAL_THREAT_MODEL" ]; then
    skip "project-root PRD shard / threat-model not present (gaia-public/-only checkout)"
  fi
  run "$SCRIPT" "$CANONICAL_SHARD" "$CANONICAL_THREAT_MODEL"
  [ "$status" -eq 0 ]
}

# --- TC-MTG-AMD10-9 — PRD monolith negative-control -------------------------

@test "TC-MTG-AMD10-9: project-root PRD monolith contains zero FR-MTG-10 references" {
  if [ ! -f "$PRD_MONOLITH" ]; then
    skip "project-root PRD monolith not present (gaia-public/-only checkout)"
  fi
  # AC #6 — PRD is sharded-only; monolith MUST NOT carry FR-MTG-10.
  run grep -cF "FR-MTG-10" "$PRD_MONOLITH"
  # grep -c prints a count; we want 0.
  [ "$output" = "0" ]
}
