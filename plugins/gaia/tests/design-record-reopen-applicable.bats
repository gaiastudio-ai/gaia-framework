#!/usr/bin/env bats
# design-record-reopen-applicable.bats — tests for the reopen-applicable verb
# that transitions a not-applicable record back to applicable/draft.

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

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true

  mkdir -p "$TEST_TMP/.gaia/state"

  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _create_na_record — create a not-applicable record via init-not-applicable.
_create_na_record() {
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init-not-applicable --actor "setup"
}

# _create_applicable_record — create a normal applicable record via init.
_create_applicable_record() {
  mkdir -p "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" init \
    --reference "test-ref" \
    --discovered-via "created" \
    --questionnaire-record "path/to/questionnaire.md"
}

# =========================================================================
# Happy path: fields, state, audit entry, chain intact
# =========================================================================

@test "reopen-applicable sets applicability, state, iteration, and project fields" {
  _create_na_record

  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "new-project-ref" \
    --discovered-via "integration-list" \
    --questionnaire-record "path/to/new-questionnaire.md" \
    --actor "reopener"

  local record="$TEST_TMP/.gaia/state/design-record.yaml"
  [ -f "$record" ]

  local app ds iter ref dv qr
  app="$(yq '.applicability' "$record")"
  ds="$(yq '.design_state' "$record")"
  iter="$(yq '.iteration' "$record")"
  ref="$(yq '.project.reference' "$record")"
  dv="$(yq '.project.discovered_via' "$record")"
  qr="$(yq '.project.questionnaire_record' "$record")"

  [ "$app" = "applicable" ]
  [ "$ds" = "draft" ]
  [ "$iter" -eq 1 ]
  [ "$ref" = "new-project-ref" ]
  [ "$dv" = "integration-list" ]
  [ "$qr" = "path/to/new-questionnaire.md" ]
}

@test "reopen-applicable appends applicability-change audit entry with from/to" {
  _create_na_record

  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" \
    --discovered-via "created" \
    --questionnaire-record "q.md" \
    --actor "reopener"

  local record="$TEST_TMP/.gaia/state/design-record.yaml"
  local count
  count="$(yq '.audit | length' "$record")"
  [ "$count" -ge 2 ] || fail "expected at least 2 audit entries, got $count"

  # The last entry must be the applicability-change
  local event from_val to_val
  event="$(yq ".audit[$((count - 1))].event" "$record")"
  from_val="$(yq ".audit[$((count - 1))].from" "$record")"
  to_val="$(yq ".audit[$((count - 1))].to" "$record")"

  [ "$event" = "applicability-change" ]
  [ "$from_val" = "not-applicable" ]
  [ "$to_val" = "applicable" ]
}

@test "reopen-applicable preserves original not-applicable-pass audit entry" {
  _create_na_record

  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" \
    --discovered-via "created" \
    --questionnaire-record "q.md"

  local record="$TEST_TMP/.gaia/state/design-record.yaml"
  local first_event
  first_event="$(yq '.audit[0].event' "$record")"
  [ "$first_event" = "not-applicable-pass" ]
}

@test "reopen-applicable produces a valid audit chain" {
  _create_na_record

  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" \
    --discovered-via "created" \
    --questionnaire-record "q.md"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ]
}

# =========================================================================
# Refusal: already applicable
# =========================================================================

@test "reopen-applicable refuses on an applicable record" {
  _create_applicable_record

  local hash
  hash="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" \
    --discovered-via "created" \
    --questionnaire-record "q.md"
  [ "$status" -ne 0 ]

  # Record must be byte-identical
  local post_hash
  post_hash="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash" = "$post_hash" ]
}

# =========================================================================
# Refusal: missing or invalid inputs — record byte-identical
# =========================================================================

@test "reopen-applicable refuses when --reference is missing" {
  _create_na_record
  local hash
  hash="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --discovered-via "created" \
    --questionnaire-record "q.md"
  [ "$status" -ne 0 ]
  [ "$hash" = "$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")" ]
}

@test "reopen-applicable refuses when --discovered-via is missing" {
  _create_na_record
  local hash
  hash="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" \
    --questionnaire-record "q.md"
  [ "$status" -ne 0 ]
  [ "$hash" = "$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")" ]
}

@test "reopen-applicable refuses when --questionnaire-record is missing" {
  _create_na_record
  local hash
  hash="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" \
    --discovered-via "created"
  [ "$status" -ne 0 ]
  [ "$hash" = "$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")" ]
}

# =========================================================================
# Round trip with special characters
# =========================================================================

@test "reopen-applicable round-trips quotes, dollar, backticks, and newline in reference" {
  _create_na_record

  local hostile_ref
  hostile_ref="$(printf 'ref with "quotes", $dollar, \x60backticks\x60,\nand a newline')"

  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "$hostile_ref" \
    --discovered-via "project-artifacts" \
    --questionnaire-record "q.md"

  local record="$TEST_TMP/.gaia/state/design-record.yaml"
  local stored_ref
  stored_ref="$(yq -r '.project.reference' "$record")"
  [ "$stored_ref" = "$hostile_ref" ]

  # Chain must still be valid after the hostile payload
  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" verify-integrity
  [ "$status" -eq 0 ]
}

# =========================================================================
# Symlink refusal
# =========================================================================

@test "reopen-applicable refuses when record path is a symlink" {
  # Build the real record in a second project root through the writer itself,
  # then point this project's record path at it — no direct file moves.
  local other_root="$TEST_TMP/other-root"
  env PROJECT_ROOT="$other_root" "$DREC_SCRIPT" init-not-applicable --actor "setup"
  local target="$other_root/.gaia/state/design-record.yaml"
  [ -f "$target" ] || fail "fixture record was not created at $target"
  mkdir -p "$TEST_TMP/.gaia/state"
  ln -s "$target" "$TEST_TMP/.gaia/state/design-record.yaml"

  local pre_hash
  pre_hash="$(_sha256_file "$target")"

  run env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" reopen-applicable \
    --reference "ref" \
    --discovered-via "created" \
    --questionnaire-record "q.md"
  [ "$status" -ne 0 ]
  # Match the refusal text only — the temp path itself contains the word.
  printf '%s\n' "${output//$TEST_TMP/}" | grep -qi "symlink" \
    || fail "expected a symlink refusal; got: $output"

  # Real record untouched
  [ "$pre_hash" = "$(_sha256_file "$target")" ]
}
