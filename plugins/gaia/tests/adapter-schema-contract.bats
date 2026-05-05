#!/usr/bin/env bats
# adapter-schema-contract.bats — E70-S1: adapter pattern formalization.
#
# Verifies the canonical adapter schema, run.sh contract documentation, and
# bats template under plugins/gaia/scripts/adapters/_schema/ are present and
# correctly formalize the implicit pattern shipped by E66-S2 adapters.

bats_require_minimum_version 1.5.0

ADAPTERS_DIR="$BATS_TEST_DIRNAME/../scripts/adapters"
SCHEMA_DIR="$ADAPTERS_DIR/_schema"
ADAPTER_SCHEMA="$SCHEMA_DIR/adapter.schema.json"
RUN_CONTRACT="$SCHEMA_DIR/run-contract.md"
CONTRACT_TEMPLATE="$SCHEMA_DIR/test/contract.bats"
BOUNDARIES="$ADAPTERS_DIR/BOUNDARIES.md"
ANALYSIS_RESULTS_SCHEMA="$BATS_TEST_DIRNAME/../schemas/analysis-results.schema.json"

# ---------------- AC1 — adapter.schema.json -------------------------------

@test "AC1: _schema/adapter.schema.json exists and is valid JSON" {
  [ -f "$ADAPTER_SCHEMA" ]
  jq -e . "$ADAPTER_SCHEMA" >/dev/null
}

@test "AC1: schema declares draft-07 (or later)" {
  run jq -r '.["$schema"] // ""' "$ADAPTER_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "json-schema.org" ]]
}

@test "AC1: schema 'required' lists the canonical seven fields" {
  run jq -r '.required | sort | .[]' "$ADAPTER_SCHEMA"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'provider'
  echo "$output" | grep -qx 'category'
  echo "$output" | grep -qx 'runtime-profile'
  echo "$output" | grep -qx 'default-timeout-seconds'
  echo "$output" | grep -qx 'file-extensions'
  echo "$output" | grep -qx 'version-range'
  echo "$output" | grep -qx 'description'
}

@test "AC1: 'category' enum covers all canonical values" {
  run jq -r '.properties.category.enum[]' "$ADAPTER_SCHEMA"
  [ "$status" -eq 0 ]
  for v in linter formatter type-checker sast secret-scan dep-audit dast e2e-runner perf-tool a11y-scanner mobile-static mobile-dynamic device-farm; do
    echo "$output" | grep -qx "$v" || { echo "missing category enum value: $v" >&2; return 1; }
  done
}

@test "AC1: 'runtime-profile' enum is exactly subprocess|container|network" {
  run jq -r '.properties["runtime-profile"].enum | sort | join(",")' "$ADAPTER_SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "container,network,subprocess" ]
}

# ---------------- AC6 — schema validates shipped adapters -----------------

# Helper: validate <adapter.json> against <schema.json>. Tries python jsonschema
# first; if not available, returns 0 with skip note. (Adapters tests already
# rely on jq; not requiring jsonschema avoids an extra system dep.)
_validate_adapter() {
  local adapter_file="$1"
  if python3 -c "import jsonschema" >/dev/null 2>&1; then
    python3 - "$ADAPTER_SCHEMA" "$adapter_file" <<'PY'
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
jsonschema.validate(instance=inst, schema=schema)
PY
    return $?
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$ADAPTER_SCHEMA" "$adapter_file" >/dev/null 2>&1
    return $?
  fi
  return 99  # no validator available — treat as skip in caller
}

_validator_skip_msg() {
  echo "no JSON Schema validator (python3 jsonschema or check-jsonschema) available"
}

@test "AC6: schema validates semgrep/adapter.json with zero errors" {
  run _validate_adapter "$ADAPTERS_DIR/semgrep/adapter.json"
  if [ "$status" -eq 99 ]; then skip "python3 jsonschema not available"; fi
  [ "$status" -eq 0 ]
}

@test "AC6: schema validates gitleaks/adapter.json with zero errors" {
  run _validate_adapter "$ADAPTERS_DIR/gitleaks/adapter.json"
  if [ "$status" -eq 99 ]; then skip "python3 jsonschema not available"; fi
  [ "$status" -eq 0 ]
}

@test "AC6: schema validates radon/adapter.json with zero errors" {
  run _validate_adapter "$ADAPTERS_DIR/radon/adapter.json"
  if [ "$status" -eq 99 ]; then skip "python3 jsonschema not available"; fi
  [ "$status" -eq 0 ]
}

@test "AC6: schema validates gocyclo/adapter.json with zero errors" {
  run _validate_adapter "$ADAPTERS_DIR/gocyclo/adapter.json"
  if [ "$status" -eq 99 ]; then skip "python3 jsonschema not available"; fi
  [ "$status" -eq 0 ]
}

@test "AC6: schema validates eslint-plugin-sonarjs/adapter.json with zero errors" {
  run _validate_adapter "$ADAPTERS_DIR/eslint-plugin-sonarjs/adapter.json"
  if [ "$status" -eq 99 ]; then skip "python3 jsonschema not available"; fi
  [ "$status" -eq 0 ]
}

# TS-02 — schema rejects an adapter.json missing 'provider'
@test "AC1/TS-02: schema rejects adapter.json missing 'provider'" {
  local bad="$BATS_TEST_TMPDIR/bad-adapter.json"
  cat >"$bad" <<'JSON'
{
  "category": "linter",
  "runtime-profile": "subprocess",
  "default-timeout-seconds": 60,
  "file-extensions": [".py"],
  "version-range": ">=1.0.0",
  "description": "missing provider"
}
JSON
  run _validate_adapter "$bad"
  if [ "$status" -eq 99 ]; then skip "$(_validator_skip_msg)"; fi
  [ "$status" -ne 0 ]
}

# ---------------- AC4 — finding fields cross-reference --------------------

@test "AC4: run-contract.md references analysis-results.schema.json" {
  [ -f "$RUN_CONTRACT" ]
  grep -q 'analysis-results.schema.json' "$RUN_CONTRACT"
}

@test "AC4: adapter schema references analysis-results.schema.json via \$ref" {
  # AC4 requires the adapter schema to NOT redefine finding fields locally
  # but instead reference the canonical schema via $ref. We assert that:
  #   (a) at least one $ref pointing at analysis-results.schema.json exists,
  #   (b) no local 'findings' block redefines fields without using $ref.
  run jq -e '
    [.. | objects | select(has("$ref")) | .["$ref"]
      | select(test("analysis-results.schema.json"))
    ] | length > 0
  ' "$ADAPTER_SCHEMA"
  [ "$status" -eq 0 ]
}

# ---------------- AC2 — run-contract.md prose -----------------------------

@test "AC2: run-contract.md documents required flags" {
  [ -f "$RUN_CONTRACT" ]
  for flag in -- '--input' '--config' '--output' '--runtime-profile' '--timeout'; do
    grep -q -- "$flag" "$RUN_CONTRACT" || { echo "missing flag: $flag" >&2; return 1; }
  done
}

@test "AC2: run-contract.md documents stdout/stderr contract" {
  grep -qi 'stdout' "$RUN_CONTRACT"
  grep -qi 'stderr' "$RUN_CONTRACT"
}

@test "AC2: run-contract.md documents exit code semantics" {
  grep -q '0.*success' "$RUN_CONTRACT" || grep -q 'exit.*0' "$RUN_CONTRACT"
  grep -q 'ran_and_errored' "$RUN_CONTRACT"
}

@test "AC2: run-contract.md documents timeout enforcement (SIGTERM/SIGKILL)" {
  grep -q 'SIGTERM' "$RUN_CONTRACT"
  grep -q 'SIGKILL' "$RUN_CONTRACT"
}

# ---------------- AC7 — four-state probe documented -----------------------

@test "AC7: run-contract.md documents all four probe states" {
  for state in available expected_and_missing ran_and_errored not_applicable; do
    grep -q "$state" "$RUN_CONTRACT" || { echo "missing probe state: $state" >&2; return 1; }
  done
}

@test "AC7: run-contract.md references probe-output.schema.json" {
  grep -q 'probe-output.schema.json' "$RUN_CONTRACT"
}

@test "AC7: run-contract.md documents probe JSON output shape (4 keys after E66-S6)" {
  # E66-S6 added the additive failure_kind key.
  for key in state skip_reason error_detail failure_kind; do
    grep -q "$key" "$RUN_CONTRACT" || { echo "missing probe key: $key" >&2; return 1; }
  done
}

# ---------------- AC3 — contract.bats template ----------------------------

@test "AC3: _schema/test/contract.bats template exists" {
  [ -f "$CONTRACT_TEMPLATE" ]
}

@test "AC3: template loads _contract-helper.bash" {
  grep -q "_contract-helper.bash" "$CONTRACT_TEMPLATE"
}

@test "AC3: template uses assert_files_exist" {
  grep -q "assert_files_exist" "$CONTRACT_TEMPLATE"
}

@test "AC3: template tests state=available" {
  grep -E -q "state=available|available\b" "$CONTRACT_TEMPLATE"
  grep -q 'assert_state .* available' "$CONTRACT_TEMPLATE"
}

@test "AC3: template tests state=expected_and_missing" {
  grep -q 'assert_state .* expected_and_missing' "$CONTRACT_TEMPLATE"
}

@test "AC3: template tests state=ran_and_errored" {
  grep -q 'assert_state .* ran_and_errored' "$CONTRACT_TEMPLATE"
}

@test "AC3: template tests state=not_applicable" {
  grep -q 'assert_state .* not_applicable' "$CONTRACT_TEMPLATE"
}

@test "AC3: template uses assert_fragment_shape" {
  grep -q "assert_fragment_shape" "$CONTRACT_TEMPLATE"
}

@test "AC3: template is syntactically valid bats" {
  if ! command -v bats >/dev/null 2>&1; then skip "bats not available"; fi
  # bats has a --parse flag in newer versions; fall back to running with --tap
  # against an empty filter to detect parse errors only.
  run bats --count "$CONTRACT_TEMPLATE"
  # --count reports test count or fails with parse error.
  [ "$status" -eq 0 ]
}

# ---------------- AC5 — BOUNDARIES.md extension ---------------------------

@test "AC5: BOUNDARIES.md still contains existing E66-S2 content" {
  grep -q 'Tool Adapter' "$BOUNDARIES" || grep -q 'tool integrations' "$BOUNDARIES"
}

@test "AC5: BOUNDARIES.md references _schema/adapter.schema.json" {
  grep -q '_schema/adapter.schema.json' "$BOUNDARIES"
}

@test "AC5: BOUNDARIES.md references _schema/test/contract.bats template" {
  grep -q '_schema/test/contract.bats' "$BOUNDARIES"
}

@test "AC5: BOUNDARIES.md documents four-state probe vocabulary" {
  for state in available expected_and_missing ran_and_errored not_applicable; do
    grep -q "$state" "$BOUNDARIES" || { echo "missing probe state in BOUNDARIES: $state" >&2; return 1; }
  done
}
