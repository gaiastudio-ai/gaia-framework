#!/usr/bin/env bats
# brain-reliance-wiring.bats — coverage for wiring the workflow-entry brain
# loader into real skills, the single-source-of-truth (SSOT) property shared by
# the loader and the brain-blind CI gate, the end-to-end entry behaviour, and
# the reliance-map tamper-evidence controls.
#
# Surfaces under test:
#   scripts/brain/brain-reliance-loader.sh         — the runtime loader (S1)
#   scripts/audit-skill-brain-load.sh              — the brain-blind CI gate (S2)
#   scripts/brain/validate-reliance-map.sh         — the map structural validator
#   skills/<consultation-required>/SKILL.md        — the wired loader lines
#   schemas/brain-reliance-map.schema.json         — the closed-enum schema
#
# SSOT is the load-bearing invariant: one obligation flip in ONE reliance map
# must reflect in BOTH the loader and the CI gate in the same run — proving the
# two enforcers read the SAME stage->node source with no second source able to
# drift. The loader reacts to the obligation (HALT vs warn); the gate reacts to
# the stage scope; both derive from the identical map file.
#
# Each test builds an isolated per-test tree. Paths derive from
# $BATS_TEST_DIRNAME so the suite is portable from both the source layout and
# the flattened plugin cache.

load 'test_helper.bash'

setup() {
  common_setup
  LOADER="$SCRIPTS_DIR/brain/brain-reliance-loader.sh"
  AUDIT="$SCRIPTS_DIR/audit-skill-brain-load.sh"
  VALIDATE_MAP="$SCRIPTS_DIR/brain/validate-reliance-map.sh"
  VALIDATOR="$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  SCHEMAS_DIR="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)"
  SCHEMA="$SCHEMAS_DIR/brain-reliance-map.schema.json"
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

  PROJ="$TEST_TMP/proj"
  KNOW="$PROJ/.gaia/knowledge"
  mkdir -p "$KNOW"
  export CLAUDE_PROJECT_ROOT="$PROJ"

  INDEX="$KNOW/brain-index.yaml"
  MAP="$KNOW/brain-reliance-map.yaml"

  # A minimal cleanly-parseable brain index carrying ONE known node. The
  # consultation node the fixtures rely on is deliberately ABSENT so a MANDATORY
  # reliance on it is a clean HALT and an OPTIONAL reliance is a clean warn.
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
EOF
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

_has_backend() {
  if command -v ajv >/dev/null 2>&1; then return 0; fi
  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import jsonschema' >/dev/null 2>&1 \
     && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Write a single-stage map for skill:stage relying on an ABSENT node with the
# given obligation, into the canonical knowledge path $MAP.
_write_map() {
  local stage="$1" node="$2" obligation="$3"
  cat > "$MAP" <<EOF
stages:
  "$stage":
    requires:
      - brain_node: "$node"
        obligation: "$obligation"
EOF
}

# ---------------------------------------------------------------------------
# SSOT — one obligation flip in ONE map reflects in BOTH the loader AND the CI
# gate in the same run (no second stage->node source).
# ---------------------------------------------------------------------------

@test "one obligation flip in the single reliance map reflects in both the loader and the CI gate" {
  # A throwaway plugin tree whose single consultation-required skill is
  # brain-blind (carries no loader line). The CI gate reads the SAME $MAP the
  # loader reads, so both consumers are pinned to one file.
  local plug="$TEST_TMP/plug"
  mkdir -p "$plug/skills/demo-skill"
  cat > "$plug/skills/demo-skill/SKILL.md" <<'EOF'
---
name: demo-skill
---
## Step 1
Dispatch with no brain loader line.
EOF

  # --- Pass 1: MANDATORY ---
  _write_map "demo-skill:entry" "absent-node" "MANDATORY"

  # Loader: cleanly-missing MANDATORY -> HALT (non-zero).
  run bash "$LOADER" "demo-skill:entry"
  [ "$status" -ne 0 ]
  # Gate: the brain-blind skill named in the SAME map is flagged (exit 1).
  run bash "$AUDIT" --plugin "$plug" --map "$MAP"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'demo-skill'

  # --- Flip the obligation in the SAME single map file: MANDATORY -> OPTIONAL ---
  _write_map "demo-skill:entry" "absent-node" "OPTIONAL"

  # Loader now warns-and-continues on the same absent node (exit 0) — the flip
  # is observed by the loader from the one map.
  run bash "$LOADER" "demo-skill:entry"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'optional|warn'
  # Gate still derives its scope from the SAME map (stage still declared), so it
  # still flags the brain-blind skill — proving it reads the identical file.
  run bash "$AUDIT" --plugin "$plug" --map "$MAP"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'demo-skill'
}

@test "the loader and the CI gate default to the SAME canonical reliance-map path" {
  # Neither consumer is given an explicit map: both must resolve the identical
  # default path from the knowledge root, which is the SSOT guarantee at the
  # path-resolution layer. The loader source and the gate source both reference
  # the same default file name under the knowledge dir.
  grep -q 'brain-reliance-map.yaml' "$LOADER"
  grep -q 'brain-reliance-map.yaml' "$AUDIT"
  grep -q 'GAIA_KNOWLEDGE_DIR' "$LOADER"
  grep -q 'GAIA_KNOWLEDGE_DIR' "$AUDIT"
}

# ---------------------------------------------------------------------------
# AC-INT1 — end-to-end: a consultation-required workflow HALTs at entry on a
# cleanly-missing MANDATORY node and proceeds on a satisfied / optional map.
# ---------------------------------------------------------------------------

@test "end-to-end: entry HALTs on a cleanly-missing MANDATORY node" {
  _write_map "gaia-create-arch:discover-inputs" "absent-governing-node" "MANDATORY"
  run bash "$LOADER" "gaia-create-arch:discover-inputs"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'absent-governing-node'
  printf '%s\n' "$output" | grep -q 'gaia-create-arch:discover-inputs'
}

@test "end-to-end: entry proceeds when the MANDATORY node is present" {
  _write_map "gaia-create-arch:discover-inputs" "present-node" "MANDATORY"
  run bash "$LOADER" "gaia-create-arch:discover-inputs"
  [ "$status" -eq 0 ]
}

@test "end-to-end: entry proceeds when the missing node is OPTIONAL" {
  _write_map "gaia-create-arch:discover-inputs" "absent-governing-node" "OPTIONAL"
  run bash "$LOADER" "gaia-create-arch:discover-inputs"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'optional|warn'
}

# ---------------------------------------------------------------------------
# Tamper-evidence — closed-enum schema rejection + structural validator.
# ---------------------------------------------------------------------------

@test "a reliance-map with an out-of-enum obligation is rejected by the schema" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  _write_map "gaia-create-arch:discover-inputs" "present-node" "REQUIRED"
  run bash "$VALIDATOR" "$SCHEMA" "$MAP"
  [ "$status" -eq 1 ]
}

@test "a well-formed reliance-map validates against the schema" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  _write_map "gaia-create-arch:discover-inputs" "present-node" "MANDATORY"
  run bash "$VALIDATOR" "$SCHEMA" "$MAP"
  [ "$status" -eq 0 ]
}

@test "the obligation enum is locked at exactly MANDATORY and OPTIONAL (backend-independent)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run python3 - "$SCHEMA" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
item = s["properties"]["stages"]["additionalProperties"]["properties"]["requires"]["items"]
assert item["properties"]["obligation"]["enum"] == ["MANDATORY", "OPTIONAL"]
assert item.get("additionalProperties") is False
print("OK")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "the reliance-map structural validator accepts a well-formed map" {
  [ -f "$VALIDATE_MAP" ]
  [ -x "$VALIDATE_MAP" ]
  _write_map "gaia-create-arch:discover-inputs" "present-node" "MANDATORY"
  run bash "$VALIDATE_MAP" "$MAP"
  # 0 (validated) or 3 (no backend on host) are both acceptable passes; a
  # structural finding (1) or usage error (2) is a failure.
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}

@test "the reliance-map structural validator rejects an out-of-enum obligation when a backend is present" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  _write_map "gaia-create-arch:discover-inputs" "present-node" "REQUIRED"
  run bash "$VALIDATE_MAP" "$MAP"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Wiring — every skill declared in the SHIPPED reliance-map seed (the source of
# truth) must carry the loader line at its entry. SSOT: the same map drives both
# the wiring assertion below and the runtime/CI consumers above.
#
# These assertions read the COMMITTED seed map under the project root only when
# present; the canonical product invariant is that whatever skills the active
# map names also carry the loader line, which the CI brain-blind gate already
# enforces. Here we additionally pin the three skills this story wires so a
# silent un-wiring turns the gate red even off the runtime map.
# ---------------------------------------------------------------------------

@test "each story-wired skill carries the brain-reliance-loader line at its entry" {
  local s
  for s in gaia-create-arch gaia-create-epics gaia-create-prd; do
    local f="$SKILLS_DIR/$s/SKILL.md"
    [ -f "$f" ]
    grep -q 'brain-reliance-loader.sh' "$f"
  done
}

@test "each story-wired loader line uses the plugin-root substrate var, not PLUGIN_DIR" {
  local s
  for s in gaia-create-arch gaia-create-epics gaia-create-prd; do
    local f="$SKILLS_DIR/$s/SKILL.md"
    grep -q 'CLAUDE_PLUGIN_ROOT.*brain-reliance-loader.sh' "$f"
    ! grep -qE 'PLUGIN_DIR.*brain-reliance-loader.sh' "$f"
  done
}

@test "the brain-blind CI gate passes against the wired skills with the seed map" {
  # Build a map naming exactly the three wired skills' entry stages and run the
  # gate against the real plugin skills tree. Because the skills now carry the
  # loader line, no GAP is emitted (exit 0).
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
  local plug
  plug="$(cd "$SKILLS_DIR/.." && pwd)"
  run bash "$AUDIT" --plugin "$plug" --map "$MAP"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'GAP'
}
