#!/usr/bin/env bats
# action-items-canonical-path.bats
#
# Tests for the action-items canonical path unification: readers and writers
# agree on a single path resolved via the shared tier resolver.
#
# Covers:
#   - resolve-artifact-path.sh returns the state-tier path for action_items
#   - escalation-halt blocks on aged HIGH items in the state-tier file
#   - SKILL.md prose names the tier-resolved canonical location
#
# @component gaia-core

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVER="$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
  ESCALATION_HALT_SH="$PLUGIN_ROOT/scripts/escalation-halt.sh"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_write_action_items() {
  local file="$1"; shift
  {
    printf 'action_items:\n'
    local e
    for e in "$@"; do
      IFS='|' read -r id title priority status esc <<<"$e"
      printf '  - id: "%s"\n' "$id"
      printf '    title: "%s"\n' "$title"
      printf '    classification: process\n'
      printf '    priority: %s\n' "$priority"
      printf '    status: %s\n' "$status"
      printf '    escalation_count: %s\n' "$esc"
    done
  } > "$file"
}

_make_sprint_status_yaml() {
  local file="$1"
  cat > "$file" <<'EOF'
sprint_id: "sprint-99"
duration: "2 weeks"
velocity_capacity: 21
total_points: 10
started: "2026-04-22"
end_date: "2026-05-06"
stories:
  - key: "T1-S1"
    title: "Example"
    status: "ready-for-dev"
    points: 3
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-04-22"
EOF
}

# ===========================================================================
# Resolver: action_items kind registration (AC1, AC3)
# ===========================================================================

@test "resolver returns state-tier path for action_items kind (AC1)" {
  cd "$TEST_TMP"
  mkdir -p .gaia/state .gaia/artifacts/planning-artifacts
  _write_action_items .gaia/state/action-items.yaml "AI-1|test|HIGH|open|2"

  run "$RESOLVER" action_items --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/state/action-items.yaml"* ]]
}

@test "resolver prefers state-tier over planning-artifacts when both exist (AC3)" {
  cd "$TEST_TMP"
  mkdir -p .gaia/state .gaia/artifacts/planning-artifacts
  _write_action_items .gaia/state/action-items.yaml "AI-1|state-tier|HIGH|open|2"
  _write_action_items .gaia/artifacts/planning-artifacts/action-items.yaml "AI-2|legacy|MEDIUM|open|0"

  run "$RESOLVER" action_items --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/state/action-items.yaml"* ]]
}

@test "resolver falls back to planning-artifacts when state-tier absent (AC1)" {
  cd "$TEST_TMP"
  mkdir -p .gaia/state .gaia/artifacts/planning-artifacts
  _write_action_items .gaia/artifacts/planning-artifacts/action-items.yaml "AI-2|legacy|MEDIUM|open|0"

  run "$RESOLVER" action_items --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/artifacts/planning-artifacts/action-items.yaml"* ]]
}

@test "resolver returns canonical rung-1 path when neither location exists (AC1)" {
  cd "$TEST_TMP"
  mkdir -p .gaia/state .gaia/artifacts/planning-artifacts

  run "$RESOLVER" action_items --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/state/action-items.yaml"* ]]
}

@test "resolver --existing-only exits 1 when no action-items file exists (AC1)" {
  cd "$TEST_TMP"
  mkdir -p .gaia/state .gaia/artifacts/planning-artifacts

  run "$RESOLVER" action_items --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 1 ]
}

# ===========================================================================
# Escalation-halt blocks on state-tier aged HIGH items (AC2)
# ===========================================================================

@test "escalation-halt blocks on HIGH item aged 2+ sprints in state-tier file (AC2)" {
  local ai="$TEST_TMP/.gaia/state/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  mkdir -p "$TEST_TMP/.gaia/state"
  _write_action_items "$ai" "AI-42|Long-running blocker|HIGH|open|2"
  _make_sprint_status_yaml "$ss"

  # Run esch_check_blocking against the state-tier path
  run bash -c "source '$ESCALATION_HALT_SH' && esch_check_blocking '$ai' '$ss'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "AI-42"
  echo "$output" | grep -q "Long-running blocker"
  echo "$output" | grep -q "HALT"
}

# ===========================================================================
# SKILL.md prose: readers name the tier-resolved canonical path (AC4)
# ===========================================================================

@test "sprint-plan SKILL.md references resolve-artifact-path for action-items (AC4)" {
  grep -q 'resolve-artifact-path' "$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
}

@test "sprint-plan SKILL.md names state-tier action-items path (AC4)" {
  grep -qF '.gaia/state/action-items.yaml' "$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
}

@test "action-items SKILL.md names state-tier action-items path as canonical (AC4)" {
  grep -qF '.gaia/state/action-items.yaml' "$PLUGIN_ROOT/skills/gaia-action-items/SKILL.md"
}

@test "sprint-plan SKILL.md does not hardcode planning-artifacts as primary read path (AC4)" {
  # The escalation-halt invocation code-fence must NOT pass planning-artifacts
  # as the action-items path. The resolver or state-tier path must appear instead.
  local invocation
  invocation="$(sed -n '/esch_check_blocking/,/```/p' "$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md")"
  run echo "$invocation"
  [[ "$output" != *"planning-artifacts/action-items.yaml"* ]]
}
