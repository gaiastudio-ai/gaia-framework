#!/usr/bin/env bats
# sprint-review-track-b-failed-routing.bats — Track B FAILED verdict routing
#
# Validates that a FAILED Track B result correctly propagates through the
# compose-verdict reducer and routes to /gaia-correct-course via the
# type-target-resolver sprint-correction type.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  COMPOSE_VERDICT="$PLUGIN_DIR/skills/gaia-sprint-review/scripts/compose-verdict.sh"
  RUNNER="$PLUGIN_DIR/skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
  RESOLVER="$PLUGIN_DIR/skills/gaia-meeting/scripts/lib/type-target-resolver.sh"
  SKILL_MD="$PLUGIN_DIR/skills/gaia-sprint-review/SKILL.md"
  FIXTURE_DIR="$PLUGIN_DIR/skills/gaia-sprint-review/tests/fixtures"
  FIXTURE="$FIXTURE_DIR/test-fixture-command.sh"

  TMPDIR_TEST="$(mktemp -d)"
  CONFIG="$TMPDIR_TEST/test-config.yaml"

  # Mock dispatch-surface.sh — emit controlled per-surface JSON.
  MOCK_DISPATCH_DIR="$TMPDIR_TEST/mock-dispatch"
  mkdir -p "$MOCK_DISPATCH_DIR"
  export DISPATCH_SURFACE_BIN="$MOCK_DISPATCH_DIR/dispatch-surface.sh"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# Helper to write a config with a backend stack.
write_config_for_verdict() {
  cat >"$CONFIG" <<EOF
project_name: test-project
platforms: [server]
sprint_review:
  backend_commands:
    node: "FIXTURE_EXIT_CODE=${1:-0} FIXTURE_STDOUT='ok' $FIXTURE"
  timeout_per_stack: 5
  manual_test:
    api_command: "echo api-smoke"
EOF
  mkdir -p "$TMPDIR_TEST/.gaia/memory/checkpoints"
  cat >"$TMPDIR_TEST/.gitignore" <<EOF
.gaia/memory/checkpoints/sprint-review-*
EOF
}

# Helper to write a mock dispatch-surface.sh with a given verdict for all surfaces.
write_mock_dispatch() {
  local verdict="${1:-SKIPPED}"
  cat >"$MOCK_DISPATCH_DIR/dispatch-surface.sh" <<MOCK
#!/usr/bin/env bash
SURFACE=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --surface) SURFACE="\$2"; shift 2 ;;
    *)         shift ;;
  esac
done
printf '{"surface":"%s","verdict":"${verdict}","reason":"mock"}\n' "\$SURFACE"
MOCK
  chmod +x "$MOCK_DISPATCH_DIR/dispatch-surface.sh"
}

# ---------------------------------------------------------------------------
# AC2: Track B FAILED + Track A PASSED → composite FAILED
# ---------------------------------------------------------------------------

@test "compose-verdict (PASSED, FAILED) → FAILED" {
  result=$(bash "$COMPOSE_VERDICT" --track-a PASSED --track-b FAILED 2>/dev/null)
  [ "$result" = "FAILED" ]
}

@test "compose-verdict (FAILED, FAILED) → FAILED" {
  result=$(bash "$COMPOSE_VERDICT" --track-a FAILED --track-b FAILED 2>/dev/null)
  [ "$result" = "FAILED" ]
}

# ---------------------------------------------------------------------------
# AC2: type-target-resolver sprint-correction → /gaia-correct-course
# ---------------------------------------------------------------------------

@test "type-target-resolver resolves sprint-correction to /gaia-correct-course" {
  result=$(bash "$RESOLVER" sprint-correction)
  [ "$result" = "/gaia-correct-course" ]
}

# ---------------------------------------------------------------------------
# AC2: SKIPPED-only Track B does NOT produce FAILED
# ---------------------------------------------------------------------------

@test "compose-verdict (PASSED, SKIPPED) → PASSED (not FAILED)" {
  result=$(bash "$COMPOSE_VERDICT" --track-a PASSED --track-b SKIPPED 2>/dev/null)
  [ "$result" = "PASSED" ]
}

@test "compose-verdict (PASSED, PASSED) → PASSED (regression guard)" {
  result=$(bash "$COMPOSE_VERDICT" --track-a PASSED --track-b PASSED 2>/dev/null)
  [ "$result" = "PASSED" ]
}

# ---------------------------------------------------------------------------
# AC2: Track A FAILED regression guard — Track A FAILED still produces FAILED
# ---------------------------------------------------------------------------

@test "compose-verdict (FAILED, PASSED) → FAILED (Track A FAILED regression guard)" {
  result=$(bash "$COMPOSE_VERDICT" --track-a FAILED --track-b PASSED 2>/dev/null)
  [ "$result" = "FAILED" ]
}

@test "compose-verdict (FAILED, SKIPPED) → FAILED (Track A FAILED + stub Track B)" {
  result=$(bash "$COMPOSE_VERDICT" --track-a FAILED --track-b SKIPPED 2>/dev/null)
  [ "$result" = "FAILED" ]
}

# ---------------------------------------------------------------------------
# AC2: SKILL.md Step 7 documents the sprint-correction → /gaia-correct-course routing
# ---------------------------------------------------------------------------

@test "SKILL.md Step 7 documents sprint-correction type and /gaia-correct-course handoff" {
  grep -q 'sprint-correction' "$SKILL_MD"
  grep -q '/gaia-correct-course' "$SKILL_MD"
}

@test "SKILL.md Step 7 documents that manual-test findings follow the same envelope pipeline" {
  # Step 7 should explicitly note manual-test findings route through the
  # same action-items pipeline (not an ad-hoc path)
  grep -qiE 'manual-test.*finding.*same.*pipeline|manual-test.*envelope.*review-gate.*action-items' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC2: track_b_verdict — composite verdict derivation is script-proven
# ---------------------------------------------------------------------------

@test "track_b_verdict is FAILED when any envelope verdict is FAILED" {
  write_config_for_verdict 0
  # Mock: one surface returns FAILED
  cat >"$MOCK_DISPATCH_DIR/dispatch-surface.sh" <<'MOCK'
#!/usr/bin/env bash
SURFACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surface) SURFACE="$2"; shift 2 ;;
    *)         shift ;;
  esac
done
case "$SURFACE" in
  api) printf '{"surface":"api","verdict":"FAILED","reason":"test"}\n' ;;
  *)   printf '{"surface":"%s","verdict":"SKIPPED","reason":"mock"}\n' "$SURFACE" ;;
esac
MOCK
  chmod +x "$MOCK_DISPATCH_DIR/dispatch-surface.sh"
  cd "$TMPDIR_TEST"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  json=$(echo "$output" | sed -n '/^{/,/^}/p')
  track_b_v=$(echo "$json" | jq -r '.track_b_verdict')
  [ "$track_b_v" = "FAILED" ]
}

@test "track_b_verdict is PASSED when all envelopes are SKIPPED" {
  write_config_for_verdict 0
  write_mock_dispatch "SKIPPED"
  cd "$TMPDIR_TEST"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  json=$(echo "$output" | sed -n '/^{/,/^}/p')
  track_b_v=$(echo "$json" | jq -r '.track_b_verdict')
  [ "$track_b_v" = "PASSED" ]
}

@test "track_b_verdict is PASSED for a PASSED+PENDING mix" {
  write_config_for_verdict 0
  # Mock: api PASSED, browser PENDING, rest SKIPPED
  cat >"$MOCK_DISPATCH_DIR/dispatch-surface.sh" <<'MOCK'
#!/usr/bin/env bash
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
  *)       printf '{"surface":"%s","verdict":"SKIPPED","reason":"mock"}\n' "$SURFACE" ;;
esac
MOCK
  chmod +x "$MOCK_DISPATCH_DIR/dispatch-surface.sh"
  cd "$TMPDIR_TEST"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  json=$(echo "$output" | sed -n '/^{/,/^}/p')
  track_b_v=$(echo "$json" | jq -r '.track_b_verdict')
  [ "$track_b_v" = "PASSED" ]
}

@test "track_b_verdict is always a canonical value (never raw PENDING)" {
  write_config_for_verdict 0
  # All surfaces return PENDING — the composite must be a canonical track value,
  # never the raw PENDING envelope verdict. With the fail-closed functional-
  # coverage rule, an all-PENDING run with a configured functional smoke that
  # never produced a real pass (and a user-facing surface present) composes to
  # UNVERIFIED — canonical, and correctly NOT a silent PASSED. The invariant
  # under test: the composite is one of {PASSED,FAILED,UNVERIFIED}, never PENDING.
  write_mock_dispatch "PENDING"
  cd "$TMPDIR_TEST"
  run bash "$RUNNER" --sprint sprint-50 --config "$CONFIG"
  [ "$status" -eq 0 ]
  json=$(echo "$output" | sed -n '/^{/,/^}/p')
  track_b_v=$(echo "$json" | jq -r '.track_b_verdict')
  case "$track_b_v" in
    PASSED|FAILED|UNVERIFIED) : ;;
    *) printf 'non-canonical track_b_verdict: %s\n' "$track_b_v"; false ;;
  esac
  [ "$track_b_v" != "PENDING" ]
}

# ---------------------------------------------------------------------------
# W4: compose-verdict rejects raw PENDING (negative guard)
# ---------------------------------------------------------------------------

@test "compose-verdict rejects raw PENDING as non-canonical input" {
  run bash "$COMPOSE_VERDICT" --track-a PASSED --track-b PENDING 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-canonical"* ]]
}
