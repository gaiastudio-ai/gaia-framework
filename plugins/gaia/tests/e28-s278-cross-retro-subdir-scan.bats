#!/usr/bin/env bats
# cross-retro-detect.sh discovers retros in the canonical retrospective/ subdir.
#
# /gaia-retro Step 6 writes retrospectives into the nested
# `.../implementation-artifacts/retrospective/` subdir, but the cross-retro
# scanner is invoked with --retros-dir pointing at the PARENT
# implementation-artifacts dir and previously globbed `retrospective-*.md`
# non-recursively. Once retros landed in the subdir the glob matched zero
# files and the systemic-theme / escalation_count mechanism silently no-op'd.
# These tests pin that the scanner now sweeps BOTH the nested subdir and the
# legacy flat location, de-duplicated.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$PLUGIN_ROOT/skills/gaia-retro/scripts/cross-retro-detect.sh"
  RD="$BATS_TEST_TMPDIR/ia"
}

# Seed two retros (distinct sprints) sharing one action-item theme.
_seed_retro() {
  # $1 = target dir, $2 = sprint id, $3 = date
  mkdir -p "$1"
  cat > "$1/retrospective-$2-$3.md" <<EOF
---
sprint_id: "$2"
---
## Action Items
- Flaky write-checkpoint test needs a fix
EOF
}

@test "scanner declares the subdir + flat dual-sweep (AC1)" {
  grep -qF '"$RETROS_DIR"/retrospective/retrospective-*.md' "$SCRIPT"
  grep -qF '"$RETROS_DIR"/retrospective-*.md' "$SCRIPT"
}

@test "retros in the nested retrospective/ subdir are discovered (AC1)" {
  _seed_retro "$RD/retrospective" sprint-1 2026-06-01
  _seed_retro "$RD/retrospective" sprint-2 2026-06-08
  run bash "$SCRIPT" --retros-dir "$RD" --current-sprint sprint-3
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemic themes detected: 1"* ]]
}

@test "legacy FLAT retros are still discovered — back-compat (AC2)" {
  _seed_retro "$RD" sprint-1 2026-06-01
  _seed_retro "$RD" sprint-2 2026-06-08
  run bash "$SCRIPT" --retros-dir "$RD" --current-sprint sprint-3
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemic themes detected: 1"* ]]
}

@test "same retro present in BOTH locations is counted once (AC3)" {
  # One sprint's retro duplicated across flat + subdir; the second sprint only
  # in the subdir. Dedup must not inflate the theme into a false 2nd instance.
  _seed_retro "$RD" sprint-1 2026-06-01
  _seed_retro "$RD/retrospective" sprint-1 2026-06-01
  _seed_retro "$RD/retrospective" sprint-2 2026-06-08
  run bash "$SCRIPT" --retros-dir "$RD" --current-sprint sprint-3
  [ "$status" -eq 0 ]
  # Exactly one systemic theme — the shared action item across sprint-1 +
  # sprint-2, NOT a spurious second from the duplicated sprint-1 file.
  [[ "$output" == *"systemic themes detected: 1"* ]]
}

@test "no prior retros anywhere → clean exit 0, no detection (AC1)" {
  mkdir -p "$RD"
  run bash "$SCRIPT" --retros-dir "$RD" --current-sprint sprint-3
  [ "$status" -eq 0 ]
  [[ "$output" != *"systemic themes detected"* ]]
}
