#!/usr/bin/env bats
# dev-story-tdd-review-config.bats — bats coverage for E57-S1
#
# Story: E57-S1 — dev_story.tdd_review schema + config plumbing + migration note
#
# Acceptance Criteria covered:
#   AC1 — fresh project, no override → resolve-config.sh --field
#         dev_story.tdd_review.threshold returns "medium"            (TC-TDR-01)
#   AC2 — override threshold: high → returns "high"                  (TC-TDR-01)
#   AC3 — invalid threshold value → schema validation fails fast,
#         naming the offending key and the allowed enum values
#   AC4 — schema's dev_story.tdd_review.phases default is [red] and
#         the field type is array
#   AC5 — gaia-public/CHANGELOG.md contains the
#         "v1.131.x — TDD Review Gate Default" migration entry
#         naming threshold: medium, phases: [red], the user-visible
#         effect, and the threshold: off opt-out
#
# All tests author per-test fixtures under $TEST_TMP — never mutate the
# committed config or schema files.

load 'test_helper.bash'

setup() {
  common_setup
  RESOLVE="$SCRIPTS_DIR/resolve-config.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CHANGELOG="$REPO_ROOT/CHANGELOG.md"
  REAL_SCHEMA="$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml"

  # Per-test fixture dir.
  cd "$TEST_TMP"
  mkdir -p config

  # Minimal valid project-config.yaml + schema. The schema is copied from
  # the committed surface so enum / unknown-key validation matches prod.
  cp "$REAL_SCHEMA" "$TEST_TMP/config/project-config.schema.yaml"

  cat > "$TEST_TMP/config/project-config.yaml" <<'EOF'
project_root: /tmp/test-root
project_path: /tmp/test-root/app
memory_path: /tmp/test-root/_memory
checkpoint_path: /tmp/test-root/_memory/checkpoints
installed_path: /tmp/test-root/_gaia
framework_version: 1.131.0
date: 2026-04-28
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — default value when nothing is set in user config.
# ---------------------------------------------------------------------------

@test "AC1: default dev_story.tdd_review.threshold is 'medium'" {
  run "$RESOLVE" --shared "$TEST_TMP/config/project-config.yaml" \
                 --field dev_story.tdd_review.threshold
  [ "$status" -eq 0 ]
  [ "$output" = "medium" ]
}

# ---------------------------------------------------------------------------
# AC2 — user override via threshold: high in the shared config.
# ---------------------------------------------------------------------------

@test "AC2: user override threshold: high resolves to 'high'" {
  cat >> "$TEST_TMP/config/project-config.yaml" <<'EOF'
dev_story:
  tdd_review:
    threshold: high
EOF
  run "$RESOLVE" --shared "$TEST_TMP/config/project-config.yaml" \
                 --field dev_story.tdd_review.threshold
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

# ---------------------------------------------------------------------------
# AC3 — invalid threshold value rejected with exit 2 + message naming
# the offending key and allowed enum values.
# ---------------------------------------------------------------------------

@test "AC3: invalid threshold value fails fast (exit 2)" {
  cat >> "$TEST_TMP/config/project-config.yaml" <<'EOF'
dev_story:
  tdd_review:
    threshold: invalid-value
EOF
  run "$RESOLVE" --shared "$TEST_TMP/config/project-config.yaml" \
                 --field dev_story.tdd_review.threshold
  [ "$status" -eq 2 ]
  # bats merges stderr into $output by default; assert the message names
  # the offending key and lists the allowed enum values.
  [[ "$output" == *"dev_story.tdd_review.threshold"* ]]
  [[ "$output" == *"off"* ]]
  [[ "$output" == *"low"* ]]
  [[ "$output" == *"medium"* ]]
  [[ "$output" == *"high"* ]]
}

# ---------------------------------------------------------------------------
# AC3 (also covers other defaults): qa_auto_in_yolo / qa_timeout_seconds /
# phases default round-trip.
# ---------------------------------------------------------------------------

@test "AC1: default qa_auto_in_yolo is 'true'" {
  run "$RESOLVE" --shared "$TEST_TMP/config/project-config.yaml" \
                 --field dev_story.tdd_review.qa_auto_in_yolo
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "AC1: default qa_timeout_seconds is '600'" {
  run "$RESOLVE" --shared "$TEST_TMP/config/project-config.yaml" \
                 --field dev_story.tdd_review.qa_timeout_seconds
  [ "$status" -eq 0 ]
  [ "$output" = "600" ]
}

@test "AC1: default phases is '[red]'" {
  run "$RESOLVE" --shared "$TEST_TMP/config/project-config.yaml" \
                 --field dev_story.tdd_review.phases
  [ "$status" -eq 0 ]
  [ "$output" = "[red]" ]
}

# ---------------------------------------------------------------------------
# AC4 — schema declares phases default = [red] and type = array.
# ---------------------------------------------------------------------------

@test "AC4: schema declares dev_story.tdd_review.phases default [red] / type array" {
  # The committed schema is descriptor-based (each top-level field has a
  # type/required/default/description block). The dev_story descriptor
  # documents the four nested keys inline; AC4 inspects the schema for
  # the literal phases default ([red]) and the explicit array type.
  grep -F "dev_story:" "$REAL_SCHEMA"
  grep -F "tdd_review" "$REAL_SCHEMA"
  grep -F "[red]" "$REAL_SCHEMA"
  grep -F "type=array" "$REAL_SCHEMA"
}

# ---------------------------------------------------------------------------
# AC5 — CHANGELOG migration entry present and complete.
# ---------------------------------------------------------------------------

@test "AC5: CHANGELOG contains v1.131.x TDD Review Gate Default entry" {
  [ -f "$CHANGELOG" ]
  grep -F "v1.131.x — TDD Review Gate Default" "$CHANGELOG"
  grep -F "threshold: medium" "$CHANGELOG"
  grep -F "phases: [red]" "$CHANGELOG"
  grep -F "threshold: off" "$CHANGELOG"
}
