#!/usr/bin/env bats
# AF-2026-05-22-7: config-hydration fail-safe in 3 finalize.sh skills.
#
# Bug 21 (CRITICAL, from YARA test report): /gaia-create-arch, /gaia-test-strategy,
# and /gaia-ci-setup are documented as auto-populating their owned sections of
# project-config.yaml after each successful artifact write. In practice the
# LLM orchestrator skipped this sub-step ~100% of the time, leaving
# config_phase=minimal with no stacks/platforms/test_execution/ci_cd blocks.
# Downstream skills then halted with generic "X missing" errors pointing at
# the wrong upstream remediation.
#
# Fix: each finalize.sh now ends with a hydration-check that DETECTS missing
# sections and emits a CRITICAL WARNING naming (a) the missing section,
# (b) the downstream skill that will halt, and (c) the correct remediation
# command. Non-fatal — the primary artifact has been written — but the
# warning is unmistakable so downstream halts have clear attribution.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- gaia-create-arch: fail-safe detects missing stacks / platforms ---

@test "AF-22-7 Bug-21: gaia-create-arch finalize.sh has the hydration fail-safe block" {
  grep -qF "Config hydration fail-safe" "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
}

@test "AF-22-7 Bug-21: gaia-create-arch fail-safe greps for stacks: + platforms: in project-config.yaml" {
  grep -qF '^stacks:' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
  grep -qF '^platforms:' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
}

@test "AF-22-7 Bug-21: gaia-create-arch fail-safe warning names downstream skills (/gaia-bridge-enable, /gaia-create-epics, /gaia-ci-setup)" {
  grep -qF '/gaia-bridge-enable' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
  grep -qF '/gaia-create-epics' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
  grep -qF '/gaia-ci-setup' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
}

@test "AF-22-7 Bug-21: gaia-create-arch fail-safe references config-hydration.sh + config_hydrate_section" {
  grep -qF 'scripts/lib/config-hydration.sh' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
  grep -qF 'config_hydrate_section stacks' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
  grep -qF 'config_hydrate_section platforms' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
}

# --- gaia-test-strategy: fail-safe detects missing test_execution / test_execution_bridge / environments ---

@test "AF-22-7 Bug-21: gaia-test-strategy finalize.sh has the hydration fail-safe block" {
  grep -qF "Config hydration fail-safe" "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}

@test "AF-22-7 Bug-21: gaia-test-strategy fail-safe greps for test_execution + test_execution_bridge + environments" {
  grep -qF '^test_execution:' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF '^test_execution_bridge:' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF '^environments:' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}

@test "AF-22-7 Bug-21: gaia-test-strategy fail-safe warning names downstream skills" {
  grep -qF '/gaia-bridge-enable' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF '/gaia-test-automate' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}

# --- gaia-ci-setup: fail-safe detects missing ci_cd ---

@test "AF-22-7 Bug-21: gaia-ci-setup finalize.sh has the hydration fail-safe block" {
  grep -qF "Config hydration fail-safe" "$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/finalize.sh"
}

@test "AF-22-7 Bug-21: gaia-ci-setup fail-safe greps for ci_cd: in project-config.yaml" {
  grep -qF '^ci_cd:' "$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/finalize.sh"
}

@test "AF-22-7 Bug-21: gaia-ci-setup fail-safe warning names downstream /gaia-bridge-enable" {
  grep -qF '/gaia-bridge-enable' "$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/finalize.sh"
}

# --- All three accept canonical OR legacy config-yaml location ---

@test "AF-22-7 Bug-21: all three fail-safes accept both .gaia/config/ (canonical) and config/ (legacy) yaml locations" {
  for skill in gaia-create-arch gaia-test-strategy gaia-ci-setup; do
    grep -qF '.gaia/config/project-config.yaml' "$PLUGIN_ROOT/skills/$skill/scripts/finalize.sh"
    grep -qF '"config/project-config.yaml"' "$PLUGIN_ROOT/skills/$skill/scripts/finalize.sh"
  done
}

# --- End-to-end: fail-safe fires when sections missing ---

@test "AF-22-7 Bug-21 e2e: gaia-create-arch finalize.sh prints WARNING when stacks: + platforms: are missing" {
  # Set up a minimal config + a written architecture artifact + run finalize.
  local tmp="$BATS_TEST_TMPDIR/yara-fixture"
  mkdir -p "$tmp/.gaia/config" "$tmp/.gaia/artifacts/planning-artifacts" "$tmp/_memory/checkpoints"
  cat > "$tmp/.gaia/config/project-config.yaml" <<'EOF'
config_phase: minimal
project_name: yara-test
EOF
  cat > "$tmp/.gaia/artifacts/planning-artifacts/architecture.md" <<'EOF'
# Architecture
## Decision Log
| ADR | Decision |
EOF
  cd "$tmp"
  # Stub out scripts the finalize script invokes that depend on a config we
  # don't fully populate; the fail-safe is what we're testing here.
  ARCHITECTURE_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/architecture.md" \
    bash "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh" 2>&1 | tee "$tmp/out.log" || true
  # The WARNING about missing stacks: + platforms: should appear.
  grep -qF "WARNING: architecture.md was written but project-config.yaml hydration was SKIPPED" "$tmp/out.log"
  grep -qF "config_phase is still 'minimal'" "$tmp/out.log"
}

@test "AF-22-7 Bug-21 e2e: gaia-create-arch finalize.sh does NOT warn when stacks: + platforms: are present" {
  local tmp="$BATS_TEST_TMPDIR/yara-fixture-hydrated"
  mkdir -p "$tmp/.gaia/config" "$tmp/.gaia/artifacts/planning-artifacts" "$tmp/_memory/checkpoints"
  cat > "$tmp/.gaia/config/project-config.yaml" <<'EOF'
config_phase: partial
project_name: yara-test
stacks:
  backend-node: {}
platforms:
  - web
EOF
  cat > "$tmp/.gaia/artifacts/planning-artifacts/architecture.md" <<'EOF'
# Architecture
EOF
  cd "$tmp"
  ARCHITECTURE_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/architecture.md" \
    bash "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh" 2>&1 | tee "$tmp/out.log" || true
  # The WARNING must NOT fire when both sections are present.
  ! grep -qF "WARNING: architecture.md was written but project-config.yaml hydration was SKIPPED" "$tmp/out.log"
}
