#!/usr/bin/env bats
# e107-s1-planned-sprint-state.bats — E107-S1
#
# Sprint-level `planned` state inserted before `active`
# (planned → active → review → closed). cmd_init seeds `status: planned` (the
# field the machine reads — the prior orphan `state:` was read by nobody);
# cmd_transition_sprint accepts a new unconditional `planned → active` edge; the
# 4 existing edges are unchanged; illegal edges into/out of planned are rejected.
#
# ALL tests use a temp SPRINT_STATUS_YAML — they NEVER touch the live
# .gaia/state/sprint-status.yaml.
#
# Maps to AC1-AC5, AC-INT1. Refs: ADR-108 (extended), ADR-128, ADR-095, FR-557.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SS="$REPO_ROOT/plugins/gaia/scripts/sprint-state.sh"
  TEST_TMP="$BATS_TEST_TMPDIR/e107s1-$$"
  mkdir -p "$TEST_TMP"
  export SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
}
teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# seed a sprint yaml directly at a given status (bypasses cmd_init for edge tests)
seed_yaml() { # $1 = status value
  cat > "$SPRINT_STATUS_YAML" <<EOF
sprint_id: "sprint-900"
status: $1
total_points: 0
goals: []
stories: []
EOF
}

# ---------- AC1 / TS1: cmd_init seeds status: planned ----------

@test "cmd_init seeds status: planned (not active, not the orphan state:)" {
  rm -f "$SPRINT_STATUS_YAML"
  run bash "$SS" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  grep -Eq '^status:[[:space:]]*planned' "$SPRINT_STATUS_YAML" \
    || { echo "init should seed status: planned, got:" >&2; cat "$SPRINT_STATUS_YAML" >&2; false; }
  # the dead orphan top-level `state:` line must be gone
  ! grep -Eq '^state:[[:space:]]*active' "$SPRINT_STATUS_YAML"
}

# ---------- AC2 / AC3 / TS2: planned -> active accepted (unconditional) ----------

@test "planned -> active transition is accepted (unconditional)" {
  seed_yaml planned
  run bash "$SS" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ] \
    || { echo "planned->active should be accepted, got status $status: $output" >&2; false; }
  grep -Eq '^status:[[:space:]]*active' "$SPRINT_STATUS_YAML"
}

# ---------- AC1+AC2 integration latent-bug regression: init'd sprint is transitionable ----------

@test "AC-INT1/TS5: an init'd sprint (planned) can be transitioned to active via the writer" {
  rm -f "$SPRINT_STATUS_YAML"
  bash "$SS" init --sprint-id sprint-900
  run bash "$SS" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ] \
    || { echo "init'd sprint must be transitionable (latent-bug regression), got: $output" >&2; cat "$SPRINT_STATUS_YAML" >&2; false; }
  grep -Eq '^status:[[:space:]]*active' "$SPRINT_STATUS_YAML"
}

# ---------- AC5 / TS3: illegal edges into/out of planned are rejected ----------

@test "planned -> review is rejected" {
  seed_yaml planned
  run bash "$SS" transition --sprint sprint-900 --to review
  [ "$status" -ne 0 ]
  grep -Eq '^status:[[:space:]]*planned' "$SPRINT_STATUS_YAML"  # unchanged
}

@test "closed -> planned is rejected" {
  seed_yaml closed
  run bash "$SS" transition --sprint sprint-900 --to planned
  [ "$status" -ne 0 ]
}

@test "review -> planned is rejected" {
  seed_yaml review
  run bash "$SS" transition --sprint sprint-900 --to planned
  [ "$status" -ne 0 ]
}

# ---------- AC2 / TS4: existing edges still accepted ----------

@test "active -> review still accepted (existing edge unchanged)" {
  seed_yaml active
  run bash "$SS" transition --sprint sprint-900 --to review
  [ "$status" -eq 0 ] \
    || { echo "active->review must still work, got: $output" >&2; false; }
  grep -Eq '^status:[[:space:]]*review' "$SPRINT_STATUS_YAML"
}

@test "review -> closed still accepted (existing edge unchanged)" {
  # AF-2026-05-31-3 / Test14 F-13: the review→closed edge now requires a
  # Val sentinel by default. This test asserts the EDGE itself remains
  # legal (ADR-108 D1 + FR-452); the sentinel gate is a separate guard
  # tested in af-2026-05-31-3-test14-findings.bats. Bypass it here with
  # the documented escape-hatch env var.
  seed_yaml review
  run env GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1 \
    bash "$SS" transition --sprint sprint-900 --to closed
  [ "$status" -eq 0 ]
  grep -Eq '^status:[[:space:]]*closed' "$SPRINT_STATUS_YAML"
}

# ---------- AC4: ADR-108 vocab enumerates planned ----------

@test "the vocabulary shard enumerates the planned sprint state" {
  ADR="$REPO_ROOT/../.gaia/artifacts/planning-artifacts/architecture/12-12-adr-detail-records.md"
  # project-root artifact, not in the gaia-public CI checkout -> skip when absent
  [ -f "$ADR" ] || skip "ADR shard is a project-root artifact not present in the gaia-public checkout"
  grep -Eiq 'planned' "$ADR" \
    || { echo "ADR-108 detail shard should enumerate the planned sprint state" >&2; false; }
}

# ---------- wrapper byte-identity (C3) ----------

@test "C3: the dev-story sprint-state.sh wrapper stays byte-identical to canonical" {
  WRAP="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/sprint-state.sh"
  [ -f "$WRAP" ]
  diff -q "$SS" "$WRAP" >/dev/null \
    || { echo "canonical and dev-story-wrapper sprint-state.sh must be byte-identical" >&2; false; }
}
