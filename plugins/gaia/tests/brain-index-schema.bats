#!/usr/bin/env bats
# brain-index-schema.bats — coverage for the brain-index.yaml entry schema
# (schemas/brain-index.schema.json) consumed via the shared
# scripts/lib/validate-artifact-schema.sh primitive.
#
# Behaviour under test:
#   - A valid brain-index manifest validates (exit 0).
#   - source_type is a closed enum: an unknown value is rejected (exit 1).
#   - edge type is a closed enum: an unknown value is rejected (exit 1).
#   - All seven canonical edge types validate; an eighth is rejected.
#   - The edge `type` enum in the schema is locked at exactly seven literals
#     (backend-independent grep — runs on every host).
#   - The trust block requires all five fields: a missing one is rejected.
#   - The ingested and lesson source_types are schema-reserved and validate.
#
# Schema-validation tests are backend-guarded (ajv → python3+jsonschema); they
# `skip` when neither is present, mirroring artifact-type-schemas.bats. The
# enum-count grep is backend-independent and always runs.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$SCRIPTS_DIR/lib"
  VALIDATOR="$LIB_DIR/validate-artifact-schema.sh"
  SCHEMAS_DIR="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)"
  SCHEMA="$SCHEMAS_DIR/brain-index.schema.json"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-index"
}

teardown() { common_teardown; }

# Detect whether a JSON-schema validator backend that can validate a YAML
# instance is available on this host. Mirrors the cascade inside
# validate-artifact-schema.sh: ajv first, then python3 + jsonschema. The
# python branch ALSO requires PyYAML because these suites validate a *.yaml
# manifest, and the primitive converts YAML→JSON via PyYAML before validating —
# a host with jsonschema but without PyYAML correctly SKIPs YAML instances
# (rc=3), so this guard must require PyYAML to match, otherwise the test runs
# and asserts exit 0 against a legitimate SKIP.
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

# ---------------------------------------------------------------------------
# Schema exists and is well-formed JSON (backend-independent)
# ---------------------------------------------------------------------------

@test "brain-index schema exists and is valid JSON" {
  [ -f "$SCHEMA" ]
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import json; json.load(open('$SCHEMA'))"
    [ "$status" -eq 0 ]
  else
    run head -c1 "$SCHEMA"
    [ "$output" = "{" ]
  fi
}

# ---------------------------------------------------------------------------
# Valid manifest passes
# ---------------------------------------------------------------------------

@test "a valid brain-index manifest validates" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/valid-entry.yaml"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# source_type closed enum
# ---------------------------------------------------------------------------

@test "source_type enum rejects an unknown value" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/bad-source-type.yaml"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# edge type closed enum
# ---------------------------------------------------------------------------

@test "edge type enum rejects an unknown value" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/bad-edge-type.yaml"
  [ "$status" -eq 1 ]
}

@test "all seven canonical edge types validate" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/seven-edge-types.yaml"
  [ "$status" -eq 0 ]
}

@test "edge type enum is exactly seven values; an eighth fails" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/eighth-edge-type.yaml"
  [ "$status" -eq 1 ]
}

# Backend-independent lock: the edge `type` enum carries EXACTLY seven literals.
# This runs on every host (no validator backend required). The seven canonical
# values are asserted individually so a rename or drop is caught, and the total
# count is pinned at seven so an addition is caught.
@test "edge type enum is locked at exactly seven literals in the schema" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  [ -f "$SCHEMA" ]
  # Extract the edge `type` enum array and count its string members by walking
  # the real JSON path (entries -> items -> properties -> edges -> items ->
  # properties -> type -> enum) and asserting both membership and a count of 7.
  run python3 - "$SCHEMA" <<'PYEOF'
import json, sys
schema = json.load(open(sys.argv[1]))
# Walk to entries -> items -> properties -> edges -> items -> properties -> type -> enum
entry = schema["properties"]["entries"]["items"]
edge = entry["properties"]["edges"]["items"]
enum = edge["properties"]["type"]["enum"]
expected = ["implements", "traces-to", "decomposes", "governed-by",
            "verified-by", "reviewed-in", "designs"]
assert enum == expected, "edge type enum mismatch: %r" % (enum,)
assert len(enum) == 7, "edge type enum is not exactly seven values: %d" % len(enum)
print("OK")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# Bidirectional total-count guard: count the TOTAL number of members in the edge
# `type` enum array (not just the seven known literals) and assert it equals
# exactly seven. Counting only the known seven catches a rename or drop but NOT an
# addition — an eighth literal still leaves exactly seven known ones matching. By
# counting ALL members of the array we close that gap: an eighth value makes the
# total eight and this test fails. The known-seven-present check is folded in so
# removal AND addition are both caught.
#
# When python3 is present we load the JSON and len() the enum (authoritative).
# Otherwise we fall back to a pure grep/awk pass that counts the quoted strings
# strictly inside the edge `type` enum array block, so the guard still runs (and
# still catches an addition) on a python3-less host.
@test "edge type enum has exactly seven total members; an eighth would fail" {
  [ -f "$SCHEMA" ]
  local total
  if command -v python3 >/dev/null 2>&1; then
    total="$(python3 - "$SCHEMA" <<'PYEOF'
import json, sys
schema = json.load(open(sys.argv[1]))
entry = schema["properties"]["entries"]["items"]
edge = entry["properties"]["edges"]["items"]
enum = edge["properties"]["type"]["enum"]
print(len(enum))
PYEOF
)"
  else
    # Pure grep/awk fallback. Isolate the edge `type` enum array block: the edge
    # type definition is preceded by a description naming it the closed enum of
    # edge types; the very next `"enum": [` opens its array, and the next `]`
    # closes it. Count every double-quoted string strictly inside that block. No
    # GNU-only flags, no mapfile/associative arrays — bash 3.2 / LC_ALL=C safe.
    total="$(awk '
      /Closed enum of exactly seven edge types/ { arm = 1; next }
      arm && /"enum"[[:space:]]*:[[:space:]]*\[/ { inblock = 1; arm = 0; next }
      inblock && /\]/ { exit }
      inblock {
        line = $0
        while (match(line, /"[^"]*"/)) {
          n++
          line = substr(line, RSTART + RLENGTH)
        }
      }
      END { print n + 0 }
    ' "$SCHEMA")"
  fi
  [ "$total" -eq 7 ]

  # Fold in the known-seven-present check so a rename/drop is also caught: each
  # canonical literal must still appear in the schema text.
  local lit
  for lit in implements traces-to decomposes governed-by verified-by reviewed-in designs; do
    grep -q "\"$lit\"" "$SCHEMA"
  done
}

# ---------------------------------------------------------------------------
# trust block — five required fields
# ---------------------------------------------------------------------------

@test "trust block missing a required field is rejected" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/missing-trust-field.yaml"
  [ "$status" -eq 1 ]
}

@test "trust block with all five fields present validates" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/valid-entry.yaml"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# reserved source_types validate (schema-reserved for P2)
# ---------------------------------------------------------------------------

@test "the ingested source_type is schema-reserved and validates" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/ingested-reserved.yaml"
  [ "$status" -eq 0 ]
}

@test "the lesson source_type is schema-reserved and validates" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$VALIDATOR" "$SCHEMA" "$FIX/lesson-reserved.yaml"
  [ "$status" -eq 0 ]
}
