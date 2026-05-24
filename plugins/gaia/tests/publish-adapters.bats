#!/usr/bin/env bats
# publish-adapters.bats — E100-S5 TC-PUB-1/2/3/4
#
# Tests the four first-class publish adapters' FR-526 + ADR-037 envelope
# conformance + NFR-081 credential-isolation + dry-run + exit-code matrix.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  ENVELOPE_VAL="$PLUGIN_DIR/scripts/lib/validate-adr037-envelope.sh"
  OUTPUT="$TEST_TMP/findings.json"
}

teardown() { common_teardown; }

_run_adapter() {
  local channel="$1"; shift
  local adapter="$PLUGIN_DIR/scripts/adapters/publish-$channel/run.sh"
  [ -x "$adapter" ] || { echo "adapter missing or not executable: $adapter" >&2; return 1; }
  "$adapter" "$@" --output "$OUTPUT"
}

_assert_envelope_well_formed() {
  [ -f "$OUTPUT" ]
  bash "$ENVELOPE_VAL" "$OUTPUT"
}

# ---------- TC-PUB-1: claude-marketplace trigger + verify happy path ----------

@test "TC-PUB-1: claude-marketplace trigger emits PASSED envelope (credentials via env only)" {
  MARKETPLACE_PUBLISH_MOCK=1 run _run_adapter claude-marketplace \
    --action trigger --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  [ "$(jq -r '.adapter_metadata.channel' "$OUTPUT")" = "claude-marketplace" ]
}

@test "TC-PUB-1: claude-marketplace verify emits PASSED envelope on success" {
  MARKETPLACE_VERIFY_MOCK_OUTCOME=PASSED run _run_adapter claude-marketplace \
    --action verify --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  [ "$(jq -r '.adapter_metadata.action' "$OUTPUT")" = "verify" ]
}

@test "TC-PUB-1: claude-marketplace verify emits FAILED envelope on 404" {
  MARKETPLACE_VERIFY_MOCK_OUTCOME=FAILED run _run_adapter claude-marketplace \
    --action verify --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
}

@test "TC-PUB-1 (NFR-081): missing CLAUDE_MARKETPLACE_TOKEN → trigger FAILED" {
  # No mock, no token → adapter MUST refuse to publish.
  unset CLAUDE_MARKETPLACE_TOKEN MARKETPLACE_PUBLISH_MOCK
  run _run_adapter claude-marketplace \
    --action trigger --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'CLAUDE_MARKETPLACE_TOKEN missing'
}

# ---------- TC-PUB-2: npm NPM_TOKEN + dry-run ----------

@test "TC-PUB-2: npm dry-run with NPM_TOKEN reads token from env (NFR-081)" {
  NPM_PUBLISH_MOCK=1 NPM_TOKEN=test-token-value run _run_adapter npm \
    --action trigger --manifest package.json --version 1.0.0 \
    --registry https://registry.npmjs.org/ --dry-run
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'dry-run'
  jq -r '.summary' "$OUTPUT" | grep -qi 'env'
}

@test "TC-PUB-2 (NFR-081): missing NPM_TOKEN → trigger FAILED (refuses ~/.npmrc fallback)" {
  unset NPM_TOKEN NPM_PUBLISH_MOCK
  run _run_adapter npm \
    --action trigger --manifest package.json --version 1.0.0 \
    --registry https://registry.npmjs.org/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qiE 'NPM_TOKEN missing|.npmrc'
}

# ---------- TC-PUB-3: pypi twine exit-code matrix ----------

@test "TC-PUB-3: pypi twine exit 0 → PASSED" {
  TWINE_MOCK_EXIT=0 run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
}

@test "TC-PUB-3: pypi twine exit 1 → FAILED with stderr in evidence" {
  TWINE_MOCK_EXIT=1 TWINE_MOCK_STDERR="auth failure: HTTPError 401" run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.evidence[0].content' "$OUTPUT" | grep -qF '401'
}

@test "TC-PUB-3: pypi twine exit 2 → FAILED distinguishable (usage/argument error)" {
  TWINE_MOCK_EXIT=2 TWINE_MOCK_STDERR="twine: argument error" run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qF 'exit 2'
}

@test "TC-PUB-3: NO silent coercion to PASSED on twine exit 1" {
  TWINE_MOCK_EXIT=1 TWINE_MOCK_STDERR="x" run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$(jq -r '.verdict' "$OUTPUT")" != "PASSED" ]
}

# ---------- TC-PUB-4: homebrew 600s window declared ----------

@test "TC-PUB-4: homebrew adapter-manifest declares verify_retry_window_seconds: 600" {
  local manifest="$PLUGIN_DIR/scripts/adapters/publish-homebrew/adapter-manifest.yaml"
  [ -f "$manifest" ]
  local window
  window=$(yq eval '.verify_retry_window_seconds' "$manifest")
  [ "$window" = "600" ]
}

@test "TC-PUB-4: homebrew verify single-shot returns PASSED on tap-200 mock" {
  HOMEBREW_VERIFY_MOCK_OUTCOME=PASSED run _run_adapter homebrew \
    --action verify --manifest Formula/mytool.rb --version 1.0.0 \
    --registry https://github.com/myorg/homebrew-tap
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
}

@test "TC-PUB-4: homebrew verify single-shot returns FAILED on tap-404 (orchestrator handles retry)" {
  # NOTE: orchestrator step-4 owns the 600s retry-window loop per E100-S3.
  # The adapter itself is single-shot — a single 404 from the tap probe.
  HOMEBREW_VERIFY_MOCK_OUTCOME=FAILED run _run_adapter homebrew \
    --action verify --manifest Formula/mytool.rb --version 1.0.0 \
    --registry https://github.com/myorg/homebrew-tap
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
}

# ---------- Contract conformance: all 4 adapters ----------

@test "All 4 adapters comply with FR-526 (--action mandatory, fails on missing)" {
  for ch in claude-marketplace npm pypi homebrew; do
    run "$PLUGIN_DIR/scripts/adapters/publish-$ch/run.sh" --version 1.0.0 --manifest x --registry x --output "$TEST_TMP/o-$ch.json"
    [ "$status" -ne 0 ] || { echo "$ch did not fail on missing --action" >&2; false; }
  done
}

@test "All 4 adapters comply with FR-526 (--dry-run accepted)" {
  # All four adapters accept --dry-run without crashing.
  for ch in claude-marketplace npm pypi homebrew; do
    case "$ch" in
      claude-marketplace) MARKETPLACE_PUBLISH_MOCK=1 ;;
      npm) NPM_PUBLISH_MOCK=1; export NPM_TOKEN=test ;;
      pypi) export TWINE_MOCK_EXIT=0 ;;
      homebrew) HOMEBREW_MOCK=1 ;;
    esac
    run env CLAUDE_MARKETPLACE_TOKEN=x NPM_TOKEN=x PYPI_API_TOKEN=x HOMEBREW_GITHUB_TOKEN=x \
        MARKETPLACE_PUBLISH_MOCK=1 NPM_PUBLISH_MOCK=1 HOMEBREW_MOCK=1 \
        "$PLUGIN_DIR/scripts/adapters/publish-$ch/run.sh" \
        --action trigger --manifest m --version 1.0.0 --registry r --output "$TEST_TMP/dr-$ch.json" --dry-run
    [ "$status" -eq 0 ]
    bash "$ENVELOPE_VAL" "$TEST_TMP/dr-$ch.json"
  done
}

@test "All 4 adapters comply with FR-526 (unknown flag rejected — fail-closed AC2)" {
  for ch in claude-marketplace npm pypi homebrew; do
    run "$PLUGIN_DIR/scripts/adapters/publish-$ch/run.sh" \
      --action trigger --manifest m --version 1.0.0 --registry r --output "$TEST_TMP/uf-$ch.json" --bogus
    [ "$status" -ne 0 ] || { echo "$ch did not reject --bogus" >&2; false; }
    echo "$output" | grep -qF 'unknown flag'
  done
}

@test "All 4 adapter-manifest.yaml files validate against adapter-manifest.schema.json shape" {
  local schema="$PLUGIN_DIR/schemas/adapter-manifest.schema.json"
  [ -f "$schema" ]
  for ch in claude-marketplace npm pypi homebrew; do
    local manifest="$PLUGIN_DIR/scripts/adapters/publish-$ch/adapter-manifest.yaml"
    [ -f "$manifest" ]
    # Top-level required fields present.
    for field in adapter_name adapter_version channel verify_retry_window_seconds credential_env_vars description; do
      yq eval ".$field" "$manifest" | grep -qv '^null$' || { echo "$ch missing $field" >&2; false; }
    done
    # Window within SR-83 cap.
    local window
    window=$(yq eval '.verify_retry_window_seconds' "$manifest")
    [ "$window" -le 3600 ] || { echo "$ch window $window exceeds SR-83 cap" >&2; false; }
  done
}
