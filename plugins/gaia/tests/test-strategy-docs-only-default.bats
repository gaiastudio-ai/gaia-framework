#!/usr/bin/env bats
# test-strategy-docs-only-default.bats
#
# Defect A: finalize.sh auto-stubs missing project-config.yaml sections by
# default. A plain --plan doc-authoring run should NOT mutate the config.
# No-mutation must be the DEFAULT; auto-stub must be opt-IN.
#
# Defect B: finalize.sh resolves .gaia/... and config/ paths against CWD
# instead of anchoring them to the project root. When invoked from a
# different CWD, paths break.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FINALIZE="$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
}

teardown() { common_teardown; }

# Build a minimal fixture: a config missing test_execution + a written
# strategy artifact. The config has content we can checksum to detect
# mutation.
_mk_docs_fixture() {
  local tmp="$1"
  mkdir -p "$tmp/.gaia/config" "$tmp/.gaia/artifacts/planning-artifacts" "$tmp/_memory/checkpoints"
  cat > "$tmp/.gaia/config/project-config.yaml" <<'YAML'
config_phase: partial
project_name: docs-only-test
stacks:
  backend: {}
platforms:
  - server
YAML
  cat > "$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" <<'MD'
---
artifact_type: test-strategy
---
# Test Strategy
## Risk Assessment
High, medium, low risk tiers.
## Scope
Unit, integration, e2e — test pyramid and test levels coverage.
## Coverage targets
Code coverage target: 80%.
MD
}

# ---------- AC1: docs-only --plan run does NOT mutate config ----------

@test "docs-only finalize does not mutate project-config.yaml by default (AC1)" {
  local tmp="$BATS_TEST_TMPDIR/ac1-no-mutate"
  _mk_docs_fixture "$tmp"
  local cfg="$tmp/.gaia/config/project-config.yaml"
  local before
  before="$(cat "$cfg")"
  cd "$tmp"
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>"$tmp/stderr.log" || true
  local after
  after="$(cat "$cfg")"
  # Config must be byte-identical — no mutation.
  [ "$before" = "$after" ]
}

@test "docs-only finalize emits NOTICE naming missing sections (AC1)" {
  local tmp="$BATS_TEST_TMPDIR/ac1-notice"
  _mk_docs_fixture "$tmp"
  cd "$tmp"
  local stderr_log="$tmp/stderr.log"
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>"$stderr_log" || true
  # NOTICE must name the missing sections.
  grep -qF 'NOTICE' "$stderr_log"
  grep -qF 'test_execution' "$stderr_log"
  grep -qF 'test_execution_bridge' "$stderr_log"
  grep -qF 'environments' "$stderr_log"
}

@test "docs-only finalize NOTICE names the remediation skills (AC1)" {
  local tmp="$BATS_TEST_TMPDIR/ac1-remediation"
  _mk_docs_fixture "$tmp"
  cd "$tmp"
  local stderr_log="$tmp/stderr.log"
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>"$stderr_log" || true
  grep -qF '/gaia-config-test' "$stderr_log"
  grep -qF '/gaia-bridge-enable' "$stderr_log"
  grep -qF '/gaia-config-env' "$stderr_log"
}

@test "explicit GAIA_TEST_STRATEGY_DOCS_ONLY=1 is redundant but harmless — still no mutation (AC1)" {
  local tmp="$BATS_TEST_TMPDIR/ac1-docs-only-compat"
  _mk_docs_fixture "$tmp"
  local cfg="$tmp/.gaia/config/project-config.yaml"
  local before
  before="$(cat "$cfg")"
  cd "$tmp"
  GAIA_TEST_STRATEGY_DOCS_ONLY=1 \
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>/dev/null || true
  local after
  after="$(cat "$cfg")"
  [ "$before" = "$after" ]
}

# ---------- AC2: config mutation opt-in ----------

@test "auto-stub writes missing sections when GAIA_TEST_STRATEGY_AUTOSTUB=1 (AC2)" {
  local tmp="$BATS_TEST_TMPDIR/ac2-autostub"
  _mk_docs_fixture "$tmp"
  local cfg="$tmp/.gaia/config/project-config.yaml"
  cd "$tmp"
  GAIA_TEST_STRATEGY_AUTOSTUB=1 \
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>/dev/null || true
  # All three missing sections must now be present.
  grep -qE '^test_execution:' "$cfg"
  grep -qF 'test_execution_bridge:' "$cfg"
  grep -qE '^environments:' "$cfg"
}

@test "scaffold-mode env vars trigger auto-stub without AUTOSTUB flag (AC2)" {
  local tmp="$BATS_TEST_TMPDIR/ac2-scaffold"
  _mk_docs_fixture "$tmp"
  local cfg="$tmp/.gaia/config/project-config.yaml"
  mkdir -p "$tmp/tests"
  cd "$tmp"
  SCAFFOLD_CONFIG_PATH="$tmp/vitest.config.ts" \
  SCAFFOLD_TEST_DIR="$tmp/tests" \
  TEST_STRATEGY_ARTIFACT="$tmp/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>/dev/null || true
  # Auto-stub should have fired because scaffold mode signals are present.
  grep -qE '^test_execution:' "$cfg"
  grep -qF 'test_execution_bridge:' "$cfg"
  grep -qE '^environments:' "$cfg"
}

# ---------- AC2 (paths): CLAUDE_PROJECT_ROOT anchoring ----------

@test "finalize resolves config and artifact paths via CLAUDE_PROJECT_ROOT, not CWD (AC2)" {
  local project="$BATS_TEST_TMPDIR/ac2-projroot"
  local elsewhere="$BATS_TEST_TMPDIR/ac2-elsewhere"
  _mk_docs_fixture "$project"
  mkdir -p "$elsewhere"
  # Run from $elsewhere with CLAUDE_PROJECT_ROOT pointing at $project.
  cd "$elsewhere"
  CLAUDE_PROJECT_ROOT="$project" \
  TEST_STRATEGY_ARTIFACT="$project/.gaia/artifacts/planning-artifacts/test-strategy.md" \
    bash "$FINALIZE" 2>"$elsewhere/stderr.log" || true
  # The NOTICE should reference missing sections (proving it found the config
  # under CLAUDE_PROJECT_ROOT, not under CWD which has no .gaia/).
  grep -qF 'test_execution' "$elsewhere/stderr.log"
  # CWD ($elsewhere) must NOT have config or artifacts dirs created in it.
  # (.gaia/memory may be created by checkpoint.sh — that is out of scope.)
  [ ! -d "$elsewhere/.gaia/config" ]
  [ ! -d "$elsewhere/.gaia/artifacts" ]
}

@test "finalize finds artifact via CLAUDE_PROJECT_ROOT tier-2 probe when no env override (AC2)" {
  local project="$BATS_TEST_TMPDIR/ac2-tier2"
  local elsewhere="$BATS_TEST_TMPDIR/ac2-tier2-cwd"
  _mk_docs_fixture "$project"
  mkdir -p "$elsewhere"
  cd "$elsewhere"
  # No TEST_STRATEGY_ARTIFACT — rely on tier-2 auto-discovery anchored at
  # CLAUDE_PROJECT_ROOT.
  CLAUDE_PROJECT_ROOT="$project" \
    bash "$FINALIZE" 2>"$elsewhere/stderr.log" || true
  # Should have found the artifact at the project root and run the checklist.
  grep -qF 'SV-01' "$elsewhere/stderr.log"
}
