#!/usr/bin/env bats
# grype-trust-boundary.bats — E70-S9 Grype DB trust-boundary enforcement.
#
# Story: E70-S9. FR-542 / ADR-122. ADR-078 (master flag + per-tool override).
#
# adapter.sh treats the Grype vulnerability DB as a trust boundary distinct from
# the binary: enforces GRYPE_DB_MAX_ALLOWED_BUILT_AGE=5d (+ override guard),
# records grype_db_checksum + grype_db_built_age, and REJECTS a mid-session DB
# checksum drift (consuming E70-S7's session-start checksum log). Trivy Mar-2026
# precedent.
#
# Offline + deterministic: a fake `grype` shim emits `db status --output json`
# (path + built timestamp) and a controllable exit; a mock DB file whose bytes
# (and thus sha256) can be rewritten between invocations exercises drift.

load '../test_helper.bash'

setup() {
  common_setup
  ADAPTER="$(cd "$BATS_TEST_DIRNAME/../../scripts/adapters/grype" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../../scripts/adapters/grype")/adapter.sh"
  export ADAPTER
  FAKE_BIN="$TEST_TMP/bin"; mkdir -p "$FAKE_BIN"; export FAKE_BIN
  # Mock DB file + audit dir (E70-S7 checksum-log location seam).
  export GAIA_GRYPE_DB_FILE="$TEST_TMP/grype-db.sqlite"
  export GAIA_BROWNFIELD_AUDIT_DIR="$TEST_TMP/brownfield-audit"
  mkdir -p "$GAIA_BROWNFIELD_AUDIT_DIR"
  export GAIA_SESSION_ID="sess-1"
  printf 'grype-db-v1-content\n' > "$GAIA_GRYPE_DB_FILE"
  _mk_grype 0 "2026-05-24T00:00:00Z"
}
teardown() { common_teardown; }

# Fake grype: `grype db status --output json` prints {path, built, schemaVersion};
# a bare scan invocation exits with $GRYPE_RC (default 0). GRYPE_RC simulates the
# GRYPE_DB_MAX_ALLOWED_BUILT_AGE=5d failure (grype itself exits non-zero on stale DB).
_mk_grype() {
  local rc="$1" built="$2"
  cat > "$FAKE_BIN/grype" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "db" ] && [ "\$2" = "status" ]; then
  printf '{"path":"%s","built":"%s","schemaVersion":5}\n' "$GAIA_GRYPE_DB_FILE" "$built"
  exit 0
fi
# A scan invocation. Honor the max-age contract: if GRYPE_DB_MAX_ALLOWED_BUILT_AGE
# is set and the (test-injected) GRYPE_RC says stale, fail like real grype would.
exit ${rc}
EOF
  chmod +x "$FAKE_BIN/grype"
}

# Seed a session-start checksum-log row (the E70-S7 producer schema).
seed_checksum_log() {
  local checksum="$1"
  printf '{"ts":"2026-05-25T00:00:00Z","session_id":"%s","checksum":"%s","db_built_age_seconds":3600}\n' \
    "$GAIA_SESSION_ID" "$checksum" >> "$GAIA_BROWNFIELD_AUDIT_DIR/grype-db-checksum.log"
}

db_sha() { shasum -a 256 "$GAIA_GRYPE_DB_FILE" | awk '{print $1}'; }

run_adapter() {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_GRYPE_ENABLED=true \
    run bash "$ADAPTER" "$@"
}

# --- AC1 — max-age env + override guard -----------------------------------

@test "E70-S9 AC1: adapter sets GRYPE_DB_MAX_ALLOWED_BUILT_AGE=5d (asserted via debug echo)" {
  seed_checksum_log "$(db_sha)"
  GAIA_GRYPE_DEBUG=1 run_adapter
  [ "$status" -eq 0 ]
  [[ "$output" == *"GRYPE_DB_MAX_ALLOWED_BUILT_AGE=5d"* ]]
}

@test "E70-S9 AC1 (scenario 5): inherited override != 5d is rejected at pre-flight (default FAIL)" {
  seed_checksum_log "$(db_sha)"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_GRYPE_ENABLED=true \
    GRYPE_DB_MAX_ALLOWED_BUILT_AGE=30d run bash "$ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"override rejected"* ]]
}

# --- AC2 — checksum + built-age telemetry ---------------------------------

@test "E70-S9 AC2: cold scan succeeds and surfaces grype_db_checksum + grype_db_built_age" {
  seed_checksum_log "$(db_sha)"
  run_adapter
  [ "$status" -eq 0 ]
  [[ "$output" == *"grype_db_checksum"* ]]
  [[ "$output" == *"grype_db_built_age"* ]]
}

# --- AC3 / scenario 3 — mid-session DB swap → reject ----------------------

@test "E70-S9 AC3: mid-session DB checksum drift is REJECTED with the exact error vocabulary" {
  # Session-start checksum was the v1 content; now swap the DB to v2.
  seed_checksum_log "$(db_sha)"
  printf 'grype-db-v2-TAMPERED\n' > "$GAIA_GRYPE_DB_FILE"
  run_adapter
  [ "$status" -ne 0 ]
  [[ "$output" == *"Grype DB checksum drift detected mid-session"* ]]
  [[ "$output" == *"session=$GAIA_SESSION_ID"* ]]
  [[ "$output" == *"expected="* ]]
  [[ "$output" == *"actual="* ]]
}

@test "E70-S9 (scenario 2): warm scan with unchanged DB across two invocations — no drift" {
  seed_checksum_log "$(db_sha)"
  run_adapter; [ "$status" -eq 0 ]
  run_adapter; [ "$status" -eq 0 ]
  [[ "$output" != *"drift detected"* ]]
}

# --- AC5 / scenario 4 — DB age > 5d → grype itself fails ------------------

@test "E70-S9 AC5 (scenario 4): stale DB (>5d) causes grype to fail and the adapter propagates it" {
  # Non-vacuous guard (F1 — Tex red review): only meaningful once the adapter exists.
  [ -x "$ADAPTER" ]
  seed_checksum_log "$(db_sha)"
  _mk_grype 1 "2026-05-10T00:00:00Z"   # grype scan exits 1 (simulating max-age failure)
  run_adapter
  [ "$status" -ne 0 ]
}

# --- AC-X1 — flag-off skip ------------------------------------------------

@test "E70-S9 AC-X1: master flag off skips the adapter with INFO, exit 0" {
  seed_checksum_log "$(db_sha)"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
}

@test "E70-S9 AC-X1 (scenario 6): per-tool override off skips the adapter, exit 0" {
  seed_checksum_log "$(db_sha)"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_GRYPE_ENABLED=false run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
}

# --- Graceful degrade — grype absent --------------------------------------

@test "E70-S9: grype binary absent → WARNING + exit 0 (graceful degrade, no scan)" {
  seed_checksum_log "$(db_sha)"
  # PATH without the fake grype.
  PATH="/usr/bin:/bin" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_GRYPE_ENABLED=true \
    GAIA_GRYPE_DB_FILE="$GAIA_GRYPE_DB_FILE" GAIA_BROWNFIELD_AUDIT_DIR="$GAIA_BROWNFIELD_AUDIT_DIR" \
    GAIA_SESSION_ID="$GAIA_SESSION_ID" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
}

# --- AC-X1 flag-resolution integration (resolve-config path) --------------

@test "E70-S9 AC-X1: resolve-config.sh --field brownfield.grype_enabled is whitelisted" {
  cat > "$TEST_TMP/project-config.yaml" <<YAML
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/.gaia/memory
checkpoint_path: /tmp/gaia/.gaia/memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.176.0
date: 2026-05-25
brownfield:
  deterministic_tools: true
  grype_enabled: true
YAML
  cp "$(cd "$BATS_TEST_DIRNAME/../../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/project-config.schema.yaml"
  run bash "$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)/resolve-config.sh" \
    --shared "$TEST_TMP/project-config.yaml" --schema "$TEST_TMP/project-config.schema.yaml" \
    --field brownfield.grype_enabled
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# --- Hygiene --------------------------------------------------------------

@test "E70-S9: adapter.sh exists, is executable, passes bash -n" {
  [ -x "$ADAPTER" ]
  run bash -n "$ADAPTER"
  [ "$status" -eq 0 ]
}
