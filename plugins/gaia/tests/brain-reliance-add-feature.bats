#!/usr/bin/env bats
# brain-reliance-add-feature.bats — coverage for the gaia-add-feature:cascade-entry
# brain-consultation stage: HALT on missing MANDATORY, WARN-continue on missing
# OPTIONAL (both nodes), fail-OPEN on un-evaluable input, audit-coverage, and
# wiring assertions (loader line present, CLAUDE_PLUGIN_ROOT, correct stage id,
# and loader-before-Val-gate ordering).
#
# Mirrors the shape of brain-reliance-create-story.bats for the add-feature
# cascade entry stage. The stage declares: epics-and-stories MANDATORY;
# prd/01-overview and traceability-matrix OPTIONAL.
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
  # OPTIONAL nodes (prd/01-overview, traceability-matrix).
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
  - key: ".gaia/artifacts/test-artifacts/strategy/traceability-matrix"
    source_type: "project-artifact"
    path: ".gaia/artifacts/test-artifacts/strategy/traceability-matrix.md"
    tags: ["test"]
    synopsis: "Traceability matrix."
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

# Write the add-feature:cascade-entry stage map matching the expected reliance-map
# stanza (1 MANDATORY + 2 OPTIONAL).
_write_add_feature_map() {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-add-feature:cascade-entry":
    requires:
      - brain_node: ".gaia/artifacts/planning-artifacts/epics-and-stories"
        obligation: MANDATORY
      - brain_node: ".gaia/artifacts/planning-artifacts/prd/01-overview"
        obligation: OPTIONAL
      - brain_node: ".gaia/artifacts/test-artifacts/strategy/traceability-matrix"
        obligation: OPTIONAL
EOF
}

# ---------------------------------------------------------------------------
# AC3 — HALT on a cleanly-missing MANDATORY node
# ---------------------------------------------------------------------------

@test "add-feature:cascade-entry HALTs when epics-and-stories MANDATORY node is absent" {
  _write_add_feature_map
  # Remove the epics-and-stories entry from the index.
  cat > "$INDEX" <<'EOF'
schema_version: 1
entries:
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
  - key: ".gaia/artifacts/test-artifacts/strategy/traceability-matrix"
    source_type: "project-artifact"
    path: ".gaia/artifacts/test-artifacts/strategy/traceability-matrix.md"
    tags: ["test"]
    synopsis: "Traceability matrix."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
  run bash "$LOADER" "gaia-add-feature:cascade-entry"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'epics-and-stories'
  printf '%s\n' "$output" | grep -q 'gaia-add-feature:cascade-entry'
}

# ---------------------------------------------------------------------------
# AC4 — OPTIONAL warn-continue on missing OPTIONAL nodes
# ---------------------------------------------------------------------------

@test "add-feature:cascade-entry warns and continues when OPTIONAL prd-overview node is absent" {
  _write_add_feature_map
  # Remove the prd-overview entry; keep mandatory + other optional.
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
  - key: ".gaia/artifacts/test-artifacts/strategy/traceability-matrix"
    source_type: "project-artifact"
    path: ".gaia/artifacts/test-artifacts/strategy/traceability-matrix.md"
    tags: ["test"]
    synopsis: "Traceability matrix."
    edges: []
    trust:
      confidence: 1.0
      content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      source_url: null
      fetched_at: null
      expires_at: null
EOF
  run bash "$LOADER" "gaia-add-feature:cascade-entry"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'warn|optional'
}

@test "add-feature:cascade-entry warns and continues when OPTIONAL traceability-matrix node is absent" {
  _write_add_feature_map
  # Remove the traceability-matrix entry; keep mandatory + other optional.
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
  run bash "$LOADER" "gaia-add-feature:cascade-entry"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'warn|optional'
}

# ---------------------------------------------------------------------------
# AC5 — fail-OPEN on un-evaluable input
# ---------------------------------------------------------------------------

@test "add-feature:cascade-entry fails OPEN on malformed reliance-map" {
  cat > "$MAP" <<'EOF'
stages:
  "gaia-add-feature:cascade-entry":
    requires:
      - brain_node: "foo
        obligation: MANDATORY  : : [ broken
   bad-indent: }{
EOF
  run bash "$LOADER" "gaia-add-feature:cascade-entry"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|skip'
}

@test "add-feature:cascade-entry fails OPEN on absent brain-index" {
  _write_add_feature_map
  rm -f "$INDEX"
  run bash "$LOADER" "gaia-add-feature:cascade-entry"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|index'
}

@test "add-feature:cascade-entry fails OPEN on unknown stage id" {
  _write_add_feature_map
  run bash "$LOADER" "gaia-add-feature:nonexistent"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|unknown stage|not.*map|warn'
}

# ---------------------------------------------------------------------------
# AC2 — Happy path: all MANDATORY + OPTIONAL present -> pass
# ---------------------------------------------------------------------------

@test "add-feature:cascade-entry passes when all MANDATORY and OPTIONAL nodes present" {
  _write_add_feature_map
  run bash "$LOADER" "gaia-add-feature:cascade-entry"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC6 — audit-coverage: gaia-add-feature no longer brain-blind
# ---------------------------------------------------------------------------

@test "brain-blind CI audit does NOT flag gaia-add-feature with the cascade-entry stage wired" {
  # Build a map declaring the add-feature stage plus the other wired stages,
  # then point the audit at the real plugin skills tree. Because the SKILL.md
  # now carries the loader line, no GAP is emitted for gaia-add-feature.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-add-feature:cascade-entry":
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
  ! echo "$output" | grep -q 'gaia-add-feature'
}

# ---------------------------------------------------------------------------
# AC2/AC3 — wiring: the SKILL.md carries the loader line
# ---------------------------------------------------------------------------

@test "gaia-add-feature SKILL.md carries the brain-reliance-loader line" {
  local f="$SKILLS_DIR/gaia-add-feature/SKILL.md"
  [ -f "$f" ]
  grep -q 'brain-reliance-loader.sh' "$f"
}

@test "gaia-add-feature loader line uses CLAUDE_PLUGIN_ROOT, not PLUGIN_DIR" {
  local f="$SKILLS_DIR/gaia-add-feature/SKILL.md"
  grep -q 'CLAUDE_PLUGIN_ROOT.*brain-reliance-loader.sh' "$f"
  ! grep -qE 'PLUGIN_DIR.*brain-reliance-loader.sh' "$f"
}

@test "gaia-add-feature loader line invokes the cascade-entry stage" {
  local f="$SKILLS_DIR/gaia-add-feature/SKILL.md"
  grep -q 'brain-reliance-loader.sh gaia-add-feature:cascade-entry' "$f"
}

# ---------------------------------------------------------------------------
# AC3 — ordering: the loader line precedes the Step 2 Val gate in SKILL.md
# ---------------------------------------------------------------------------

@test "gaia-add-feature loader line appears BEFORE the Step 2 Val gate in SKILL.md" {
  local f="$SKILLS_DIR/gaia-add-feature/SKILL.md"
  local loader_line val_gate_line
  loader_line=$(grep -n 'brain-reliance-loader.sh gaia-add-feature:cascade-entry' "$f" | head -1 | cut -d: -f1)
  val_gate_line=$(grep -n '### Step 2 -- Val Review Gate' "$f" | head -1 | cut -d: -f1)
  [ -n "$loader_line" ]
  [ -n "$val_gate_line" ]
  [ "$loader_line" -lt "$val_gate_line" ]
}

@test "gaia-add-feature loader line appears BEFORE Step 1 in SKILL.md" {
  local f="$SKILLS_DIR/gaia-add-feature/SKILL.md"
  local loader_line step1_line
  loader_line=$(grep -n 'brain-reliance-loader.sh gaia-add-feature:cascade-entry' "$f" | head -1 | cut -d: -f1)
  step1_line=$(grep -n '### Step 1 -- Capture Feature Scope' "$f" | head -1 | cut -d: -f1)
  [ -n "$loader_line" ]
  [ -n "$step1_line" ]
  [ "$loader_line" -lt "$step1_line" ]
}
