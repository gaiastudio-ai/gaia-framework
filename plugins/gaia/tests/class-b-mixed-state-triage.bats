#!/usr/bin/env bats
# class-b-mixed-state-triage.bats — E97-S3
#
# Asserts the per-line triage for 4 Class B mixed-state scripts is consistent:
# canonical .gaia/ paths are preferred first, legacy docs/ / _memory/ /
# custom/ literals remain as fallback chain entries, and any user-visible
# remediation hints mention .gaia/ canonical paths first.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_SCRIPTS="$( cd "$BATS_TEST_DIRNAME/../scripts" && pwd )"
}

teardown() {
  common_teardown
}

# ---------- sprint-status-dashboard.sh ----------

@test "sprint-status-dashboard.sh — yaml resolution prefers .gaia/state/ canonical" {
  # Class A: fallback chain MUST list .gaia/state/ first in the YAML_PATH derivation.
  run awk '/^YAML_PATH=/,/^fi$/' "$PLUGIN_SCRIPTS/sprint-status-dashboard.sh"
  [[ "$output" == *".gaia/state/sprint-status.yaml"* ]]
  [[ "$output" == *"docs/implementation-artifacts/sprint-status.yaml"* ]]
  # Canonical line must come BEFORE legacy line in resolution order.
  gaia_line=$(grep -n 'GAIA_STATE_YAML=' "$PLUGIN_SCRIPTS/sprint-status-dashboard.sh" | head -1 | cut -d: -f1)
  legacy_line=$(grep -n 'CANONICAL_YAML="$PROJECT_PATH/docs' "$PLUGIN_SCRIPTS/sprint-status-dashboard.sh" | head -1 | cut -d: -f1)
  [ -n "$gaia_line" ]
  [ -n "$legacy_line" ]
  [ "$gaia_line" -lt "$legacy_line" ]
}

@test "sprint-status-dashboard.sh — IMPLEMENTATION_ARTIFACTS smart-fallback prefers .gaia/" {
  run grep -nE '\.gaia/artifacts/implementation-artifacts' "$PLUGIN_SCRIPTS/sprint-status-dashboard.sh"
  [ "$status" -eq 0 ]
  # The .gaia branch must appear in the `if -d` test BEFORE the legacy `docs/` else branch.
  gaia_line=$(grep -nE 'if \[ -d "\$PROJECT_PATH/\.gaia/artifacts/implementation-artifacts"' "$PLUGIN_SCRIPTS/sprint-status-dashboard.sh" | head -1 | cut -d: -f1)
  legacy_line=$(grep -nE 'IMPLEMENTATION_ARTIFACTS="\$PROJECT_PATH/docs/implementation-artifacts"' "$PLUGIN_SCRIPTS/sprint-status-dashboard.sh" | head -1 | cut -d: -f1)
  [ "$gaia_line" -lt "$legacy_line" ]
}

@test "sprint-status-dashboard.sh — remediation hint mentions .gaia/state/ canonical first" {
  # Class B: the user-visible remediation hint at the sprint-overdue branch
  # should reference .gaia/state/sprint-status.yaml as the primary path.
  run grep -nE 'yq -i.*sprint-status\.yaml' "$PLUGIN_SCRIPTS/sprint-status-dashboard.sh"
  [ "$status" -eq 0 ]
  # The first remediation line must mention .gaia/state/ (canonical).
  [[ "$output" == *".gaia/state/sprint-status.yaml"* ]]
}

# ---------- check-status-discipline.sh ----------

@test "check-status-discipline.sh — classify_path lists .gaia/ patterns before docs/" {
  # Class A: case statement must list .gaia/ patterns before docs/ patterns.
  gaia_line=$(grep -n '\.gaia/artifacts/implementation-artifacts/epic-' "$PLUGIN_SCRIPTS/check-status-discipline.sh" | head -1 | cut -d: -f1)
  legacy_line=$(grep -n '^[[:space:]]*docs/implementation-artifacts/epic-' "$PLUGIN_SCRIPTS/check-status-discipline.sh" | head -1 | cut -d: -f1)
  [ -n "$gaia_line" ]
  [ -n "$legacy_line" ]
  [ "$gaia_line" -lt "$legacy_line" ]
}

@test "check-status-discipline.sh — sprint-status.yaml classification covers both layouts" {
  run grep -E '(\.gaia/state|docs/implementation-artifacts)/sprint-status\.yaml\)[[:space:]]*printf' "$PLUGIN_SCRIPTS/check-status-discipline.sh"
  [ "$status" -eq 0 ]
  # Should have both — .gaia/state/ AND docs/implementation-artifacts/
  [[ "$output" == *".gaia/state/sprint-status.yaml"* ]]
  [[ "$output" == *"docs/implementation-artifacts/sprint-status.yaml"* ]]
}

# ---------- retro-sidecar-write.sh ----------

@test "retro-sidecar-write.sh — allowlist accepts both legacy + .gaia/ retrospective paths" {
  run grep -E '(\.gaia/artifacts/implementation-artifacts|docs/implementation-artifacts)/retrospective' "$PLUGIN_SCRIPTS/retro-sidecar-write.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/artifacts/implementation-artifacts/retrospective"* ]]
  [[ "$output" == *"docs/implementation-artifacts/retrospective"* ]]
}

@test "retro-sidecar-write.sh — allowlist accepts .gaia/memory/ sidecars only (AF-2026-05-27-3)" {
  # AF-2026-05-27-3 (ADR-111): the legacy _memory/ allowlist arm was removed.
  run grep -E '\.gaia/memory/\*-sidecar' "$PLUGIN_SCRIPTS/retro-sidecar-write.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/memory/"* ]]
  # legacy _memory/*-sidecar arm must be gone
  ! grep -qE '"\$real_root"/_memory/\*-sidecar' "$PLUGIN_SCRIPTS/retro-sidecar-write.sh"
}

@test "retro-sidecar-write.sh — allowlist accepts both action-items.yaml locations" {
  run grep -E '(\.gaia/state|docs/planning-artifacts)/action-items\.yaml' "$PLUGIN_SCRIPTS/retro-sidecar-write.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/state/action-items.yaml"* ]]
  [[ "$output" == *"docs/planning-artifacts/action-items.yaml"* ]]
}

# ---------- statusline.sh ----------

@test "statusline.sh — walk-up loop prefers .gaia/state/ over legacy docs/" {
  # Class A: inside the while loop, .gaia/state/ MUST be checked before docs/.
  gaia_line=$(grep -n '_GAIA_CANDIDATE="\$_SEARCH_DIR/\.gaia/state/sprint-status\.yaml"' "$PLUGIN_SCRIPTS/statusline.sh" | head -1 | cut -d: -f1)
  legacy_line=$(grep -n '_CANDIDATE="\$_SEARCH_DIR/docs/implementation-artifacts/sprint-status\.yaml"' "$PLUGIN_SCRIPTS/statusline.sh" | head -1 | cut -d: -f1)
  [ -n "$gaia_line" ]
  [ -n "$legacy_line" ]
  [ "$gaia_line" -lt "$legacy_line" ]
}

# ---------- smoke: all 4 scripts have valid bash syntax ----------

@test "all 4 mixed-state scripts pass bash -n syntax check" {
  for s in sprint-status-dashboard.sh check-status-discipline.sh retro-sidecar-write.sh statusline.sh; do
    run bash -n "$PLUGIN_SCRIPTS/$s"
    [ "$status" -eq 0 ]
  done
}
