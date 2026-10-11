#!/usr/bin/env bats
# design-record-review-coverage.bats — tests for the record-review-coverage verb.
#
# Public functions covered: cmd_record_review_coverage.
#
# No internal identifiers in @test names.

load 'test_helper.bash'

# fail MSG — abort the current test with a diagnostic message.
fail() { printf '%s\n' "$1" >&2; return 1; }

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _create_test_record — create a v2 record via init with design-tagged roster.
_create_test_record() {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$TEST_TMP/.gaia/config"
  mkdir -p "$TEST_TMP/.gaia/state"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
compliance:
  ui_present: true
YAML
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design, ux]
---
STAKE

  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" \
    --discovered-via project-artifacts \
    --actor test
}

# _create_approved_record — create a record in approved state.
_create_approved_record() {
  _create_test_record
  # Transition: draft -> review -> approved
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor test
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-review \
    --verdict approved --reviewer stakeholder-A --kind internal --actor test
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" approve \
    --stakeholder stakeholder-A --recorded-by test
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to approved --actor test
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  DREC_SCRIPT="$SCRIPTS_DIR/design-record.sh"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA="$PLUGIN_ROOT/schemas/design-record.schema.json"

  # Run with all path vars unset so tests prove correct resolution
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  export PROJECT_ROOT="$TEST_TMP"

  STATE_DIR="$TEST_TMP/.gaia/state"
  mkdir -p "$STATE_DIR"
  RECORD="$STATE_DIR/design-record.yaml"

  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
  command -v jq >/dev/null 2>&1 || fail "jq is required but not found on PATH"
}

teardown() {
  common_teardown
}

# =========================================================================
# Public function coverage
# =========================================================================

@test "cmd_record_review_coverage is a public function in design-record.sh" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh does not exist"
  grep -qE '^cmd_record_review_coverage\(\)' "$DREC_SCRIPT" \
    || fail "cmd_record_review_coverage not found as a public function in design-record.sh"
}

# =========================================================================
# Coverage verb — value writes
# =========================================================================

@test "coverage verb writes design-system only" {
  _create_test_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system
  [ "$status" -eq 0 ] || fail "record-review-coverage failed (exit $status): $output"

  local coverage
  coverage="$(yq -o=json -I=0 '.review_coverage' "$RECORD")"
  [ "$coverage" = '["design-system"]' ] \
    || fail "expected [\"design-system\"], got: $coverage"
}

@test "coverage verb writes design-system and product-design" {
  _create_test_record
  # Set a product project so product-design coverage is valid
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor test

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system,product-design
  [ "$status" -eq 0 ] || fail "record-review-coverage failed (exit $status): $output"

  local coverage
  coverage="$(yq -o=json -I=0 '.review_coverage' "$RECORD")"
  [ "$coverage" = '["design-system","product-design"]' ] \
    || fail "expected [\"design-system\",\"product-design\"], got: $coverage"
}

# =========================================================================
# Coverage verb — rejection
# =========================================================================

@test "coverage verb rejects unknown value" {
  _create_test_record
  local sha_before
  sha_before="$(_sha256_file "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage screens
  [ "$status" -ne 0 ] || fail "should reject unknown coverage value 'screens'"

  local sha_after
  sha_after="$(_sha256_file "$RECORD")"
  [ "$sha_before" = "$sha_after" ] \
    || fail "record changed after rejected coverage write"
}

@test "coverage verb rejects product-design without design-system" {
  _create_test_record
  local sha_before
  sha_before="$(_sha256_file "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage product-design
  [ "$status" -ne 0 ] || fail "should reject product-design without design-system"

  local sha_after
  sha_after="$(_sha256_file "$RECORD")"
  [ "$sha_before" = "$sha_after" ] \
    || fail "record changed after rejected coverage write"
}

# =========================================================================
# Coverage verb — deduplication
# =========================================================================

@test "coverage verb deduplicates repeated values" {
  _create_test_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system,design-system
  [ "$status" -eq 0 ] || fail "record-review-coverage failed (exit $status): $output"

  local coverage
  coverage="$(yq -o=json -I=0 '.review_coverage' "$RECORD")"
  [ "$coverage" = '["design-system"]' ] \
    || fail "expected deduplicated [\"design-system\"], got: $coverage"
}

# =========================================================================
# Coverage verb — audit trail
# =========================================================================

@test "coverage verb appends one audit entry per call" {
  _create_test_record
  # Set a product project so product-design coverage is valid
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor test

  local count_before
  count_before="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system
  [ "$status" -eq 0 ] || fail "first call failed (exit $status): $output"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system,product-design
  [ "$status" -eq 0 ] || fail "second call failed (exit $status): $output"

  local count_after
  count_after="$(yq '.audit | length' "$RECORD")"
  local expected=$((count_before + 2))
  [ "$count_after" -eq "$expected" ] \
    || fail "expected $expected audit entries, got $count_after"

  # Both new entries must have event = review-coverage-recorded
  local event1 event2
  event1="$(yq ".audit[$((count_after - 2))].event" "$RECORD")"
  event2="$(yq ".audit[$((count_after - 1))].event" "$RECORD")"
  [ "$event1" = "review-coverage-recorded" ] \
    || fail "first audit entry event: expected review-coverage-recorded, got $event1"
  [ "$event2" = "review-coverage-recorded" ] \
    || fail "second audit entry event: expected review-coverage-recorded, got $event2"
}

@test "audit entry coverage field is a string" {
  _create_test_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system
  [ "$status" -eq 0 ] || fail "record-review-coverage failed (exit $status): $output"

  # Get the last audit entry's coverage field
  local coverage_type
  coverage_type="$(yq -o=json '.audit[-1].coverage' "$RECORD" | jq -r 'type')"
  [ "$coverage_type" = "string" ] \
    || fail "audit entry coverage field type: expected string, got $coverage_type"
}

# =========================================================================
# Schema compliance
# =========================================================================

@test "audit entry event is in schema enum" {
  [ -f "$SCHEMA" ] || fail "schema file does not exist: $SCHEMA"

  local found
  found="$(jq -r '.properties.audit.items.properties.event.enum[]' "$SCHEMA" \
    | grep -cxF 'review-coverage-recorded' || true)"
  [ "$found" -ge 1 ] \
    || fail "review-coverage-recorded is not in the schema's audit event enum"
}

@test "written record validates against schema" {
  _create_test_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system
  [ "$status" -eq 0 ] || fail "record-review-coverage failed (exit $status): $output"

  # Convert YAML record to JSON for schema validation
  local json_record="$TEST_TMP/record-for-validation.json"
  yq -o=json '.' "$RECORD" > "$json_record"

  if command -v ajv >/dev/null 2>&1; then
    run ajv validate -s "$SCHEMA" -d "$json_record" --spec=draft2020 2>&1
    [ "$status" -eq 0 ] || fail "schema validation failed (ajv): $output"
  elif command -v python3 >/dev/null 2>&1 && python3 -c "import jsonschema" 2>/dev/null; then
    run python3 -c "
import json, jsonschema, sys
with open('$json_record') as f: instance = json.load(f)
with open('$SCHEMA') as f: schema = json.load(f)
jsonschema.validate(instance, schema)
" 2>&1
    [ "$status" -eq 0 ] || fail "schema validation failed (python3+jsonschema): $output"
  else
    fail "no JSON-schema validator backend (ajv or python3+jsonschema) -- this test requires one"
  fi
}

@test "product-design-only value fails schema validation" {
  _create_test_record

  # Directly write an invalid review_coverage to the record (bypassing the verb)
  yq -i '.review_coverage = ["product-design"]' "$RECORD"

  local json_record="$TEST_TMP/record-for-validation.json"
  yq -o=json '.' "$RECORD" > "$json_record"

  local rc=0
  if command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$SCHEMA" -d "$json_record" --spec=draft2020 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
      || fail "schema should reject review_coverage=[\"product-design\"] but validation passed"
  elif command -v python3 >/dev/null 2>&1 && python3 -c "import jsonschema" 2>/dev/null; then
    python3 -c "
import json, jsonschema, sys
with open('$json_record') as f: instance = json.load(f)
with open('$SCHEMA') as f: schema = json.load(f)
try:
    jsonschema.validate(instance, schema)
    sys.exit(0)
except jsonschema.ValidationError:
    sys.exit(1)
" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
      || fail "schema should reject review_coverage=[\"product-design\"] but validation passed"
  else
    fail "no JSON-schema validator backend (ajv or python3+jsonschema) -- this test requires one"
  fi
}

# =========================================================================
# Stale-after-creation scenario
# =========================================================================

@test "stale after product-project creation then full coverage on next review" {
  _create_approved_record

  # Verify the record is approved
  local state
  state="$(yq '.design_state' "$RECORD")"
  [ "$state" = "approved" ] || fail "expected approved, got $state"

  # Set product project — should trigger stale-on-creation
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor test
  [ "$status" -eq 0 ] || fail "set-product-project failed (exit $status): $output"

  # Must be stale now
  state="$(yq '.design_state' "$RECORD")"
  [ "$state" = "stale" ] || fail "expected stale after set-product-project, got $state"

  # Now call record-review-coverage with both values (as the review would)
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" record-review-coverage \
    --coverage design-system,product-design
  [ "$status" -eq 0 ] || fail "record-review-coverage failed (exit $status): $output"

  local coverage
  coverage="$(yq -o=json -I=0 '.review_coverage' "$RECORD")"
  [ "$coverage" = '["design-system","product-design"]' ] \
    || fail "expected both coverage values after set-product-project, got: $coverage"
}


# =========================================================================
# Coverage value split is not subject to glob expansion
# =========================================================================

@test "coverage glob expansion blocked by globbing guard" {
  # Create files named like coverage values in the current directory
  local trap_dir
  trap_dir="$(mktemp -d)"
  touch "$trap_dir/design-system"
  touch "$trap_dir/product-design"

  # Prepare a minimal design record for the verb to work on
  local record_dir="$trap_dir/.gaia/state"
  mkdir -p "$record_dir"
  cat > "$record_dir/design-record.yaml" <<'YAML'
design_state: review
iteration: 1
reviews: []
approvals: []
audit: []
YAML
  mkdir -p "$trap_dir/.gaia/config"
  cat > "$trap_dir/.gaia/config/project-config.yaml" <<'YAML'
project_name: test
YAML

  # Run with --coverage "design-*" from the trap directory.
  # Before the fix, * would glob-expand to the filenames.
  run env PROJECT_ROOT="$trap_dir" \
    bash -c "cd '$trap_dir' && '$DREC_SCRIPT' record-review-coverage --coverage 'design-*'"

  # Must reject the unknown value "design-*" (not expand to filenames)
  [ "$status" -ne 0 ] || \
    fail "should reject 'design-*' as unknown coverage value (exit $status): $output"
  [[ "$output" == *'unknown coverage value'* ]] || \
    fail "expected 'unknown coverage value' diagnostic: $output"

  rm -rf "$trap_dir"
}


# =========================================================================
# Product-design coverage rejected when product_design_project is null
# =========================================================================

@test "coverage verb rejects product-design when product project is null" {
  [ -x "$DREC_SCRIPT" ] || fail "script missing: $DREC_SCRIPT"

  local record_dir
  record_dir="$(mktemp -d)"
  mkdir -p "$record_dir/.gaia/state"
  cat > "$record_dir/.gaia/state/design-record.yaml" <<'YAML'
schema_version: "2.0"
design_state: review
design_system_project:
  reference: "test-ds-ref"
  type: "design-system"
  surface: "artifact"
  discovered_via: "manual"
product_design_project: null
iteration: 1
reviews: []
approvals: []
audit: []
YAML
  mkdir -p "$record_dir/.gaia/config"
  cat > "$record_dir/.gaia/config/project-config.yaml" <<'YAML'
project_name: test
YAML

  run env PROJECT_ROOT="$record_dir" \
    "$DREC_SCRIPT" record-review-coverage --coverage "design-system,product-design"

  [ "$status" -ne 0 ] || \
    fail "should reject product-design coverage when product_design_project is null (exit $status): $output"
  [[ "$output" == *'product_design_project is null'* ]] || \
    fail "expected diagnostic about null product_design_project: $output"

  rm -rf "$record_dir"
}


# =========================================================================
# Symlinked record refused before product-project guard
# =========================================================================

@test "symlinked record refused before product-project guard" {
  [ -x "$DREC_SCRIPT" ] || fail "script missing: $DREC_SCRIPT"

  local record_dir
  record_dir="$(mktemp -d)"
  mkdir -p "$record_dir/.gaia/state"
  mkdir -p "$record_dir/.gaia/config"
  cat > "$record_dir/.gaia/config/project-config.yaml" <<'YAML'
project_name: test
YAML

  # Create a real record, then replace it with a symlink.
  local real_record="$record_dir/.gaia/state/design-record-real.yaml"
  cat > "$real_record" <<'YAML'
schema_version: "2.0"
design_state: review
design_system_project:
  reference: "test-ds-ref"
  type: "design-system"
  surface: "artifact"
  discovered_via: "manual"
product_design_project: null
iteration: 1
reviews: []
approvals: []
audit: []
YAML

  ln -sf "$real_record" "$record_dir/.gaia/state/design-record.yaml"

  run env PROJECT_ROOT="$record_dir" \
    "$DREC_SCRIPT" record-review-coverage --coverage "design-system,product-design"

  # The symlink refusal must fire before the product-project guard.
  [ "$status" -ne 0 ] || \
    fail "should refuse a symlinked record (exit $status): $output"
  [[ "$output" == *'symlink'* ]] || \
    fail "expected symlink diagnostic, not product-project guard: $output"

  rm -rf "$record_dir"
}


# =========================================================================
# Corrupt record gives a read-failure diagnostic, not "null"
# =========================================================================

@test "yq read failure in product-project guard gives its own diagnostic" {
  [ -x "$DREC_SCRIPT" ] || fail "script missing: $DREC_SCRIPT"

  # Create a valid record so schema validation passes, then place a yq
  # shim first on PATH that fails when asked for .product_design_project.
  local record_dir
  record_dir="$(mktemp -d)"
  mkdir -p "$record_dir/.gaia/state"
  cat > "$record_dir/.gaia/state/design-record.yaml" <<'YAML'
schema_version: "2.0"
design_state: review
design_system_project:
  reference: "test-ds-ref"
  type: "design-system"
  surface: "artifact"
  discovered_via: "manual"
product_design_project:
  reference: "test-pd-ref"
  type: "design"
  surface: "artifact"
  discovered_via: "manual"
iteration: 1
reviews: []
approvals: []
audit: []
review_coverage: ["design-system"]
YAML
  mkdir -p "$record_dir/.gaia/config"
  cat > "$record_dir/.gaia/config/project-config.yaml" <<'YAML'
project_name: test
YAML

  # yq shim: fail only on .product_design_project queries (the guard query),
  # pass all other invocations through to the real yq.
  local shim_dir real_yq
  shim_dir="$(mktemp -d)"
  real_yq="$(command -v yq)"
  cat > "$shim_dir/yq" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = ".product_design_project" ]; then
    exit 7
  fi
done
exec "$real_yq" "\$@"
SHIM
  chmod +x "$shim_dir/yq"

  PATH="$shim_dir:$PATH" run env PROJECT_ROOT="$record_dir" \
    "$DREC_SCRIPT" record-review-coverage --coverage "design-system,product-design"

  rm -rf "$shim_dir"

  [ "$status" -ne 0 ] || \
    fail "should fail when yq cannot read product_design_project (exit $status): $output"
  # The diagnostic must name the read failure, not say "is null".
  [[ "$output" == *'could not read product_design_project'* ]] || \
    fail "expected read-failure diagnostic, got: $output"
  [[ "$output" != *'product_design_project is null'* ]] || \
    fail "yq failure should not be reported as null: $output"

  rm -rf "$record_dir"
}
