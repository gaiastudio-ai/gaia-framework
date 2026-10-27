#!/usr/bin/env bats
# concurrent-sprint-independence-cd.bats — tests for independence-check.sh
# rules (c) and (d): touch-set overlap + planning-artifact exclusivity.
#
# Uses synthetic E9xx fixture keys to avoid leaking internal identifiers.

# shellcheck disable=SC2030,SC2031

load 'test_helper.bash'

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

  # Concurrent mode config (complete — the resolver must exit 0).
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
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
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/some-file.sh"]'

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

@test "question-mark wildcard expands correctly and overlaps" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  # ? matches any single character — sprint-state.s? matches sprint-state.sh
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.s?"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "character-class glob expands correctly and overlaps" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  # [a-z] character class matches 's' in sprint-state.sh
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/[a-z]print-state.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
}

@test "literal dot in glob does not match arbitrary character" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  # Create a file named "sprint-stateXsh" (X instead of .)
  touch "$TEST_DIR/gaia-public/plugins/gaia/scripts/sprint-stateXsh"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-stateXsh"]'
  # The glob "sprint-state.sh" has a literal dot — must not match "sprint-stateXsh"
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  # No overlap — the dot is literal in find -path, not a regex wildcard.
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d):"* ]]
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
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["nonexistent-dir/*.sh", "gaia-public/plugins/gaia/hooks/new-hook.sh"]'

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
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/new-hook.sh"]'

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
  [ -z "$stderr_content" ] || { echo "unexpected stderr: $stderr_content"; false; }
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

  cat > "$spaced_dir/.gaia/config/project-config.yaml" <<YAML
project_name: "test-spaced"
project_root: "$spaced_dir"
project_path: "$spaced_dir/app"
memory_path: "$spaced_dir/.gaia/memory"
checkpoint_path: "$spaced_dir/.gaia/memory/checkpoints"
installed_path: "$spaced_dir/_gaia"
framework_version: 1.200.0
date: 1970-01-01
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

# ---- AC6: same config section overlap ----

@test "config key granularity same section fails rule (d)" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" \
    'predicted_touch_set: [".gaia/config/project-config.yaml"]' \
    'predicted_config_sections: ["sprint"]'
  create_story_ts "E903-S1" "E903" \
    'predicted_touch_set: [".gaia/config/project-config.yaml"]' \
    'predicted_config_sections: ["sprint"]'

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL rule (d): config section "sprint"'* ]]
}

# ---- AC10: FAIL lines on both stdout AND stderr ----

@test "FAIL rule (c) appears on both stdout and stderr" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  local stderr_f
  stderr_f="$(mktemp)"
  run bash -c "bash '$IC_SCRIPT' --candidate sprint-903 --active sprint-900 2>'$stderr_f'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rule (c):"* ]]
  /usr/bin/grep -q "FAIL rule (c):" "$stderr_f"
  rm -f "$stderr_f"
}

@test "FAIL rule (d) appears on both stdout and stderr" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$PLANNING_DIR/prd/prd.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'

  local stderr_f
  stderr_f="$(mktemp)"
  run bash -c "bash '$IC_SCRIPT' --candidate sprint-903 --active sprint-900 2>'$stderr_f'"
  [ "$status" -eq 1 ]
  /usr/bin/grep -q "FAIL rule (d):" "$stderr_f"
  rm -f "$stderr_f"
}

@test "FAIL indeterminate appears on both stdout and stderr" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_no_ts "E903-S1" "E903"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'

  local stderr_f
  stderr_f="$(mktemp)"
  run bash -c "bash '$IC_SCRIPT' --candidate sprint-903 --active sprint-900 2>'$stderr_f'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"* ]]
  /usr/bin/grep -q "FAIL indeterminate:" "$stderr_f"
  rm -f "$stderr_f"
}

# ---- No story declares field → FAIL indeterminate (kills SKIP mutant) ----

@test "no story declares predicted_touch_set fails indeterminate" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_no_ts "E900-S1" "E900"
  create_story_no_ts "E903-S1" "E903"

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate: missing predicted_touch_set:"* ]]
  [[ "$output" != *"PASS rules (c),(d):"* ]]
}

# ---- Sprint-id prefix confusion ----

@test "sprint-90 vs sprint-900 not confused by prefix matching" {
  create_sprint "sprint-90" "active" "E900-S1"
  create_sprint "sprint-900" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'

  run bash "$IC_SCRIPT" --candidate sprint-900 --active sprint-90
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 vs sprint-90"* ]]
  [[ "$output" != *"sprint-900 vs sprint-900"* ]]
}

# ---- Fail-closed safety gate tests ----

@test "awk crash in classification fails closed, not open" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'

  # Shim awk to crash on classification invocations.
  local shim_dir="$TEST_DIR/shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/awk" <<'SHIM'
#!/usr/bin/env bash
# Crash on any invocation that writes type files (classification phase).
for arg in "$@"; do
  case "$arg" in *ts_dir*|*meta_file*) exit 99 ;; esac
done
exec /usr/bin/awk "$@"
SHIM
  chmod +x "$shim_dir/awk"

  export PATH="$shim_dir:$PATH"
  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"* ]]
}

@test "realpath failure fails closed, not silently dropped" {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]'

  # Shim realpath to fail on any call.
  local shim_dir="$TEST_DIR/shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/realpath" <<'SHIM'
#!/usr/bin/env bash
echo "realpath: simulated failure" >&2
exit 1
SHIM
  chmod +x "$shim_dir/realpath"

  export PATH="$shim_dir:$PATH"
  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL indeterminate:"* ]]
}

# ---------- rule (d) with real resolver (absolute artifact paths) ---------

# Helper: write a complete config with all required fields so the resolver
# runs its full path instead of bailing on a missing field.
_write_full_config() {
  local root="$1"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: $root
project_path: $root/app
memory_path: $root/.gaia/memory
checkpoint_path: $root/.gaia/memory/checkpoints
installed_path: $root/_gaia
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: .gaia/artifacts/planning-artifacts
test_artifacts: .gaia/artifacts/test-artifacts
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
}

# Seed two sprints that both touch the same PRD.
_seed_prd_overlap() {
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$PLANNING_DIR/prd/prd.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/prd.md"]'
}

@test "rule (d) fires with absolute project_root in config" {
  _write_full_config "$TEST_DIR"
  _seed_prd_overlap
  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "rule (d) fires with dot root and root env set to test dir" {
  _write_full_config "."
  _seed_prd_overlap
  export PROJECT_ROOT="$TEST_DIR"
  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "rule (d) fires with dot root and all root envs unset" {
  # The shipping call shape: project_root: ".", no root env.
  _write_full_config "."
  _seed_prd_overlap
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "traversal root in config fails closed via resolver error" {
  # project_root: "../<dirname>" — the resolver rejects traversal and exits
  # non-zero. The check must fail closed, not silently fall back.
  local name
  name="$(basename "$TEST_DIR")"
  _write_full_config "../${name}"
  _seed_prd_overlap
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected exit 1, got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL indeterminate"* ]] || { echo "missing FAIL indeterminate"; echo "$output"; false; }
}

@test "rule (d) fires with doubled-slash root and envs unset" {
  _write_full_config "$TEST_DIR//"
  _seed_prd_overlap
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "rule (d) fires with trailing-dot root and envs unset" {
  _write_full_config "$TEST_DIR/./"
  _seed_prd_overlap
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "rule (d) fires for test-plan family overlap via resolver" {
  # Covers the test_dir strip (guards test-plan/traceability families).
  _write_full_config "$TEST_DIR"
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  touch "$TEST_ARTIFACTS_DIR/strategy/traceability-matrix.md"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: [".gaia/artifacts/test-artifacts/strategy/traceability-matrix.md"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: [".gaia/artifacts/test-artifacts/strategy/traceability-matrix.md"]'
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on traceability"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "rule (d) fires when project root path contains an apostrophe" {
  # The resolver shell-escapes apostrophes as '\''. The parser must decode
  # them so the prefix strip matches. The apostrophe is in the project root
  # directory name, so every resolved absolute path contains it.
  # Stories touch DIFFERENT files in the prd family so rule (c) cannot mask.
  local apos_dir="$TEST_DIR/proj'apos"
  local a_state="$apos_dir/.gaia/state"
  local a_impl="$apos_dir/.gaia/artifacts/implementation-artifacts"
  local a_plan="$apos_dir/.gaia/artifacts/planning-artifacts"
  local a_test="$apos_dir/.gaia/artifacts/test-artifacts"
  local a_cfg="$apos_dir/.gaia/config"
  mkdir -p "$a_state" "$a_impl" "$a_cfg" "$a_plan/prd" "$a_plan/architecture" "$a_plan/epics" "$a_test/strategy"
  mkdir -p "$apos_dir/gaia-public/plugins/gaia/scripts/lib" "$apos_dir/gaia-public/plugins/gaia/hooks"
  touch "$apos_dir/gaia-public/plugins/gaia/scripts/sprint-state.sh" "$apos_dir/gaia-public/plugins/gaia/scripts/independence-check.sh" "$apos_dir/gaia-public/plugins/gaia/scripts/lib/helper.sh" "$apos_dir/gaia-public/plugins/gaia/hooks/pre-commit.sh"
  cat > "$a_plan/epics-and-stories.md" <<'MD'
# Epics and Stories
## E900 — Test
## E903 — Test2
MD
  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$a_state/.sprint-migration-complete"
  cat > "$a_cfg/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$apos_dir"
project_path: "$apos_dir/app"
memory_path: "$apos_dir/.gaia/memory"
checkpoint_path: "$apos_dir/.gaia/memory/checkpoints"
installed_path: "$apos_dir/_gaia"
framework_version: 1.200.0
date: 1970-01-01
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  for sid in sprint-900 sprint-903; do
    local _status; [ "$sid" = "sprint-900" ] && _status=active || _status=planned
    local _key; [ "$sid" = "sprint-900" ] && _key=E900-S1 || _key=E903-S1
    cat > "$a_state/sprint-status-${sid}.yaml" <<YML
sprint_id: "$sid"
status: $_status
stories:
  - key: "$_key"
    status: in-progress
YML
  done
  touch "$a_plan/prd/a.md" "$a_plan/prd/b.md"
  local _d
  for pair in "E900-S1:E900:a" "E903-S1:E903:b"; do
    IFS=: read -r _k _e _f <<< "$pair"
    _d="$a_impl/epic-$(printf '%s' "$_e" | tr '[:upper:]' '[:lower:]')/${_k}-test-story"
    mkdir -p "$_d"
    printf -- '---\nkey: "%s"\nepic: "%s"\nstatus: in-progress\npredicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/%s.md"]\n---\n# Story: %s\n' "$_k" "$_e" "$_f" "$_k" > "$_d/story.md"
  done
  cd "$apos_dir"
  run env PROJECT_ROOT="$apos_dir" PROJECT_PATH="$apos_dir" \
    IMPLEMENTATION_ARTIFACTS="$a_impl" GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}


@test "rule (d) fires with apostrophe in planning_artifacts dir name" {
  # Apostrophe in the artifact dir name exercises the quote decoder.
  # Stories touch DIFFERENT files of one family so rule (c) cannot mask.
  local apos_dir="$TEST_DIR/proj'plan"
  local a_state="$apos_dir/.gaia/state" a_impl="$apos_dir/.gaia/artifacts/implementation-artifacts"
  local a_plan="$apos_dir/.gaia/artifacts/plan'ning" a_test="$apos_dir/.gaia/artifacts/test-artifacts"
  local a_cfg="$apos_dir/.gaia/config"
  mkdir -p "$a_state" "$a_impl" "$a_cfg" "$a_plan/prd" "$a_plan/architecture" "$a_plan/epics" "$a_test/strategy"
  mkdir -p "$apos_dir/gaia-public/plugins/gaia/scripts/lib" "$apos_dir/gaia-public/plugins/gaia/hooks"
  touch "$apos_dir/gaia-public/plugins/gaia/scripts/sprint-state.sh" "$apos_dir/gaia-public/plugins/gaia/scripts/independence-check.sh" "$apos_dir/gaia-public/plugins/gaia/scripts/lib/helper.sh" "$apos_dir/gaia-public/plugins/gaia/hooks/pre-commit.sh"
  cat > "$a_plan/epics-and-stories.md" <<'MD'
# Epics and Stories
## E900 — Test
## E903 — Test2
MD
  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$a_state/.sprint-migration-complete"
  cat > "$a_cfg/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$apos_dir"
project_path: "$apos_dir/app"
memory_path: "$apos_dir/.gaia/memory"
checkpoint_path: "$apos_dir/.gaia/memory/checkpoints"
installed_path: "$apos_dir/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: "$a_plan"
test_artifacts: "$a_test"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  for sid in sprint-900 sprint-903; do
    local _st; [ "$sid" = "sprint-900" ] && _st=active || _st=planned
    local _k; [ "$sid" = "sprint-900" ] && _k=E900-S1 || _k=E903-S1
    cat > "$a_state/sprint-status-${sid}.yaml" <<YML
sprint_id: "$sid"
status: $_st
stories:
  - key: "$_k"
    status: in-progress
YML
  done
  touch "$a_plan/prd/a.md" "$a_plan/prd/b.md"
  for pair in "E900-S1:E900:a" "E903-S1:E903:b"; do
    IFS=: read -r _k _e _f <<< "$pair"
    local _d="$a_impl/epic-$(printf '%s' "$_e" | tr '[:upper:]' '[:lower:]')/${_k}-test-story"
    mkdir -p "$_d"
    printf -- "---\nkey: \"%s\"\nepic: \"%s\"\nstatus: in-progress\npredicted_touch_set: [\".gaia/artifacts/plan'ning/prd/%s.md\"]\n---\n# Story: %s\n" "$_k" "$_e" "$_f" "$_k" > "$_d/story.md"
  done
  cd "$apos_dir"
  run env PROJECT_ROOT="$apos_dir" PROJECT_PATH="$apos_dir" \
    IMPLEMENTATION_ARTIFACTS="$a_impl" GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

# ---- Standalone project fixture helper ----
# _make_project <root> <planning_rel> <test_rel> <overlap_family> [touch1] [touch2]
#   Creates a minimal project tree with two sprints and two stories that
#   touch DIFFERENT files of <overlap_family>. Dirs are created under <root>.
#   planning_rel/test_rel are the config values (relative or absolute).
#   Returns 0 on success.
_make_project() {
  local root="$1" p_cfg="$2" t_cfg="$3" family="$4"
  local touch1="${5:-}" touch2="${6:-}"
  local state="$root/.gaia/state" impl="$root/.gaia/artifacts/implementation-artifacts"
  local cfg="$root/.gaia/config"
  # Resolve the physical dir for planning/test from the config value.
  local p_dir t_dir
  case "$p_cfg" in
    /*) p_dir="$p_cfg" ;;
    *)  p_dir="$root/$p_cfg" ;;
  esac
  case "$t_cfg" in
    /*) t_dir="$t_cfg" ;;
    *)  t_dir="$root/$t_cfg" ;;
  esac
  mkdir -p "$state" "$impl" "$cfg"
  mkdir -p "$p_dir/prd" "$p_dir/architecture" "$p_dir/epics"
  mkdir -p "$t_dir/strategy"
  mkdir -p "$root/gaia-public/plugins/gaia/scripts/lib" "$root/gaia-public/plugins/gaia/hooks"
  touch "$root/gaia-public/plugins/gaia/scripts/sprint-state.sh"
  touch "$root/gaia-public/plugins/gaia/scripts/independence-check.sh"
  touch "$root/gaia-public/plugins/gaia/scripts/lib/helper.sh"
  touch "$root/gaia-public/plugins/gaia/hooks/pre-commit.sh"
  cat > "$p_dir/epics-and-stories.md" <<'MD'
# Epics and Stories
## E900 — Test
## E903 — Test2
MD
  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$state/.sprint-migration-complete"
  cat > "$cfg/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$root"
project_path: "$root/app"
memory_path: "$root/.gaia/memory"
checkpoint_path: "$root/.gaia/memory/checkpoints"
installed_path: "$root/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: "$p_cfg"
test_artifacts: "$t_cfg"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  for sid in sprint-900 sprint-903; do
    local _st; [ "$sid" = "sprint-900" ] && _st=active || _st=planned
    local _k; [ "$sid" = "sprint-900" ] && _k=E900-S1 || _k=E903-S1
    cat > "$state/sprint-status-${sid}.yaml" <<YML
sprint_id: "$sid"
status: $_st
stories:
  - key: "$_k"
    status: in-progress
YML
  done
  # Default touches: two files in prd family.
  [ -n "$touch1" ] || touch1=".gaia/artifacts/planning-artifacts/prd/a.md"
  [ -n "$touch2" ] || touch2=".gaia/artifacts/planning-artifacts/prd/b.md"
  # Create the files.
  local _tf
  for _tf in "$touch1" "$touch2"; do
    local _abs
    case "$_tf" in /*) _abs="$_tf" ;; *) _abs="$root/$_tf" ;; esac
    mkdir -p "$(dirname "$_abs")"
    touch "$_abs"
  done
  for pair in "E900-S1:E900:$touch1" "E903-S1:E903:$touch2"; do
    IFS=: read -r _k _e _f <<< "$pair"
    local _d="$impl/epic-$(printf '%s' "$_e" | tr '[:upper:]' '[:lower:]')/${_k}-test-story"
    mkdir -p "$_d"
    printf -- '---\nkey: "%s"\nepic: "%s"\nstatus: in-progress\npredicted_touch_set: ["%s"]\n---\n# Story: %s\n' "$_k" "$_e" "$_f" "$_k" > "$_d/story.md"
  done
}

# ---- Apostrophe + newline + outside-root + alias tests ----

@test "rule (d) fires with apostrophe in relative planning_artifacts value" {
  # planning_artifacts: "pl'an" (relative) — the resolver shell-escapes the
  # apostrophe. The decode must strip it for the prefix to match.
  # Two stories touch different files in the prd family so rule (c) cannot mask.
  local pdir="$TEST_DIR/.gaia/artifacts/pl'an"
  mkdir -p "$pdir/prd" "$pdir/architecture" "$pdir/epics"
  cat > "$pdir/epics-and-stories.md" <<'MD'
# Epics and Stories
## E900 — Test
## E903 — Test2
MD
  touch "$pdir/prd/a.md" "$pdir/prd/b.md"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: ".gaia/artifacts/pl'an"
test_artifacts: .gaia/artifacts/test-artifacts
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" "predicted_touch_set: [\".gaia/artifacts/pl'an/prd/a.md\"]"
  create_story_ts "E903-S1" "E903" "predicted_touch_set: [\".gaia/artifacts/pl'an/prd/b.md\"]"
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "rule (d) fires with apostrophe in relative test_artifacts value" {
  # test_artifacts: "te'st" (relative) — same decode on the test side.
  # Two stories touch different traceability-family files so rule (c) cannot mask.
  local tdir="$TEST_DIR/.gaia/artifacts/te'st"
  mkdir -p "$tdir/strategy"
  touch "$tdir/traceability-matrix.md" "$tdir/strategy/traceability-matrix.md"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: .gaia/artifacts/planning-artifacts
test_artifacts: ".gaia/artifacts/te'st"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" "predicted_touch_set: [\".gaia/artifacts/te'st/traceability-matrix.md\"]"
  create_story_ts "E903-S1" "E903" "predicted_touch_set: [\".gaia/artifacts/te'st/strategy/traceability-matrix.md\"]"
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on traceability"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}


@test "newline in root directory name refuses with malformed-line message" {
  # A newline in the root path produces a malformed line in the resolver
  # output (the value spans two lines). The check must refuse with a clear
  # message naming the bad line. The pre-fix code (6d0e07b7) gives PASS
  # exit 0 (fail-open).
  local nl_root
  nl_root="$TEST_DIR/root
broken"
  mkdir -p "$nl_root/.gaia/state" "$nl_root/.gaia/config" "$nl_root/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$nl_root/.gaia/artifacts/planning-artifacts/prd"
  mkdir -p "$nl_root/.gaia/artifacts/planning-artifacts/epics"
  mkdir -p "$nl_root/.gaia/artifacts/test-artifacts/strategy"
  mkdir -p "$nl_root/gaia-public/plugins/gaia/scripts/lib" "$nl_root/gaia-public/plugins/gaia/hooks"
  touch "$nl_root/gaia-public/plugins/gaia/scripts/sprint-state.sh"
  touch "$nl_root/gaia-public/plugins/gaia/scripts/independence-check.sh"
  touch "$nl_root/gaia-public/plugins/gaia/scripts/lib/helper.sh"
  touch "$nl_root/gaia-public/plugins/gaia/hooks/pre-commit.sh"
  cat > "$nl_root/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'MD'
# Epics and Stories
## E900 — Test
## E903 — Test2
MD
  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$nl_root/.gaia/state/.sprint-migration-complete"
  # Full config with project_root: "." — the resolver resolves it to CWD
  # which contains the newline. The --all output then has a malformed line.
  cat > "$nl_root/.gaia/config/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "."
project_path: "$nl_root/app"
memory_path: ".gaia/memory"
checkpoint_path: ".gaia/memory/checkpoints"
installed_path: "_gaia"
framework_version: 1.200.0
date: 1970-01-01
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  for sid in sprint-900 sprint-903; do
    local _st; [ "$sid" = "sprint-900" ] && _st=active || _st=planned
    local _k; [ "$sid" = "sprint-900" ] && _k=E900-S1 || _k=E903-S1
    cat > "$nl_root/.gaia/state/sprint-status-${sid}.yaml" <<YML
sprint_id: "$sid"
status: $_st
stories:
  - key: "$_k"
    status: in-progress
YML
  done
  touch "$nl_root/.gaia/artifacts/planning-artifacts/prd/a.md" "$nl_root/.gaia/artifacts/planning-artifacts/prd/b.md"
  local _d
  for pair in "E900-S1:E900:a" "E903-S1:E903:b"; do
    IFS=: read -r _k _e _f <<< "$pair"
    _d="$nl_root/.gaia/artifacts/implementation-artifacts/epic-$(printf '%s' "$_e" | tr '[:upper:]' '[:lower:]')/${_k}-test-story"
    mkdir -p "$_d"
    printf -- '---\nkey: "%s"\nepic: "%s"\nstatus: in-progress\npredicted_touch_set: [".gaia/artifacts/planning-artifacts/prd/%s.md"]\n---\n# Story: %s\n' "$_k" "$_e" "$_f" "$_k" > "$_d/story.md"
  done
  cd "$nl_root"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -ne 0 ] || { echo "expected non-zero exit, got 0"; echo "$output"; false; }
  [[ "$output" == *"FAIL indeterminate"*"malformed line"* ]] || { echo "missing malformed-line refusal"; echo "$output"; false; }
}

@test "outside-root absolute planning_artifacts warns and continues" {
  # An absolute planning_artifacts OUTSIDE the project_root must not block.
  # The check prints a WARNING and the epics file is read from the configured
  # (outside) dir. Delete the default-path epics file to prove the check
  # reads from the configured location.
  local outside_plan
  outside_plan="$(mktemp -d "$TEST_DIR/../outside-plan-XXXXXX")"
  mkdir -p "$outside_plan/prd" "$outside_plan/architecture" "$outside_plan/epics"
  cat > "$outside_plan/epics-and-stories.md" <<'MD'
# Epics and Stories
## E900 — Test
## E903 — Test2
MD
  # Remove the default-path epics file so the check must use the configured dir.
  rm -f "$PLANNING_DIR/epics-and-stories.md"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: "$outside_plan"
test_artifacts: .gaia/artifacts/test-artifacts
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["src/a.txt"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["src/b.txt"]'
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  rm -rf "$outside_plan"
  [ "$status" -eq 0 ] || { echo "expected PASS, got status=$status"; echo "$output"; false; }
  [[ "$output" == *"WARNING"*"outside"* ]] || { echo "missing outside-root WARNING"; echo "$output"; false; }
}

@test "outside-root absolute test_artifacts warns and continues" {
  local outside_test
  outside_test="$(mktemp -d "$TEST_DIR/../outside-test-XXXXXX")"
  mkdir -p "$outside_test/strategy"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: .gaia/artifacts/planning-artifacts
test_artifacts: "$outside_test"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["src/a.txt"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["src/b.txt"]'
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  rm -rf "$outside_test"
  [ "$status" -eq 0 ] || { echo "expected PASS, got status=$status"; echo "$output"; false; }
  [[ "$output" == *"WARNING"*"outside"* ]] || { echo "missing outside-root WARNING"; echo "$output"; false; }
}

@test "symlinked root with custom planning dir classifies correctly" {
  # project_root is a symlink, planning_artifacts is a CUSTOM absolute
  # physical path (not the default). The physical-path compare must resolve
  # both sides so the prefix strip matches.
  local real_root="$TEST_DIR/real-proj"
  local link_root="$TEST_DIR/link-proj"
  local custom_plan="$real_root/docs/plan"
  _make_project "$real_root" \
    "$custom_plan" \
    "$real_root/.gaia/artifacts/test-artifacts" \
    "prd" \
    "docs/plan/prd/a.md" \
    "docs/plan/prd/b.md"
  ln -s "$real_root" "$link_root"
  cat > "$real_root/.gaia/config/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$link_root"
project_path: "$link_root/app"
memory_path: "$link_root/.gaia/memory"
checkpoint_path: "$link_root/.gaia/memory/checkpoints"
installed_path: "$link_root/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: "$real_root/docs/plan"
test_artifacts: "$real_root/.gaia/artifacts/test-artifacts"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  cd "$real_root"
  run env PROJECT_ROOT="$link_root" PROJECT_PATH="$link_root" \
    IMPLEMENTATION_ARTIFACTS="$real_root/.gaia/artifacts/implementation-artifacts" \
    GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "symlinked planning dir with custom path classifies correctly" {
  # project_root points to the real dir; planning_artifacts points to a
  # SYMLINK of a custom planning dir. The physical-path compare resolves
  # the symlink so the prefix strip matches.
  local real_root="$TEST_DIR/sym-proj"
  local custom_plan="$real_root/docs/plan"
  local link_plan="$TEST_DIR/plan-link"
  _make_project "$real_root" \
    "$custom_plan" \
    "$real_root/.gaia/artifacts/test-artifacts" \
    "prd" \
    "docs/plan/prd/a.md" \
    "docs/plan/prd/b.md"
  ln -s "$custom_plan" "$link_plan"
  cat > "$real_root/.gaia/config/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$real_root"
project_path: "$real_root/app"
memory_path: "$real_root/.gaia/memory"
checkpoint_path: "$real_root/.gaia/memory/checkpoints"
installed_path: "$real_root/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: "$link_plan"
test_artifacts: "$real_root/.gaia/artifacts/test-artifacts"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  cd "$real_root"
  run env PROJECT_ROOT="$real_root" PROJECT_PATH="$real_root" \
    IMPLEMENTATION_ARTIFACTS="$real_root/.gaia/artifacts/implementation-artifacts" \
    GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "symlinked root with dot and custom plan from alias CWD classifies correctly" {
  # project_root: "."; CWD is a symlink to the real dir; planning is a
  # custom absolute path under the real dir.
  local real_root="$TEST_DIR/dot-real"
  local link_root="$TEST_DIR/dot-link"
  local custom_plan="$real_root/docs/plan"
  _make_project "$real_root" \
    "$custom_plan" \
    "$real_root/.gaia/artifacts/test-artifacts" \
    "prd" \
    "docs/plan/prd/a.md" \
    "docs/plan/prd/b.md"
  ln -s "$real_root" "$link_root"
  cat > "$real_root/.gaia/config/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "."
project_path: "app"
memory_path: ".gaia/memory"
checkpoint_path: ".gaia/memory/checkpoints"
installed_path: "_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: "$real_root/docs/plan"
test_artifacts: "$real_root/.gaia/artifacts/test-artifacts"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  cd "$link_root"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    IMPLEMENTATION_ARTIFACTS="$real_root/.gaia/artifacts/implementation-artifacts" \
    GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected FAIL rule (d), got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL rule (d): planning-artifact conflict on prd"* ]] || { echo "missing rule (d)"; echo "$output"; false; }
}

@test "non-conflicting layout with symlinked paths passes" {
  local real_root="$TEST_DIR/pass-proj"
  local link_root="$TEST_DIR/pass-link"
  local custom_plan="$real_root/docs/plan"
  _make_project "$real_root" \
    "$custom_plan" \
    "$real_root/.gaia/artifacts/test-artifacts" \
    "none" \
    "src/a.txt" \
    "src/b.txt"
  ln -s "$real_root" "$link_root"
  cat > "$real_root/.gaia/config/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$link_root"
project_path: "$link_root/app"
memory_path: "$link_root/.gaia/memory"
checkpoint_path: "$link_root/.gaia/memory/checkpoints"
installed_path: "$link_root/_gaia"
framework_version: 1.200.0
date: 1970-01-01
planning_artifacts: "$real_root/docs/plan"
test_artifacts: "$real_root/.gaia/artifacts/test-artifacts"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  cd "$real_root"
  run env PROJECT_ROOT="$link_root" PROJECT_PATH="$link_root" \
    IMPLEMENTATION_ARTIFACTS="$real_root/.gaia/artifacts/implementation-artifacts" \
    GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ] || { echo "expected PASS, got status=$status"; echo "$output"; false; }
}

@test "resolver returning non-absolute value fails closed via caller" {
  # A mock resolve-config.sh returns a non-absolute test_artifacts.
  # The non-absolute guard catches it; the caller propagates the failure.
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["src/a.txt"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["src/b.txt"]'
  local mock_scripts="$TEST_DIR/mock-scripts"
  mkdir -p "$mock_scripts"
  local real_scripts _f _bn
  real_scripts="$(cd "$(dirname "$IC_SCRIPT")" && pwd)"
  for _f in "$real_scripts"/*; do
    [ -e "$_f" ] || continue
    _bn="$(basename "$_f")"
    [ "$_bn" = "resolve-config.sh" ] && continue
    ln -sf "$_f" "$mock_scripts/$_bn"
  done
  rm -f "$mock_scripts/independence-check.sh"
  cp "$IC_SCRIPT" "$mock_scripts/independence-check.sh"
  cat > "$mock_scripts/resolve-config.sh" <<MOCK
#!/usr/bin/env bash
printf "project_root='$TEST_DIR'\nplanning_artifacts='$PLANNING_DIR'\ntest_artifacts='not_absolute'\n"
MOCK
  chmod +x "$mock_scripts/resolve-config.sh"
  cd "$TEST_DIR"
  run bash "$mock_scripts/independence-check.sh" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 1 ] || { echo "expected exit 1, got status=$status"; echo "$output"; false; }
  [[ "$output" == *"FAIL indeterminate: artifact-dir resolution failed"* ]] || { echo "missing FAIL indeterminate"; echo "$output"; false; }
}

@test "config missing required field fails closed naming the resolver" {
  # A config that lacks a required field (date) causes the resolver to
  # exit non-zero. The check must refuse, not fall back to defaults.
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
project_path: "$TEST_DIR/app"
memory_path: "$TEST_DIR/.gaia/memory"
checkpoint_path: "$TEST_DIR/.gaia/memory/checkpoints"
installed_path: "$TEST_DIR/_gaia"
framework_version: 1.200.0
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["src/a.txt"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["src/b.txt"]'
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -ne 0 ] || { echo "expected non-zero exit, got 0"; echo "$output"; false; }
  [[ "$output" == *"FAIL indeterminate"*"config resolver failed"* ]] || { echo "missing resolver-error message"; echo "$output"; false; }
}

@test "resolver error message names the exit code" {
  # Assert the exact diagnostic so the message cannot be silently removed.
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_name: "test-project"
project_root: "$TEST_DIR"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  create_sprint "sprint-900" "active" "E900-S1"
  create_sprint "sprint-903" "planned" "E903-S1"
  create_story_ts "E900-S1" "E900" 'predicted_touch_set: ["src/a.txt"]'
  create_story_ts "E903-S1" "E903" 'predicted_touch_set: ["src/b.txt"]'
  cd "$TEST_DIR"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -ne 0 ] || { echo "expected non-zero, got 0"; echo "$output"; false; }
  [[ "$output" == *"config resolver failed (exit "* ]] || { echo "missing exit-code in message"; echo "$output"; false; }
}
