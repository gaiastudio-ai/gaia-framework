#!/usr/bin/env bats
# design-record-init-not-applicable.bats — tests for the init-not-applicable verb
# added to design-record.sh. Creates a minimal schema-valid not-applicable record
# on a fresh headless project, delegates to the existing not-applicable verb on
# an existing record, refuses symlinks, and publishes via tempfile-then-mv.

load 'test_helper.bash'

fail() { printf '%s\n' "$1" >&2; return 1; }

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

setup() {
  common_setup
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/design-record.sh"
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  export PROJECT_ROOT="$TEST_TMP"
  STATE_DIR="$TEST_TMP/.gaia/state"
  mkdir -p "$STATE_DIR"
  RECORD="$STATE_DIR/design-record.yaml"
  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

_init_existing_record() {
  "$SCRIPT" init \
    --reference "test-ref" \
    --discovered-via "created" \
    --questionnaire-record "path/to/questionnaire.md"
}

# =========================================================================
# (AC-EC1) init-not-applicable verb — fresh project (no record on disk)
# =========================================================================

@test "(AC-EC1) init-not-applicable creates a schema-valid record on fresh project" {
  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ] || fail "init-not-applicable failed: $output"
  [ -f "$RECORD" ] || fail "init-not-applicable did not create $RECORD"

  # Check required fields
  local sv app ds iter ref dv qr
  sv="$(yq '.schema_version' "$RECORD")"
  app="$(yq '.applicability' "$RECORD")"
  ds="$(yq '.design_state' "$RECORD")"
  iter="$(yq '.iteration' "$RECORD")"
  ref="$(yq '.project.reference' "$RECORD")"
  dv="$(yq '.project.discovered_via' "$RECORD")"
  qr="$(yq '.project.questionnaire_record' "$RECORD")"

  [ "$sv" = "1.0" ]
  [ "$app" = "not-applicable" ]
  [ "$ds" = "draft" ]
  [ "$iter" -eq 1 ]
  [ "$ref" = "not-applicable" ]
  [ "$dv" = "project-artifacts" ]
  [ "$qr" = "not-applicable" ]
}

@test "(AC-EC1) init-not-applicable creates a not-applicable-pass audit entry" {
  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ]

  local event actor count
  event="$(yq '.audit[0].event' "$RECORD")"
  actor="$(yq '.audit[0].actor' "$RECORD")"
  count="$(yq '.audit | length' "$RECORD")"

  [ "$event" = "not-applicable-pass" ]
  [ "$actor" = "design-gate" ]
  [ "$count" -eq 1 ]
}

@test "(AC-EC1) init-not-applicable audit entry has a valid chained digest" {
  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ]

  # Verify the chain is valid
  run "$SCRIPT" verify-integrity
  [ "$status" -eq 0 ]
}

@test "(AC-EC1) init-not-applicable has empty arrays for reviews, approvals, overrides" {
  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ]

  local reviews approvals overrides
  reviews="$(yq '.reviews | length' "$RECORD")"
  approvals="$(yq '.approvals | length' "$RECORD")"
  overrides="$(yq '.overrides | length' "$RECORD")"

  [ "$reviews" -eq 0 ]
  [ "$approvals" -eq 0 ]
  [ "$overrides" -eq 0 ]
}

# =========================================================================
# (AC-EC1) init-not-applicable verb — existing record (idempotence)
# =========================================================================

@test "(AC-EC1) init-not-applicable delegates to not-applicable on existing record" {
  _init_existing_record
  [ -f "$RECORD" ]

  local pre_app
  pre_app="$(yq '.applicability' "$RECORD")"
  [ "$pre_app" = "applicable" ]

  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ]

  local post_app
  post_app="$(yq '.applicability' "$RECORD")"
  [ "$post_app" = "not-applicable" ]
}

@test "(AC-EC1) init-not-applicable called twice is idempotent" {
  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ]
  [ -f "$RECORD" ]

  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ]

  local app
  app="$(yq '.applicability' "$RECORD")"
  [ "$app" = "not-applicable" ]
}

# =========================================================================
# (AC-EC1) init-not-applicable verb — symlink refusal
# =========================================================================

@test "(AC-EC1) init-not-applicable refuses symlink at record path" {
  # Create a symlink at the record path
  local target="$TEST_TMP/elsewhere.yaml"
  touch "$target"
  ln -sf "$target" "$RECORD"
  [ -L "$RECORD" ]

  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "symlink"
}

# =========================================================================
# (AC-EC1) init-not-applicable verb — default actor
# =========================================================================

@test "(AC-EC1) init-not-applicable uses default actor when none provided" {
  run "$SCRIPT" init-not-applicable
  [ "$status" -eq 0 ]

  local actor
  actor="$(yq '.audit[0].actor' "$RECORD")"
  # Should be $USER or "unknown", not empty
  [ -n "$actor" ]
  [ "$actor" != "null" ]
}
