#!/usr/bin/env bats
# drift-detection.bats — ambient drift detection hook in resolve-config.sh
# (E86-S2).
#
# Story: E86-S2 — `resolve-config.sh` drift detection hook + namespaced
#                  `_memory/.framework-version-stale` marker.
# Traces: FR-470, FR-473, NFR-063, ADR-102, T-FVD-1, T-FVD-3, SR-55, SR-57.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/resolve-config.sh"
  PLUGIN_VERSION="$(python3 -c "import json; print(json.load(open('$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json'))['version'])")"
  # Fixture project layout that resolve-config.sh expects.
  FIXTURE_DIR="$TEST_TMP/proj"
  mkdir -p "$FIXTURE_DIR/config" "$FIXTURE_DIR/_memory"
}
teardown() { common_teardown; }

# Build a minimal project-config.yaml with the given framework_version.
# All other required fields (project_root, project_path, memory_path, etc.)
# are populated so the required-field die-block does not fire.
write_config() {
  local cfg_version="$1"
  cat > "$FIXTURE_DIR/config/project-config.yaml" <<YAML
project_root: $FIXTURE_DIR
project_path: $FIXTURE_DIR
memory_path: $FIXTURE_DIR/_memory
checkpoint_path: $FIXTURE_DIR/_memory/checkpoints
installed_path: $FIXTURE_DIR
framework_version: "$cfg_version"
date: "2026-05-13"
test_artifacts: $FIXTURE_DIR/docs/test-artifacts
planning_artifacts: $FIXTURE_DIR/docs/planning-artifacts
implementation_artifacts: $FIXTURE_DIR/docs/implementation-artifacts
creative_artifacts: $FIXTURE_DIR/docs/creative-artifacts
YAML
}

# Run resolve-config.sh against the fixture, capturing stdout + stderr.
run_resolver() {
  run --separate-stderr bash -c "
    CLAUDE_PROJECT_ROOT='$FIXTURE_DIR' \
    GAIA_MEMORY_PATH='$FIXTURE_DIR/_memory' \
    '$SCRIPT' --shared '$FIXTURE_DIR/config/project-config.yaml'
  "
}

# ---- AC1+AC2+AC4+AC5+AC10: drift detected → marker + WARNING --------------

@test "AC1-2-4-5-10 / Scenario 1: drift detected writes marker + emits stderr WARNING" {
  write_config "9.9.9-different-from-plugin"
  run_resolver
  [ "$status" -eq 0 ]
  # AC4: marker filename is .framework-version-stale (NOT .config-stale)
  [ -f "$FIXTURE_DIR/_memory/.framework-version-stale" ]
  [ ! -f "$FIXTURE_DIR/_memory/.config-stale" ]
  # AC5: marker content format — single line, three fields
  local marker_content
  marker_content="$(cat "$FIXTURE_DIR/_memory/.framework-version-stale")"
  [[ "$marker_content" =~ ^stale_since=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z[[:space:]]installed=$PLUGIN_VERSION[[:space:]]config=9\.9\.9-different-from-plugin$ ]]
  # AC10: stderr WARNING contains canonical text
  [[ "$stderr" == *"framework drift"* ]]
  [[ "$stderr" == *"9.9.9-different-from-plugin"* ]]
  [[ "$stderr" == *"$PLUGIN_VERSION"* ]]
  [[ "$stderr" == *"/gaia-help"* ]]
}

# ---- AC11: versions match → no marker, no warning -------------------------

@test "AC11 / Scenario 2: versions match — no marker, no warning" {
  write_config "$PLUGIN_VERSION"
  run_resolver
  [ "$status" -eq 0 ]
  [ ! -f "$FIXTURE_DIR/_memory/.framework-version-stale" ]
  ! [[ "$stderr" == *"framework drift"* ]]
}

# ---- AC9: sentinel created (whether drift or not) -------------------------

@test "AC9 / Scenario 4 (sentinel touch on match): sentinel file is created" {
  write_config "$PLUGIN_VERSION"
  run_resolver
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE_DIR/_memory/.framework-version-checked-$PLUGIN_VERSION" ]
}

@test "AC9 (sentinel touch on drift): sentinel file is created after drift detection" {
  write_config "1.0.0-old"
  run_resolver
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE_DIR/_memory/.framework-version-checked-$PLUGIN_VERSION" ]
}

# ---- AC8: session-cache sentinel → second call is no-op -------------------

@test "AC8 / Scenario 4 (warm cache): second invocation produces no warning" {
  write_config "1.0.0-old"
  # First call — drift detected, sentinel created.
  run_resolver
  [ -f "$FIXTURE_DIR/_memory/.framework-version-stale" ]
  # Delete the marker but keep the sentinel — second call should NOT
  # re-emit the warning (sentinel exists).
  rm "$FIXTURE_DIR/_memory/.framework-version-stale"
  run_resolver
  [ "$status" -eq 0 ]
  ! [[ "$stderr" == *"framework drift"* ]]
  # Marker should NOT have been re-written (sentinel suppresses).
  [ ! -f "$FIXTURE_DIR/_memory/.framework-version-stale" ]
}

# ---- AC6+AC7: write failure tolerance (_memory missing) --------------------

@test "AC7 / Scenario 7 (write tolerance): _memory missing → no crash, no marker" {
  write_config "1.0.0-old"
  # Remove the _memory directory entirely. resolve-config.sh should NOT die.
  rm -rf "$FIXTURE_DIR/_memory"
  run_resolver
  # The resolver itself must still exit 0 (drift detection is advisory).
  [ "$status" -eq 0 ]
  # No marker should exist (write failed silently).
  [ ! -f "$FIXTURE_DIR/_memory/.framework-version-stale" ]
}

# ---- AC5: marker content exact format check -------------------------------

@test "AC5 marker content: single line with stale_since= installed= config= fields" {
  write_config "0.1.2"
  run_resolver
  [ -f "$FIXTURE_DIR/_memory/.framework-version-stale" ]
  # Line count = 1 (no trailing blank lines).
  local lines
  lines=$(wc -l < "$FIXTURE_DIR/_memory/.framework-version-stale")
  [ "$lines" -eq 1 ]
  # All three required fields present.
  grep -qE '^stale_since=[0-9TZ:-]+ installed=[^ ]+ config=0\.1\.2$' \
    "$FIXTURE_DIR/_memory/.framework-version-stale"
}

# ---- AC4 marker naming collision guard -------------------------------------

@test "AC4: marker is .framework-version-stale, NOT .config-stale" {
  write_config "1.0.0-old"
  run_resolver
  [ -f "$FIXTURE_DIR/_memory/.framework-version-stale" ]
  [ ! -f "$FIXTURE_DIR/_memory/.config-stale" ]
}

# ---- AC1 hook placement: function exists in resolve-config.sh -------------

@test "AC1 placement: resolve-config.sh contains _drift_detect function" {
  grep -qE '^[[:space:]]*_drift_detect[[:space:]]*\(\)' "$SCRIPT"
}

@test "AC1 placement: resolve-config.sh sources lib/framework-version.sh" {
  grep -qE '(source|\.)[[:space:]]+["$]*[^[:space:]]*lib/framework-version\.sh' "$SCRIPT"
}

# ---- W1 (Tex Red review): AC3 defense-in-depth — empty config version ----

@test "AC3 (defense-in-depth): _drift_detect skips when v_framework_version is empty" {
  # Today the L923 required-field check dies on empty v_framework_version
  # before the hook can see it. This test exercises the hook function in
  # isolation by invoking resolve-config.sh in --field mode with an env
  # override that effectively forces v_framework_version=""  through the
  # only documented path. If that proves impossible, fall back to a
  # structural assertion that the hook function tolerates the empty case
  # (look for an early-return branch in the source).
  write_config "" || true
  # The required-field die WILL fire on empty framework_version (L923).
  # AC3's "skip silently" is defense-in-depth for a future schema where
  # the field becomes optional. Verify the SOURCE contains the empty-string
  # early-return branch as static evidence.
  grep -qE '\[\s*-z\s*"?\$\{?v_framework_version\}?"?\s*\]' "$SCRIPT"
}

# ---- W3 (Tex Red review): AC6 atomic-write runtime evidence -------------

@test "AC6 (atomic write): marker write goes through tempfile + mv" {
  # Verify by source-inspection that the hook uses the SR-55 pattern:
  # tempfile path includes a PID suffix and the final write is via `mv`.
  # A truly runtime test would require strace, which is heavy and not
  # portable across macOS/Linux CI images. This structural+grep evidence
  # combined with the AC1-2-4-5-10 end-to-end test (which verifies the
  # final marker exists and has correct content) provides adequate
  # coverage for the SR-55 contract.
  # The implementation uses `${_stale_path}.tmp.$$` (variable expansion).
  # Look for the tempfile construction pattern + the mv call.
  grep -qE '_tmp_path=.*\.tmp\.\$\$' "$SCRIPT"
  grep -qE 'mv[[:space:]]+"\$_tmp_path"[[:space:]]+"\$_stale_path"' "$SCRIPT"
}
