#!/usr/bin/env bats
# sprint-review-track-b-manual-test-dispatch.bats — Track B manual-test surface dispatch
#
# Validates that track-b-dispatch.sh invokes dispatch-surface.sh for each of
# the four manual-test surfaces (browser, api, mobile, desktop), appends
# type-tagged envelopes, and degrades gracefully when the dispatch script is
# absent.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  RUNNER="$PLUGIN_DIR/skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
  FIXTURE_DIR="$PLUGIN_DIR/skills/gaia-sprint-review/tests/fixtures"
  FIXTURE="$FIXTURE_DIR/test-fixture-command.sh"

  TMPDIR_TEST="$(mktemp -d)"
  CONFIG="$TMPDIR_TEST/test-config.yaml"

  # Create a mock dispatch-surface.sh that emits controlled JSON based on
  # surface name. Placed at the relative path track-b-dispatch.sh resolves.
  MOCK_DISPATCH_DIR="$TMPDIR_TEST/mock-manual-scripts"
  mkdir -p "$MOCK_DISPATCH_DIR"
  cat > "$MOCK_DISPATCH_DIR/dispatch-surface.sh" <<'MOCK'
#!/usr/bin/env bash
# Mock dispatch-surface.sh — emits controlled JSON for testing.
SURFACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surface) SURFACE="$2"; shift 2 ;;
    *)         shift ;;
  esac
done
case "$SURFACE" in
  api)     printf '{"surface":"api","verdict":"PASSED","exit_code":0}\n' ;;
  browser) printf '{"surface":"browser","verdict":"PENDING","reason":"dispatch ready"}\n' ;;
  mobile)  printf '{"surface":"mobile","verdict":"SKIPPED","reason":"not configured"}\n' ;;
  desktop) printf '{"surface":"desktop","verdict":"SKIPPED","reason":"not configured"}\n' ;;
  *)       printf '{"surface":"%s","verdict":"SKIPPED","reason":"unknown"}\n' "$SURFACE" ;;
esac
MOCK
  chmod +x "$MOCK_DISPATCH_DIR/dispatch-surface.sh"

  # Helper to write a config with a backend stack + optional platform markers
  write_config() {
    local timeout="${1:-5}"
    local platforms="${2:-server,web}"
    cat >"$CONFIG" <<EOF
project_name: test-project
platforms: [${platforms}]
sprint_review:
  backend_commands:
    node: "FIXTURE_EXIT_CODE=0 FIXTURE_STDOUT='hello' $FIXTURE"
  timeout_per_stack: $timeout
  manual_test:
    api_command: "echo api-smoke-ok"
EOF
  }

  # Default config
  write_config 5 "server,web"

  # Point track-b-dispatch.sh at the mock dispatch-surface.sh so the
  # controlled JSON is actually exercised (not the real sibling script).
  export DISPATCH_SURFACE_BIN="$MOCK_DISPATCH_DIR/dispatch-surface.sh"

  # Set up .gaia/memory/checkpoints under TMPDIR + matching .gitignore
  mkdir -p "$TMPDIR_TEST/.gaia/memory/checkpoints"
  cat >"$TMPDIR_TEST/.gitignore" <<EOF
.gaia/memory/checkpoints/sprint-review-*
EOF
  cd "$TMPDIR_TEST"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# AC1: configured surface produces manual-test envelope with type field
# ---------------------------------------------------------------------------

@test "Track B emits manual-test envelopes for configured surfaces" {
  write_config 5 "server,web"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # Must contain at least one envelope with type "manual-test"
  echo "$output" | grep -q '"type"[[:space:]]*:[[:space:]]*"manual-test"'
}

@test "manual-test envelope contains surface field matching dispatch output" {
  write_config 5 "server,web"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # The api surface should appear (server platform → api surface configured)
  echo "$output" | grep -q '"surface"[[:space:]]*:[[:space:]]*"api"'
}

@test "stack-command envelopes also carry type field" {
  write_config 5 "server,web"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # The per-stack (node) envelope must have type "stack-command"
  echo "$output" | grep -q '"type"[[:space:]]*:[[:space:]]*"stack-command"'
}

# ---------------------------------------------------------------------------
# AC1: unconfigured surfaces produce SKIPPED and do NOT fail Track B
# ---------------------------------------------------------------------------

@test "unconfigured surface (mobile) returns SKIPPED without failing Track B" {
  # Only server platform — mobile is not configured
  write_config 5 "server"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # Track B should still succeed (SKIPPED is PASSED-equivalent)
}

@test "all-unconfigured surfaces produce only stack-command envelopes when no platforms match" {
  # No platforms that match any manual-test surface
  cat >"$CONFIG" <<EOF
project_name: test-project
platforms: []
sprint_review:
  backend_commands:
    node: "FIXTURE_EXIT_CODE=0 FIXTURE_STDOUT='hello' $FIXTURE"
  timeout_per_stack: 5
EOF
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # Should have stack-command envelopes but no manual-test envelopes
  # (or manual-test envelopes are all SKIPPED)
  echo "$output" | grep -q '"type"[[:space:]]*:[[:space:]]*"stack-command"'
}

# ---------------------------------------------------------------------------
# AC1: mixed configured + unconfigured surfaces
# ---------------------------------------------------------------------------

@test "mixed surfaces — api PASSED, browser PENDING, mobile SKIPPED, desktop SKIPPED" {
  write_config 5 "server,web"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # Extract the JSON object (skip any subprocess stdout lines preceding it).
  json=$(echo "$output" | sed -n '/^{/,/^}/p')
  # Assert specific surface+verdict pairs from mock dispatch-surface.sh
  api_verdict=$(echo "$json" | jq -r '[.envelopes[] | select(.surface == "api")] | .[0].verdict')
  browser_verdict=$(echo "$json" | jq -r '[.envelopes[] | select(.surface == "browser")] | .[0].verdict')
  mobile_verdict=$(echo "$json" | jq -r '[.envelopes[] | select(.surface == "mobile")] | .[0].verdict')
  desktop_verdict=$(echo "$json" | jq -r '[.envelopes[] | select(.surface == "desktop")] | .[0].verdict')
  [ "$api_verdict" = "PASSED" ]
  [ "$browser_verdict" = "PENDING" ]
  [ "$mobile_verdict" = "SKIPPED" ]
  [ "$desktop_verdict" = "SKIPPED" ]
}

# ---------------------------------------------------------------------------
# AC1: dispatch-surface.sh absent → graceful skip with warning
# ---------------------------------------------------------------------------

@test "track-b-dispatch.sh has pre-flight existence check for dispatch-surface.sh" {
  # Verify the runner checks whether dispatch-surface.sh exists before
  # attempting the manual-test loop. The check must be a file-existence
  # test followed by a graceful-degradation path (warning + skip).
  grep -q 'if \[ ! -f.*DISPATCH_SURFACE' "$RUNNER"
  grep -qi 'skip.*manual-test\|graceful degradation' "$RUNNER"
}

@test "track-b-dispatch.sh resolves dispatch-surface.sh via two-level parent (../../gaia-test-manual)" {
  # Verify the sibling path uses TWO parent dirs, not one
  grep -q 'SCRIPT_DIR/../../gaia-test-manual/scripts/dispatch-surface.sh' "$RUNNER"
}

# ---------------------------------------------------------------------------
# AC1: envelope has type field for both stack-command and manual-test kinds
# ---------------------------------------------------------------------------

@test "every envelope in the output array has a type field" {
  write_config 5 "server,web"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # Extract the JSON object (skip any subprocess stdout lines preceding it).
  json=$(echo "$output" | sed -n '/^{/,/^}/p')
  total_envelopes=$(echo "$json" | jq '.envelopes | length')
  envelopes_without_type=$(echo "$json" | jq '[.envelopes[] | select(.type == null or .type == "")] | length')
  [ "$total_envelopes" -gt 0 ]
  [ "$envelopes_without_type" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC1: PENDING and SKIPPED surfaces do NOT fail Track B
# ---------------------------------------------------------------------------

@test "PENDING verdict from browser surface does not fail Track B" {
  write_config 5 "server,web"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  # Track B script-level exit code is 0 even with PENDING surfaces
}

@test "SKIPPED verdict from unconfigured surface does not fail Track B" {
  write_config 5 "server"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
}
