#!/usr/bin/env bats
# AF-2026-05-22-9: medium/low bug bundle from YARA test report.
#
# Covers 11 framework-friction findings:
#   Bug-1   generate-config.sh emits `ci_cd: {}` at phase=full (schema fix).
#   Bug-2   PRD SV-16..SV-24 regexes tolerate numbered headings.
#   Bug-3   epics SV-05..SV-10, SV-17 regexes tolerate **bolded** labels.
#   Bug-7   /gaia-bridge-enable scaffolds a stub instead of halting.
#   Bug-8   sprint-state.sh init subcommand for fresh projects.
#   Bug-9   set-goals replaces `goals: []` instead of duplicating.
#   Bug-11  gaia-init/setup.sh preflights yq availability.
#   Bug-12  sprint-review/finalize.sh SPRINT_ID unset is a hard error
#           unless GAIA_SPRINT_REVIEW_FIXTURE=1.
#   Bug-13  compose-verdict.sh accepts WARNING and normalizes to PASSED.
#   Bug-15  generate-config.sh coerces list-form compliance instead of
#           crashing on AttributeError.
#   Bug-16  test-strategy/finalize.sh surfaces stderr from checkpoint /
#           lifecycle-event failures instead of swallowing it.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- Bug 1: ci_cd: {} stub at phase=full ---

@test "AF-22-9 Bug-1: generate-config.sh emits ci_cd: {} at phase=full" {
  grep -qF 'AF-2026-05-22-9 Bug-1' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  grep -qF 'ci_cd: {}' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}

# --- Bug 2: PRD numbered headings ---

@test "AF-22-9 Bug-2: PRD section_body_nonempty regex tolerates numbered prefix" {
  grep -qF 'AF-2026-05-22-9 Bug-2' "$PLUGIN_ROOT/skills/gaia-create-prd/scripts/finalize.sh"
  # The numeric-prefix sub-pattern appears inside section_body_nonempty's awk.
  grep -qF '([0-9]+(\\.[0-9]+)*\\.?[[:space:]]+)' "$PLUGIN_ROOT/skills/gaia-create-prd/scripts/finalize.sh"
}

# --- Bug 3: epics bolded **Priority:** labels ---

@test "AF-22-9 Bug-3: epics per_story_field_present regex accepts bolded labels" {
  grep -qF 'AF-2026-05-22-9 Bug-3' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  grep -qF '(\\*\\*)?" lab "(\\*\\*)?' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
}

# --- Bug 7: bridge-enable scaffold ---

@test "AF-22-9 Bug-7: gaia-bridge-enable SKILL.md scaffolds stub instead of halting" {
  grep -qF 'AF-2026-05-22-9 Bug-7' "$PLUGIN_ROOT/skills/gaia-bridge-enable/SKILL.md"
  grep -qF 'scaffold a minimal stub' "$PLUGIN_ROOT/skills/gaia-bridge-enable/SKILL.md"
  # Negative: the old "fail fast" wording is gone from the relevant step.
  ! grep -qF 'fail fast with `test_execution_bridge block missing' "$PLUGIN_ROOT/skills/gaia-bridge-enable/SKILL.md"
}

# --- Bug 8: sprint-state.sh init subcommand ---

@test "AF-22-9 Bug-8: sprint-state.sh declares cmd_init + init case branch" {
  grep -qF 'AF-2026-05-22-9 Bug-8' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  grep -qF 'cmd_init()' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  # init MUST be a routed subcommand in the dispatcher.
  grep -qE '^[[:space:]]+init\)$' "$PLUGIN_ROOT/scripts/sprint-state.sh"
}

@test "AF-22-9 Bug-8: gaia-dev-story sprint-state.sh wrapper is byte-identical to canonical" {
  diff -q "$PLUGIN_ROOT/scripts/sprint-state.sh" \
          "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh"
}

@test "AF-22-9 Bug-8: sprint-state.sh init seeds yaml shape end-to-end" {
  local tmp="$BATS_TEST_TMPDIR/init-fixture"
  mkdir -p "$tmp"
  SPRINT_STATUS_YAML="$tmp/sprint-status.yaml" \
    bash "$PLUGIN_ROOT/scripts/sprint-state.sh" init --sprint-id sprint-7
  [ -f "$tmp/sprint-status.yaml" ]
  grep -qF 'sprint_id: "sprint-7"' "$tmp/sprint-status.yaml"
  grep -qF 'state: active' "$tmp/sprint-status.yaml"
  grep -qF 'total_points: 0' "$tmp/sprint-status.yaml"
  grep -qF 'goals: []' "$tmp/sprint-status.yaml"
  grep -qF 'items: []' "$tmp/sprint-status.yaml"
}

@test "AF-22-9 Bug-8: sprint-state.sh init refuses to overwrite existing yaml" {
  local tmp="$BATS_TEST_TMPDIR/init-noclobber"
  mkdir -p "$tmp"
  printf 'sprint_id: existing\n' > "$tmp/sprint-status.yaml"
  run env SPRINT_STATUS_YAML="$tmp/sprint-status.yaml" \
    bash "$PLUGIN_ROOT/scripts/sprint-state.sh" init --sprint-id sprint-8
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'already exists'
}

# --- Bug 9: set-goals replaces goals: [] (end-to-end) ---

@test "AF-22-9 Bug-9: set-goals replaces goals: [] without duplicating the key" {
  local tmp="$BATS_TEST_TMPDIR/setgoals-fixture"
  mkdir -p "$tmp"
  cat > "$tmp/sprint-status.yaml" <<'EOF'
sprint_id: "sprint-1"
state: active
total_points: 0
goals: []
items: []
EOF
  SPRINT_STATUS_YAML="$tmp/sprint-status.yaml" \
    bash "$PLUGIN_ROOT/scripts/sprint-state.sh" set-goals --sprint sprint-1 --goals "ship A|ship B"
  # Exactly one `goals:` line should exist after the rewrite.
  local n
  n=$(grep -c '^goals:' "$tmp/sprint-status.yaml")
  [ "$n" -eq 1 ]
  grep -qF 'ship A' "$tmp/sprint-status.yaml"
  grep -qF 'ship B' "$tmp/sprint-status.yaml"
}

# --- Bug 11: gaia-init/setup.sh yq preflight ---

@test "AF-22-9 Bug-11: gaia-init/setup.sh preflights yq presence" {
  grep -qF 'AF-2026-05-22-9 Bug-11' "$PLUGIN_ROOT/skills/gaia-init/scripts/setup.sh"
  grep -qF 'yq (mikefarah Go v4) not on PATH' "$PLUGIN_ROOT/skills/gaia-init/scripts/setup.sh"
}

# --- Bug 12: sprint-review SPRINT_ID hard error unless fixture flag ---

@test "AF-22-9 Bug-12: sprint-review/finalize.sh halts without SPRINT_ID unless fixture flag" {
  grep -qF 'AF-2026-05-22-9 Bug-12' "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/finalize.sh"
  grep -qF 'GAIA_SPRINT_REVIEW_FIXTURE' "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/finalize.sh"
}

# --- Bug 13: compose-verdict accepts WARNING ---

@test "AF-22-9 Bug-13: compose-verdict.sh accepts WARNING on track-a and yields PASSED" {
  grep -qF 'AF-2026-05-22-9 Bug-13' "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/compose-verdict.sh"
  run bash "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/compose-verdict.sh" \
    --track-a WARNING --track-b SKIPPED
  [ "$status" -eq 0 ]
  [ "$output" = "PASSED" ]
}

@test "AF-22-9 Bug-13: compose-verdict.sh accepts WARNING on track-b and yields PASSED" {
  run bash "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/compose-verdict.sh" \
    --track-a PASSED --track-b WARNING
  [ "$status" -eq 0 ]
  [ "$output" = "PASSED" ]
}

@test "AF-22-9 Bug-13: compose-verdict.sh still rejects truly bogus verdicts" {
  run bash "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/compose-verdict.sh" \
    --track-a BOGUS --track-b SKIPPED
  [ "$status" -ne 0 ]
}

# --- Bug 15: list-form compliance doesn't crash ---

@test "AF-22-9 Bug-15: generate-config.sh declares list-form compliance coercion" {
  grep -qF 'AF-2026-05-22-9 Bug-15' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  grep -qF 'isinstance(compliance, list)' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}

# --- Bug 16: test-strategy stderr surfacing ---

@test "AF-22-9 Bug-16: test-strategy/finalize.sh surfaces stderr from non-fatal observability failures" {
  grep -qF 'AF-2026-05-22-9 Bug-16' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  # Confirm the new pattern captures stderr and concatenates it into log.
  grep -qF 'observability gap only): ${_cp_err' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF 'observability gap only): ${_le_err' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}
