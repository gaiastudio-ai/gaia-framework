#!/usr/bin/env bats
# resolve-config-backward-compat.bats — E68-S1 backward-compatibility regression
#
# Verifies that the eleven new top-level sections introduced by E68-S1 do not
# regress any existing resolver caller. Tests the legacy emit surface, the
# existing --field lookups (dev_story.tdd_review.*), the sizing_map positional
# query, and artifact-path positional queries.

load 'test_helper.bash'

setup() { common_setup; SCRIPT="$SCRIPTS_DIR/resolve-config.sh"; }
teardown() { common_teardown; }

mk_required_fields() {
  cat <<'YAML'
project_root: /tmp/gaia-e68-bc
project_path: /tmp/gaia-e68-bc/app
memory_path: /tmp/gaia-e68-bc/_memory
checkpoint_path: /tmp/gaia-e68-bc/_memory/checkpoints
installed_path: /tmp/gaia-e68-bc/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
YAML
}

mk_shared_legacy_only() {
  # No new sections, only legacy keys. Verifies the existing emit surface
  # is unchanged byte-for-byte.
  local dir="$1"
  mkdir -p "$dir/config"
  mk_required_fields > "$dir/config/project-config.yaml"
}

mk_shared_legacy_plus_new() {
  # Both legacy keys AND new sections — verifies new sections do not displace
  # or rename any existing key.
  local dir="$1"
  mkdir -p "$dir/config"
  {
    mk_required_fields
    cat <<'YAML'
sizing_map:
  S: 2
  M: 5
  L: 8
  XL: 13
dev_story:
  tdd_review:
    threshold: high
compliance:
  regimes: [gdpr]
tools:
  sast:
    provider: semgrep
YAML
  } > "$dir/config/project-config.yaml"
}

# ---------------------------------------------------------------------------
# Legacy emit surface preserved (no new keys present)
# ---------------------------------------------------------------------------

@test "E68-S1 backward-compat: legacy default shell emit surface still works" {
  mk_shared_legacy_only "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-e68-bc'"* ]]
  [[ "$output" == *"framework_version='1.127.2-rc.1'"* ]]
  # No new-section keys when none were declared
  ! [[ "$output" == *"compliance.regimes="* ]]
  ! [[ "$output" == *"tools.sast.provider="* ]]
}

@test "E68-S1 backward-compat: legacy --format json still works" {
  mk_shared_legacy_only "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"project_root\""* ]]
  [[ "$output" == *"\"framework_version\""* ]]
}

# ---------------------------------------------------------------------------
# Existing --field lookups still work
# ---------------------------------------------------------------------------

@test "E68-S1 backward-compat: --field dev_story.tdd_review.threshold still works" {
  mk_shared_legacy_plus_new "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field dev_story.tdd_review.threshold
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "E68-S1 backward-compat: --field dev_story.tdd_review.qa_auto_in_yolo still works" {
  mk_shared_legacy_plus_new "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field dev_story.tdd_review.qa_auto_in_yolo
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# ---------------------------------------------------------------------------
# sizing_map positional query still works
# ---------------------------------------------------------------------------

@test "E68-S1 backward-compat: sizing_map positional query still works" {
  mk_shared_legacy_plus_new "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" sizing_map
  [ "$status" -eq 0 ]
  [[ "$output" == *"S=2"* ]]
  [[ "$output" == *"M=5"* ]]
  [[ "$output" == *"L=8"* ]]
  [[ "$output" == *"XL=13"* ]]
}

# ---------------------------------------------------------------------------
# Artifact-path positional queries still work
# ---------------------------------------------------------------------------

@test "E68-S1 backward-compat: planning_artifacts positional query still works" {
  mk_shared_legacy_only "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" planning_artifacts
  [ "$status" -eq 0 ]
  # The positional query still resolves; the default artifact root is the
  # canonical .gaia/artifacts/ tree (legacy docs/ only when a docs/ tree exists).
  [[ "$output" == *".gaia/artifacts/planning-artifacts"* ]]
}

# ---------------------------------------------------------------------------
# --all batch mode still works and includes existing keys
# ---------------------------------------------------------------------------

@test "E68-S1 backward-compat: --all still emits all legacy flat keys" {
  mk_shared_legacy_only "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"checkpoint_path="* ]]
  [[ "$output" == *"creative_artifacts="* ]]
  [[ "$output" == *"date="* ]]
  [[ "$output" == *"framework_version="* ]]
  [[ "$output" == *"sizing_map.L="* ]]
  [[ "$output" == *"dev_story.tdd_review.threshold="* ]]
}
