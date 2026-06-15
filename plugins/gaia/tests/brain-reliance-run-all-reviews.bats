#!/usr/bin/env bats
# brain-reliance-run-all-reviews.bats — coverage for the brain-consultation
# wiring into gaia-run-all-reviews. The run-all-reviews stage uses a templated
# MANDATORY node (the bare ${STORY_KEY} placeholder) that the loader
# interpolates per-review to the story under review's bare key, matching the
# brain index's bare-story-key shape.
#
# Surfaces under test:
#   scripts/brain/brain-reliance-loader.sh  — the runtime loader + interpolation
#   scripts/audit-skill-brain-load.sh       — the brain-blind CI gate
#   skills/gaia-run-all-reviews/SKILL.md    — the wired loader line
#
# Test families:
#   1. Three-way contract (HALT / warn-continue / fail-OPEN) for the
#      gaia-run-all-reviews:review-entry stage.
#   2. ${STORY_KEY} interpolation resolves the per-story node for a present key.
#   3. No-regression pin: placeholder-free stages are byte-identical no-ops
#      (the three existing planning stages are unaffected by interpolation).
#   4. Wiring assertions: the SKILL.md carries the loader line at entry, uses
#      CLAUDE_PLUGIN_ROOT, and the audit gate passes.

load 'test_helper.bash'

setup() {
  common_setup
  LOADER="$SCRIPTS_DIR/brain/brain-reliance-loader.sh"
  AUDIT="$SCRIPTS_DIR/audit-skill-brain-load.sh"
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

  PROJ="$TEST_TMP/proj"
  KNOW="$PROJ/.gaia/knowledge"
  mkdir -p "$KNOW"
  export CLAUDE_PROJECT_ROOT="$PROJ"

  INDEX="$KNOW/brain-index.yaml"
  MAP="$KNOW/brain-reliance-map.yaml"

  # A brain index carrying two entries: a path-shaped planning node (for the
  # existing stages) and a bare story key (for the interpolated node).
  cat > "$INDEX" <<'EOF'
schema_version: 1
entries:
  - key: "present-node"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/architecture/present-node.md"
    tags: ["architecture"]
    synopsis: "A node that is present in the index."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
  - key: "E99-S1"
    source_type: "story"
    path: ".gaia/artifacts/implementation-artifacts/epic-E99/E99-S1-demo/story.md"
    tags: ["story"]
    synopsis: "A test story entry for interpolation tests."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "1111111111111111111111111111111111111111111111111111111111111111"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# Write a reliance map with the review-entry stage carrying a templated
# MANDATORY node and two OPTIONAL nodes.
_write_review_entry_map() {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-run-all-reviews:review-entry":
    requires:
      - brain_node: "${STORY_KEY}"
        obligation: MANDATORY
      - brain_node: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions"
        obligation: OPTIONAL
      - brain_node: ".gaia/artifacts/test-artifacts/strategy/test-strategy"
        obligation: OPTIONAL
EOF
}

# Write a map with a single MANDATORY templated node only.
_write_review_entry_mandatory_only() {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-run-all-reviews:review-entry":
    requires:
      - brain_node: "${STORY_KEY}"
        obligation: MANDATORY
EOF
}

# ---------------------------------------------------------------------------
# Family 1: Three-way contract for the review-entry stage
# ---------------------------------------------------------------------------

@test "review-entry: HALT on cleanly-missing MANDATORY story-key node (story not in index)" {
  # E99-S99 is NOT in the index — the MANDATORY ${STORY_KEY} interpolates to
  # E99-S99 and is cleanly absent -> HALT.
  _write_review_entry_mandatory_only
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S99"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'E99-S99'
  printf '%s\n' "$output" | grep -q 'gaia-run-all-reviews:review-entry'
}

@test "review-entry: MANDATORY story-key node present -> pass (exit 0)" {
  # E99-S1 IS in the index — the MANDATORY ${STORY_KEY} interpolates to
  # E99-S1 and is present -> pass.
  _write_review_entry_mandatory_only
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S1"
  [ "$status" -eq 0 ]
}

@test "review-entry: warn-continue on missing OPTIONAL nodes (exit 0)" {
  # The two OPTIONAL architecture/test-plan nodes are absent from the fixture
  # index -> WARNING, not HALT. The MANDATORY story key resolves to E99-S1
  # which IS present, so only the optionals are missing.
  _write_review_entry_map
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'optional|warn'
}

@test "review-entry: fail-OPEN on malformed reliance-map" {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-run-all-reviews:review-entry":
    requires:
      - brain_node: "${STORY_KEY}
        obligation: MANDATORY : : [ broken
   bad-indent: }{
EOF
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|malformed'
}

@test "review-entry: fail-OPEN on absent brain-index" {
  _write_review_entry_mandatory_only
  rm -f "$INDEX"
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|index'
}

@test "review-entry: fail-OPEN on corrupt brain-index" {
  _write_review_entry_mandatory_only
  cat > "$INDEX" <<'EOF'
this is: not a [valid brain index
  entries: "
    - broken
EOF
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|index'
}

@test "review-entry: fail-OPEN on unknown stage id" {
  _write_review_entry_mandatory_only
  run bash "$LOADER" "gaia-run-all-reviews:never-declared" --story-key "E99-S1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|unknown stage|not.*map|warn'
}

# ---------------------------------------------------------------------------
# Family 2: ${STORY_KEY} interpolation
# ---------------------------------------------------------------------------

@test "interpolation: \${STORY_KEY} resolves to the per-story bare key for a present node" {
  _write_review_entry_mandatory_only
  # E99-S1 is in the index; ${STORY_KEY} must interpolate to "E99-S1" -> pass.
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S1"
  [ "$status" -eq 0 ]
}

@test "interpolation: \${STORY_KEY} resolves to the per-story bare key for an absent node" {
  _write_review_entry_mandatory_only
  # E99-S99 is NOT in the index; ${STORY_KEY} must interpolate to "E99-S99"
  # and HALT naming "E99-S99" (the interpolated value, not the template).
  run bash "$LOADER" "gaia-run-all-reviews:review-entry" --story-key "E99-S99"
  [ "$status" -ne 0 ]
  # The HALT diagnostic must name the INTERPOLATED key, not the raw template.
  printf '%s\n' "$output" | grep -q 'E99-S99'
  # Must NOT contain the raw template literal.
  ! printf '%s\n' "$output" | grep -qF '${STORY_KEY}'
}

@test "interpolation: without --story-key, a templated node is resolved as the literal placeholder" {
  # When no --story-key is passed, the raw "${STORY_KEY}" is looked up as-is
  # in the index (where it is absent) -> HALT. This tests the no-arg guard.
  _write_review_entry_mandatory_only
  run bash "$LOADER" "gaia-run-all-reviews:review-entry"
  # Should HALT because "${STORY_KEY}" literal is not in the index.
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Family 3: No-regression pin — placeholder-free stages are byte-identical
# ---------------------------------------------------------------------------

@test "no-regression: a stage with no \${STORY_KEY} placeholder is unaffected by --story-key" {
  # A stage with a static brain_node. Passing --story-key must NOT alter
  # resolution for stages that have no placeholder. The existing 3 planning
  # stages use static nodes; this test pins that property.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-create-arch:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
EOF
  # With --story-key: the static "present-node" is unchanged -> pass.
  run bash "$LOADER" "gaia-create-arch:discover-inputs" --story-key "E99-S1"
  [ "$status" -eq 0 ]
  # Without --story-key: identical result -> pass.
  run bash "$LOADER" "gaia-create-arch:discover-inputs"
  [ "$status" -eq 0 ]
}

@test "no-regression: existing three planning stages produce identical exit codes with and without --story-key" {
  # Write a map with all three existing stages, all MANDATORY on present-node.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-create-arch:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-create-epics:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-create-prd:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
EOF
  local stage
  for stage in \
    "gaia-create-arch:discover-inputs" \
    "gaia-create-epics:discover-inputs" \
    "gaia-create-prd:discover-inputs"; do
    run bash "$LOADER" "$stage"
    [ "$status" -eq 0 ]
    run bash "$LOADER" "$stage" --story-key "E99-S1"
    [ "$status" -eq 0 ]
  done
}

# ---------------------------------------------------------------------------
# Family 4: Wiring assertions — SKILL.md + audit gate
# ---------------------------------------------------------------------------

@test "wiring: gaia-run-all-reviews SKILL.md carries the brain-reliance-loader line" {
  local f="$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  [ -f "$f" ]
  grep -q 'brain-reliance-loader.sh' "$f"
}

@test "wiring: the loader line uses CLAUDE_PLUGIN_ROOT, not PLUGIN_DIR" {
  local f="$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  grep -q 'CLAUDE_PLUGIN_ROOT.*brain-reliance-loader.sh' "$f"
  ! grep -qE 'PLUGIN_DIR.*brain-reliance-loader.sh' "$f"
}

@test "wiring: the loader line passes the review-entry stage composite key" {
  local f="$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  grep -q 'gaia-run-all-reviews:review-entry' "$f"
}

@test "wiring: the brain-blind CI gate passes with the review-entry stage wired" {
  # Build a map naming gaia-run-all-reviews plus the three existing wired
  # skills. The audit gate should find zero gaps.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-create-arch:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-create-epics:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-create-prd:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-run-all-reviews:review-entry":
    requires:
      - brain_node: "${STORY_KEY}"
        obligation: MANDATORY
EOF
  local plug
  plug="$(cd "$SKILLS_DIR/.." && pwd)"
  run bash "$AUDIT" --plugin "$plug" --map "$MAP"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'GAP'
}

@test "wiring: the three existing wired skills still pass the audit alongside the new stage" {
  # Ensure the new stage doesn't disturb the existing three.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-create-arch:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-create-epics:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-create-prd:discover-inputs":
    requires:
      - brain_node: "present-node"
        obligation: MANDATORY
  "gaia-run-all-reviews:review-entry":
    requires:
      - brain_node: "${STORY_KEY}"
        obligation: MANDATORY
EOF
  local plug
  plug="$(cd "$SKILLS_DIR/.." && pwd)"
  run bash "$AUDIT" --plugin "$plug" --map "$MAP"
  [ "$status" -eq 0 ]
}
