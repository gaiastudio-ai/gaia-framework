#!/usr/bin/env bats
# brain-reliance-loader.bats — coverage for the workflow-entry brain-context
# loader (scripts/brain/brain-reliance-loader.sh) and the reliance-map schema
# (schemas/brain-reliance-map.schema.json).
#
# The reliance-map is the single stage -> required-node source of truth:
#   stages["<skill>:<stage-id>"].requires -> [ {brain_node, obligation} ]
# with obligation a CLOSED enum {MANDATORY, OPTIONAL}. The loader resolves the
# entering stage's requires, looks each node up in brain-index.yaml (reusing the
# existing manifest parse idiom), and decides:
#
#   - A cleanly-evaluated, genuinely-missing MANDATORY node -> HALT (non-zero)
#     with a diagnostic naming BOTH the node and the stage.
#   - A missing OPTIONAL node -> WARNING on stderr, exit 0 (continue).
#   - An UN-EVALUABLE check (malformed map, OR absent/corrupt brain-index, OR an
#     unknown stage id not present in the map) -> warn-and-continue, exit 0
#     (fail OPEN). This asymmetry is load-bearing: the un-evaluable branch must
#     NEVER HALT, even though it targets the same input a later fail-CLOSED gate
#     will reject.
#
# Each test builds an isolated per-test project tree and points the path helper
# at it via CLAUDE_PROJECT_ROOT, so the loader runs on a fixture project and
# never touches the real .gaia/ tree. Paths derive from $BATS_TEST_DIRNAME so
# the suite is portable from both the source layout and the flattened cache.

load 'test_helper.bash'

setup() {
  common_setup
  LOADER="$SCRIPTS_DIR/brain/brain-reliance-loader.sh"
  AUDIT="$SCRIPTS_DIR/brain/audit-no-vector-dep.sh"
  VALIDATOR="$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  SCHEMAS_DIR="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)"
  SCHEMA="$SCHEMAS_DIR/brain-reliance-map.schema.json"

  PROJ="$TEST_TMP/proj"
  KNOW="$PROJ/.gaia/knowledge"
  mkdir -p "$KNOW"
  export CLAUDE_PROJECT_ROOT="$PROJ"

  INDEX="$KNOW/brain-index.yaml"
  MAP="$KNOW/brain-reliance-map.yaml"

  # A minimal, cleanly-parseable brain index carrying a single known node. The
  # loader only needs to answer "is this node key present in a cleanly-parsed
  # index" — the trust block is included to mirror the real manifest shape.
  cat > "$INDEX" <<'EOF'
schema_version: 1
entries:
  - key: "governing-decision"
    source_type: "project-artifact"
    path: ".gaia/artifacts/planning-artifacts/architecture/governing-decision.md"
    tags: ["architecture"]
    synopsis: "A governing decision that an entering stage relies upon."
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

# Detect a JSON-schema validator backend that can validate a YAML instance
# (ajv first, then python3 + jsonschema + PyYAML). Mirrors brain-index-schema.bats.
_has_backend() {
  if command -v ajv >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import jsonschema' >/dev/null 2>&1 \
     && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Write a well-formed reliance-map declaring one stage with the given single
# requirement (node + obligation).
_write_map_one() {
  local stage="$1" node="$2" obligation="$3"
  cat > "$MAP" <<EOF
stages:
  "$stage":
    requires:
      - brain_node: "$node"
        obligation: "$obligation"
EOF
}

# --- HALT on a cleanly-missing MANDATORY node ------------------------------

@test "a MANDATORY node absent from a cleanly-parsed index HALTs naming node and stage" {
  _write_map_one "gaia-dev-story:validate" "absent-decision" "MANDATORY"
  run bash "$LOADER" "gaia-dev-story:validate"
  [ "$status" -ne 0 ]
  # The diagnostic must name BOTH the missing node and the stage.
  printf '%s\n' "$output" > "$TEST_TMP/out.txt"
  grep -q 'absent-decision' "$TEST_TMP/out.txt"
  grep -q 'gaia-dev-story:validate' "$TEST_TMP/out.txt"
}

# --- OPTIONAL warn-continue ------------------------------------------------

@test "a missing OPTIONAL node warns and continues with exit 0" {
  _write_map_one "gaia-dev-story:validate" "absent-decision" "OPTIONAL"
  run bash "$LOADER" "gaia-dev-story:validate"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'warn|optional'
}

# --- fail-OPEN: malformed reliance-map -------------------------------------

@test "a malformed reliance-map fails OPEN (warn and continue, not HALT)" {
  # Deliberately broken YAML so the map cannot be parsed -> un-evaluable.
  cat > "$MAP" <<'EOF'
stages:
  "gaia-dev-story:validate":
    requires:
      - brain_node: "governing-decision
        obligation: MANDATORY  : : [ broken
   bad-indent: }{
EOF
  run bash "$LOADER" "gaia-dev-story:validate"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|skip'
}

# --- fail-OPEN: absent/corrupt brain-index ---------------------------------

@test "an absent brain-index fails OPEN (warn and continue, not HALT)" {
  _write_map_one "gaia-dev-story:validate" "governing-decision" "MANDATORY"
  rm -f "$INDEX"
  run bash "$LOADER" "gaia-dev-story:validate"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|index'
}

@test "a corrupt brain-index fails OPEN (warn and continue, not HALT)" {
  _write_map_one "gaia-dev-story:validate" "governing-decision" "MANDATORY"
  # Garble the index so it cannot be cleanly parsed into entries.
  cat > "$INDEX" <<'EOF'
this is: not a [valid brain index
  entries: "
    - broken
EOF
  run bash "$LOADER" "gaia-dev-story:validate"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|index'
}

# --- MANDATORY node present -> pass -----------------------------------------

@test "a MANDATORY node present in the index passes with exit 0" {
  _write_map_one "gaia-dev-story:validate" "governing-decision" "MANDATORY"
  run bash "$LOADER" "gaia-dev-story:validate"
  [ "$status" -eq 0 ]
}

# --- fail-OPEN: unknown stage id -------------------------------------------

@test "an unknown stage id not present in the map fails OPEN with exit 0" {
  _write_map_one "gaia-dev-story:validate" "governing-decision" "MANDATORY"
  run bash "$LOADER" "some-skill:never-declared"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|unknown stage|not.*map|warn'
}

@test "an absent reliance-map fails OPEN with exit 0" {
  rm -f "$MAP"
  run bash "$LOADER" "gaia-dev-story:validate"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'un-?evaluable|warn|map'
}

# --- the un-evaluable vs cleanly-missing distinction is explicit -----------

@test "the loader source factors un-evaluable distinctly from cleanly-missing" {
  # The fail-direction asymmetry is load-bearing and a sibling fail-CLOSED gate
  # targets the same un-evaluable input, so the branch must be named in source.
  grep -qiE 'un-?evaluable' "$LOADER"
  grep -qiE 'cleanly.?missing|cleanly.?evaluated|genuinely.?missing' "$LOADER"
}

# --- schema: closed-enum obligation ----------------------------------------

@test "a reliance-map with the documented schema validates" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  _write_map_one "gaia-dev-story:validate" "governing-decision" "MANDATORY"
  run bash "$VALIDATOR" "$SCHEMA" "$MAP"
  [ "$status" -eq 0 ]
}

@test "an obligation outside MANDATORY or OPTIONAL is rejected by the schema" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  _write_map_one "gaia-dev-story:validate" "governing-decision" "REQUIRED"
  run bash "$VALIDATOR" "$SCHEMA" "$MAP"
  [ "$status" -eq 1 ]
}

@test "the obligation enum is locked at exactly MANDATORY and OPTIONAL in the schema" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  [ -f "$SCHEMA" ]
  run python3 - "$SCHEMA" <<'PYEOF'
import json, sys
schema = json.load(open(sys.argv[1]))
stage = schema["properties"]["stages"]["additionalProperties"]
req = stage["properties"]["requires"]["items"]
enum = req["properties"]["obligation"]["enum"]
assert enum == ["MANDATORY", "OPTIONAL"], "obligation enum mismatch: %r" % (enum,)
assert req.get("additionalProperties") is False, "requires-entry must reject unknown fields"
print("OK")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# --- read-only boundary + no-vector audit ----------------------------------

@test "the loader source never references the memory tree" {
  # Read-only boundary: the loader reads only knowledge (map + index) and never
  # the agent-sidecar memory subtree.
  ! grep -qE '\.gaia/memory|GAIA_MEMORY_DIR|MEMORY_PATH' "$LOADER"
}

@test "the loader source references the knowledge root" {
  grep -qE 'GAIA_KNOWLEDGE_DIR' "$LOADER"
}

@test "the no-vector audit passes with the loader script in scope" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
}
