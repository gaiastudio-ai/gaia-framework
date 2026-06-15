#!/usr/bin/env bats
# brain-reliance-create-story.bats — coverage for the gaia-create-story:load-context
# brain-consultation stage: HALT on missing MANDATORY, WARN-continue on missing
# OPTIONAL, fail-OPEN on un-evaluable input, and audit-coverage (gaia-create-story
# no longer brain-blind).
#
# Mirrors the shape of brain-reliance-dev-story.bats for the create-story entry
# stage. The stage declares: epics-and-stories MANDATORY; architecture-decisions
# and prd-overview OPTIONAL.
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

  # Minimal index carrying the MANDATORY node (epics-and-stories) plus the two
  # OPTIONAL nodes (architecture-decisions, prd-overview).
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
  - key: ".gaia/artifacts/planning-artifacts/prd/01-overview"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/prd/01-overview.md"
    tags: ["prd"]
    synopsis: "PRD overview."
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

# Write the create-story:load-context stage map matching the SHIPPED reliance-map
# stanza (1 MANDATORY + 2 OPTIONAL).
_write_create_story_map() {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-create-story:load-context":
    requires:
      - brain_node: ".gaia/artifacts/planning-artifacts/epics-and-stories"
        obligation: MANDATORY
      - brain_node: ".gaia/artifacts/planning-artifacts/architecture/02-2-architecture-decisions"
        obligation: OPTIONAL
      - brain_node: ".gaia/artifacts/planning-artifacts/prd/01-overview"
        obligation: OPTIONAL
EOF
}

# ---------------------------------------------------------------------------
# AC3 — HALT on a cleanly-missing MANDATORY node
# ---------------------------------------------------------------------------

@test "create-story:load-context HALTs when epics-and-stories MANDATORY node is absent" {
  _write_create_story_map
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
  - key: ".gaia/artifacts/planning-artifacts/prd/01-overview"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/prd/01-overview.md"
    tags: ["prd"]
    synopsis: "PRD overview."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
  run bash "$LOADER" "gaia-create-story:load-context"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'epics-and-stories'
  printf '%s\n' "$output" | grep -q 'gaia-create-story:load-context'
}

# ---------------------------------------------------------------------------
# AC4 — OPTIONAL warn-continue on missing OPTIONAL nodes
# ---------------------------------------------------------------------------

@test "create-story:load-context warns and continues when OPTIONAL architecture-decisions node is absent" {
  _write_create_story_map
  # Remove the architecture-decisions entry from the index; keep mandatory + other optional.
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
  - key: ".gaia/artifacts/planning-artifacts/prd/01-overview"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/prd/01-overview.md"
    tags: ["prd"]
    synopsis: "PRD overview."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
  run bash "$LOADER" "gaia-create-story:load-context"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'warn|optional'
}

@test "create-story:load-context warns and continues when OPTIONAL prd-overview node is absent" {
  _write_create_story_map
  # Remove the prd-overview entry from the index; keep mandatory + other optional.
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
  run bash "$LOADER" "gaia-create-story:load-context"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'warn|optional'
}

# ---------------------------------------------------------------------------
# AC5 — fail-OPEN on un-evaluable input
# ---------------------------------------------------------------------------

@test "create-story:load-context fails OPEN on malformed reliance-map" {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-create-story:load-context":
    requires:
      - brain_node: "foo
        obligation: MANDATORY  : : [ broken
   bad-indent: }{
EOF
  run bash "$LOADER" "gaia-create-story:load-context"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|skip'
}

@test "create-story:load-context fails OPEN on absent brain-index" {
  _write_create_story_map
  rm -f "$INDEX"
  run bash "$LOADER" "gaia-create-story:load-context"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|index'
}

@test "create-story:load-context fails OPEN on unknown stage id" {
  _write_create_story_map
  run bash "$LOADER" "gaia-create-story:nonexistent"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|unknown stage|not.*map|warn'
}

# ---------------------------------------------------------------------------
# Happy path — all MANDATORY + OPTIONAL present -> pass
# ---------------------------------------------------------------------------

@test "create-story:load-context passes when all MANDATORY and OPTIONAL nodes present" {
  _write_create_story_map
  run bash "$LOADER" "gaia-create-story:load-context"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC6 — audit-coverage: gaia-create-story no longer brain-blind
# ---------------------------------------------------------------------------

@test "brain-blind CI audit does NOT flag gaia-create-story with the load-context stage wired" {
  # Build a map declaring the create-story stage, then point the audit at the
  # real plugin skills tree. Because the SKILL.md now carries the loader line,
  # no GAP is emitted for gaia-create-story.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-create-story:load-context":
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
  ! echo "$output" | grep -q 'gaia-create-story'
}

# ---------------------------------------------------------------------------
# AC2 — wiring: the SKILL.md carries the loader line
# ---------------------------------------------------------------------------

@test "gaia-create-story SKILL.md carries the brain-reliance-loader line" {
  local f="$SKILLS_DIR/gaia-create-story/SKILL.md"
  [ -f "$f" ]
  grep -q 'brain-reliance-loader.sh' "$f"
}

@test "gaia-create-story loader line uses CLAUDE_PLUGIN_ROOT, not PLUGIN_DIR" {
  local f="$SKILLS_DIR/gaia-create-story/SKILL.md"
  grep -q 'CLAUDE_PLUGIN_ROOT.*brain-reliance-loader.sh' "$f"
  ! grep -qE 'PLUGIN_DIR.*brain-reliance-loader.sh' "$f"
}

@test "gaia-create-story loader line invokes the load-context stage" {
  local f="$SKILLS_DIR/gaia-create-story/SKILL.md"
  grep -q 'brain-reliance-loader.sh gaia-create-story:load-context' "$f"
}
