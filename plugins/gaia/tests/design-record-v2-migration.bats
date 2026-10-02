#!/usr/bin/env bats
# design-record-v2-migration.bats — v2 migration, cross-validation,
# set-product-project verb, EXIT traps, ds_attachment_mode, skip-questionnaire.
#
# cmd_set_product_project is named literally in test names for
# public-function coverage gate compliance.

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------

fail() { printf '%s\n' "$1" >&2; return 1; }

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
  DREC_SCRIPT="$SCRIPTS_DIR/design-record.sh"
  SCHEMA="$PLUGIN_ROOT/schemas/design-record.schema.json"
  SKIP_QR="$PLUGIN_ROOT/skills/gaia-create-ux/scripts/should-skip-questionnaire.sh"

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  export PROJECT_ROOT="$TEST_TMP"

  STATE_DIR="$TEST_TMP/.gaia/state"
  mkdir -p "$STATE_DIR"
  RECORD="$STATE_DIR/design-record.yaml"

  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# _extract_fn_body — duplicated from design-record.bats for independence
# ---------------------------------------------------------------------------

_extract_fn_body() {
  local funcname="$1" file="$2"
  local body
  body="$(awk "/^${funcname}\\(\\)/{p=1} p{print} p && /^}\$/{exit}" "$file" 2>/dev/null)"
  [ -n "$body" ] || fail "_extract_fn_body: function '$funcname' not found or empty in $file"
  printf '%s' "$body"
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _create_v1_record — create a genuine v1.0 record via init + downgrade.
# init now writes v2 records, so we call init then strip v2 fields back to v1.
# The audit chain stays valid because only top-level fields are removed.
_create_v1_record() {
  local ref="${1:-test-ds-ref}"
  local dv="${2:-project-artifacts}"
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  if [ "$dv" = "created" ]; then
    mkdir -p "$TEST_TMP/path/to"
    touch "$TEST_TMP/path/to/questionnaire.md"
    env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
      --reference "$ref" \
      --discovered-via "$dv" \
      --questionnaire-record "path/to/questionnaire.md"
  else
    env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
      --reference "$ref" \
      --discovered-via "$dv"
  fi
  # Downgrade to v1.0 — strip v2 fields
  local _rec_file="$RECORD"
  yq -i '.schema_version = "1.0"' "$_rec_file"
  yq -i 'del(.design_system_project)' "$_rec_file"
  yq -i 'del(.product_design_project)' "$_rec_file"
  yq -i 'del(.sync_mode)' "$_rec_file"
  yq -i 'del(.ds_attachment_mode)' "$_rec_file"
}

# _create_na_record — create a not-applicable record via init-not-applicable.
_create_na_record() {
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init-not-applicable --actor "setup"
}

# _advance_to_state TARGET — advance a draft record to the target state.
_advance_to_state() {
  local target="$1"
  case "$target" in
    draft) return 0 ;;
    review)
      env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
      ;;
    approved)
      env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
      env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" approve --stakeholder stakeholder-A --recorded-by "test"
      env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to approved --actor "test"
      ;;
    in-dev)
      _advance_to_state approved
      env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to in-dev --actor "test"
      ;;
  esac
}


# =========================================================================
# Migration tests — v1-to-v2 field promotion and schema upgrade
# =========================================================================

@test "migration roundtrip: v1.0 record migrates to v2.0 with populated design_system_project" {
  _create_v1_record "my-ds-ref" "project-artifacts"
  [ -f "$RECORD" ] || fail "record not created"

  # Trigger migration via a read verb that goes through _locked_mutate
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "migrator"
  [ "$status" -eq 0 ] || fail "transition (triggering migration) failed: $output"

  # Check v2 fields
  local sv dsp_ref dsp_type pdp sync
  sv="$(yq '.schema_version' "$RECORD")"
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  dsp_type="$(yq '.design_system_project.type' "$RECORD")"
  pdp="$(yq '.product_design_project' "$RECORD")"
  sync="$(yq '.sync_mode' "$RECORD")"

  [ "$sv" = "2.0" ] || fail "schema_version=$sv, expected 2.0"
  [ "$dsp_ref" = "my-ds-ref" ] || fail "design_system_project.reference=$dsp_ref"
  [ "$dsp_type" = "design-system" ] || fail "design_system_project.type=$dsp_type"
  [ "$pdp" = "null" ] || fail "product_design_project=$pdp, expected null"
  [ "$sync" = "react-components" ] || fail "sync_mode=$sync"
}

@test "migration preserves non-project fields" {
  _create_v1_record
  local pre_app pre_iter
  pre_app="$(yq '.applicability' "$RECORD")"
  pre_iter="$(yq '.iteration' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "migrator"
  [ "$status" -eq 0 ] || fail "migration-trigger failed: $output"

  local post_app post_iter
  post_app="$(yq '.applicability' "$RECORD")"
  post_iter="$(yq '.iteration' "$RECORD")"

  [ "$post_app" = "$pre_app" ] || fail "applicability changed from $pre_app to $post_app"
  [ "$post_iter" = "$pre_iter" ] || fail "iteration changed from $pre_iter to $post_iter"
  # design_state changes due to transition, not migration — that's expected
}

@test "v2 fixture with both references is not re-migrated on subsequent mutation" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "first mutation failed: $output"

  # Set product project to populate both references
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  # Record is now v2 with both refs — capture hash
  local hash
  hash="$(_sha256_file "$RECORD")"

  # Another mutation should NOT re-migrate (already v2)
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -eq 0 ] || fail "second mutation failed: $output"

  # After transition, hash changes (new audit entry), but the v2 fields should still be there
  local sv
  sv="$(yq '.schema_version' "$RECORD")"
  [ "$sv" = "2.0" ] || fail "schema_version=$sv after second mutation"

  # has("product_design_project") must be checked in its own yq call
  local has_pdp
  has_pdp="$(yq 'has("product_design_project")' "$RECORD")"
  [ "$has_pdp" = "true" ] || fail "product_design_project key lost after re-mutation"
}

@test "migration preserves special chars and rejects unknown fields via schema" {
  _create_v1_record 'ref with "quotes" and $dollar'

  # Inject an unknown top-level field
  local _rec_file="$RECORD"
  yq -i '.unknown_extra = "should-survive"' "$_rec_file"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "migration failed: $output"

  # Special chars survived
  local ref
  ref="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$ref" = 'ref with "quotes" and $dollar' ] || fail "special chars lost in migration"

  # Unknown field survived migration (migration doesn't strip unknown fields)
  local extra
  extra="$(yq '.unknown_extra' "$RECORD")"
  [ "$extra" = "should-survive" ] || fail "unknown field lost"

  # But schema validation should reject it
  if command -v ajv >/dev/null 2>&1; then
    run ajv validate -s "$SCHEMA" -d "$RECORD" --spec=draft2020 2>&1
    [ "$status" -ne 0 ] || fail "schema should reject unknown field"
  else
    # No ajv — use jq to check additionalProperties is false
    local addl
    addl="$(jq '.additionalProperties' "$SCHEMA")"
    [ "$addl" = "false" ] || fail "schema missing additionalProperties: false"
  fi
}

@test "migration writes only tmp file (static scan)" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"
  local body
  body="$(_extract_fn_body "_migrate_v1_to_v2" "$DREC_SCRIPT")" \
    || fail "_migrate_v1_to_v2 function not found — not yet implemented"
  [ -n "$body" ] || fail "_migrate_v1_to_v2 function body is empty"

  # Must reference only $1 (the tmp parameter) or "$tmp" or "$file" — never $RECORD_PATH
  if printf '%s' "$body" | grep -qE '\$RECORD_PATH|\$\{RECORD_PATH'; then
    fail "_migrate_v1_to_v2 references RECORD_PATH — must only write to the passed tmp file"
  fi
}

@test "I/O failure leaves original intact" {
  _create_v1_record
  local hash
  hash="$(_sha256_file "$RECORD")"

  # Intercept mv via a PATH shim that rejects the atomic publish rename.
  # This avoids chmod a-w (which prevents lock acquisition on some platforms).
  local shim_dir="$TEST_TMP/mv-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/mv" <<'SHIM'
#!/usr/bin/env bash
# Fail on any mv into the design-record path; pass through everything else
for arg in "$@"; do
  case "$arg" in
    *design-record.yaml) exit 1 ;;
  esac
done
exec /bin/mv "$@"
SHIM
  chmod +x "$shim_dir/mv"

  run env PATH="$shim_dir:$PATH" PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"

  [ "$status" -ne 0 ] || fail "expected failure on mv shim"
  [[ "$output" == *"atomic publish failed"* ]] || fail "expected 'atomic publish failed' diagnostic, got: $output"

  # Original unchanged
  local post_hash
  post_hash="$(_sha256_file "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record was modified despite I/O failure"
}

# bats test_tags=hardware-dependent
@test "64 KB migration completes under 200 ms (best-of-3)" {
  # Build a 64 KB v1 fixture statically — no _create_v1_record overhead.
  # One jq pass builds the bulk audit array, yq -P converts to YAML, then
  # yq eval-all merges it into a hand-written v1 skeleton.
  local v1_fixture="$RECORD"
  mkdir -p "$(dirname "$v1_fixture")"
  cat > "$v1_fixture" <<'EOF'
schema_version: "1.0"
applicability: applicable
design_state: draft
iteration: 1
project:
  reference: "ds-perf-ref"
  discovered_via: "project-artifacts"
  questionnaire_record: "skipped"
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF

  local bulk_file="$TEST_TMP/bulk-audit.yaml"
  jq -n --argjson n 200 '
    [range($n) | {
      at: "2024-01-01T00:00:00Z",
      actor: "bulk",
      event: "state-transition",
      design_state: "review",
      iteration: 1,
      _digest: ("pad-" + (. | tostring) + "-" + ("_" * 200)),
      from: "draft",
      to: "review"
    }]
  ' | yq -P '.' > "$bulk_file"
  yq eval-all -i 'select(fi == 0).audit += select(fi == 1) | select(fi == 0)' "$v1_fixture" "$bulk_file"
  local size
  size="$(wc -c < "$v1_fixture" | tr -d ' ')"
  [ "$size" -ge 60000 ] || fail "record only $size bytes, expected >= 64KB"

  # Verify the function exists when sourced
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    declare -F _migrate_v1_to_v2 >/dev/null
  ) || fail "_migrate_v1_to_v2 not available via source — function not yet implemented"

  # best-of-3 timing — source once, run all 3 attempts in a single subshell
  # so that only the _migrate_v1_to_v2 call is timed, not source overhead.
  local best
  best="$(
    (
      # shellcheck source=../scripts/design-record.sh
      _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
      _best=999999
      for _attempt in 1 2 3; do
        _tmp="$TEST_TMP/timing-attempt-$_attempt.yaml"
        cp "$v1_fixture" "$_tmp"
        _s="$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000')"
        _migrate_v1_to_v2 "$_tmp"
        _e="$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000')"
        _ms="$(( _e - _s ))"
        [ "$_ms" -lt "$_best" ] && _best="$_ms"
      done
      printf '%d\n' "$_best"
    )
  )"

  [ "$best" -lt 200 ] || fail "best-of-3 migration took ${best}ms, limit is 200ms"

  # Assert the timed copies were actually migrated — a no-op migration must fail here
  local _attempt_file _sv _dsp_ref
  for _attempt_file in "$TEST_TMP"/timing-attempt-*.yaml; do
    _sv="$(yq '.schema_version' "$_attempt_file")"
    [ "$_sv" = "2.0" ] || fail "timing copy ${_attempt_file} not migrated: schema_version=$_sv"
    _dsp_ref="$(yq '.design_system_project.reference' "$_attempt_file")"
    [ "$_dsp_ref" = "ds-perf-ref" ] || fail "timing copy not migrated: design_system_project.reference=$_dsp_ref"
  done
}

@test "chain continuity after migration: next mutation appends correctly chained entry" {
  _create_v1_record
  # Trigger migration + mutation
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Verify integrity — proves the chain is still valid after migration + new entry
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "integrity check failed after migration+mutation: $output"
}

@test "field-swap mutant detected: legacy ref must NOT map to product_design_project" {
  _create_v1_record "original-ds-ref" "project-artifacts"

  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "migration-trigger failed: $output"

  # The legacy project.reference should be in design_system_project, NOT product_design_project
  local dsp_ref pdp
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  pdp="$(yq '.product_design_project' "$RECORD")"

  [ "$dsp_ref" = "original-ds-ref" ] || fail "legacy ref not in design_system_project: $dsp_ref"
  [ "$pdp" = "null" ] || fail "product_design_project should be null after migration, got: $pdp"
}

@test "reopen-applicable on NA record: sets ds reference, product null, has ds_attachment_mode" {
  _create_na_record

  # reopen-applicable triggers migration then overwrites project fields
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "new-ref" --discovered-via "created" \
    --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen-applicable failed: $output"

  # Before reopen modifies: the migration should have set null projects
  # After reopen: design_system_project populated, product null
  local sv dsp pdp
  sv="$(yq '.schema_version' "$RECORD")"
  [ "$sv" = "2.0" ] || fail "schema_version=$sv"

  dsp="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$dsp" = "new-ref" ] || fail "design_system_project.reference=$dsp"

  pdp="$(yq '.product_design_project' "$RECORD")"
  [ "$pdp" = "null" ] || fail "product_design_project=$pdp, expected null"
}

@test "migration of sentinel+applicable: populated design_system_project" {
  _create_na_record

  # Downgrade to v1 so migration actually runs
  local _rec_file="$RECORD"
  yq -i '.schema_version = "1.0"' "$_rec_file"
  yq -i 'del(.design_system_project)' "$_rec_file"
  yq -i 'del(.product_design_project)' "$_rec_file"

  # Hand-edit to make sentinel+applicable (anomalous state from pre-v2 era)
  yq -i '.applicability = "applicable"' "$_rec_file"

  # Trigger migration via a mutation
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Applicable with sentinel ref takes the applicable branch
  local dsp_type
  dsp_type="$(yq '.design_system_project.type' "$RECORD")"
  [ "$dsp_type" = "design-system" ] || fail "expected design-system type, got $dsp_type"
}

@test "migration of real-ref+not-applicable: populated design_system_project with ds_attachment_mode" {
  _create_na_record

  # Downgrade to v1 so migration actually runs
  local _rec_file="$RECORD"
  yq -i '.schema_version = "1.0"' "$_rec_file"
  yq -i 'del(.design_system_project)' "$_rec_file"
  yq -i 'del(.product_design_project)' "$_rec_file"

  # Hand-edit: real ref but not-applicable
  _RA_REF="real-ref" yq -i '.project.reference = strenv(_RA_REF)' "$_rec_file"

  # Trigger migration
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "real-ref" --discovered-via "created" \
    --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen-applicable failed: $output"

  local dam
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode=$dam"
}

@test "schema declares design_system_project and product_design_project properties" {
  [ -f "$SCHEMA" ] || fail "schema not found"

  # The schema must declare design_system_project and product_design_project
  local has_dsp has_pdp
  has_dsp="$(jq 'has("properties") and (.properties | has("design_system_project"))' "$SCHEMA")"
  has_pdp="$(jq 'has("properties") and (.properties | has("product_design_project"))' "$SCHEMA")"
  [ "$has_dsp" = "true" ] || fail "schema missing design_system_project property"
  [ "$has_pdp" = "true" ] || fail "schema missing product_design_project property"
}

@test "review_coverage absent after migration" {
  _create_v1_record
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # has() in its own invocation
  local has_rc
  has_rc="$(yq 'has("review_coverage")' "$RECORD")"
  [ "$has_rc" = "false" ] || fail "review_coverage should be absent after migration"
}


# =========================================================================
# Cross-validation — consistency between sub-documents
# =========================================================================

@test "schema downgrade rejected: v2 keys on a v1.0 record (both keys)" {
  _create_v1_record

  # Hand-edit: inject v2 keys while keeping schema_version 1.0
  local _rec_file="$RECORD"
  yq -i '.design_system_project.reference = "ds"' "$_rec_file"
  yq -i '.product_design_project = null' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -ne 0 ] || fail "expected downgrade rejection"
  [[ "$output" == *"downgrade"* ]] || fail "expected downgrade diagnostic, got: $output"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "schema downgrade rejected: v1 record with only product_design_project key" {
  _create_v1_record

  # Hand-edit: inject only product_design_project
  local _rec_file="$RECORD"
  yq -i '.product_design_project.reference = "pd"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -ne 0 ] || fail "expected downgrade rejection"
  [[ "$output" == *"downgrade"* ]] || fail "expected downgrade diagnostic, got: $output"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "wrong design_system_project.type rejected" {
  _create_v1_record
  # Trigger migration first
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Hand-edit: set wrong type
  local _rec_file="$RECORD"
  yq -i '.design_system_project.type = "design"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected type rejection"
  [[ "$output" == *"type"* ]] || fail "expected type diagnostic, got: $output"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "wrong product_design_project.type rejected" {
  _create_v1_record "ds-ref"
  # Trigger migration + set product project
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "setup set-product-project failed: $output"

  # Hand-edit: wrong type on product project
  local _rec_file="$RECORD"
  yq -i '.product_design_project.type = "design-system"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -ne 0 ] || fail "expected type rejection"
  [[ "$output" == *"type"* ]] || fail "expected type diagnostic, got: $output"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "identical references rejected (both non-null)" {
  _create_v1_record "same-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Hand-edit: set product project to same reference
  local _rec_file="$RECORD"
  yq -i '.product_design_project.reference = "same-ref"' "$_rec_file"
  yq -i '.product_design_project.type = "design"' "$_rec_file"
  yq -i '.product_design_project.surface = "artifact"' "$_rec_file"
  yq -i '.product_design_project.discovered_via = "existing"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected identical-ref rejection"
  [[ "$output" == *"identical"* ]] || [[ "$output" == *"same"* ]] || \
    fail "expected identical-ref diagnostic, got: $output"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "null design_system_project allowed on not-applicable record" {
  _create_na_record

  # After init-not-applicable + migration, design_system_project should be null
  # and that's allowed. Verify by reading (verify-integrity goes through validation)
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "verify-integrity should pass on NA record: $output"
}

@test "null design_system_project refused on applicable record" {
  _create_v1_record
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Hand-edit: null out design_system_project on an applicable record
  local _rec_file="$RECORD"
  yq -i '.design_system_project = null' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected null-ds refusal on applicable"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "missing design_system_project KEY refused on applicable v2 record (distinct diagnostic)" {
  _create_v1_record
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Hand-edit: remove the key entirely
  local _rec_file="$RECORD"
  yq -i 'del(.design_system_project)' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected missing-key refusal"
  # Diagnostic must be DISTINCT from the null check diagnostic
  [[ "$output" == *"missing"* ]] || [[ "$output" == *"key"* ]] || \
    fail "expected missing-key diagnostic, got: $output"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "missing product_design_project KEY refused on applicable v2 record" {
  _create_v1_record
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Hand-edit: remove the key entirely
  local _rec_file="$RECORD"
  yq -i 'del(.product_design_project)' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected missing-key refusal"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "wrong ds type refused even when product_design_project key is absent" {
  # Regression: the early-return bug skipped the type check when either key
  # was missing.  This test proves the fix by removing the pd key entirely
  # and setting a wrong type on ds.
  _create_na_record

  # Build a v2 record with design_system_project present but no pd key
  local _rec_file="$RECORD"
  yq -i '.applicability = "not-applicable"' "$_rec_file"
  yq -i '.design_system_project.reference = "ds-ref"' "$_rec_file"
  yq -i '.design_system_project.type = "design"' "$_rec_file"
  yq -i '.design_system_project.surface = "designsync"' "$_rec_file"
  yq -i '.design_system_project.discovered_via = "project-artifacts"' "$_rec_file"
  yq -i 'del(.product_design_project)' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected type rejection when pd key absent"
  [[ "$output" == *"type"* ]] || fail "expected type diagnostic, got: $output"

  # Record unchanged, no audit appended
  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed"
}

@test "bogus ds_attachment_mode refused even when product_design_project key is absent" {
  # Regression: the early-return bug skipped the enum check when either key
  # was missing.
  _create_na_record

  local _rec_file="$RECORD"
  yq -i '.applicability = "not-applicable"' "$_rec_file"
  yq -i '.design_system_project = null' "$_rec_file"
  yq -i 'del(.product_design_project)' "$_rec_file"
  yq -i '.ds_attachment_mode = "bogus"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for bogus ds_attachment_mode when pd key absent"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed"
}

@test "applicability with embedded comma does not bypass cross-validation" {
  # Regression: a crafted applicability value containing a comma shifted the
  # CSV fields, making every boolean check see the wrong column.
  _create_v1_record "ds-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Hand-edit: inject comma-bearing applicability and a wrong ds type
  local _rec_file="$RECORD"
  yq -i '.applicability = "applicable,9,false,false,false"' "$_rec_file"
  yq -i '.design_system_project.type = "bogus"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "comma in applicability bypassed cross-validation"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "applicability with embedded newline does not bypass cross-validation" {
  # Regression: a crafted applicability containing a newline could truncate
  # the CSV line, leaving downstream fields empty and skipping all checks.
  _create_v1_record "ds-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Hand-edit: inject newline-bearing applicability and a wrong ds type
  local _rec_file="$RECORD"
  # yq literal scalar with explicit newline
  yq -i '.applicability = "applicable\nx"' "$_rec_file"
  yq -i '.design_system_project.type = "bogus"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "newline in applicability bypassed cross-validation"

  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed despite rejection"
}

@test "cross-check removal mutant: function body replaced with return 0" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  # Assert _validate_project_references exists as a function
  grep -q '^_validate_project_references()' "$DREC_SCRIPT" || \
    fail "_validate_project_references function not found — not yet implemented"

  _create_v1_record
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "setup transition failed: $output"

  # Create a mutated script with _validate_project_references body = return 0
  local mutant_dir="$TEST_TMP/mutant-scripts"
  mkdir -p "$mutant_dir/lib"
  cp "$SCRIPTS_DIR/design-record.sh" "$mutant_dir/design-record.sh"
  cp "$SCRIPTS_DIR/lib/acquire-lock.sh" "$mutant_dir/lib/acquire-lock.sh"
  chmod +x "$mutant_dir/design-record.sh"

  # Replace the function body with return 0
  awk '
    /^_validate_project_references\(\)/ { print; getline; print; in_fn=1; next }
    in_fn && /^\}$/ { print "  return 0"; print; in_fn=0; next }
    in_fn { next }
    { print }
  ' "$SCRIPTS_DIR/design-record.sh" > "$mutant_dir/design-record.sh"

  # Now inject a wrong type — the mutant should NOT catch it
  local _rec_file="$RECORD"
  yq -i '.design_system_project.type = "bogus"' "$_rec_file"

  run env PROJECT_ROOT="$TEST_TMP" "$mutant_dir/design-record.sh" transition --to stale --actor "test"
  # With the real code, this would fail. With the mutant, it succeeds → proves the guard matters.
  [ "$status" -eq 0 ] || fail "mutant should have let the wrong type through (function replaced with return 0)"
}

@test "downgrade-check removal mutant: v1 with v2 keys passes through" {
  _create_v1_record

  # Hand-edit: inject v2 key on a v1 record
  local _rec_file="$RECORD"
  yq -i '.design_system_project.reference = "ds"' "$_rec_file"

  # With real code, this should fail with a downgrade-specific diagnostic
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -ne 0 ] || fail "expected downgrade rejection on real code"
  [[ "$output" == *"downgrade"* ]] || fail "expected downgrade diagnostic, got: $output"
}

@test "downgrade-check removal mutant lets corruption through" {
  _create_v1_record

  # Build a mutant that strips the downgrade check from _validate_project_references
  local mutant_dir="$TEST_TMP/dg-mutant"
  mkdir -p "$mutant_dir/lib"
  cp "$DREC_SCRIPT" "$mutant_dir/design-record.sh"
  cp "$SCRIPTS_DIR/lib/acquire-lock.sh" "$mutant_dir/lib/acquire-lock.sh"
  chmod +x "$mutant_dir/design-record.sh"

  # Remove the downgrade-check block: lines matching "downgrade" through the
  # next "fi" that closes the check.
  sed -i.bak '/[Dd]owngrade/,/^[[:space:]]*fi$/d' "$mutant_dir/design-record.sh"

  # Inject v2 key on a v1 record
  local _rec_file="$RECORD"
  yq -i '.design_system_project.reference = "ds"' "$_rec_file"

  # Mutant should let the corruption pass (status 0) — proving the check is load-bearing
  run env PROJECT_ROOT="$TEST_TMP" /bin/bash "$mutant_dir/design-record.sh" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "mutant should have let corruption through, got status=$status; output=$output"
}

@test "init with identical --ds-reference and --pd-reference rejected" {
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "same" --pd-reference "same" \
    --discovered-via project-artifacts --actor "test"
  [ "$status" -ne 0 ] || fail "expected identical-ref rejection"
  [[ "$output" == *"identical"* ]] || [[ "$output" == *"same"* ]] || \
    fail "expected identical-ref diagnostic, got: $output"
}

@test "reopen-applicable with identical --ds-reference and --pd-reference rejected" {
  _create_na_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "same" --pd-reference "same" \
    --discovered-via project-artifacts --actor "test"
  [ "$status" -ne 0 ] || fail "expected identical-ref rejection"
  [[ "$output" == *"identical"* ]] || [[ "$output" == *"same"* ]] || \
    fail "expected identical-ref diagnostic, got: $output"
}


# =========================================================================
# Schema version acceptance — valid and invalid version strings
# =========================================================================

@test "version 1.0 and 2.0 accepted by show, status, mutation; 9.9 rejected" {
  _create_v1_record
  # v1 record — show/status should work
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" show
  [ "$status" -eq 0 ] || fail "show failed on v1.0: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" status
  [ "$status" -eq 0 ] || fail "status failed on v1.0: $output"

  # check-convergence returns non-zero for not-converged (semantically correct,
  # not a schema rejection). Validate it doesn't die with a schema error:
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" check-convergence
  # Exit 0 or 1 are valid — only 2+ is a schema error
  [ "$status" -le 1 ] || fail "check-convergence schema error on v1.0: $output"

  # Trigger migration to v2
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition on v1.0 failed: $output"

  # v2 record — show/status should work
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" show
  [ "$status" -eq 0 ] || fail "show failed on v2.0: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" status
  [ "$status" -eq 0 ] || fail "status failed on v2.0: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" check-convergence
  [ "$status" -le 1 ] || fail "check-convergence schema error on v2.0: $output"

  # 9.9 — rejected
  local _rec_file="$RECORD"
  yq -i '.schema_version = "9.9"' "$_rec_file"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" show
  [ "$status" -ne 0 ] || fail "show should reject 9.9"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" status
  [ "$status" -ne 0 ] || fail "status should reject 9.9"
}


# =========================================================================
# cmd_set_product_project — surface, reference, and type fields
# =========================================================================

@test "cmd_set_product_project on null product_design_project sets field and passes verify-integrity" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "my-pd-ref" --discovered-via existing --actor "setter"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  # Field set
  local pdp_ref pdp_type
  pdp_ref="$(yq '.product_design_project.reference' "$RECORD")"
  pdp_type="$(yq '.product_design_project.type' "$RECORD")"
  [ "$pdp_ref" = "my-pd-ref" ] || fail "pd reference=$pdp_ref"
  [ "$pdp_type" = "design" ] || fail "pd type=$pdp_type"

  # Verify integrity
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "verify-integrity failed: $output"
}

@test "cmd_set_product_project refuses overwrite on non-null (positive control: succeeds on null)" {
  _create_v1_record "ds-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Positive control: succeeds on null
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "first" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "first set should succeed: $output"

  # Now overwrite attempt
  local hash
  hash="$(_sha256_file "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "second" --discovered-via existing --actor "test"
  [ "$status" -ne 0 ] || fail "expected overwrite refusal"
  [[ "$output" == *"already"* ]] || fail "expected 'already' diagnostic, got: $output"

  # Byte-identical
  local post_hash
  post_hash="$(_sha256_file "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite refusal"
}

@test "cmd_set_product_project identical-ref rejected" {
  _create_v1_record "same-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  local hash
  hash="$(_sha256_file "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "same-ref" --discovered-via existing --actor "test"
  [ "$status" -ne 0 ] || fail "expected identical-ref rejection"
  [[ "$output" == *"identical"* ]] || [[ "$output" == *"same"* ]] || \
    fail "expected identical-ref diagnostic, got: $output"

  local post_hash
  post_hash="$(_sha256_file "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
}

@test "cmd_set_product_project approved to stale with state-transition audit entry" {
  _create_v1_record "ds-ref" "project-artifacts"
  _advance_to_state approved

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local ds
  ds="$(yq '.design_state' "$RECORD")"
  [ "$ds" = "stale" ] || fail "design_state=$ds, expected stale"

  # Last audit entry should be state-transition with from=approved to=stale
  local last_event last_from last_to
  last_event="$(yq '.audit[-1].event' "$RECORD")"
  last_from="$(yq '.audit[-1].from' "$RECORD")"
  last_to="$(yq '.audit[-1].to' "$RECORD")"
  [ "$last_event" = "state-transition" ] || fail "last event=$last_event"
  [ "$last_from" = "approved" ] || fail "from=$last_from"
  [ "$last_to" = "stale" ] || fail "to=$last_to"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "verify-integrity failed: $output"
}

@test "cmd_set_product_project in-dev to stale with state-transition audit entry" {
  _create_v1_record "ds-ref" "project-artifacts"
  _advance_to_state in-dev

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local ds last_from last_to
  ds="$(yq '.design_state' "$RECORD")"
  [ "$ds" = "stale" ] || fail "design_state=$ds, expected stale"
  last_from="$(yq '.audit[-1].from' "$RECORD")"
  last_to="$(yq '.audit[-1].to' "$RECORD")"
  [ "$last_from" = "in-dev" ] || fail "from=$last_from"
  [ "$last_to" = "stale" ] || fail "to=$last_to"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "verify-integrity failed: $output"
}

@test "cmd_set_product_project review to stale with state-transition audit entry" {
  _create_v1_record "ds-ref" "project-artifacts"
  _advance_to_state review

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local ds last_from last_to
  ds="$(yq '.design_state' "$RECORD")"
  [ "$ds" = "stale" ] || fail "design_state=$ds, expected stale"
  last_from="$(yq '.audit[-1].from' "$RECORD")"
  last_to="$(yq '.audit[-1].to' "$RECORD")"
  [ "$last_from" = "review" ] || fail "from=$last_from"
  [ "$last_to" = "stale" ] || fail "to=$last_to"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "verify-integrity failed: $output"
}

@test "cmd_set_product_project draft stays draft with product-project-set entry" {
  _create_v1_record "ds-ref"
  # Stay in draft — don't advance
  # Trigger migration via a read
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" show
  # Migration happens on mutation verbs, not reads. Use set-product-project itself.
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local ds last_event
  ds="$(yq '.design_state' "$RECORD")"
  [ "$ds" = "draft" ] || fail "design_state=$ds, expected draft"

  last_event="$(yq '.audit[-1].event' "$RECORD")"
  [ "$last_event" = "product-project-set" ] || fail "last event=$last_event, expected product-project-set"
}

@test "cmd_set_product_project on not-applicable refused" {
  _create_na_record
  local hash
  hash="$(_sha256_file "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -ne 0 ] || fail "expected not-applicable refusal"
  # Must be a not-applicable-specific diagnostic, not "unknown verb"
  [[ "$output" != *"unknown verb"* ]] || fail "verb not implemented yet, got: $output"
  [[ "$output" == *"not-applicable"* ]] || fail "expected not-applicable diagnostic, got: $output"

  local post_hash
  post_hash="$(_sha256_file "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite refusal"
}

@test "cmd_set_product_project on stale stays stale with product-project-set entry" {
  _create_v1_record "ds-ref"
  # Advance to stale
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -eq 0 ] || fail "transition to stale failed: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local ds last_event
  ds="$(yq '.design_state' "$RECORD")"
  [ "$ds" = "stale" ] || fail "design_state=$ds, expected stale"

  last_event="$(yq '.audit[-1].event' "$RECORD")"
  [ "$last_event" = "product-project-set" ] || fail "last event=$last_event"
}

@test "cmd_set_product_project --discovered-via enum validated" {
  _create_v1_record "ds-ref"

  # bogus rejected with specific diagnostic
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via bogus --actor "test"
  [ "$status" -ne 0 ] || fail "expected enum rejection for bogus"
  [[ "$output" != *"unknown verb"* ]] || fail "verb not implemented yet, got: $output"
  [[ "$output" == *"discovered"* ]] || [[ "$output" == *"bogus"* ]] || \
    fail "expected discovered-via diagnostic, got: $output"

  # existing accepted
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "existing should be accepted: $output"
}

@test "cmd_set_product_project empty --pd-reference rejected" {
  _create_v1_record "ds-ref"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "" --discovered-via existing --actor "test"
  [ "$status" -ne 0 ] || fail "expected empty rejection"
  [[ "$output" == *"required"* ]] || [[ "$output" == *"empty"* ]] || \
    fail "expected required/empty diagnostic, got: $output"
}

@test "cmd_set_product_project sentinel --pd-reference rejected" {
  _create_v1_record "ds-ref"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "not-applicable" --discovered-via existing --actor "test"
  [ "$status" -ne 0 ] || fail "expected sentinel rejection"
  # Must be a sentinel-specific diagnostic, not "unknown verb"
  [[ "$output" != *"unknown verb"* ]] || fail "verb not implemented yet, got: $output"
  [[ "$output" == *"not-applicable"* ]] || fail "expected sentinel diagnostic, got: $output"
}

@test "cmd_set_product_project with NO --pd-reference: non-zero, required diagnostic, byte-identical, no new audit" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --discovered-via existing --actor "test"
  [ "$status" -ne 0 ] || fail "expected required diagnostic"
  [[ "$output" == *"required"* ]] || fail "expected 'required' in diagnostic, got: $output"

  local post_hash post_audit_count
  post_hash="$(_sha256_file "$RECORD")"
  post_audit_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite missing --pd-reference"
  [ "$audit_count" = "$post_audit_count" ] || fail "audit count changed: $audit_count → $post_audit_count"
}

@test "cmd_set_product_project --discovered-via existing stores discovered_via and exactly one audit append" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  local pre_count
  pre_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local post_count stored_dv
  post_count="$(yq '.audit | length' "$RECORD")"
  stored_dv="$(yq '.product_design_project.discovered_via' "$RECORD")"

  [ "$stored_dv" = "existing" ] || fail "discovered_via=$stored_dv, expected existing"
  [ "$post_count" -eq "$((pre_count + 1))" ] || fail "expected exactly 1 audit append, got $((post_count - pre_count))"
}

@test "cmd_set_product_project --discovered-via created stores discovered_via and exactly one audit append" {
  _create_v1_record "ds-ref"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via created --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local stored_dv
  stored_dv="$(yq '.product_design_project.discovered_via' "$RECORD")"
  [ "$stored_dv" = "created" ] || fail "discovered_via=$stored_dv, expected created"
}


# =========================================================================
# Backward compatibility — v1 records auto-migrate on read
# =========================================================================

@test "backward-compat alias: v2 project.reference equals design_system_project.reference" {
  _create_v1_record "my-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  local proj_ref dsp_ref
  proj_ref="$(yq '.project.reference' "$RECORD")"
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$proj_ref" = "$dsp_ref" ] || fail "backward compat broken: project.reference=$proj_ref, design_system_project.reference=$dsp_ref"
}


# =========================================================================
# Init and reopen-applicable — questionnaire, applicability, reference
# =========================================================================

@test "init with --ds-reference + --pd-reference + --sync-mode brand-style writes correctly" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "project-artifacts" --sync-mode "brand-style" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local sv dsp_ref pdp_ref sync dam
  sv="$(yq '.schema_version' "$RECORD")"
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  pdp_ref="$(yq '.product_design_project.reference' "$RECORD")"
  sync="$(yq '.sync_mode' "$RECORD")"
  dam="$(yq '.ds_attachment_mode' "$RECORD")"

  [ "$sv" = "2.0" ] || fail "schema_version=$sv"
  [ "$dsp_ref" = "ds-ref" ] || fail "ds ref=$dsp_ref"
  [ "$pdp_ref" = "pd-ref" ] || fail "pd ref=$pdp_ref"
  [ "$sync" = "brand-style" ] || fail "sync_mode=$sync"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode=$dam"
}

@test "init with --pd-reference sets product_design_project.discovered_via to existing" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local pdp_dv
  pdp_dv="$(yq '.product_design_project.discovered_via' "$RECORD")"
  [ "$pdp_dv" = "existing" ] || fail "pd discovered_via=$pdp_dv, expected existing"
}

@test "init with --reference alias writes design_system_project.reference" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "legacy-ref" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local dsp_ref
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$dsp_ref" = "legacy-ref" ] || fail "ds ref=$dsp_ref"
}

@test "init with --ds-reference + --reference: --ds-reference wins" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "winner" --reference "loser" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local dsp_ref
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$dsp_ref" = "winner" ] || fail "ds ref=$dsp_ref, expected winner"
}

@test "init skip-path without --questionnaire-record stores skipped" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local qr
  qr="$(yq '.project.questionnaire_record' "$RECORD")"
  [ "$qr" = "skipped" ] || fail "questionnaire_record=$qr, expected skipped"
}

@test "init created-path without --questionnaire-record rejected" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "created" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection without questionnaire-record on created"
  [[ "$output" == *"required"* ]] || fail "expected 'required' in diagnostic, got: $output"
}

@test "init with nonexistent --questionnaire-record path rejected with diagnostic" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "created" \
    --questionnaire-record "no/such/file.md" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for nonexistent questionnaire"
  [[ "$output" == *"no/such/file.md"* ]] || fail "expected path in diagnostic, got: $output"
}

@test "init with relative --questionnaire-record resolves against PROJECT_ROOT" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  mkdir -p "$TEST_TMP/docs"
  touch "$TEST_TMP/docs/questionnaire.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "created" \
    --questionnaire-record "docs/questionnaire.md" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"
}

@test "init stores the given (not resolved) questionnaire path" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  mkdir -p "$TEST_TMP/docs"
  touch "$TEST_TMP/docs/questionnaire.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "created" \
    --questionnaire-record "docs/questionnaire.md" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local qr
  qr="$(yq '.project.questionnaire_record' "$RECORD")"
  [ "$qr" = "docs/questionnaire.md" ] || fail "stored path=$qr, expected docs/questionnaire.md"
}

@test "reopen-applicable skip path stores skipped" {
  _create_na_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen-applicable failed: $output"

  local qr
  qr="$(yq '.project.questionnaire_record' "$RECORD")"
  [ "$qr" = "skipped" ] || fail "questionnaire_record=$qr, expected skipped"
}

@test "reopen-applicable -f check rejects missing questionnaire file with created" {
  _create_na_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" --discovered-via "created" \
    --questionnaire-record "no/such/file.md" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for missing questionnaire"
  [[ "$output" == *"no/such/file.md"* ]] || fail "expected path in diagnostic, got: $output"
}

@test "init empty --pd-reference rejected" {
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -ne 0 ] || fail "expected empty pd-reference rejection"
  [[ "$output" != *"unknown option"* ]] || fail "flag not implemented yet, got: $output"
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"required"* ]] || \
    fail "expected empty/required diagnostic, got: $output"
}

@test "reopen-applicable with --ds-reference + --pd-reference writes correctly" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen-applicable failed: $output"

  local dsp_ref pdp_ref
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  pdp_ref="$(yq '.product_design_project.reference' "$RECORD")"
  [ "$dsp_ref" = "ds-ref" ] || fail "ds ref=$dsp_ref"
  [ "$pdp_ref" = "pd-ref" ] || fail "pd ref=$pdp_ref"
}

@test "reopen-applicable without --pd-reference keeps non-null product_design_project" {
  _create_na_record

  # First reopen with pd-reference
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "first reopen failed: $output"

  # Flip back to not-applicable
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" not-applicable --actor "test"
  [ "$status" -eq 0 ] || fail "not-applicable failed: $output"

  # Second reopen WITHOUT --pd-reference
  touch "$TEST_TMP/path/to/q2.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref-2" --discovered-via "created" \
    --questionnaire-record "path/to/q2.md" --actor "test"
  [ "$status" -eq 0 ] || fail "second reopen failed: $output"

  local pdp_ref
  pdp_ref="$(yq '.product_design_project.reference' "$RECORD")"
  [ "$pdp_ref" = "pd-ref" ] || fail "pd ref lost: $pdp_ref"
}

@test "reopen-applicable without --sync-mode keeps existing sync_mode" {
  _create_na_record

  # First reopen with sync-mode
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --sync-mode "brand-style" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "first reopen failed: $output"

  # Flip back to not-applicable
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" not-applicable --actor "test"
  [ "$status" -eq 0 ] || fail "not-applicable failed: $output"

  # Second reopen WITHOUT --sync-mode
  touch "$TEST_TMP/path/to/q2.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref-2" --discovered-via "created" \
    --questionnaire-record "path/to/q2.md" --actor "test"
  [ "$status" -eq 0 ] || fail "second reopen failed: $output"

  local sync
  sync="$(yq '.sync_mode' "$RECORD")"
  [ "$sync" = "brand-style" ] || fail "sync_mode=$sync, expected brand-style"
}

@test "reopen-applicable project/design-system alias invariant" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "my-ref" --discovered-via "created" \
    --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen-applicable failed: $output"

  local proj_ref dsp_ref
  proj_ref="$(yq '.project.reference' "$RECORD")"
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$proj_ref" = "$dsp_ref" ] || fail "alias invariant broken: project=$proj_ref, dsp=$dsp_ref"
}

@test "sentinel as --ds-reference rejected" {
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "not-applicable" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -ne 0 ] || fail "expected sentinel rejection"
  [[ "$output" == *"not-applicable"* ]] || fail "expected sentinel diagnostic, got: $output"
}

@test "sentinel as --reference rejected" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "not-applicable" --discovered-via "project-artifacts" \
    --actor "test"
  [ "$status" -ne 0 ] || fail "expected sentinel rejection"
  [[ "$output" == *"not-applicable"* ]] || [[ "$output" == *"sentinel"* ]] || \
    fail "expected sentinel diagnostic, got: $output"
}

@test "sentinel as --pd-reference rejected" {
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "not-applicable" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -ne 0 ] || fail "expected sentinel rejection"
  [[ "$output" != *"unknown option"* ]] || fail "flag not implemented yet, got: $output"
  [[ "$output" == *"not-applicable"* ]] || [[ "$output" == *"sentinel"* ]] || \
    fail "expected sentinel diagnostic, got: $output"
}

@test "--sync-mode unknown value rejected before write" {
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" \
    --sync-mode "bogus" --actor "test"
  [ "$status" -ne 0 ] || fail "expected sync-mode rejection"
  [[ "$output" != *"unknown option"* ]] || fail "flag not implemented yet, got: $output"
  [[ "$output" == *"bogus"* ]] || [[ "$output" == *"sync"* ]] || \
    fail "expected sync-mode diagnostic, got: $output"
}

@test "--discovered-via unknown value rejected on init" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "bogus" \
    --actor "test"
  [ "$status" -ne 0 ] || fail "expected discovered-via rejection"
  [[ "$output" == *"bogus"* ]] || [[ "$output" == *"discovered"* ]] || \
    fail "expected discovered-via diagnostic, got: $output"
}

@test "--discovered-via unknown value rejected on reopen-applicable" {
  _create_na_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" --discovered-via "bogus" \
    --actor "test"
  [ "$status" -ne 0 ] || fail "expected discovered-via rejection"
  [[ "$output" == *"bogus"* ]] || [[ "$output" == *"discovered"* ]] || \
    fail "expected discovered-via diagnostic, got: $output"
}

@test "omitted --sync-mode defaults to react-components" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" \
    --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local sync
  sync="$(yq '.sync_mode' "$RECORD")"
  [ "$sync" = "react-components" ] || fail "sync_mode=$sync, expected react-components"
}

@test "empty --pd-reference rejected on reopen-applicable" {
  _create_na_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" --pd-reference "" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -ne 0 ] || fail "expected empty pd-reference rejection"
  [[ "$output" != *"unknown option"* ]] || fail "flag not implemented yet, got: $output"
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"required"* ]] || \
    fail "expected empty/required diagnostic, got: $output"
}

@test "reopen-applicable --pd-reference on non-null product_design_project REFUSED" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  # First reopen with pd-reference
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "first reopen failed: $output"

  # Flip back to not-applicable
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" not-applicable --actor "test"
  [ "$status" -eq 0 ] || fail "not-applicable failed: $output"

  local hash
  hash="$(_sha256_file "$RECORD")"

  # Second reopen WITH --pd-reference when product_design_project is non-null
  touch "$TEST_TMP/path/to/q2.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref-2" --pd-reference "pd-ref-2" \
    --discovered-via "created" --questionnaire-record "path/to/q2.md" --actor "test"
  [ "$status" -ne 0 ] || fail "expected no-overwrite refusal"
  [[ "$output" == *"already set"* ]] || fail "expected 'already set' diagnostic, got: $output"
  # The message must tell the user what to do (omit --pd-reference), not point
  # at set-product-project which also refuses to overwrite
  [[ "$output" == *"omit --pd-reference"* ]] || fail "expected 'omit --pd-reference' guidance, got: $output"

  local post_hash
  post_hash="$(_sha256_file "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite refusal"
}


# =========================================================================
# ds_attachment_mode — enum enforcement and migration default
# =========================================================================

@test "init sets ds_attachment_mode to token-by-value" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" \
    --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local dam
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode=$dam"
}

@test "migration applicable sets ds_attachment_mode to token-by-value" {
  _create_v1_record
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  local dam
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode=$dam"
}

@test "migration sentinel+NA results in absent ds_attachment_mode" {
  _create_na_record

  # Read the record directly (don't trigger mutation which would reopen)
  # Check that after init-not-applicable, ds_attachment_mode is absent
  local has_dam
  has_dam="$(yq 'has("ds_attachment_mode")' "$RECORD")"
  [ "$has_dam" = "false" ] || fail "ds_attachment_mode should be absent on NA record"
}

@test "init-not-applicable results in absent ds_attachment_mode" {
  _create_na_record

  local has_dam
  has_dam="$(yq 'has("ds_attachment_mode")' "$RECORD")"
  [ "$has_dam" = "false" ] || fail "ds_attachment_mode should be absent"
  assert_file_excludes "$RECORD" "ds_attachment_mode"

  # Positive: expected keys ARE present
  local key_count
  key_count="$(yq 'keys | length' "$RECORD")"
  [ "$key_count" -ge 5 ] || fail "too few keys: $key_count"
}

@test "set-product-project on absent ds_attachment_mode sets token-by-value" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Remove ds_attachment_mode to simulate absence
  local _rec_file="$RECORD"
  yq -i 'del(.ds_attachment_mode)' "$_rec_file"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local dam
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode=$dam"
}

@test "set-product-project preserves artifact-installed ds_attachment_mode" {
  _create_v1_record "ds-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Set to artifact-installed
  local _rec_file="$RECORD"
  yq -i '.ds_attachment_mode = "artifact-installed"' "$_rec_file"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local dam
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "artifact-installed" ] || fail "ds_attachment_mode=$dam, expected artifact-installed"
}

@test "reopen-applicable with --pd-reference preserves existing ds_attachment_mode" {
  # Guards against reopen overwriting an existing valid ds_attachment_mode
  # with the default.  A writer that unconditionally sets token-by-value
  # would silently discard the user's choice.
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  # First reopen to make the record applicable and set ds_attachment_mode
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "first reopen failed: $output"

  # Set ds_attachment_mode to artifact-installed (valid, non-default)
  local _rec_file="$RECORD"
  yq -i '.ds_attachment_mode = "artifact-installed"' "$_rec_file"

  # Flip to not-applicable so we can reopen again
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" not-applicable --actor "test"
  [ "$status" -eq 0 ] || fail "not-applicable failed: $output"

  # Clear the product_design_project so reopen can set it again
  yq -i '.product_design_project = null' "$_rec_file"

  touch "$TEST_TMP/path/to/q2.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref-2" --pd-reference "pd-ref-2" \
    --discovered-via "created" --questionnaire-record "path/to/q2.md" --actor "test"
  [ "$status" -eq 0 ] || fail "second reopen failed: $output"

  local dam
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "artifact-installed" ] || fail "ds_attachment_mode=$dam, expected artifact-installed (preserved)"
}

@test "bogus ds_attachment_mode rejected by writer" {
  _create_v1_record "ds-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Hand-edit: set bogus value
  local _rec_file="$RECORD"
  yq -i '.ds_attachment_mode = "bogus"' "$_rec_file"

  local hash audit_count
  hash="$(_sha256_file "$RECORD")"
  audit_count="$(yq '.audit | length' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for bogus ds_attachment_mode"

  # Record unchanged, no new audit
  local post_hash post_count
  post_hash="$(_sha256_file "$RECORD")"
  post_count="$(yq '.audit | length' "$RECORD")"
  [ "$hash" = "$post_hash" ] || fail "record modified despite rejection"
  [ "$audit_count" = "$post_count" ] || fail "audit count changed"
}

@test "reopen-applicable with --pd-reference sets ds_attachment_mode when absent" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen failed: $output"

  local dam
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode=$dam"
}

@test "reopen-applicable without --pd-reference does not add ds_attachment_mode" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --discovered-via "created" \
    --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen failed: $output"

  local has_dam
  has_dam="$(yq 'has("ds_attachment_mode")' "$RECORD")"
  [ "$has_dam" = "false" ] || fail "ds_attachment_mode should be absent without --pd-reference"
}

@test "init --pd-discovered-via created records discovered_via on product project" {
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "pd-ref" \
    --pd-discovered-via "created" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local pd_dv
  pd_dv="$(yq '.product_design_project.discovered_via' "$RECORD")"
  [ "$pd_dv" = "created" ] || fail "product_design_project.discovered_via=$pd_dv, expected created"
}

@test "init --pd-discovered-via defaults to existing when omitted" {
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local pd_dv
  pd_dv="$(yq '.product_design_project.discovered_via' "$RECORD")"
  [ "$pd_dv" = "existing" ] || fail "product_design_project.discovered_via=$pd_dv, expected existing"
}

@test "init --pd-discovered-via rejects invalid enum values" {
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "pd-ref" \
    --pd-discovered-via "bogus-value" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for invalid --pd-discovered-via"
  [[ "$output" == *"bogus-value"* ]] || fail "expected diagnostic to name the rejected value, got: $output"
}

@test "reopen-applicable --pd-discovered-via created records discovered_via on product project" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --pd-discovered-via "created" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen failed: $output"

  local pd_dv
  pd_dv="$(yq '.product_design_project.discovered_via' "$RECORD")"
  [ "$pd_dv" = "created" ] || fail "product_design_project.discovered_via=$pd_dv, expected created"
}

@test "reopen-applicable --pd-discovered-via defaults to existing when omitted" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen failed: $output"

  local pd_dv
  pd_dv="$(yq '.product_design_project.discovered_via' "$RECORD")"
  [ "$pd_dv" = "existing" ] || fail "product_design_project.discovered_via=$pd_dv, expected existing"
}

@test "reopen-applicable --pd-discovered-via rejects invalid enum values" {
  _create_na_record
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ds-ref" --pd-reference "pd-ref" \
    --pd-discovered-via "bogus-value" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for invalid --pd-discovered-via on reopen"
  [[ "$output" == *"bogus-value"* ]] || fail "expected diagnostic to name the rejected value, got: $output"
}

@test "schema validates token-by-value and artifact-installed; rejects bogus" {
  [ -f "$SCHEMA" ] || fail "schema not found"

  # ds_attachment_mode must be an enum with exactly token-by-value and artifact-installed
  local enum_json
  enum_json="$(jq -r '.properties.ds_attachment_mode.enum // empty' "$SCHEMA")"
  [ -n "$enum_json" ] || fail "ds_attachment_mode missing enum constraint"

  local has_tbv has_ai count
  has_tbv="$(jq '.properties.ds_attachment_mode.enum | index("token-by-value") != null' "$SCHEMA")"
  has_ai="$(jq '.properties.ds_attachment_mode.enum | index("artifact-installed") != null' "$SCHEMA")"
  count="$(jq '.properties.ds_attachment_mode.enum | length' "$SCHEMA")"
  [ "$has_tbv" = "true" ] || fail "ds_attachment_mode enum missing token-by-value"
  [ "$has_ai" = "true" ] || fail "ds_attachment_mode enum missing artifact-installed"
  [ "$count" -eq 2 ] || fail "ds_attachment_mode enum has $count values, expected 2"
}

@test "schema ds_attachment_mode has default and non-empty description" {
  [ -f "$SCHEMA" ] || fail "schema not found"

  local dflt desc
  dflt="$(jq -r '.properties.ds_attachment_mode.default // empty' "$SCHEMA")"
  desc="$(jq -r '.properties.ds_attachment_mode.description // empty' "$SCHEMA")"

  [ "$dflt" = "token-by-value" ] || fail "default=$dflt, expected token-by-value"
  [ -n "$desc" ] || fail "description is empty"
}


# =========================================================================
# Schema validation — required fields and type constraints
# =========================================================================

@test "schema accepts schema_version 2.0 in its enum" {
  [ -f "$SCHEMA" ] || fail "schema not found"

  # Schema must accept schema_version "2.0" in enum
  local sv_enum
  sv_enum="$(jq -r '.properties.schema_version.enum // empty' "$SCHEMA")"
  [ -n "$sv_enum" ] || fail "schema_version has no enum constraint"

  local has_v2
  has_v2="$(jq '.properties.schema_version.enum | index("2.0") != null' "$SCHEMA")"
  [ "$has_v2" = "true" ] || fail "schema_version enum does not include 2.0"
}

@test "review_coverage schema: property declared with correct type" {
  [ -f "$SCHEMA" ] || fail "schema not found"

  local has_rc
  has_rc="$(jq 'has("properties") and (.properties | has("review_coverage"))' "$SCHEMA")"
  [ "$has_rc" = "true" ] || fail "schema missing review_coverage property"
}


# =========================================================================
# Questionnaire-skip — "skipped" sentinel written when omitted
# =========================================================================

@test "skip reads v2 design_system_project.reference (exit 0)" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  run "$SKIP_QR" --record-path "$RECORD"
  [ "$status" -eq 0 ] || fail "skip should exit 0 on v2 record with ds ref: $output"
}

@test "skip present-but-null design_system_project exits 1 (no fallback)" {
  _create_na_record

  # After init-not-applicable, design_system_project is null (once migrated)
  # The skip script should exit 1
  run "$SKIP_QR" --record-path "$RECORD"
  [ "$status" -eq 1 ] || fail "skip should exit 1 on null design_system_project"
}

@test "skip product_design_project null still exits 0" {
  _create_v1_record "ds-ref"
  # Trigger migration — product is null, but ds ref exists
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  run "$SKIP_QR" --record-path "$RECORD"
  [ "$status" -eq 0 ] || fail "skip should exit 0 when ds ref exists (pd null)"
}

@test "skip pre-migration fallback reads project.reference" {
  # Create a v1 record WITHOUT triggering migration (no mutation verbs)
  _create_v1_record "ds-ref"

  run "$SKIP_QR" --record-path "$RECORD"
  [ "$status" -eq 0 ] || fail "skip should fall back to project.reference on v1 record"
}

@test "skip separating fixture: ds_ref populated but project.reference empty exits 0" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Empty the legacy field but keep the v2 field
  local _rec_file="$RECORD"
  yq -i '.project.reference = ""' "$_rec_file"

  run "$SKIP_QR" --record-path "$RECORD"
  [ "$status" -eq 0 ] || fail "skip should read design_system_project.reference, not project.reference"
}


# =========================================================================
# EXIT traps — error-forcing and completion markers
# =========================================================================

@test "set -u abort exits non-zero at _locked_mutate (under /bin/bash)" {
  [ -x /bin/bash ] || skip "/bin/bash not available"

  _create_v1_record

  # Create mutated script that triggers set -u abort inside _locked_mutate
  local mutant_dir="$TEST_TMP/trap-mutant"
  mkdir -p "$mutant_dir/lib"
  cp "$SCRIPTS_DIR/design-record.sh" "$mutant_dir/design-record.sh"
  cp "$SCRIPTS_DIR/lib/acquire-lock.sh" "$mutant_dir/lib/acquire-lock.sh"
  chmod +x "$mutant_dir/design-record.sh"

  # Inject unset variable reference INSIDE _locked_mutate, after the trap line.
  # The trap at line 291 contains _DR_TMP, matching /_DR/.
  local tmpscript="$mutant_dir/design-record.sh.tmp"
  awk '
    /trap .* EXIT/ && !done_mutate && /_DR/ {
      print
      print "    echo \"$_UNSET_VAR_TRIGGER_ABORT\""
      done_mutate = 1
      next
    }
    { print }
  ' "$mutant_dir/design-record.sh" > "$tmpscript" && mv "$tmpscript" "$mutant_dir/design-record.sh"
  chmod +x "$mutant_dir/design-record.sh"

  # Use --to (valid transition option) to actually reach _locked_mutate
  run env PROJECT_ROOT="$TEST_TMP" /bin/bash "$mutant_dir/design-record.sh" transition --to review --actor "test"
  [ "$status" -ne 0 ] || fail "expected non-zero exit on set -u abort"
}

@test "set -u abort exits non-zero at cmd_init (under /bin/bash)" {
  [ -x /bin/bash ] || skip "/bin/bash not available"

  local mutant_dir="$TEST_TMP/trap-mutant-init"
  mkdir -p "$mutant_dir/lib"
  cp "$SCRIPTS_DIR/design-record.sh" "$mutant_dir/design-record.sh"
  cp "$SCRIPTS_DIR/lib/acquire-lock.sh" "$mutant_dir/lib/acquire-lock.sh"
  chmod +x "$mutant_dir/design-record.sh"

  # Inject unset var after the cmd_init trap (2nd trap in file)
  local tmpscript="$mutant_dir/design-record.sh.tmp"
  awk '
    /trap .* EXIT/ && !/trap - EXIT/ {
      trap_count++
      print
      if (trap_count == 2) {
        print "    echo \"$_UNSET_VAR_TRIGGER\""
      }
      next
    }
    { print }
  ' "$mutant_dir/design-record.sh" > "$tmpscript" && mv "$tmpscript" "$mutant_dir/design-record.sh"
  chmod +x "$mutant_dir/design-record.sh"

  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" /bin/bash "$mutant_dir/design-record.sh" init \
    --reference "ref" --discovered-via "project-artifacts" \
    --actor "test"
  [ "$status" -ne 0 ] || fail "expected non-zero exit on set -u abort in cmd_init"
}

@test "set -u abort exits non-zero at init-not-applicable (under /bin/bash)" {
  [ -x /bin/bash ] || skip "/bin/bash not available"

  local mutant_dir="$TEST_TMP/trap-mutant-na"
  mkdir -p "$mutant_dir/lib"
  cp "$SCRIPTS_DIR/design-record.sh" "$mutant_dir/design-record.sh"
  cp "$SCRIPTS_DIR/lib/acquire-lock.sh" "$mutant_dir/lib/acquire-lock.sh"
  chmod +x "$mutant_dir/design-record.sh"

  # Inject unset var after the third trap (init-not-applicable)
  local tmpscript="$mutant_dir/design-record.sh.tmp"
  awk '
    /trap .* EXIT/ && !/trap - EXIT/ {
      trap_count++
      print
      if (trap_count == 3) {
        print "    echo \"$_UNSET_VAR_TRIGGER\""
      }
      next
    }
    { print }
  ' "$mutant_dir/design-record.sh" > "$tmpscript" && mv "$tmpscript" "$mutant_dir/design-record.sh"
  chmod +x "$mutant_dir/design-record.sh"

  run env PROJECT_ROOT="$TEST_TMP" /bin/bash "$mutant_dir/design-record.sh" init-not-applicable --actor "test"
  [ "$status" -ne 0 ] || fail "expected non-zero exit on set -u abort in init-not-applicable"
}

@test "success path exits 0" {
  _create_v1_record
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "success path should exit 0: $output"
}

@test "static: each trap body contains the exact error-forcing clause" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  # Each trap '...' EXIT line must contain the exact forcing clause
  local trap_lines
  trap_lines="$(grep -n "trap '.*' EXIT" "$DREC_SCRIPT" | grep -v "trap - EXIT" || true)"

  [ -n "$trap_lines" ] || fail "no trap lines found"

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Every trap must contain the exact forcing clause
    if ! printf '%s' "$line" | grep -qF '[ "$_rc" -eq 0 ] && _rc=1'; then
      fail "trap at $line lacks exact error-forcing clause: [ \"\$_rc\" -eq 0 ] && _rc=1"
    fi
  done <<< "$trap_lines"
}

@test "static: _locked_mutate trap has completion guard and exact error-forcing clause" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  local trap_line
  trap_line="$(grep "trap '.*' EXIT" "$DREC_SCRIPT" | grep -v "trap - EXIT" | head -1)"
  [ -n "$trap_line" ] || fail "no trap EXIT line found in _locked_mutate"

  # Must contain the exact completion guard before the forcing clause
  printf '%s' "$trap_line" | grep -qF '[ "${_DR_DONE:-0}" = 1 ] ||' || \
    fail "_locked_mutate trap lacks completion guard: [ \"\${_DR_DONE:-0}\" = 1 ] ||"
  # Must contain the exact forcing clause
  printf '%s' "$trap_line" | grep -qF '[ "$_rc" -eq 0 ] && _rc=1' || \
    fail "_locked_mutate trap lacks exact error-forcing clause"
}

@test "static: cmd_init trap has exact failure-only forcing clause" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  local trap_line
  trap_line="$(grep "trap '.*' EXIT" "$DREC_SCRIPT" | grep -v "trap - EXIT" | sed -n '2p')"
  [ -n "$trap_line" ] || fail "no second trap EXIT line found (cmd_init)"

  # Must contain the exact forcing clause
  printf '%s' "$trap_line" | grep -qF '[ "$_rc" -eq 0 ] && _rc=1' || \
    fail "cmd_init trap lacks exact error-forcing clause"
}

@test "static: init-not-applicable trap has exact failure-only forcing clause" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  local trap_line
  trap_line="$(grep "trap '.*' EXIT" "$DREC_SCRIPT" | grep -v "trap - EXIT" | sed -n '3p')"
  [ -n "$trap_line" ] || fail "no third trap EXIT line found (cmd_init_not_applicable)"

  # Must contain the exact forcing clause
  printf '%s' "$trap_line" | grep -qF '[ "$_rc" -eq 0 ] && _rc=1' || \
    fail "init-not-applicable trap lacks exact error-forcing clause"
}

@test "migration preserves reference with trailing content: alias equality holds" {
  _create_v1_record
  # Inject a reference with an embedded newline (literal in the YAML scalar)
  _TR=$'ref-with-trailing\n' yq -i '.project.reference = strenv(_TR)' "$RECORD"

  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Alias invariant: assert equality INSIDE yq so trailing newlines cannot be
  # stripped by shell command substitution on either side.
  local eq
  eq="$(yq '.project.reference == .design_system_project.reference' "$RECORD")"
  [ "$eq" = "true" ] || fail "alias invariant broken: yq reports project.reference != design_system_project.reference"
}


# =========================================================================
# Static ordering tests
# =========================================================================

@test "static ordering: _locked_mutate cross-checks after migration before callback and after callback before mv" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  local body
  body="$(_extract_fn_body "_locked_mutate" "$DREC_SCRIPT")"

  # Must contain _migrate_v1_to_v2
  printf '%s' "$body" | grep -q '_migrate_v1_to_v2' || \
    fail "_locked_mutate missing _migrate_v1_to_v2"

  # Must contain _validate_project_references
  printf '%s' "$body" | grep -q '_validate_project_references' || \
    fail "_locked_mutate missing _validate_project_references"

  # Order: migrate before callback, cross-check before callback AND before mv
  local migrate_line callback_line mv_line
  migrate_line="$(printf '%s' "$body" | grep -n '_migrate_v1_to_v2' | head -1 | cut -d: -f1)"
  callback_line="$(printf '%s' "$body" | grep -n '"$callback"' | head -1 | cut -d: -f1)"
  mv_line="$(printf '%s' "$body" | grep -n 'mv -f' | head -1 | cut -d: -f1)"

  [ -n "$migrate_line" ] || fail "migrate line not found"
  [ -n "$callback_line" ] || fail "callback line not found"
  [ -n "$mv_line" ] || fail "mv line not found"

  [ "$migrate_line" -lt "$callback_line" ] || \
    fail "migration ($migrate_line) must come before callback ($callback_line)"

  # Two cross-check calls: one before callback, one before mv
  local cross_check_lines
  cross_check_lines="$(printf '%s\n' "$body" | grep -n '_validate_project_references' | cut -d: -f1)"
  local count
  count="$(printf '%s\n' "$body" | grep -c '_validate_project_references')"
  [ "$count" -ge 2 ] || fail "expected at least 2 _validate_project_references calls, found $count"

  # First cross-check before callback
  local first_check
  first_check="$(printf '%s' "$cross_check_lines" | head -1)"
  [ "$first_check" -lt "$callback_line" ] || \
    fail "first cross-check ($first_check) must come before callback ($callback_line)"

  # Second cross-check before mv
  local second_check
  second_check="$(printf '%s' "$cross_check_lines" | tail -1)"
  [ "$second_check" -lt "$mv_line" ] || \
    fail "second cross-check ($second_check) must come before mv ($mv_line)"
  [ "$second_check" -gt "$callback_line" ] || \
    fail "second cross-check ($second_check) must come after callback ($callback_line)"
}

@test "static ordering: cmd_init cross-check before mv" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  local body
  body="$(_extract_fn_body "cmd_init" "$DREC_SCRIPT")"

  printf '%s' "$body" | grep -q '_validate_project_references' || \
    fail "cmd_init missing _validate_project_references"

  local check_line mv_line
  check_line="$(printf '%s' "$body" | grep -n '_validate_project_references' | head -1 | cut -d: -f1)"
  mv_line="$(printf '%s' "$body" | grep -n 'mv -f' | head -1 | cut -d: -f1)"

  [ "$check_line" -lt "$mv_line" ] || \
    fail "cross-check ($check_line) must come before mv ($mv_line) in cmd_init"
}


# =========================================================================
# Questionnaire-record file existence check — all discovered-via values
# =========================================================================

@test "init skip path: --questionnaire-record nonexistent file rejected" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" \
    --questionnaire-record "no/such/file.md" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for nonexistent file on skip path"
  [[ "$output" == *"not found"* ]] || fail "expected 'not found' diagnostic, got: $output"
}

@test "init skip path: --questionnaire-record empty value rejected" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" \
    --questionnaire-record "" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for empty questionnaire-record"
  [[ "$output" == *"empty"* ]] || fail "expected 'empty' diagnostic, got: $output"
}

@test "init skip path: --questionnaire-record existing file accepted and stored" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  mkdir -p "$TEST_TMP/docs"
  touch "$TEST_TMP/docs/q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" \
    --questionnaire-record "docs/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local qr
  qr="$(yq '.project.questionnaire_record' "$RECORD")"
  [ "$qr" = "docs/q.md" ] || fail "stored=$qr, expected docs/q.md"
}

@test "reopen-applicable skip path: --questionnaire-record nonexistent file rejected" {
  _create_na_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" --discovered-via "project-artifacts" \
    --questionnaire-record "no/such/file.md" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for nonexistent file on skip path"
  [[ "$output" == *"not found"* ]] || fail "expected 'not found' diagnostic, got: $output"
}

@test "reopen-applicable skip path: --questionnaire-record empty value rejected" {
  _create_na_record

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" --discovered-via "project-artifacts" \
    --questionnaire-record "" --actor "test"
  [ "$status" -ne 0 ] || fail "expected rejection for empty questionnaire-record"
  [[ "$output" == *"empty"* ]] || fail "expected 'empty' diagnostic, got: $output"
}


# =========================================================================
# Not-applicable sentinel migration — null sub-documents for NA records
# =========================================================================

@test "direct _migrate_v1_to_v2 on NA sentinel: both projects null, sync/dam absent" {
  _create_na_record
  # Downgrade to v1 so migration runs
  yq -i '.schema_version = "1.0"' "$RECORD"
  yq -i 'del(.design_system_project)' "$RECORD"
  yq -i 'del(.product_design_project)' "$RECORD"

  # Source script and call migration directly
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    _migrate_v1_to_v2 "$RECORD"
  ) || fail "direct migration failed"

  local sv
  sv="$(yq '.schema_version' "$RECORD")"
  [ "$sv" = "2.0" ] || fail "schema_version=$sv"

  # Assert keys EXIST (has() == true) with null values — dropping a null
  # assignment would make has() return false, which value-reading misses
  local has_dsp has_pdp
  has_dsp="$(yq 'has("design_system_project")' "$RECORD")"
  has_pdp="$(yq 'has("product_design_project")' "$RECORD")"
  [ "$has_dsp" = "true" ] || fail "design_system_project key absent — null assignment was dropped"
  [ "$has_pdp" = "true" ] || fail "product_design_project key absent — null assignment was dropped"

  local dsp pdp
  dsp="$(yq '.design_system_project' "$RECORD")"
  pdp="$(yq '.product_design_project' "$RECORD")"
  [ "$dsp" = "null" ] || fail "design_system_project=$dsp, expected null"
  [ "$pdp" = "null" ] || fail "product_design_project=$pdp, expected null"

  # sync_mode and ds_attachment_mode must be ABSENT (has() in separate yq calls)
  local has_sm has_dam
  has_sm="$(yq 'has("sync_mode")' "$RECORD")"
  has_dam="$(yq 'has("ds_attachment_mode")' "$RECORD")"
  [ "$has_sm" = "false" ] || fail "sync_mode should be absent on NA sentinel migration"
  [ "$has_dam" = "false" ] || fail "ds_attachment_mode should be absent on NA sentinel migration"
}

@test "direct _migrate_v1_to_v2 on real-ref + not-applicable: gets token-by-value" {
  _create_na_record
  # Downgrade to v1
  yq -i '.schema_version = "1.0"' "$RECORD"
  yq -i 'del(.design_system_project)' "$RECORD"
  yq -i 'del(.product_design_project)' "$RECORD"
  # Set real reference while keeping not-applicable
  _RA_REF="real-ds-ref" yq -i '.project.reference = strenv(_RA_REF)' "$RECORD"
  _RA_DV="project-artifacts" yq -i '.project.discovered_via = strenv(_RA_DV)' "$RECORD"

  # Source and migrate directly
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    _migrate_v1_to_v2 "$RECORD"
  ) || fail "direct migration failed"

  local sv dsp_ref dam
  sv="$(yq '.schema_version' "$RECORD")"
  [ "$sv" = "2.0" ] || fail "schema_version=$sv"

  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$dsp_ref" = "real-ds-ref" ] || fail "dsp ref=$dsp_ref"

  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode=$dam, expected token-by-value"
}

@test "NA sentinel migration via mutating verb: projects null, sync/dam absent" {
  _create_na_record
  # Downgrade to v1
  yq -i '.schema_version = "1.0"' "$RECORD"
  yq -i 'del(.design_system_project)' "$RECORD"
  yq -i 'del(.product_design_project)' "$RECORD"

  # Trigger via not-applicable verb (delegates to cmd_not_applicable on existing record)
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" not-applicable --actor "test"
  [ "$status" -eq 0 ] || fail "not-applicable failed: $output"

  # Assert keys exist with null values (has() catches dropped null assignments)
  local has_dsp has_pdp
  has_dsp="$(yq 'has("design_system_project")' "$RECORD")"
  has_pdp="$(yq 'has("product_design_project")' "$RECORD")"
  [ "$has_dsp" = "true" ] || fail "design_system_project key absent"
  [ "$has_pdp" = "true" ] || fail "product_design_project key absent"

  local dsp pdp
  dsp="$(yq '.design_system_project' "$RECORD")"
  pdp="$(yq '.product_design_project' "$RECORD")"
  [ "$dsp" = "null" ] || fail "design_system_project=$dsp"
  [ "$pdp" = "null" ] || fail "product_design_project=$pdp"

  local has_sm has_dam
  has_sm="$(yq 'has("sync_mode")' "$RECORD")"
  has_dam="$(yq 'has("ds_attachment_mode")' "$RECORD")"
  [ "$has_sm" = "false" ] || fail "sync_mode should be absent"
  [ "$has_dam" = "false" ] || fail "ds_attachment_mode should be absent"
}


# =========================================================================
# Field mapping assertions — surface, discovered_via, identity on re-migration
# =========================================================================

@test "migration sets surface to designsync" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  local surface
  surface="$(yq '.design_system_project.surface' "$RECORD")"
  [ "$surface" = "designsync" ] || fail "surface=$surface, expected designsync"
}

@test "migration copies discovered_via from project (integration-list fixture)" {
  _create_v1_record "ds-ref" "integration-list"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  local dv
  dv="$(yq '.design_system_project.discovered_via' "$RECORD")"
  [ "$dv" = "integration-list" ] || fail "discovered_via=$dv, expected integration-list"
}

@test "re-migration is byte-identical (sha256 comparison)" {
  _create_v1_record "ds-ref"
  # Trigger migration
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "first transition failed: $output"

  local hash_before
  hash_before="$(_sha256_file "$RECORD")"

  # Copy and run migration again
  local copy="$TEST_TMP/re-migration-copy.yaml"
  cp "$RECORD" "$copy"
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    _migrate_v1_to_v2 "$copy"
  ) || fail "re-migration failed"

  local hash_after
  hash_after="$(_sha256_file "$copy")"
  [ "$hash_before" = "$hash_after" ] || fail "re-migration not byte-identical: $hash_before vs $hash_after"
}

@test "migration preserves non-project fields as JSON (structural comparison)" {
  _create_v1_record "ds-ref"

  # Capture non-project fields before migration
  local before_json
  before_json="$(yq -o=json 'del(.schema_version, .project, .design_system_project, .product_design_project, .sync_mode, .ds_attachment_mode)' "$RECORD")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Same fields after migration (excluding transition-added state change and audit)
  local after_json
  after_json="$(yq -o=json 'del(.schema_version, .project, .design_system_project, .product_design_project, .sync_mode, .ds_attachment_mode, .design_state, .iteration, .audit, .audit_head)' "$RECORD")"

  local before_subset
  before_subset="$(yq -o=json 'del(.design_state, .iteration, .audit, .audit_head)' <<< "$before_json")"

  [ "$before_subset" = "$after_json" ] || fail "non-project fields changed: before=$before_subset, after=$after_json"
}


# =========================================================================
# Schema validation via validate_artifact_schema — full-document checks
# =========================================================================

@test "schema: migrated applicable record is schema-valid" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema validation failed on migrated record: $output"
}

@test "schema: migrated NA-sentinel record is schema-valid" {
  _create_na_record
  yq -i '.schema_version = "1.0"' "$RECORD"
  yq -i 'del(.design_system_project)' "$RECORD"
  yq -i 'del(.product_design_project)' "$RECORD"
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    _migrate_v1_to_v2 "$RECORD"
  ) || fail "migration failed"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema validation failed on NA-sentinel: $output"
}

@test "schema: init output is schema-valid" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema validation failed on init output: $output"
}

@test "schema: init with --pd-reference is schema-valid" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema validation failed on init+pd: $output"
}

@test "schema: init-not-applicable output is schema-valid" {
  _create_na_record

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema validation failed on init-not-applicable: $output"
}

@test "schema: set-product-project on draft is schema-valid" {
  _create_v1_record "ds-ref"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema validation failed on set-product-project/draft: $output"
}

@test "schema: set-product-project on review (stale transition) is schema-valid" {
  _create_v1_record "ds-ref" "project-artifacts"
  _advance_to_state review
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema validation failed on set-product-project/review: $output"
}

@test "schema: review_coverage combos are schema-valid" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"

  # review_coverage is an array of enum values: design-system, product-design
  # Test: empty array
  local copy="$TEST_TMP/rc-empty.yaml"
  cp "$RECORD" "$copy"
  yq -i '.review_coverage = []' "$copy"
  run validate_artifact_schema "$SCHEMA" "$copy"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema rejected empty review_coverage: $output"

  # Test: single element
  copy="$TEST_TMP/rc-single.yaml"
  cp "$RECORD" "$copy"
  yq -i '.review_coverage = ["design-system"]' "$copy"
  run validate_artifact_schema "$SCHEMA" "$copy"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema rejected single review_coverage: $output"

  # Test: both elements
  copy="$TEST_TMP/rc-both.yaml"
  cp "$RECORD" "$copy"
  yq -i '.review_coverage = ["design-system", "product-design"]' "$copy"
  run validate_artifact_schema "$SCHEMA" "$copy"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -eq 0 ] || fail "schema rejected both review_coverage: $output"
}

@test "schema: bogus ds_attachment_mode rejected by schema" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  # Inject bogus ds_attachment_mode
  yq -i '.ds_attachment_mode = "bogus"' "$RECORD"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -ne 0 ] || fail "schema should reject bogus ds_attachment_mode"
}


# =========================================================================
# Injection tests — hostile payloads in reference arguments
# =========================================================================

@test "hostile payloads in --ds-reference and --pd-reference round-trip safely" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  local ds_payload='ds"; rm -rf / #'
  local pd_payload='pd$(whoami) `id`'

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "$ds_payload" --pd-reference "$pd_payload" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init with hostile payloads failed: $output"

  local stored_ds stored_pd
  stored_ds="$(yq '.design_system_project.reference' "$RECORD")"
  stored_pd="$(yq '.product_design_project.reference' "$RECORD")"

  [ "$stored_ds" = "$ds_payload" ] || fail "ds round-trip broken: '$stored_ds'"
  [ "$stored_pd" = "$pd_payload" ] || fail "pd round-trip broken: '$stored_pd'"
}


# =========================================================================
# check-convergence — schema version diagnostic on unknown versions
# =========================================================================

@test "check-convergence accepts 1.0 and 2.0 without unknown-schema diagnostic" {
  # v1.0
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" check-convergence 2>&1
  [[ "$output" != *"unknown schema_version"* ]] || fail "1.0 should not produce schema version diagnostic"

  # Trigger migration to v2.0
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" check-convergence 2>&1
  [[ "$output" != *"unknown schema_version"* ]] || fail "2.0 should not produce schema version diagnostic"
}

@test "check-convergence rejects 9.9 with unknown-schema diagnostic" {
  _create_v1_record "ds-ref" "project-artifacts"
  yq -i '.schema_version = "9.9"' "$RECORD"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" check-convergence
  [ "$status" -ne 0 ] || fail "expected rejection for 9.9"
  [[ "$output" == *"unknown schema_version"* ]] || [[ "$output" == *"9.9"* ]] || \
    fail "expected schema version diagnostic, got: $output"
}


# =========================================================================
# INFO items: surface "artifact", discovered_via alias, NA cross-check
# =========================================================================

@test "init with --pd-reference sets product_design_project.surface to artifact" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "ds-ref" --pd-reference "pd-ref" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local surface
  surface="$(yq '.product_design_project.surface' "$RECORD")"
  [ "$surface" = "artifact" ] || fail "surface=$surface, expected artifact"
}

@test "init project/design_system_project discovered_via alias equality" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "ref" --discovered-via "integration-list" --actor "test"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local proj_dv dsp_dv
  proj_dv="$(yq '.project.discovered_via' "$RECORD")"
  dsp_dv="$(yq '.design_system_project.discovered_via' "$RECORD")"
  [ "$proj_dv" = "$dsp_dv" ] || fail "alias broken: project=$proj_dv, dsp=$dsp_dv"
}

@test "null design_system_project allowed on NA: mutating verb passes" {
  _create_na_record

  # Use a mutating verb (not just verify-integrity) to exercise cross-check
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" not-applicable --actor "test"
  [ "$status" -eq 0 ] || fail "not-applicable (idempotent) failed: $output"

  local dsp
  dsp="$(yq '.design_system_project' "$RECORD")"
  [ "$dsp" = "null" ] || fail "design_system_project=$dsp, expected null"
}


# =========================================================================
# Newline/comma-safe migration probe — user data never reaches shell split
# =========================================================================

@test "reference containing a newline survives migration and subsequent mutations" {
  # A reference with embedded newlines must not break the migration probe's CSV
  # parsing. After init + set-product-project + transition, all three new v2
  # fields must survive (product_design_project, sync_mode, ds_attachment_mode).
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  local nl_ref
  nl_ref=$'line1\nline2\nline3'
  _NL_REF="$nl_ref" env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "__PLACEHOLDER__" --discovered-via "project-artifacts" --actor "test"
  # Inject the newline reference via strenv (init sanitises but we want it raw)
  _NL_REF="$nl_ref" yq -i '.project.reference = strenv(_NL_REF) | .design_system_project.reference = strenv(_NL_REF)' "$RECORD"

  # set-product-project should not re-migrate (already v2)
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "pd-ref" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project after newline-ref init failed: $output"

  # transition should not wipe product_design_project
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition after set-product-project failed: $output"

  local pdp sync dam
  pdp="$(yq '.product_design_project.reference' "$RECORD")"
  sync="$(yq '.sync_mode' "$RECORD")"
  dam="$(yq '.ds_attachment_mode' "$RECORD")"
  [ "$pdp" = "pd-ref" ] || fail "product_design_project.reference lost: $pdp"
  [ "$sync" = "react-components" ] || fail "sync_mode lost: $sync"
  [ "$dam" = "token-by-value" ] || fail "ds_attachment_mode lost: $dam"
}

@test "NA record with comma in reference value does not hit applicable migration branch" {
  # A not-applicable v1 record whose reference is "not-applicable,legacy-ds"
  # must NOT be treated as a pure NA sentinel (both fields == "not-applicable").
  # It should hit the applicable branch and get design_system_project populated.
  _create_v1_record "not-applicable,legacy-ds" "project-artifacts"
  yq -i '.applicability = "not-applicable"' "$RECORD"
  _NA_REF="not-applicable,legacy-ds" yq -i '.project.reference = strenv(_NA_REF)' "$RECORD"

  # Source and migrate directly
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    _migrate_v1_to_v2 "$RECORD"
  ) || fail "direct migration failed"

  # Should NOT be null — the reference is not exactly "not-applicable"
  local dsp_ref
  dsp_ref="$(yq '.design_system_project.reference' "$RECORD")"
  [ "$dsp_ref" = "not-applicable,legacy-ds" ] || fail "design_system_project.reference=$dsp_ref, expected the comma-bearing value"

  # Should have sync_mode (applicable branch sets it)
  local has_sm
  has_sm="$(yq 'has("sync_mode")' "$RECORD")"
  [ "$has_sm" = "true" ] || fail "sync_mode absent — hit NA branch instead of applicable"
}


# =========================================================================
# Migration preserves reviews, approvals, overrides, and audit chain
# =========================================================================

@test "migration preserves reviews, approvals, overrides, audit and audit_head" {
  # Build a rich v1 record in review state with populated governance fields
  _create_v1_record "ds-ref" "project-artifacts"

  # Advance to review so the record is non-draft
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"

  # Add a review
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-review \
    --reviewer "reviewer-1" --verdict "approved" --actor "test"

  # Add a second review for richer data
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-review \
    --reviewer "reviewer-2" --verdict "changes-requested" --actor "test"

  # Add approval
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" approve \
    --stakeholder "stakeholder-A" --recorded-by "test"

  # Add override
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-override \
    --reason "deadline pressure" --actor "test" --entry-point "test-gate"

  # Now downgrade to v1 (strip v2 keys only — keep all governance fields)
  yq -i '.schema_version = "1.0"' "$RECORD"
  yq -i 'del(.design_system_project)' "$RECORD"
  yq -i 'del(.product_design_project)' "$RECORD"
  yq -i 'del(.sync_mode)' "$RECORD"
  yq -i 'del(.ds_attachment_mode)' "$RECORD"

  # Snapshot everything except the 5 migration-touched keys
  local before_json
  before_json="$(yq -o=json 'del(.schema_version, .design_system_project, .product_design_project, .sync_mode, .ds_attachment_mode)' "$RECORD")"

  # Run migration directly
  local copy="$TEST_TMP/rich-v1-copy.yaml"
  cp "$RECORD" "$copy"
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    _migrate_v1_to_v2 "$copy"
  ) || fail "direct migration failed"

  # Verify schema upgraded
  local sv
  sv="$(yq '.schema_version' "$copy")"
  [ "$sv" = "2.0" ] || fail "schema_version=$sv"

  # Snapshot the same keys after migration
  local after_json
  after_json="$(yq -o=json 'del(.schema_version, .design_system_project, .product_design_project, .sync_mode, .ds_attachment_mode)' "$copy")"

  # The non-migration fields must be identical
  [ "$before_json" = "$after_json" ] || fail "migration altered non-migration fields"
}


# =========================================================================
# Negative schema validation — rejected documents
# =========================================================================

@test "schema rejects applicable record with null design_system_project" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  # Null out design_system_project on an applicable record
  yq -i '.design_system_project = null' "$RECORD"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -ne 0 ] || fail "schema should reject null design_system_project on applicable record"
}

@test "schema rejects applicable record with deleted design_system_project key" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  yq -i 'del(.design_system_project)' "$RECORD"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -ne 0 ] || fail "schema should reject missing design_system_project key"
}

@test "schema rejects applicable record with deleted product_design_project key" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  yq -i 'del(.product_design_project)' "$RECORD"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -ne 0 ] || fail "schema should reject missing product_design_project key"
}

@test "schema rejects review_coverage with invalid enum value" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  yq -i '.review_coverage = ["bogus"]' "$RECORD"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -ne 0 ] || fail "schema should reject bogus review_coverage item"
}

@test "schema rejects review_coverage with duplicate items" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  yq -i '.review_coverage = ["design-system", "design-system"]' "$RECORD"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -ne 0 ] || fail "schema should reject duplicate review_coverage items"
}

@test "schema rejects empty product_design_project reference" {
  _create_v1_record "ds-ref" "project-artifacts"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor "test"
  [ "$status" -eq 0 ] || fail "transition failed: $output"

  yq -i '.product_design_project.reference = "" | .product_design_project.type = "design" | .product_design_project.surface = "artifact" | .product_design_project.discovered_via = "existing"' "$RECORD"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || skip "schema validation backend absent"
  [ "$status" -ne 0 ] || fail "schema should reject empty product reference"
}


# =========================================================================
# Injection safety — set-product-project and reopen-applicable
# =========================================================================

@test "set-product-project: hostile --pd-reference stored verbatim" {
  _create_v1_record "ds-ref" "project-artifacts"

  local payload='pd" | .iteration = 42 | .x = "y'
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "$payload" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project with hostile payload failed: $output"

  local stored
  stored="$(yq '.product_design_project.reference' "$RECORD")"
  [ "$stored" = "$payload" ] || fail "round-trip broken: '$stored'"

  # iteration must NOT be 42 (injection attempt)
  local iter
  iter="$(yq '.iteration' "$RECORD")"
  [ "$iter" != "42" ] || fail "injection succeeded: iteration was overwritten to 42"
}

@test "set-product-project: quotes and command substitution in --pd-reference" {
  _create_v1_record "ds-ref" "project-artifacts"

  local payload='$(whoami) `id` "double" '\''single'\'''
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" set-product-project \
    --pd-reference "$payload" --discovered-via existing --actor "test"
  [ "$status" -eq 0 ] || fail "set-product-project failed: $output"

  local stored
  stored="$(yq '.product_design_project.reference' "$RECORD")"
  [ "$stored" = "$payload" ] || fail "round-trip broken: '$stored'"
}

@test "reopen-applicable: hostile --pd-reference stored verbatim" {
  _create_na_record

  local payload='pd" | .iteration = 42 | .x = "y'
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "new-ref" --pd-reference "$payload" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen-applicable with hostile payload failed: $output"

  local stored
  stored="$(yq '.product_design_project.reference' "$RECORD")"
  [ "$stored" = "$payload" ] || fail "round-trip broken: '$stored'"

  local iter
  iter="$(yq '.iteration' "$RECORD")"
  [ "$iter" != "42" ] || fail "injection succeeded: iteration was overwritten to 42"
}

@test "reopen-applicable: backticks and dollar-paren in --pd-reference" {
  _create_na_record

  local payload='`id` $(whoami)'
  mkdir -p "$TEST_TMP/path/to"
  touch "$TEST_TMP/path/to/q.md"
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "new-ref" --pd-reference "$payload" \
    --discovered-via "created" --questionnaire-record "path/to/q.md" --actor "test"
  [ "$status" -eq 0 ] || fail "reopen-applicable failed: $output"

  local stored
  stored="$(yq '.product_design_project.reference' "$RECORD")"
  [ "$stored" = "$payload" ] || fail "round-trip broken: '$stored'"
}


# =========================================================================
# Not-applicable migration governance preservation
# =========================================================================

@test "not-applicable migration preserves reviews, approvals, overrides, audit and audit_head" {
  # Build a not-applicable v1 record with populated governance fields.
  # Create a normal v1 record first, then convert to the NA sentinel shape.
  _create_v1_record "real-ds-ref" "project-artifacts"

  # Convert to NA sentinel shape (applicability + reference both set to sentinel)
  yq -i '.applicability = "not-applicable" | .project.reference = "not-applicable"' "$RECORD"

  # Populate governance fields (direct yq — building fixture, not testing init)
  yq -i '.reviews = [{"reviewer": "r1", "verdict": "approved"}, {"reviewer": "r2", "verdict": "changes-requested"}]' "$RECORD"
  yq -i '.approvals = [{"stakeholder": "stakeholder-A", "recorded_by": "test"}]' "$RECORD"
  yq -i '.overrides = [{"reason": "deadline", "actor": "test", "entry_point": "gate"}]' "$RECORD"

  # Populate audit with at least 2 entries
  yq -i '.audit = [{"action": "init", "actor": "test", "ts": "2026-01-01T00:00:00Z"}, {"action": "transition", "actor": "test", "ts": "2026-01-01T01:00:00Z"}]' "$RECORD"
  yq -i '.audit_head = {"last_digest": "abc123", "iteration": 2}' "$RECORD"

  # Snapshot everything except the 5 migration-touched keys
  local before_json
  before_json="$(yq -o=json 'del(.schema_version, .design_system_project, .product_design_project, .sync_mode, .ds_attachment_mode)' "$RECORD")"

  # Run migration directly on a copy
  local copy="$TEST_TMP/na-rich-v1-copy.yaml"
  cp "$RECORD" "$copy"
  (
    # shellcheck source=../scripts/design-record.sh
    _GAIA_DREC_SOURCED=1 source "$DREC_SCRIPT" 2>/dev/null
    _migrate_v1_to_v2 "$copy"
  ) || fail "direct migration failed"

  # Verify schema upgraded
  local sv
  sv="$(yq '.schema_version' "$copy")"
  [ "$sv" = "2.0" ] || fail "schema_version=$sv"

  # Snapshot the same keys after migration
  local after_json
  after_json="$(yq -o=json 'del(.schema_version, .design_system_project, .product_design_project, .sync_mode, .ds_attachment_mode)' "$copy")"

  # The non-migration fields must be identical
  [ "$before_json" = "$after_json" ] || fail "NA migration altered non-migration fields"
}


# =========================================================================
# Injection safety — init with double-quote and yq pipe fragment
# =========================================================================

@test "init: hostile --pd-reference with double quote and yq pipe fragment stored verbatim" {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  local payload='pd" | .iteration = 42 | .x = "y'
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --ds-reference "safe-ds-ref" --pd-reference "$payload" \
    --discovered-via "project-artifacts" --actor "test"
  [ "$status" -eq 0 ] || fail "init with hostile pd-reference failed: $output"

  local stored
  stored="$(yq '.product_design_project.reference' "$RECORD")"
  [ "$stored" = "$payload" ] || fail "round-trip broken: '$stored'"

  # injection must not have overwritten iteration
  local iter
  iter="$(yq '.iteration' "$RECORD")"
  [ "$iter" != "42" ] || fail "injection succeeded: iteration was overwritten to 42"

  # no spurious .x key
  local has_x
  has_x="$(yq 'has("x")' "$RECORD")"
  [ "$has_x" = "false" ] || fail "injection succeeded: spurious .x key present"
}


# =========================================================================
# Static assertion — completion marker initialisation
# =========================================================================

@test "static: _locked_mutate completion marker initialised to zero" {
  [ -f "$DREC_SCRIPT" ] || fail "design-record.sh not found"

  # The completion marker must start at exactly _DR_DONE=0.
  # Initialising to 1 would bypass the trap's error-forcing clause on Linux.
  grep -qF '_DR_DONE=0' "$DREC_SCRIPT" || \
    fail "_locked_mutate missing exact _DR_DONE=0 initialisation"
}


# =========================================================================
# SKILL.md structural test — v2 field paths and skip-path documentation
# =========================================================================

@test "SKILL.md record-step mentions auto-store skipped sentinel" {
  local skill_file="$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  [ -f "$skill_file" ] || fail "SKILL.md not found"

  # The "Record the selection" step must explain that the skip path does not
  # pass --questionnaire-record (the writer auto-stores "skipped").
  local record_step
  record_step="$(grep 'Record the selection' "$skill_file")"
  [ -n "$record_step" ] || fail "Record the selection step not found"

  # Must mention "skipped" (auto-store) and NOT say the skip path passes the path
  printf '%s' "$record_step" | grep -q 'skipped' || \
    fail "step 2.5 should mention auto-store 'skipped'"
}
