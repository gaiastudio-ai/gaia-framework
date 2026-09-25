#!/usr/bin/env bats
# design-stale-transition.bats — driver script for stale-on-change propagation.
#
# Tests the shared design-stale-transition.sh driver that is bang-invoked by
# add-feature and edit-ux SKILL.md. The driver accepts --decision and --actor,
# reads the probe classification via the probe's existing bridge seam
# (DESIGN_PROBE_BRIDGE_CMD), and transitions the record to stale when needed.
#
# Public functions covered: (script entry point, not a library)

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
# Fixture helpers
# ---------------------------------------------------------------------------

seed_config() {
  local ui_present="${1:-true}"
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<EOF
compliance:
  ui_present: $ui_present
EOF
}

seed_roster() {
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"
  cat > "$roster_dir/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
}

_init_record() {
  env PROJECT_ROOT="$TEST_TMP" \
    "$DREC_SCRIPT" init \
      --reference "test-project-ref" \
      --discovered-via "created" \
      --questionnaire-record "not-applicable"
}

_build_approved_record() {
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-review --verdict approved --reviewer stakeholder-A --actor ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to approved --actor ci
}

# _make_bridge_stub STATE EXIT_CODE — create a bridge command stub for
# DESIGN_PROBE_BRIDGE_CMD. Exit codes follow the probe bridge contract:
#   0 = available, 3 = unauthorized, 1 = missing
_make_bridge_stub() {
  local state="$1" exit_code="$2"
  local stub_path="$TEST_TMP/bridge-stub.sh"
  cat > "$stub_path" <<BRIDGEOF
#!/usr/bin/env bash
case "$exit_code" in
  3) printf '%s\n' "unauthorized" >&2; exit 3 ;;
  0) exit 0 ;;
  *) exit 1 ;;
esac
BRIDGEOF
  chmod +x "$stub_path"
  printf '%s' "bash $stub_path"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
  DREC_SCRIPT="$SCRIPTS_DIR/design-record.sh"
  DRIVER_SCRIPT="$SCRIPTS_DIR/design-stale-transition.sh"

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  mkdir -p "$TEST_TMP/.gaia/state"

  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
}

teardown() { common_teardown; }

# ===========================================================================
# Driver script existence
# ===========================================================================

@test "driver script exists at the expected path" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"
}

# ===========================================================================
# AC-EC4 — Probe classification via bridge seam
# ===========================================================================

@test "(AC-EC4) probe available with decision yes transitions and proceeds" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"

  seed_config true
  seed_roster
  _build_approved_record

  local bridge_cmd
  bridge_cmd="$(_make_bridge_stub available 0)"

  local stderr_file="$TEST_TMP/driver-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    DESIGN_PROBE_BRIDGE_CMD="$bridge_cmd" \
    bash "$DRIVER_SCRIPT" \
      --decision yes \
      --actor gaia-add-feature \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 0 ] || fail "driver should exit 0 on available probe but exited $rc"

  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale after --decision yes but is $state"
}

@test "(AC-EC4) probe missing halts with message" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"

  seed_config true
  seed_roster
  _build_approved_record

  local bridge_cmd
  bridge_cmd="$(_make_bridge_stub missing 1)"

  local stderr_file="$TEST_TMP/driver-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    DESIGN_PROBE_BRIDGE_CMD="$bridge_cmd" \
    bash "$DRIVER_SCRIPT" \
      --decision yes \
      --actor test \
    2>"$stderr_file" || rc=$?

  [ "$rc" -ne 0 ] || fail "driver should halt on probe missing but exited 0"
  grep -q 'design-first ordering cannot be kept' "$stderr_file" \
    || fail "stderr should contain 'design-first ordering cannot be kept'"

  # Record should be stale (transition happens before halt)
  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale (transition precedes halt) but is $state"
}

@test "(AC-EC4) probe unauthorized halts with distinct message" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"

  seed_config true
  seed_roster
  _build_approved_record

  local bridge_cmd
  bridge_cmd="$(_make_bridge_stub unauthorized 3)"

  local stderr_file="$TEST_TMP/driver-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    DESIGN_PROBE_BRIDGE_CMD="$bridge_cmd" \
    bash "$DRIVER_SCRIPT" \
      --decision yes \
      --actor test \
    2>"$stderr_file" || rc=$?

  [ "$rc" -ne 0 ] || fail "driver should halt on probe unauthorized but exited 0"
  grep -q 'design-first ordering cannot be kept' "$stderr_file" \
    || fail "stderr should contain 'design-first ordering cannot be kept'"
  grep -qi 'unauthorized' "$stderr_file" \
    || fail "stderr should contain 'unauthorized' for unauthorized probe state"
}

@test "(AC-EC4) decision no skips transition entirely" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"

  seed_config true
  seed_roster
  _build_approved_record

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  local bridge_cmd
  bridge_cmd="$(_make_bridge_stub available 0)"

  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    DESIGN_PROBE_BRIDGE_CMD="$bridge_cmd" \
    bash "$DRIVER_SCRIPT" \
      --decision no \
      --actor test \
    2>/dev/null || rc=$?

  [ "$rc" -eq 0 ] || fail "driver should exit 0 on --decision no but exited $rc"

  # Record must be byte-identical (no transition)
  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was modified despite --decision no"
}

@test "(AC-EC4) decision ambiguous defaults to stale" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"

  seed_config true
  seed_roster
  _build_approved_record

  local bridge_cmd
  bridge_cmd="$(_make_bridge_stub available 0)"

  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    DESIGN_PROBE_BRIDGE_CMD="$bridge_cmd" \
    bash "$DRIVER_SCRIPT" \
      --decision ambiguous \
      --actor test \
    2>/dev/null || rc=$?

  [ "$rc" -eq 0 ] || fail "driver should exit 0 on ambiguous+available but exited $rc"

  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale on ambiguous decision but is $state"
}

@test "(AC-EC4) unknown probe stdout fails closed" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"

  seed_config true
  seed_roster
  _build_approved_record

  # The real probe normalizes all bridge outcomes to available/missing/unauthorized,
  # so unknown stdout can only arise from a corrupted probe. Test the driver's
  # defense-in-depth by placing a fake probe next to a copy of the driver.
  local fake_dir="$TEST_TMP/fake-scripts"
  mkdir -p "$fake_dir"
  cp "$DRIVER_SCRIPT" "$fake_dir/design-stale-transition.sh"
  # Copy design-record.sh and its dependencies so the driver can find them
  cp -R "$SCRIPTS_DIR"/* "$fake_dir/" 2>/dev/null || true
  # Replace design-probe.sh with one that outputs garbage
  cat > "$fake_dir/design-probe.sh" <<'GARBOF'
#!/usr/bin/env bash
printf 'something-unknown\n'
exit 0
GARBOF
  chmod +x "$fake_dir/design-probe.sh"

  local stderr_file="$TEST_TMP/driver-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$fake_dir/design-stale-transition.sh" \
      --decision yes \
      --actor test \
    2>"$stderr_file" || rc=$?

  # Unknown stdout from probe should be treated as missing (fail closed)
  [ "$rc" -ne 0 ] || fail "driver should fail closed on unknown probe stdout but exited 0"
  grep -q 'design-first ordering cannot be kept' "$stderr_file" \
    || fail "stderr should contain the halt message"
}

# ===========================================================================
# Temp-file cleanup on signal
# ===========================================================================

@test "SIGTERM during probe leaves no temp files behind" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found at $DRIVER_SCRIPT"

  seed_config true
  seed_roster
  _build_approved_record

  # Create a copy of the driver with a known temp-file path so we can verify
  # cleanup. The copy replaces the mktemp call with a fixed-path file.
  local fake_dir="$TEST_TMP/fake-scripts"
  mkdir -p "$fake_dir"
  cp -R "$SCRIPTS_DIR"/* "$fake_dir/" 2>/dev/null || true
  local known_tmpfile="$TEST_TMP/probe-stderr-fixed.tmp"
  # Patch the driver: replace the mktemp line with our known path
  sed "s|mktemp -t dst-probe-stderr.XXXXXX|echo '$known_tmpfile'|" \
    "$DRIVER_SCRIPT" > "$fake_dir/design-stale-transition.sh"
  chmod +x "$fake_dir/design-stale-transition.sh"

  # Plant a slow probe that signals readiness via a sentinel file, then sleeps
  local sentinel="$TEST_TMP/probe-reached"
  cat > "$fake_dir/design-probe.sh" <<PROBEOF
#!/usr/bin/env bash
touch "$sentinel"
printf '%s' "\$\$" > "$TEST_TMP/probe.pid"
exec sleep 60
PROBEOF
  chmod +x "$fake_dir/design-probe.sh"

  # Launch the driver in background
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$fake_dir/design-stale-transition.sh" \
      --decision yes --actor test \
    2>/dev/null &
  local driver_pid=$!

  # Wait until the probe is reached (sentinel file appears)
  local waited=0
  while [ ! -f "$sentinel" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$sentinel" ] || fail "probe was never reached (sentinel missing after 5s)"

  # Assert the sed substitution actually took effect
  grep -q "$known_tmpfile" "$fake_dir/design-stale-transition.sh" \
    || fail "sed substitution did not take effect — test is vacuous"

  # The temp file must exist now (created before the probe ran)
  [ -f "$known_tmpfile" ] || fail "temp file was never created — test is vacuous"

  # Send SIGTERM to the driver
  kill -TERM "$driver_pid" 2>/dev/null || true
  # Kill the probe's sleep if still running
  if [ -f "$TEST_TMP/probe.pid" ]; then
    kill "$(cat "$TEST_TMP/probe.pid")" 2>/dev/null || true
  fi
  wait "$driver_pid" 2>/dev/null || true

  # Assert the temp file was cleaned up
  [ ! -f "$known_tmpfile" ] || fail "temp file leaked after SIGTERM: $known_tmpfile"
}

# Tests 8 and 9 removed — they duplicated test 6 (ambiguous defaults to stale)
# and test 5 (decision no skips transition) respectively.

# ===========================================================================
# ATDD Tests — attested integration state
# ===========================================================================

# _build_indev_record — helper: drive the record from draft through to in-dev.
_build_indev_record() {
  _build_approved_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to in-dev --actor ci
}

# _make_spy_scripts — copy the scripts dir and replace design-probe.sh with a
# counting spy. Sets SPY_SCRIPTS_DIR to the copy root. The spy logs each run
# to a counter file and then exec's the real probe.
_make_spy_scripts() {
  SPY_SCRIPTS_DIR="$TEST_TMP/spy-scripts"
  cp -R "$SCRIPTS_DIR" "$SPY_SCRIPTS_DIR"
  local real_probe="$SCRIPTS_DIR/design-probe.sh"
  cat > "$SPY_SCRIPTS_DIR/design-probe.sh" <<SPYEOF
#!/usr/bin/env bash
echo 1 >> "$TEST_TMP/.probe-spy-counter"
exec "$real_probe" "\$@"
SPYEOF
  chmod +x "$SPY_SCRIPTS_DIR/design-probe.sh"
}

_spy_probe_count() {
  if [ -f "$TEST_TMP/.probe-spy-counter" ]; then
    wc -l < "$TEST_TMP/.probe-spy-counter" | tr -d ' '
  else
    echo 0
  fi
}

@test "(AC1) attested integration state drives stale-then-halt without spawning the probe" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found at $DRIVER_SCRIPT"

  # --- Sub-scenario: attested available ---
  seed_config true
  seed_roster
  _build_indev_record
  _make_spy_scripts

  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$SPY_SCRIPTS_DIR/design-stale-transition.sh" \
      --decision yes --actor test-agent --integration available \
    2>/dev/null || rc=$?

  [ "$rc" -eq 0 ] || fail "attested available should exit 0 but got $rc"
  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale but is $state"
  local spy_count
  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -eq 0 ] || fail "probe should not have been run but spy counted $spy_count"
  # Audit must record integration_state and integration_source
  local audit_int_state audit_int_source
  audit_int_state="$(yq '.audit[-1].integration_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  audit_int_source="$(yq '.audit[-1].integration_source' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$audit_int_state" = "available" ] || fail "audit integration_state should be available but is $audit_int_state"
  [ "$audit_int_source" = "attested" ] || fail "audit integration_source should be attested but is $audit_int_source"

  # --- Sub-scenario: attested missing ---
  rm -f "$TEST_TMP/.gaia/state/design-record.yaml" "$TEST_TMP/.probe-spy-counter"
  _build_indev_record

  local stderr_file="$TEST_TMP/stderr-missing.txt"
  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$SPY_SCRIPTS_DIR/design-stale-transition.sh" \
      --decision yes --actor test-agent --integration missing \
    2>"$stderr_file" || rc=$?

  [ "$rc" -ne 0 ] || fail "attested missing should halt (non-zero) but got 0"
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale but is $state"
  grep -qi 'not available in this session' "$stderr_file" \
    || fail "stderr should contain the missing-state remediation"
  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -eq 0 ] || fail "probe should not have been run for attested missing"

  # --- Sub-scenario: attested unauthorized ---
  rm -f "$TEST_TMP/.gaia/state/design-record.yaml" "$TEST_TMP/.probe-spy-counter"
  _build_indev_record

  local stderr_file_unauth="$TEST_TMP/stderr-unauth.txt"
  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$SPY_SCRIPTS_DIR/design-stale-transition.sh" \
      --decision yes --actor test-agent --integration unauthorized \
    2>"$stderr_file_unauth" || rc=$?

  [ "$rc" -ne 0 ] || fail "attested unauthorized should halt (non-zero) but got 0"
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale but is $state"
  grep -qi 'unauthorized' "$stderr_file_unauth" \
    || fail "stderr should contain 'unauthorized'"
  grep -qi 'design-login' "$stderr_file_unauth" \
    || fail "unauthorized remediation should mention /design-login"
  # The unauthorized message must differ from the missing message
  if diff -q "$stderr_file" "$stderr_file_unauth" >/dev/null 2>&1; then
    fail "unauthorized and missing remediations must differ in substance"
  fi
  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -eq 0 ] || fail "probe should not have been run for attested unauthorized"
}

@test "(AC2) invalid --integration value halts exit 2 before record mutation" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  # Sub-scenario: --decision yes --integration garbage
  local stderr_file="$TEST_TMP/stderr-invalid.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration garbage \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "invalid --integration should exit 2 but got $rc"
  grep -q 'garbage' "$stderr_file" || fail "stderr should name the invalid value 'garbage'"

  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated despite invalid --integration"

  # Sub-scenario: --decision no --integration garbage (validation before decision)
  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision no --actor test-agent --integration garbage \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "--decision no with invalid --integration should still exit 2 but got $rc"
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated on --decision no with invalid value"
}

@test "(AC6) stale transition precedes halt with audit recording state and source" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  # Sub-scenario: attested path
  seed_config true
  seed_roster
  _build_indev_record

  local stderr_file="$TEST_TMP/stderr-ac6.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration unauthorized \
    2>"$stderr_file" || rc=$?

  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale (transition happened) but is $state"

  local audit_int_state audit_int_source audit_timestamp
  audit_int_state="$(yq '.audit[-1].integration_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  audit_int_source="$(yq '.audit[-1].integration_source' "$TEST_TMP/.gaia/state/design-record.yaml")"
  audit_timestamp="$(yq '.audit[-1].at' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$audit_int_state" = "unauthorized" ] || fail "audit integration_state should be unauthorized"
  [ "$audit_int_source" = "attested" ] || fail "audit integration_source should be attested"
  [ -n "$audit_timestamp" ] && [ "$audit_timestamp" != "null" ] \
    || fail "audit timestamp should be non-empty"
  [ "$rc" -ne 0 ] || fail "should halt after stale write"

  # Sub-scenario: probed path
  rm -f "$TEST_TMP/.gaia/state/design-record.yaml"
  _build_indev_record

  rc=0
  env -u BATS_TEST_FILENAME -u DESIGN_PROBE_BRIDGE_CMD -u DESIGN_PROBE_ALLOW_BRIDGE_CMD \
    PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent \
    2>"$stderr_file" || rc=$?

  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale on probed path but is $state"
  audit_int_source="$(yq '.audit[-1].integration_source' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$audit_int_source" = "probed" ] || fail "audit integration_source should be probed but is $audit_int_source"
  [ "$rc" -ne 0 ] || fail "probed path should halt"
}

@test "(AC-EC1) duplicate --integration flags halt exit 2 before record mutation" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  local stderr_file="$TEST_TMP/stderr-dup.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration available --integration missing \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "duplicate --integration should exit 2 but got $rc"
  grep -qi 'more than once\|duplicate\|--integration' "$stderr_file" \
    || fail "stderr should mention the duplicate flag"

  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated despite duplicate flag"
}

@test "(AC-EC2) missing --integration value halts exit 2 with usage diagnostic" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  local stderr_file="$TEST_TMP/stderr-missing-val.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "missing --integration value should exit 2 but got $rc"
  grep -qi '\-\-integration' "$stderr_file" \
    || fail "stderr should name --integration"
  grep -qi 'available.*missing.*unauthorized\|legal values' "$stderr_file" \
    || fail "stderr should list the legal values"

  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated despite missing value"
}

@test "(AC-EC3) non-canonical casing or whitespace rejected as invalid exit 2" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  # Sub-scenario: wrong case
  local stderr_file="$TEST_TMP/stderr-case.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration Available \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "wrong-case 'Available' should exit 2 but got $rc"
  grep -q 'Available' "$stderr_file" || fail "stderr should name 'Available'"

  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated on wrong case"

  # Sub-scenario: whitespace-padded
  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration " available " \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "whitespace-padded value should exit 2 but got $rc"
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated on whitespace-padded value"
}

@test "(AC-EC4) attestation wins over configured bridge and audit records source attested" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record
  _make_spy_scripts

  # Configure a bridge that would classify "missing"
  local bridge_cmd
  bridge_cmd="$(_make_bridge_stub missing 1)"

  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    DESIGN_PROBE_BRIDGE_CMD="$bridge_cmd" \
    DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 \
    bash "$SPY_SCRIPTS_DIR/design-stale-transition.sh" \
      --decision yes --actor test-agent --integration available \
    2>/dev/null || rc=$?

  [ "$rc" -eq 0 ] || fail "attested available should exit 0 despite bridge"
  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale but is $state"

  local spy_count
  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -eq 0 ] || fail "attestation should take precedence over bridge, probe ran $spy_count times"

  local audit_source
  audit_source="$(yq '.audit[-1].integration_source' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$audit_source" = "attested" ] || fail "audit integration_source should be attested but is $audit_source"
}

@test "(AC-EC5) non-design-affecting decision ignores integration state entirely" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  local stderr_file="$TEST_TMP/stderr-ec5.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision no --actor test-agent --integration missing \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 0 ] || fail "decision no should exit 0 regardless of integration state"
  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated despite --decision no"
}

@test "(AC-EC6) shell metacharacters and newlines in attested value rejected exit 2" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  # Sub-scenario: shell metacharacters
  local stderr_file="$TEST_TMP/stderr-meta.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration 'available; rm -rf x' \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "metacharacter value should exit 2 but got $rc"
  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated with metacharacter value"
  if [ -e "$TEST_TMP/x" ]; then
    fail "a file named 'x' was created — the semicolon was interpreted"
  fi

  # Sub-scenario: embedded newline
  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration $'available\nmissing' \
    2>"$stderr_file" || rc=$?

  [ "$rc" -eq 2 ] || fail "newline value should exit 2 but got $rc"
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was mutated with newline value"
}

@test "(AC-EC9) driver trusts stale attestation and auth failure surfaces at the update step" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  # Functional sub-scenario: the driver trusts the attestation
  seed_config true
  seed_roster
  _build_indev_record
  _make_spy_scripts

  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$SPY_SCRIPTS_DIR/design-stale-transition.sh" \
      --decision yes --actor test-agent --integration available \
    2>/dev/null || rc=$?

  [ "$rc" -eq 0 ] || fail "driver should trust attestation and exit 0"
  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale"
  local spy_count
  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -eq 0 ] || fail "no probe should have run"
  local audit_state audit_source
  audit_state="$(yq '.audit[-1].integration_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  audit_source="$(yq '.audit[-1].integration_source' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$audit_state" = "available" ] || fail "audit should record available"
  [ "$audit_source" = "attested" ] || fail "audit should record attested"

  # Documentation sub-scenario: the header documents the trade-off
  grep -qE 'revok|token' "$DRIVER_SCRIPT" \
    || fail "driver header should document the authorization-expiry trade-off"
  grep -qiE 'update step|later' "$DRIVER_SCRIPT" \
    || fail "driver header should mention the later update step"

  # The shared attestation block also documents the trade-off
  local skill_af="$PLUGIN_ROOT/skills/gaia-add-feature/SKILL.md"
  local att_block
  att_block="$(awk '/<!-- design-attestation begin -->/{p=1;next} /<!-- design-attestation end -->/{p=0} p' "$skill_af")"
  [ -n "$att_block" ] || fail "attestation block not found in add-feature SKILL.md"
  echo "$att_block" | grep -qiE 'revok|token' \
    || fail "attestation block should document the authorization-expiry trade-off"
}

# ===========================================================================
# Unconfigured-path tests
# ===========================================================================

@test "(AC4) unconfigured real-install path classifies missing via probe fallback" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local stderr_file="$TEST_TMP/stderr-unconfigured.txt"
  local rc=0
  env -u BATS_TEST_FILENAME -u DESIGN_PROBE_BRIDGE_CMD -u DESIGN_PROBE_ALLOW_BRIDGE_CMD \
    PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent \
    2>"$stderr_file" || rc=$?

  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale on unconfigured path but is $state"
  [ "$rc" -ne 0 ] || fail "unconfigured path should halt (non-zero exit)"

  local audit_source audit_state
  audit_source="$(yq '.audit[-1].integration_source' "$TEST_TMP/.gaia/state/design-record.yaml")"
  audit_state="$(yq '.audit[-1].integration_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$audit_source" = "probed" ] || fail "audit should record source=probed but got $audit_source"
  [ "$audit_state" = "missing" ] || fail "audit should record state=missing but got $audit_state"

  grep -qi 'not available in this session' "$stderr_file" \
    || fail "stderr should contain the missing-state remediation text"
}

@test "(AC-EC8) omitted attestation triggers probe fallback with stale-first then fail-closed halt" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  local stderr_file="$TEST_TMP/stderr-ec8.txt"
  local rc=0
  env -u BATS_TEST_FILENAME -u DESIGN_PROBE_BRIDGE_CMD -u DESIGN_PROBE_ALLOW_BRIDGE_CMD \
    PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent \
    2>"$stderr_file" || rc=$?

  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale (stale-first) but is $state"
  [ "$rc" -ne 0 ] || fail "fail-closed halt expected but got exit 0"

  local audit_source audit_state
  audit_source="$(yq '.audit[-1].integration_source' "$TEST_TMP/.gaia/state/design-record.yaml")"
  audit_state="$(yq '.audit[-1].integration_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$audit_source" = "probed" ] || fail "audit should record source=probed but got $audit_source"
  [ "$audit_state" = "missing" ] || fail "audit should record state=missing but got $audit_state"

  grep -qi 'not available in this session' "$stderr_file" \
    || fail "stderr should contain the missing-state remediation"
}

# ===========================================================================
# Driver mutants (AC7)
# ===========================================================================

@test "(AC7) mutant: attestation ignored" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record
  _make_spy_scripts

  # The original should exit 0 with no probe when attested available
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$SPY_SCRIPTS_DIR/design-stale-transition.sh" \
      --decision yes --actor test-agent --integration available \
    2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "original should exit 0 with attested available"
  local spy_count
  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -eq 0 ] || fail "original should not run probe"

  # Reset
  rm -f "$TEST_TMP/.gaia/state/design-record.yaml" "$TEST_TMP/.probe-spy-counter"
  _build_indev_record

  # Patch: make attestation guard always false
  local orig="$SPY_SCRIPTS_DIR/design-stale-transition.sh"
  local patched="$SPY_SCRIPTS_DIR/design-stale-transition-mutant.sh"
  sed 's/if \[ "$_integration_seen" -eq 1 \]; then  # MUTANT-ANCHOR: attestation-guard/if false; then  # MUTANT-ANCHOR: attestation-guard/' \
    "$orig" > "$patched"
  chmod +x "$patched"
  if cmp -s "$orig" "$patched"; then fail "patch did not apply"; fi

  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$patched" \
      --decision yes --actor test-agent --integration available \
    2>/dev/null || rc=$?

  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -gt 0 ] || fail "mutant should run the probe despite attestation"
}

@test "(AC7) mutant: enum validation removed" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  # Original: exit 2 on garbage
  local stderr_file="$TEST_TMP/stderr-enum.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent --integration garbage \
    2>"$stderr_file" || rc=$?
  [ "$rc" -eq 2 ] || fail "original should exit 2 on invalid value but got $rc"
  grep -q 'garbage' "$stderr_file" || fail "original stderr should name the invalid value"

  # Patch: neutralise the enum validation by removing the exit 2 from the default case
  _make_spy_scripts
  local orig="$SPY_SCRIPTS_DIR/design-stale-transition.sh"
  local patched="$SPY_SCRIPTS_DIR/design-stale-transition-mutant.sh"
  sed '/# MUTANT-ANCHOR: enum-validation/,/esac/{
    s/exit 2/: # exit 2 neutralised/
  }' "$orig" > "$patched"
  chmod +x "$patched"
  if cmp -s "$orig" "$patched"; then fail "patch did not apply"; fi

  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$patched" \
      --decision yes --actor test-agent --integration garbage \
    2>/dev/null || rc=$?

  [ "$rc" -ne 2 ] || fail "mutant should NOT exit 2 when validation is removed"
}

@test "(AC7) mutant: absent attestation defaults to available" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record

  # Original: no --integration, no bridge, probe fallback, halt
  local rc=0
  env -u BATS_TEST_FILENAME -u DESIGN_PROBE_BRIDGE_CMD -u DESIGN_PROBE_ALLOW_BRIDGE_CMD \
    PROJECT_ROOT="$TEST_TMP" \
    bash "$DRIVER_SCRIPT" \
      --decision yes --actor test-agent \
    2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "original should halt on unconfigured path"

  # Reset
  rm -f "$TEST_TMP/.gaia/state/design-record.yaml"
  _build_indev_record

  # Patch: default to available instead of missing on the fail-closed line
  _make_spy_scripts
  local orig="$SPY_SCRIPTS_DIR/design-stale-transition.sh"
  local patched="$SPY_SCRIPTS_DIR/design-stale-transition-mutant.sh"
  sed 's/_resolved_state="missing"  # MUTANT-ANCHOR: probe-fallback-default/_resolved_state="available"  # MUTANT-ANCHOR: probe-fallback-default/' \
    "$orig" > "$patched"
  chmod +x "$patched"
  if cmp -s "$orig" "$patched"; then fail "patch did not apply"; fi

  rc=0
  env -u BATS_TEST_FILENAME -u DESIGN_PROBE_BRIDGE_CMD -u DESIGN_PROBE_ALLOW_BRIDGE_CMD \
    PROJECT_ROOT="$TEST_TMP" \
    bash "$patched" \
      --decision yes --actor test-agent \
    2>/dev/null || rc=$?

  [ "$rc" -eq 0 ] || fail "mutant should exit 0 when defaulting to available"
}

@test "(AC7) mutant: probe run despite attestation" {
  [ -f "$DRIVER_SCRIPT" ] || fail "driver script not found"

  seed_config true
  seed_roster
  _build_indev_record
  _make_spy_scripts

  # Original: attested available, spy log empty
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$SPY_SCRIPTS_DIR/design-stale-transition.sh" \
      --decision yes --actor test-agent --integration available \
    2>/dev/null || rc=$?
  local spy_count
  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -eq 0 ] || fail "original should not run probe"

  # Reset
  rm -f "$TEST_TMP/.gaia/state/design-record.yaml" "$TEST_TMP/.probe-spy-counter"
  _build_indev_record

  # Patch: insert probe run after attestation-guard anchor
  local orig="$SPY_SCRIPTS_DIR/design-stale-transition.sh"
  local patched="$SPY_SCRIPTS_DIR/design-stale-transition-mutant.sh"
  awk '/# MUTANT-ANCHOR: attestation-guard/{print; print "    \"$PROBE_SCRIPT\" >/dev/null 2>&1 || true"; next} {print}' \
    "$orig" > "$patched"
  chmod +x "$patched"
  if cmp -s "$orig" "$patched"; then fail "patch did not apply"; fi

  rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    bash "$patched" \
      --decision yes --actor test-agent --integration available \
    2>/dev/null || rc=$?

  spy_count="$(_spy_probe_count)"
  [ "$spy_count" -gt 0 ] || fail "mutant should run the probe despite attestation"
}
