#!/usr/bin/env bats
# brain-store-guards.bats — the two bash-side guards that JSON Schema alone
# cannot express for the brain store layer.
#
# Behaviour under test:
#   index-in-place guard (validate-brain-index.sh):
#     - A project-artifact entry whose `path` resolves INSIDE .gaia/knowledge/
#       is rejected (the Brain indexes in place, never copies).
#     - A project-artifact entry whose `path` is a canonical .gaia/artifacts/
#       location is accepted.
#   no-vector-dep audit (audit-no-vector-dep.sh):
#     - The real brain store layer carries no vector-DB / embedding / external
#       search dependency — the audit exits 0.
#     - A temp tree seeded with a vector/embedding token is detected — the audit
#       exits non-zero and names the offending match.

load 'test_helper.bash'

setup() {
  common_setup
  BRAIN_DIR="$SCRIPTS_DIR/brain"
  VALIDATE_INDEX="$BRAIN_DIR/validate-brain-index.sh"
  AUDIT="$BRAIN_DIR/audit-no-vector-dep.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-index"
  SCHEMAS_DIR="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)"
}

teardown() { common_teardown; }

# Mirrors validate-artifact-schema.sh's backend cascade. The index-in-place
# guard's structural pre-check delegates to that primitive; with no backend it
# SKIPs (exit 3) before reaching the path guard, so guard-behaviour assertions
# are backend-guarded.
_has_backend() {
  if command -v ajv >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# The path guard parses YAML to read each entry's path; it needs python3+PyYAML.
_has_yaml() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# index-in-place guard (AC2)
# ---------------------------------------------------------------------------

@test "validate-brain-index.sh exists and is executable" {
  [ -f "$VALIDATE_INDEX" ]
  [ -x "$VALIDATE_INDEX" ]
}

@test "a project-artifact path inside .gaia/knowledge is rejected" {
  if ! _has_yaml; then
    skip "no python3+PyYAML on host for the path guard"
  fi
  run bash "$VALIDATE_INDEX" "$FIX/path-inside-knowledge.yaml"
  [ "$status" -eq 1 ]
}

@test "a project-artifact path under .gaia/artifacts is accepted" {
  # Structural pre-check delegates to the schema primitive; if there is no
  # schema backend, the wrapper SKIPs (exit 3) rather than asserting acceptance.
  if ! _has_yaml; then
    skip "no python3+PyYAML on host for the path guard"
  fi
  run bash "$VALIDATE_INDEX" "$FIX/path-canonical.yaml"
  if [ "$status" -eq 3 ]; then
    skip "no JSON-schema backend; structural pre-check skipped"
  fi
  [ "$status" -eq 0 ]
}

# Regression: the guard must reject the violating path from ANY working
# directory, not just when CWD happens to be the project root.
#
# The guard compares an entry's resolved path against GAIA_KNOWLEDGE_DIR. That
# constant is derived from the paths helper's canonical root (which walks UP to
# the .gaia/ ancestor), but the entry path used to be resolved against
# `${CLAUDE_PROJECT_ROOT:-$PWD}` — no walk-up. Whenever CWD was a subdirectory
# of the project root the two roots disagreed, the under-root test was false for
# a path that genuinely IS inside the knowledge store, and the violation was
# ACCEPTED (exit 0). The original test above ran from the bats CWD and never
# exercised the divergence, so the fail-open shipped green.
@test "the index-in-place guard rejects from a non-root working directory" {
  if ! _has_yaml; then
    skip "no python3+PyYAML on host for the path guard"
  fi
  local elsewhere
  elsewhere="$(mktemp -d)"

  # Run the guard with CWD outside the project tree entirely.
  run bash -c "cd '$elsewhere' && bash '$VALIDATE_INDEX' '$FIX/path-inside-knowledge.yaml'"
  rm -rf "$elsewhere"

  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "index-in-place violation"
}

# ---------------------------------------------------------------------------
# no-vector-dep audit (AC4)
# ---------------------------------------------------------------------------

@test "audit-no-vector-dep.sh exists and is executable" {
  [ -f "$AUDIT" ]
  [ -x "$AUDIT" ]
}

@test "the real brain store layer has no vector dependency" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
}

@test "a seeded vector/embedding token is detected" {
  # Build a temp tree shaped like the brain layer, seed a forbidden token, and
  # point the audit at it via --root.
  local root="$TEST_TMP/seeded-brain"
  mkdir -p "$root/scripts/brain" "$root/schemas"
  cat > "$root/scripts/brain/leaky.sh" <<'EOF'
#!/usr/bin/env bash
# This script imports a vector database client.
import_pinecone() { :; }
EOF
  printf '{ "x": "embedding model reference" }\n' > "$root/schemas/brain-index.schema.json"
  run bash "$AUDIT" --root "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pinecone"* ]] || [[ "$output" == *"embedding"* ]]
}
