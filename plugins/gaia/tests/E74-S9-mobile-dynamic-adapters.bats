#!/usr/bin/env bats
# E74-S9-mobile-dynamic-adapters.bats — covers AC1-AC8 for the five mobile
# dynamic adapters (Detox, Maestro, Appium, XCUITest, Espresso) and the three
# device-farm adapters (Firebase Test Lab, BrowserStack, Sauce Labs).
#
# Path layout follows the E74-S9 story spec verbatim:
#   plugins/gaia/config/adapters/dynamic/{name}.yaml      (5 manifests)
#   plugins/gaia/config/adapters/device-farm/{name}.yaml  (3 manifests)
#   plugins/gaia/scripts/dispatch-dynamic-test.sh
#   plugins/gaia/scripts/dispatch-device-farm.sh
#   plugins/gaia/scripts/normalize-adapter-output.sh
#   plugins/gaia/schemas/adapter-output.schema.json
#
# Note on YAML parsing: bats uses POSIX-portable shell tools. We grep the
# manifests for required keys rather than using `yq` (not always installed).
# This matches the E74-S7 manifest-presence test pattern.

bats_require_minimum_version 1.5.0

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
DYNAMIC_DIR="$PLUGIN_ROOT/config/adapters/dynamic"
DEVICE_FARM_DIR="$PLUGIN_ROOT/config/adapters/device-farm"
SCHEMA_FILE="$PLUGIN_ROOT/schemas/adapter-output.schema.json"
DISPATCH_DYN="$PLUGIN_ROOT/scripts/dispatch-dynamic-test.sh"
DISPATCH_DF="$PLUGIN_ROOT/scripts/dispatch-device-farm.sh"
NORMALIZE="$PLUGIN_ROOT/scripts/normalize-adapter-output.sh"

DYNAMIC_ADAPTERS=(detox maestro appium xcuitest espresso)
DEVICE_FARM_ADAPTERS=(firebase-test-lab browserstack sauce-labs)

# ---------------- AC1 — five dynamic adapters registered ------------------

@test "dynamic adapter registry contains exactly five manifests" {
  [ -d "$DYNAMIC_DIR" ]
  local count
  count="$(find "$DYNAMIC_DIR" -maxdepth 1 -name '*.yaml' -type f | wc -l | tr -d ' ')"
  [ "$count" = "5" ]
}

@test "each dynamic manifest has required fields (name, type, platform, binary, config_file_pattern, output_format)" {
  for adapter in "${DYNAMIC_ADAPTERS[@]}"; do
    local f="$DYNAMIC_DIR/$adapter.yaml"
    [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
    grep -Eq '^name:[[:space:]]+' "$f" || { echo "$adapter: missing name" >&2; return 1; }
    grep -Eq '^type:[[:space:]]+dynamic[[:space:]]*$' "$f" || { echo "$adapter: type must be dynamic" >&2; return 1; }
    grep -Eq '^platform:[[:space:]]+(ios|android|cross-platform)[[:space:]]*$' "$f" || { echo "$adapter: invalid platform" >&2; return 1; }
    grep -Eq '^binary:[[:space:]]+' "$f" || { echo "$adapter: missing binary" >&2; return 1; }
    grep -Eq '^config_file_pattern:[[:space:]]+' "$f" || { echo "$adapter: missing config_file_pattern" >&2; return 1; }
    grep -Eq '^output_format:[[:space:]]+' "$f" || { echo "$adapter: missing output_format" >&2; return 1; }
  done
}

# ---------------- AC2 — three device-farm adapters registered -------------

@test "device-farm adapter registry contains exactly three manifests" {
  [ -d "$DEVICE_FARM_DIR" ]
  local count
  count="$(find "$DEVICE_FARM_DIR" -maxdepth 1 -name '*.yaml' -type f | wc -l | tr -d ' ')"
  [ "$count" = "3" ]
}

@test "each device-farm manifest has required fields (runtime_profile=network, auth_env_var, api_base_url, device_matrix_format, result_polling_strategy)" {
  for adapter in "${DEVICE_FARM_ADAPTERS[@]}"; do
    local f="$DEVICE_FARM_DIR/$adapter.yaml"
    [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
    grep -Eq '^name:[[:space:]]+' "$f" || { echo "$adapter: missing name" >&2; return 1; }
    grep -Eq '^type:[[:space:]]+device-farm[[:space:]]*$' "$f" || { echo "$adapter: type must be device-farm" >&2; return 1; }
    grep -Eq '^runtime_profile:[[:space:]]+network[[:space:]]*$' "$f" || { echo "$adapter: runtime_profile must be network" >&2; return 1; }
    grep -Eq '^auth_env_var:[[:space:]]+' "$f" || { echo "$adapter: missing auth_env_var" >&2; return 1; }
    grep -Eq '^api_base_url:[[:space:]]+' "$f" || { echo "$adapter: missing api_base_url" >&2; return 1; }
    grep -Eq '^device_matrix_format:[[:space:]]+' "$f" || { echo "$adapter: missing device_matrix_format" >&2; return 1; }
    grep -Eq '^result_polling_strategy:[[:space:]]+(poll|webhook)[[:space:]]*$' "$f" || { echo "$adapter: invalid result_polling_strategy" >&2; return 1; }
  done
}

# ---------------- AC3 — dynamic adapter dispatch --------------------------

@test "dispatch-dynamic-test.sh resolves manifest and emits structured JSON" {
  [ -x "$DISPATCH_DYN" ]
  local fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  # Stub `npx` so detox invocation succeeds (detox uses `npx detox`).
  cat > "$fakebin/npx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fakebin/npx"

  PATH="$fakebin:$PATH" run "$DISPATCH_DYN" --adapter detox --suite "$BATS_TEST_TMPDIR/suite"
  [ "$status" -eq 0 ] || { echo "dispatch failed: $output" >&2; return 1; }

  echo "$output" | jq -e '.adapter == "detox"' >/dev/null
  echo "$output" | jq -e 'has("exit_code")' >/dev/null
  echo "$output" | jq -e 'has("test_count")' >/dev/null
  echo "$output" | jq -e 'has("pass_count")' >/dev/null
  echo "$output" | jq -e 'has("fail_count")' >/dev/null
  echo "$output" | jq -e 'has("duration_ms")' >/dev/null
}

# ---------------- AC4 — device-farm adapter dispatch ----------------------

@test "dispatch-device-farm.sh emits structured JSON with composite_verdict" {
  [ -x "$DISPATCH_DF" ]
  FIREBASE_TEST_LAB_TOKEN="dummy" \
    GAIA_DEVICE_FARM_MOCK=1 \
    run "$DISPATCH_DF" --adapter firebase-test-lab --suite "$BATS_TEST_TMPDIR/suite" \
      --device-matrix "$BATS_TEST_TMPDIR/matrix.yaml"
  [ "$status" -eq 0 ] || { echo "dispatch failed: $output" >&2; return 1; }

  echo "$output" | jq -e '.adapter == "firebase-test-lab"' >/dev/null
  echo "$output" | jq -e 'has("devices_requested")' >/dev/null
  echo "$output" | jq -e 'has("devices_completed")' >/dev/null
  echo "$output" | jq -e '.per_device_results | type == "array"' >/dev/null
  echo "$output" | jq -e '.composite_verdict | test("^(pass|fail|partial)$")' >/dev/null
}

# ---------------- AC5 — runtime-profile: network enforcement --------------

@test "dispatch-device-farm.sh exits 2 with offline mode (GAIA_OFFLINE=true)" {
  GAIA_OFFLINE=true \
    FIREBASE_TEST_LAB_TOKEN="dummy" \
    run "$DISPATCH_DF" --adapter firebase-test-lab --suite "$BATS_TEST_TMPDIR/suite" \
      --device-matrix "$BATS_TEST_TMPDIR/matrix.yaml"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'runtime-profile: network' || { echo "expected network diag, got: $output" >&2; return 1; }
}

# ---------------- AC6 — missing auth credential detection -----------------

@test "dispatch-device-farm.sh exits 3 when auth_env_var unset" {
  unset FIREBASE_TEST_LAB_TOKEN
  run "$DISPATCH_DF" --adapter firebase-test-lab --suite "$BATS_TEST_TMPDIR/suite" \
    --device-matrix "$BATS_TEST_TMPDIR/matrix.yaml"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'FIREBASE_TEST_LAB_TOKEN' || { echo "expected env var name in diag, got: $output" >&2; return 1; }
}

# ---------------- AC7 — adapter output normalization ----------------------

@test "schemas/adapter-output.schema.json exists and is valid JSON" {
  [ -f "$SCHEMA_FILE" ]
  jq empty "$SCHEMA_FILE"
}

@test "normalize-adapter-output.sh produces canonical JSON from JUnit XML" {
  [ -x "$NORMALIZE" ]
  local junit="$BATS_TEST_TMPDIR/junit.xml"
  cat > "$junit" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="DetoxSuite" tests="3" failures="1" skipped="0" time="2.500">
    <testcase name="login passes" time="0.500"/>
    <testcase name="logout passes" time="0.300"/>
    <testcase name="checkout fails" time="1.700">
      <failure message="expected button visible">stack trace</failure>
    </testcase>
  </testsuite>
</testsuites>
XML
  run "$NORMALIZE" --adapter detox --format junit-xml --input "$junit"
  [ "$status" -eq 0 ] || { echo "normalize failed: $output" >&2; return 1; }
  echo "$output" | jq -e '.adapter == "detox"' >/dev/null
  echo "$output" | jq -e '.summary.total == 3' >/dev/null
  echo "$output" | jq -e '.summary.passed == 2' >/dev/null
  echo "$output" | jq -e '.summary.failed == 1' >/dev/null
  echo "$output" | jq -e '.test_results | type == "array" and length == 3' >/dev/null
  echo "$output" | jq -e 'has("framework")' >/dev/null
  echo "$output" | jq -e 'has("platform")' >/dev/null
  echo "$output" | jq -e 'has("duration_ms")' >/dev/null
}

@test "normalize-adapter-output.sh produces canonical JSON from Maestro JSON output" {
  local maestro="$BATS_TEST_TMPDIR/maestro.json"
  cat > "$maestro" <<'JSON'
{
  "tests": [
    {"name": "open app", "status": "passed", "duration_ms": 200},
    {"name": "tap login", "status": "passed", "duration_ms": 150},
    {"name": "submit form", "status": "failed", "duration_ms": 500, "error": "timeout"}
  ]
}
JSON
  run "$NORMALIZE" --adapter maestro --format json --input "$maestro"
  [ "$status" -eq 0 ] || { echo "normalize failed: $output" >&2; return 1; }
  echo "$output" | jq -e '.adapter == "maestro"' >/dev/null
  echo "$output" | jq -e '.summary.total == 3' >/dev/null
  echo "$output" | jq -e '.summary.passed == 2' >/dev/null
  echo "$output" | jq -e '.summary.failed == 1' >/dev/null
}

# ---------------- AC8 — device-farm result polling ------------------------

@test "dispatch-device-farm.sh poll strategy times out -> exit 4" {
  FIREBASE_TEST_LAB_TOKEN="dummy" \
    GAIA_DEVICE_FARM_MOCK=timeout \
    run "$DISPATCH_DF" --adapter firebase-test-lab --suite "$BATS_TEST_TMPDIR/suite" \
      --device-matrix "$BATS_TEST_TMPDIR/matrix.yaml" \
      --max-poll-attempts 2 --poll-interval-seconds 0
  [ "$status" -eq 4 ]
  echo "$output" | grep -qi 'timeout\|max_poll_attempts' || { echo "expected poll-timeout diag, got: $output" >&2; return 1; }
}

@test "dispatch-device-farm.sh webhook strategy times out -> exit 4" {
  BROWSERSTACK_ACCESS_KEY="dummy" \
    GAIA_DEVICE_FARM_MOCK=webhook-timeout \
    run "$DISPATCH_DF" --adapter browserstack --suite "$BATS_TEST_TMPDIR/suite" \
      --device-matrix "$BATS_TEST_TMPDIR/matrix.yaml" \
      --webhook-timeout-seconds 1
  [ "$status" -eq 4 ]
  echo "$output" | grep -qi 'webhook\|timeout' || { echo "expected webhook-timeout diag, got: $output" >&2; return 1; }
}

# ---------------- AC2 specifics — polling-strategy mapping ----------------

@test "firebase-test-lab and sauce-labs declare poll strategy with max_poll_attempts/poll_interval_seconds" {
  for adapter in firebase-test-lab sauce-labs; do
    local f="$DEVICE_FARM_DIR/$adapter.yaml"
    grep -Eq '^result_polling_strategy:[[:space:]]+poll[[:space:]]*$' "$f" || { echo "$adapter: not poll" >&2; return 1; }
    grep -Eq '^max_poll_attempts:[[:space:]]+[0-9]+' "$f" || { echo "$adapter: missing max_poll_attempts" >&2; return 1; }
    grep -Eq '^poll_interval_seconds:[[:space:]]+[0-9]+' "$f" || { echo "$adapter: missing poll_interval_seconds" >&2; return 1; }
  done
}

@test "browserstack declares webhook strategy with webhook_timeout_seconds" {
  local f="$DEVICE_FARM_DIR/browserstack.yaml"
  grep -Eq '^result_polling_strategy:[[:space:]]+webhook[[:space:]]*$' "$f"
  grep -Eq '^webhook_timeout_seconds:[[:space:]]+[0-9]+' "$f"
}
