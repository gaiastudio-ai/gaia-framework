#!/usr/bin/env bats
# gaia-meeting-prd-fr-mtg-32-33-amendment.bats — E76-S16 verification gate
#
# Verifies the FR-MTG-32 / FR-MTG-33 prose updates landed by the
# AF-2026-05-10-1 cascade. The PRD shard at
# `docs/planning-artifacts/prd/04-functional-requirements/40-4-39-...md`
# is the canonical source of truth — confirmed by Val attempt 5
# (PRD monolith contains zero FR-MTG-32/33 references).
#
# This bats file exercises the verification script
# `verify-fr-mtg-32-33-amendment.sh` against bundled fixtures so the
# gate is hermetic and runnable from gaia-public/ alone (project-root
# `docs/` lives outside the gaia-public git tree).
#
# Test cases (AC mapping per E76-S16 §Test Scenarios):
#   TC-MTG-AMD-1 — fixture with both amendment markers + 5-option mapping +
#                  yield-gate.sh side-effect-only language + interject
#                  rationale PASSes.
#   TC-MTG-AMD-2 — fixture missing FR-MTG-32 amendment marker FAILs.
#   TC-MTG-AMD-3 — fixture missing FR-MTG-33 amendment marker FAILs.
#   TC-MTG-AMD-4 — fixture with new FR-MTG-3[4-9] ID FAILs (in-place
#                  revision invariant).
#   TC-MTG-AMD-5 — fixture with duplicate FR-MTG-32 definition row FAILs.
#   TC-MTG-AMD-6 — fixture missing yield-gate.sh side-effect-only language FAILs.
#   TC-MTG-AMD-7 — fixture missing [i]nterject auto-Other rationale FAILs.
#   TC-MTG-AMD-8 — canonical project-root PRD shard PASSes when present.
#   TC-MTG-AMD-9 — PRD monolith negative-control passes (zero matches).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  SCRIPT="$SKILL_DIR/scripts/verify-fr-mtg-32-33-amendment.sh"
  FIXTURES_DIR="$SKILL_DIR/tests/fixtures/fr-mtg-32-33"

  export LC_ALL=C

  # Project-root PRD shard (outside gaia-public/) — used by the
  # canonical-shard test only when the running tree is the live
  # GAIA-Framework workspace. Skipped otherwise so CI runs against
  # gaia-public/ in isolation stay green.
  PROJECT_ROOT_DOCS="$(cd "$REPO_ROOT/.." 2>/dev/null && pwd)"
  CANONICAL_SHARD="$PROJECT_ROOT_DOCS/docs/planning-artifacts/prd/04-functional-requirements/40-4-39-gaia-meeting-peer-to-peer-multi-agent-discussion-skill-af-2026-05-05-1.md"
  PRD_MONOLITH="$PROJECT_ROOT_DOCS/docs/planning-artifacts/prd/prd.md"
}

# --- Script existence -------------------------------------------------------

@test "verify-fr-mtg-32-33-amendment.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

# --- TC-MTG-AMD-1 — canonical fixture passes -------------------------------

@test "TC-MTG-AMD-1: canonical fixture (all markers + 5-option + rationale) passes" {
  run "$SCRIPT" "$FIXTURES_DIR/canonical.md"
  [ "$status" -eq 0 ]
}

# --- TC-MTG-AMD-2 — missing FR-MTG-32 marker fails -------------------------

@test "TC-MTG-AMD-2: fixture missing FR-MTG-32 amendment marker fails" {
  run "$SCRIPT" "$FIXTURES_DIR/missing-fr32-marker.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FR-MTG-32"* ]]
  [[ "$output" == *"amended AF-2026-05-10-1"* ]]
}

# --- TC-MTG-AMD-3 — missing FR-MTG-33 marker fails -------------------------

@test "TC-MTG-AMD-3: fixture missing FR-MTG-33 amendment marker fails" {
  run "$SCRIPT" "$FIXTURES_DIR/missing-fr33-marker.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FR-MTG-33"* ]]
  [[ "$output" == *"amended AF-2026-05-10-1"* ]]
}

# --- TC-MTG-AMD-4 — new FR-MTG-3[4-9] ID present fails ---------------------

@test "TC-MTG-AMD-4: fixture with new FR-MTG-34 ID fails (in-place revision invariant)" {
  run "$SCRIPT" "$FIXTURES_DIR/new-fr-id.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FR-MTG-34"* || "$output" == *"new FR-MTG"* ]]
}

# --- TC-MTG-AMD-5 — duplicate definition row fails -------------------------

@test "TC-MTG-AMD-5: fixture with duplicate FR-MTG-32 definition row fails" {
  run "$SCRIPT" "$FIXTURES_DIR/duplicate-fr32-row.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* || "$output" == *"FR-MTG-32"* ]]
}

# --- TC-MTG-AMD-6 — missing yield-gate.sh side-effect language fails -------

@test "TC-MTG-AMD-6: fixture missing yield-gate.sh side-effect-only language fails" {
  run "$SCRIPT" "$FIXTURES_DIR/missing-yieldgate-side-effect.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"yield-gate"* || "$output" == *"side-effect"* ]]
}

# --- TC-MTG-AMD-7 — missing [i]nterject auto-Other rationale fails ---------

@test "TC-MTG-AMD-7: fixture missing [i]nterject auto-Other rationale fails" {
  run "$SCRIPT" "$FIXTURES_DIR/missing-interject-rationale.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interject"* || "$output" == *"auto-Other"* || "$output" == *"rationale"* ]]
}

# --- TC-MTG-AMD-8 — canonical project-root PRD shard passes ----------------

@test "TC-MTG-AMD-8: project-root PRD shard contains all amendment markers" {
  if [ ! -f "$CANONICAL_SHARD" ]; then
    skip "project-root PRD shard not present (gaia-public/-only checkout)"
  fi
  run "$SCRIPT" "$CANONICAL_SHARD"
  [ "$status" -eq 0 ]
}

# --- TC-MTG-AMD-9 — PRD monolith negative-control --------------------------

@test "TC-MTG-AMD-9: project-root PRD monolith contains zero FR-MTG-32/33 references" {
  if [ ! -f "$PRD_MONOLITH" ]; then
    skip "project-root PRD monolith not present (gaia-public/-only checkout)"
  fi
  # AC #5 — PRD is sharded-only; monolith MUST NOT carry FR-MTG-32/33.
  run grep -cE "FR-MTG-32|FR-MTG-33|yield-gate|YIELD-STOP" "$PRD_MONOLITH"
  # grep -c prints a count; status is 0 only if at least one match. We want 0.
  [ "$output" = "0" ]
}
