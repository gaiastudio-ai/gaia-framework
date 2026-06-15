#!/usr/bin/env bats
# brain-reliance-dev-story.bats — coverage for the gaia-dev-story:load-story
# brain-consultation stage: HALT on missing MANDATORY, WARN-continue on missing
# OPTIONAL, fail-OPEN on un-evaluable input, and audit-coverage (gaia-dev-story
# no longer brain-blind).
#
# Mirrors the shape of brain-reliance-wiring.bats (the 3 planning-skill wiring
# tests) for the dev-story entry stage.
#
# Each test builds an isolated per-test project tree and points the path helper
# at it via CLAUDE_PROJECT_ROOT. Paths derive from $BATS_TEST_DIRNAME so the
# suite is portable from both the source layout and the flattened cache.

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

  # Minimal index carrying the two MANDATORY nodes the dev-story stage relies
  # upon, plus one OPTIONAL-only node.
  cat > "$INDEX" <<'EOF'
schema_version: 1
entries:
  - key: ".gaia/artifacts/planning-artifacts/epics-and-stories"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/epics-and-stories.md"
    tags: ["planning"]
    synopsis: "Epics and stories registry."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
  - key: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions.md"
    tags: ["architecture"]
    synopsis: "Architecture decisions."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
  - key: ".gaia/artifacts/planning-artifacts/prd/07-ux-requirements"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/prd/07-ux-requirements.md"
    tags: ["prd"]
    synopsis: "UX requirements."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# Write the dev-story:load-story stage map matching the SHIPPED reliance-map
# stanza (2 MANDATORY + 1 OPTIONAL).
_write_dev_story_map() {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-dev-story:load-story":
    requires:
      - brain_node: ".gaia/artifacts/planning-artifacts/epics-and-stories"
        obligation: MANDATORY
      - brain_node: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions"
        obligation: MANDATORY
      - brain_node: ".gaia/artifacts/planning-artifacts/prd/07-ux-requirements"
        obligation: OPTIONAL
EOF
}

# ---------------------------------------------------------------------------
# AC4 — HALT on a cleanly-missing MANDATORY node
# ---------------------------------------------------------------------------

@test "dev-story:load-story HALTs when epics-and-stories MANDATORY node is absent" {
  _write_dev_story_map
  # Remove the epics-and-stories entry from the index.
  cat > "$INDEX" <<'EOF'
schema_version: 1
entries:
  - key: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions.md"
    tags: ["architecture"]
    synopsis: "Architecture decisions."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
  run bash "$LOADER" "gaia-dev-story:load-story"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'epics-and-stories'
  printf '%s\n' "$output" | grep -q 'gaia-dev-story:load-story'
}

@test "dev-story:load-story HALTs when architecture-decisions MANDATORY node is absent" {
  _write_dev_story_map
  # Remove the architecture-decisions entry from the index.
  cat > "$INDEX" <<'EOF'
schema_version: 1
entries:
  - key: ".gaia/artifacts/planning-artifacts/epics-and-stories"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/epics-and-stories.md"
    tags: ["planning"]
    synopsis: "Epics and stories registry."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
  run bash "$LOADER" "gaia-dev-story:load-story"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'architecture-decisions'
  printf '%s\n' "$output" | grep -q 'gaia-dev-story:load-story'
}

# ---------------------------------------------------------------------------
# AC5 — OPTIONAL warn-continue on missing OPTIONAL node
# ---------------------------------------------------------------------------

@test "dev-story:load-story warns and continues when OPTIONAL UX node is absent" {
  _write_dev_story_map
  # Remove the optional UX node from the index.
  cat > "$INDEX" <<'EOF'
schema_version: 1
entries:
  - key: ".gaia/artifacts/planning-artifacts/epics-and-stories"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/epics-and-stories.md"
    tags: ["planning"]
    synopsis: "Epics and stories registry."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
  - key: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions.md"
    tags: ["architecture"]
    synopsis: "Architecture decisions."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
  run bash "$LOADER" "gaia-dev-story:load-story"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'warn|optional'
}

# ---------------------------------------------------------------------------
# AC6 — fail-OPEN on un-evaluable input
# ---------------------------------------------------------------------------

@test "dev-story:load-story fails OPEN on malformed reliance-map" {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-dev-story:load-story":
    requires:
      - brain_node: "foo
        obligation: MANDATORY  : : [ broken
   bad-indent: }{
EOF
  run bash "$LOADER" "gaia-dev-story:load-story"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|skip'
}

@test "dev-story:load-story fails OPEN on absent brain-index" {
  _write_dev_story_map
  rm -f "$INDEX"
  run bash "$LOADER" "gaia-dev-story:load-story"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|index'
}

@test "dev-story:load-story fails OPEN on unknown stage id" {
  _write_dev_story_map
  run bash "$LOADER" "gaia-dev-story:nonexistent"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|unknown stage|not.*map|warn'
}

# ---------------------------------------------------------------------------
# AC1/AC2 — all MANDATORY + OPTIONAL present -> pass (happy path)
# ---------------------------------------------------------------------------

@test "dev-story:load-story passes when all MANDATORY and OPTIONAL nodes present" {
  _write_dev_story_map
  run bash "$LOADER" "gaia-dev-story:load-story"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC7 — audit-coverage: gaia-dev-story no longer brain-blind
# ---------------------------------------------------------------------------

@test "brain-blind CI audit does NOT flag gaia-dev-story with the load-story stage wired" {
  # Build a map declaring the dev-story stage, then point the audit at the
  # real plugin skills tree. Because the SKILL.md now carries the loader line,
  # no GAP is emitted for gaia-dev-story.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-dev-story:load-story":
    requires:
      - brain_node: ".gaia/artifacts/planning-artifacts/epics-and-stories"
        obligation: MANDATORY
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
  local plug
  plug="$(cd "$SKILLS_DIR/.." && pwd)"
  run bash "$AUDIT" --plugin "$plug" --map "$MAP"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'gaia-dev-story'
}

# ---------------------------------------------------------------------------
# AC1/AC3 — wiring: the SKILL.md carries the loader line
# ---------------------------------------------------------------------------

@test "gaia-dev-story SKILL.md carries the brain-reliance-loader line" {
  local f="$SKILLS_DIR/gaia-dev-story/SKILL.md"
  [ -f "$f" ]
  grep -q 'brain-reliance-loader.sh' "$f"
}

@test "gaia-dev-story loader line uses CLAUDE_PLUGIN_ROOT, not PLUGIN_DIR" {
  local f="$SKILLS_DIR/gaia-dev-story/SKILL.md"
  grep -q 'CLAUDE_PLUGIN_ROOT.*brain-reliance-loader.sh' "$f"
  ! grep -qE 'PLUGIN_DIR.*brain-reliance-loader.sh' "$f"
}

@test "gaia-dev-story loader line invokes the load-story stage" {
  local f="$SKILLS_DIR/gaia-dev-story/SKILL.md"
  grep -q 'brain-reliance-loader.sh gaia-dev-story:load-story' "$f"
}
