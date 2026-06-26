#!/usr/bin/env bash
# issue-1249-test-strategy-real-hydration.bats
#
# Config auto-hydration produced EMPTY stubs (`test_execution: {}`) so the
# downstream test-runner found the key present but with no `tier_1.command`
# to execute — the operator still had to hand-edit project-config.yaml.
#
# Fix: when the `test_execution` section is missing, the test-strategy
# finalize fail-safe now derives a REAL, runnable `tier_1` block from the
# framework's own stack-runner detector (`run-tests.sh --detect-runner`)
# and maps the detected runner token (vitest|junit|pytest|go|maestro) to a
# canonical command. It falls back to the empty `{}` stub only when no
# runner can be detected (genuinely unknown stack). The bridge + environments
# sections remain documented stubs — those have no deterministic value to
# derive without operator/CI input.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FINALIZE="$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}

teardown() { common_teardown; }

# Build a minimal fixture: a config missing test_execution + a written
# strategy artifact + a project root that the detector can fingerprint.
_mk_fixture() {
  local tmp="$1"; local runner_marker="$2"
  mkdir -p "$tmp/.gaia/config" "$tmp/.gaia/artifacts/planning-artifacts" "$tmp/_memory/checkpoints"
  cat > "$tmp/.gaia/config/project-config.yaml" <<'EOF'
config_phase: partial
project_name: hydration-test
stacks:
  backend: {}
platforms:
  - server
EOF
  cat > "$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" <<'EOF'
# Test Strategy
## Tiers
Unit, integration, e2e.
EOF
  # Drop the runner fingerprint at the project root so detect-runner fires.
  case "$runner_marker" in
    pytest)  printf '[tool.pytest.ini_options]\n' > "$tmp/pyproject.toml" ;;
    go)      printf 'module example.com/x\n'      > "$tmp/go.mod" ;;
    vitest)  printf '{"devDependencies":{"vitest":"^1"}}\n' > "$tmp/package.json" ;;
    junit)   printf '<project/>\n'                > "$tmp/pom.xml" ;;
    none)    : ;;  # no marker — detection fails, expect empty-stub fallback
  esac
}

# --- the source-level contract ---

@test "issue-1249: finalize references the run-tests.sh stack-runner detector" {
  grep -qF 'run-tests.sh' "$FINALIZE"
  grep -qF -- '--detect-runner' "$FINALIZE"
}

@test "issue-1249: finalize maps detected runners to real commands (not empty stub)" {
  # Each canonical runner token must map to a real command somewhere in the
  # hydration block.
  grep -qE 'pytest' "$FINALIZE"
  grep -qE 'vitest' "$FINALIZE"
  grep -qE 'go test' "$FINALIZE"
}

@test "issue-1249: finalize still falls back to empty test_execution stub on unknown stack" {
  grep -qF 'test_execution: {}' "$FINALIZE"
}

# --- end-to-end: real value written for a detectable stack ---

@test "issue-1249 e2e: pytest project gets a runnable tier_1.command (not {})" {
  local tmp="$BATS_TEST_TMPDIR/hyd-pytest"
  _mk_fixture "$tmp" pytest
  cd "$tmp"
  GAIA_TEST_STRATEGY_AUTOSTUB=1 \
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>&1 | tee "$tmp/out.log" || true
  local cfg="$tmp/.gaia/config/project-config.yaml"
  # test_execution must now be a populated block with a real pytest command.
  grep -qE '^test_execution:' "$cfg"
  grep -qF 'tier_1:' "$cfg"
  grep -qE 'command:.*pytest' "$cfg"
  # It must NOT be the empty-map form for a detected stack.
  ! grep -qF 'test_execution: {}' "$cfg"
}

@test "issue-1249 e2e: go project gets a runnable go-test tier_1.command" {
  local tmp="$BATS_TEST_TMPDIR/hyd-go"
  _mk_fixture "$tmp" go
  cd "$tmp"
  GAIA_TEST_STRATEGY_AUTOSTUB=1 \
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>&1 || true
  local cfg="$tmp/.gaia/config/project-config.yaml"
  grep -qE 'command:.*go test' "$cfg"
}

@test "issue-1249 e2e: unknown stack falls back to empty test_execution stub (no crash)" {
  local tmp="$BATS_TEST_TMPDIR/hyd-none"
  _mk_fixture "$tmp" none
  cd "$tmp"
  run env GAIA_TEST_STRATEGY_AUTOSTUB=1 \
    TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE"
  local cfg="$tmp/.gaia/config/project-config.yaml"
  # Either the empty stub OR a present-but-empty test_execution key — but no crash.
  grep -qE '^test_execution:' "$cfg"
  # bridge + environments remain documented stubs regardless of stack.
  grep -qF 'test_execution_bridge:' "$cfg"
  grep -qE '^environments:' "$cfg"
}

@test "issue-1249 e2e: docs-only run still skips hydration entirely" {
  local tmp="$BATS_TEST_TMPDIR/hyd-docsonly"
  _mk_fixture "$tmp" pytest
  cd "$tmp"
  GAIA_TEST_STRATEGY_DOCS_ONLY=1 \
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>&1 | tee "$tmp/out.log" || true
  local cfg="$tmp/.gaia/config/project-config.yaml"
  # No test_execution section appended on a docs-only run.
  ! grep -qE '^test_execution:' "$cfg"
}
