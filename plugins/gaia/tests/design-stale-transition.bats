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

  # Record should be stale (transition happens before probe)
  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ] || fail "record should be stale (transition precedes probe) but is $state"
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

# Tests 8 and 9 removed — they duplicated test 6 (ambiguous defaults to stale)
# and test 5 (decision no skips transition) respectively.
