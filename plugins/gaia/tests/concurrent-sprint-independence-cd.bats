#!/usr/bin/env bats
# concurrent-sprint-independence-cd.bats — tests for independence-check.sh
# rules (c) and (d): touch-set overlap + planning-artifact exclusivity.
#
# Uses synthetic E9xx fixture keys to avoid leaking internal identifiers.

# shellcheck disable=SC2030,SC2031

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  PLANNING_DIR="$TEST_DIR/.gaia/artifacts/planning-artifacts"
  TEST_ARTIFACTS_DIR="$TEST_DIR/.gaia/artifacts/test-artifacts"
  SHARDS_DIR="$PLANNING_DIR/epics"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR" "$PLANNING_DIR" "$SHARDS_DIR"
  mkdir -p "$TEST_ARTIFACTS_DIR/strategy"
  mkdir -p "$PLANNING_DIR/architecture" "$PLANNING_DIR/prd" "$PLANNING_DIR/epics"
  mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/scripts/lib"
  mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/hooks"

  # Create real files for glob expansion tests.
  touch "$TEST_DIR/gaia-public/plugins/gaia/scripts/sprint-state.sh"
  touch "$TEST_DIR/gaia-public/plugins/gaia/scripts/independence-check.sh"
  touch "$TEST_DIR/gaia-public/plugins/gaia/scripts/lib/helper.sh"
  touch "$TEST_DIR/gaia-public/plugins/gaia/hooks/pre-commit.sh"

  # Concurrent mode config.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "test-project"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML

  # Epics file.
  cat > "$PLANNING_DIR/epics-and-stories.md" <<'MD'
# Epics and Stories

## E900 — Test Epic Alpha
## E901 — Test Epic Beta
## E902 — Test Epic Gamma
## E903 — Test Epic Delta
MD

  # Migration marker.
  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE_DIR/.sprint-migration-complete"

  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  IC_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/independence-check.sh"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_SCRIPT_DIR/scripts"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ---- Fixture helpers ----

create_sprint() {
  local sid="$1" status="$2"
  shift 2
  local f="$STATE_DIR/sprint-status-${sid}.yaml"
  {
    printf 'sprint_id: "%s"\n' "$sid"
    printf 'status: %s\n' "$status"
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    if [ $# -eq 0 ]; then
      printf 'stories: []\n'
    else
      printf 'stories:\n'
      for key in "$@"; do
        printf '  - key: "%s"\n' "$key"
        printf '    title: "Test story %s"\n' "$key"
        printf '    status: "in-progress"\n'
        printf '    points: 3\n'
        printf '    risk: "medium"\n'
      done
    fi
  } > "$f"
}

# Create a story with predicted_touch_set.
# Usage: create_story_ts <key> <epic> <touch_set_yaml> [config_sections_yaml]
create_story_ts() {
  local key="$1" epic="$2" ts_yaml="$3" cs_yaml="${4:-}"
  local epic_slug
  epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
  local story_dir="$IMPL_DIR/epic-${epic_slug}/${key}-test-story"
  mkdir -p "$story_dir"
  local f="$story_dir/story.md"
  {
    printf -- '---\n'
    printf 'key: "%s"\n' "$key"
    printf 'epic: "%s"\n' "$epic"
    printf 'status: in-progress\n'
    printf '%s\n' "$ts_yaml"
    if [ -n "$cs_yaml" ]; then
      printf '%s\n' "$cs_yaml"
    fi
    printf -- '---\n'
    printf '# Story: %s\n' "$key"
  } > "$f"
}

# Create a story with NO predicted_touch_set field.
create_story_no_ts() {
  local key="$1" epic="$2"
  local epic_slug
  epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
  local story_dir="$IMPL_DIR/epic-${epic_slug}/${key}-test-story"
  mkdir -p "$story_dir"
  local f="$story_dir/story.md"
  {
    printf -- '---\n'
    printf 'key: "%s"\n' "$key"
    printf 'epic: "%s"\n' "$epic"
    printf 'status: in-progress\n'
    printf -- '---\n'
    printf '# Story: %s\n' "$key"
  } > "$f"
}

# ---- Tests ----

@test "overlapping literal paths fail rule (c)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
  [[ "$output" == *"sprint-state.sh"* ]]
}

@test "missing predicted_touch_set fails closed naming sprint and story" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_no_ts "E900-S1" "E900"
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/some-file.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: missing predicted_touch_set: sprint-900"* ]]
}

@test "empty predicted_touch_set passes rule (c)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: []'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d): sprint-903 vs sprint-900"* ]]
}

@test "shared-prefix globs overlap when both match files" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/*"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/lib/*"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "disjoint prefix globs pass" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/*"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/*"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d):"* ]]
}

@test "directory literal prefix containment fails rule (c)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/lib/helper.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "zero-match glob excluded from shared-prefix evaluation" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  # */.git/* matches zero files due to .git pruning.
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["*/.git/*", "gaia-public/plugins/gaia/hooks/pre-commit.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/*"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d):"* ]]
}

@test "glob bounded to project tree" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/*.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/*.sh"]'

  # Create a file outside PROJECT_ROOT that would match *.sh — it must not be found.
  local outside_dir
  outside_dir="$(mktemp -d)"
  touch "$outside_dir/should-not-match.sh"

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  rm -rf "$outside_dir"
}

@test "backslash-escaped metacharacters treated as literal" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  # Create the file with brackets in the name.
  touch "$TEST_DIR/gaia-public/plugins/gaia/scripts/acquire-lock[1].sh"
  # Both stories use escaped brackets — un-escaped to the same literal path.
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/acquire-lock\[1\].sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/acquire-lock\[1\].sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
  [[ "$output" == *"acquire-lock[1].sh"* ]]
}

@test "symlink outside project excluded with warning on stdout" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  # Create a symlink pointing outside.
  ln -sf /etc/passwd "$TEST_DIR/gaia-public/plugins/gaia/scripts/symlink-to-outside"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/symlink-to-outside"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN out-of-root path excluded:"* ]]
}

@test "planning-artifact family overlap same path fails rule (d)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$PLANNING_DIR/prd/prd.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]]
}

@test "same family via shard path fails rule (d)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$PLANNING_DIR/prd/prd.md"
  mkdir -p "$PLANNING_DIR/prd/04-functional-requirements"
  touch "$PLANNING_DIR/prd/04-functional-requirements/shard.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/04-functional-requirements/shard.md"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]]
}

@test "cross-placement traceability family fails rule (d)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$TEST_ARTIFACTS_DIR/strategy/traceability-matrix.md"
  touch "$PLANNING_DIR/traceability-matrix.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/test-artifacts/strategy/traceability-matrix.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/traceability-matrix.md"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on traceability"* ]]
}

@test "different artifact families pass rule (d)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$PLANNING_DIR/prd/prd.md"
  touch "$PLANNING_DIR/architecture/architecture.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/architecture/architecture.md"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d):"* ]]
}

@test "path outside configured artifact dirs not classified for rule (d)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
}

@test "directory literal classified into every family beneath it" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$PLANNING_DIR/prd/x.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/x.md"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (d):"* ]]
}

@test "rules (c),(d) evaluated against every active sprint" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-901" "active" "E901-S1"
  create_sprint "sprint-902" "active" "E902-S1"
  create_sprint "sprint-903" "planned" "E903-S1"

  # Overlap only with sprint-901.
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'
  create_story_ts "E901-S1" "E901" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E902-S1" "E902" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/lib/helper.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900,sprint-901,sprint-902
  [ "$status" -eq 1 ]
  [[ "$output" == *"PASS rules (c),(d): sprint-903 vs sprint-900"* ]]
  [[ "$output" == *"FAIL rule (c):"*"sprint-903 -> sprint-901"* ]]
  [[ "$output" == *"PASS rules (c),(d): sprint-903 vs sprint-902"* ]]
}

@test "missing predicted_touch_set does not fall through to PASS" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_no_ts "E903-S1" "E903"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  # Must not contain any PASS for rules (c),(d).
  [[ "$output" != *"PASS rules (c),(d):"* ]]
}

@test "ambiguous path with double-dot segments fails closed" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/../../../etc/passwd"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"* ]]
}

@test "zero-match glob with literal entry — story not indeterminate" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["nonexistent-dir/*.sh", "gaia-public/plugins/gaia/scripts/new-script.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAIL indeterminate"* ]]
}

@test "all-zero-match-glob story fails indeterminate" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["nonexistent-dir/*.sh", "another-missing/*.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"*"zero-match"* ]]
}

@test "expansion timeout fails indeterminate" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/*.sh"]'

  # Shim timeout/gtimeout to return exit 124 immediately (simulating timeout).
  local shim_dir="$TEST_DIR/shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/timeout" <<'SHIM'
#!/usr/bin/env bash
exit 124
SHIM
  chmod +x "$shim_dir/timeout"
  cp "$shim_dir/timeout" "$shim_dir/gtimeout"
  chmod +x "$shim_dir/gtimeout"

  export GAIA_INDEPENDENCE_GLOB_TIMEOUT=1
  export PATH="$shim_dir:$PATH"
  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: expansion timed out"* ]]
}

@test "absolute path outside project rejected" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["/etc/hosts"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"*"outside"* ]]
}

@test "new-file literal entry accepted" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/new-script.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d):"* ]]
}

@test "PASS produces no stderr" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  local stderr_file
  stderr_file="$(mktemp)"
  run bash -c "bash '$IC_SCRIPT' --candidate sprint-903 --active sprint-900 2>'$stderr_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d): sprint-903 vs sprint-900"* ]]
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  rm -f "$stderr_file"
  [ -z "$stderr_content" ]
}

@test "config key granularity different sections pass" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$CONFIG_DIR/project-config.yaml"
  create_story_ts "E900-S1" "E900" \
    'predicted_touch_set: [".gaia/config/project-config.yaml"]' \
    'predicted_config_sections: ["sprint"]'
  create_story_ts "E903-S1" "E903" \
    'predicted_touch_set: [".gaia/config/project-config.yaml"]' \
    'predicted_config_sections: ["stacks"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d):"* ]]
}

@test "config key granularity missing field conservative fail" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" \
    'predicted_touch_set: [".gaia/config/project-config.yaml"]' \
    'predicted_config_sections: ["sprint"]'
  create_story_ts "E903-S1" "E903" \
    'predicted_touch_set: [".gaia/config/project-config.yaml"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL rule (d): config file ".gaia/config/project-config.yaml"'* ]]
}

@test "scaffold round-trip emits config sections when provided" {
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local gen="$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  local scaffold="$PLUGIN_ROOT/skills/gaia-create-story/scripts/scaffold-story.sh"
  local template="$PLUGIN_ROOT/skills/gaia-create-story/story-template.md"

  # Create minimal epics file.
  local epics_file="$TEST_DIR/epics.md"
  cat > "$epics_file" <<'MD'
# Epics and Stories

## E900 — Test Epic

### Story E900-S1: Config section test
- **Priority:** P1
- **Size:** M
- **Risk:** medium
- **Depends on:** —
- **Blocks:** —
- **Traces to:** —
MD

  # Scaffold test needs a full config for resolve-config.sh.
  local full_config="$TEST_DIR/full-config.yaml"
  cat > "$full_config" <<'YAML'
project_name: test
framework_version: "1.221.0"
installed_path: "./_gaia"
project_root: "."
project_path: "."
memory_path: "./.gaia/memory"
checkpoint_path: "./.gaia/memory/checkpoints"
date: "2026-01-01"
planning_artifacts: "./.gaia/artifacts/planning-artifacts"
implementation_artifacts: "./.gaia/artifacts/implementation-artifacts"
test_artifacts: "./.gaia/artifacts/test-artifacts"
creative_artifacts: "./.gaia/artifacts/creative-artifacts"
sizing_map:
  S: 1
  M: 3
  L: 5
  XL: 8
stacks:
  - id: bash
    path: "."
    role: primary
platforms: [web]
environments:
  - name: local
    url: "http://localhost"
YAML

  local fm
  fm="$(bash "$gen" --story-key "E900-S1" --epics-file "$epics_file" --project-config "$full_config" --config-section sprint --config-section stacks --project-root "$TEST_DIR" 2>&1)"

  [[ "$fm" == *'predicted_config_sections: ["sprint", "stacks"]'* ]]

  # Scaffold should emit the field.
  local out_f="$TEST_DIR/story_out.md"
  bash "$scaffold" --template "$template" --output "$out_f" --frontmatter "$fm" >/dev/null 2>&1

  /usr/bin/grep -q 'predicted_config_sections:.*sprint.*stacks' "$out_f"
}

@test "scaffold round-trip omits config sections when empty" {
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local gen="$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  local scaffold="$PLUGIN_ROOT/skills/gaia-create-story/scripts/scaffold-story.sh"
  local template="$PLUGIN_ROOT/skills/gaia-create-story/story-template.md"

  local epics_file="$TEST_DIR/epics.md"
  cat > "$epics_file" <<'MD'
# Epics and Stories

## E900 — Test Epic

### Story E900-S1: No config section test
- **Priority:** P1
- **Size:** M
- **Risk:** medium
- **Depends on:** —
- **Blocks:** —
- **Traces to:** —
MD

  local full_config="$TEST_DIR/full-config.yaml"
  cat > "$full_config" <<'YAML'
project_name: test
framework_version: "1.221.0"
installed_path: "./_gaia"
project_root: "."
project_path: "."
memory_path: "./.gaia/memory"
checkpoint_path: "./.gaia/memory/checkpoints"
date: "2026-01-01"
planning_artifacts: "./.gaia/artifacts/planning-artifacts"
implementation_artifacts: "./.gaia/artifacts/implementation-artifacts"
test_artifacts: "./.gaia/artifacts/test-artifacts"
creative_artifacts: "./.gaia/artifacts/creative-artifacts"
sizing_map:
  S: 1
  M: 3
  L: 5
  XL: 8
stacks:
  - id: bash
    path: "."
    role: primary
platforms: [web]
environments:
  - name: local
    url: "http://localhost"
YAML

  local fm
  fm="$(bash "$gen" --story-key "E900-S1" --epics-file "$epics_file" --project-config "$full_config" --project-root "$TEST_DIR" 2>&1)"

  # No config sections flag → field absent.
  [[ "$fm" != *"predicted_config_sections"* ]]

  local out_f="$TEST_DIR/story_out.md"
  bash "$scaffold" --template "$template" --output "$out_f" --frontmatter "$fm" >/dev/null 2>&1

  ! /usr/bin/grep -q 'predicted_config_sections' "$out_f"
}

@test "sanitizer mirror byte-identity" {
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local src="$PLUGIN_ROOT/scripts/lib/touch-set-sanitizer.sh"
  local mirror="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/lib/touch-set-sanitizer.sh"
  [ -f "$src" ]
  [ -f "$mirror" ]
  diff "$src" "$mirror"
}

@test "path outside configured artifact dirs not classified into any family" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  # Both touch files outside artifact dirs — different files.
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  # Rule (d) should not fail since neither path is in a family.
  [[ "$output" != *"FAIL rule (d):"* ]]
}

@test "broad glob matches unintended files — operator responsibility" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  # Create contest.js which *test* will match.
  touch "$TEST_DIR/contest.js"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["contest.js"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["*test*"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "same architecture family overlap fails rule (d)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$PLANNING_DIR/architecture/shard.md"
  touch "$PLANNING_DIR/architecture/architecture.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/architecture/shard.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/architecture/architecture.md"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on architecture"* ]]
}

@test "symlink resolving to same realpath detected as overlap" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  mkdir -p "$TEST_DIR/gaia-public/scripts"
  touch "$TEST_DIR/gaia-public/scripts/real.sh"
  ln -sf real.sh "$TEST_DIR/gaia-public/scripts/link.sh"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/scripts/link.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/scripts/real.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "project root with spaces handled correctly" {
  # Create a separate test dir with spaces in the path.
  local spaced_dir
  spaced_dir="$(mktemp -d "${TMPDIR:-/tmp}/my project.XXXXXX")"
  mkdir -p "$spaced_dir/.gaia/state" "$spaced_dir/.gaia/config"
  mkdir -p "$spaced_dir/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$spaced_dir/.gaia/artifacts/planning-artifacts/epics"
  mkdir -p "$spaced_dir/gaia-public/plugins/gaia/scripts"

  touch "$spaced_dir/gaia-public/plugins/gaia/scripts/sprint-state.sh"

  cat > "$spaced_dir/.gaia/config/project-config.yaml" <<'YAML'
project_name: "test-spaced"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML

  cat > "$spaced_dir/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'MD'
# Epics and Stories
## E900 — Alpha
## E903 — Delta
MD

  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$spaced_dir/.gaia/state/.sprint-migration-complete"

  # Create sprints and stories.
  local impl="$spaced_dir/.gaia/artifacts/implementation-artifacts"
  local state="$spaced_dir/.gaia/state"

  cat > "$state/sprint-status-sprint-900.yaml" <<YAML
sprint_id: "sprint-900"
status: active
total_points: 0
goals: []
stories:
  - key: "E900-S1"
    title: "Test"
    status: "in-progress"
    points: 3
    risk: "medium"
YAML

  cat > "$state/sprint-status-sprint-903.yaml" <<YAML
sprint_id: "sprint-903"
status: planned
total_points: 0
goals: []
stories:
  - key: "E903-S1"
    title: "Test"
    status: "in-progress"
    points: 3
    risk: "medium"
YAML

  mkdir -p "$impl/epic-e900/E900-S1-test-story"
  cat > "$impl/epic-e900/E900-S1-test-story/story.md" <<'STORY'
---
key: "E900-S1"
epic: "E900"
status: in-progress
predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]
---
# Story: E900-S1
STORY

  mkdir -p "$impl/epic-e903/E903-S1-test-story"
  cat > "$impl/epic-e903/E903-S1-test-story/story.md" <<'STORY'
---
key: "E903-S1"
epic: "E903"
status: in-progress
predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]
---
# Story: E903-S1
STORY

  export PROJECT_ROOT="$spaced_dir"
  export PROJECT_PATH="$spaced_dir"
  export IMPLEMENTATION_ARTIFACTS="$impl"

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  rm -rf "$spaced_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "absolute path under project root made relative" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" "predicted_touch_set: [\"${TEST_DIR}/gaia-public/plugins/gaia/scripts/sprint-state.sh\"]"

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "exclusion list prunes git and node_modules directories" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"

  # Create nested .git and node_modules dirs with files.
  mkdir -p "$TEST_DIR/gaia-public/.git/objects"
  touch "$TEST_DIR/gaia-public/.git/objects/test-file.sh"
  mkdir -p "$TEST_DIR/node_modules/some-pkg"
  touch "$TEST_DIR/node_modules/some-pkg/index.sh"

  # Globs that would match inside .git and node_modules without pruning.
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
}

@test "literal vs glob overlap by pattern match" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/*.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}
