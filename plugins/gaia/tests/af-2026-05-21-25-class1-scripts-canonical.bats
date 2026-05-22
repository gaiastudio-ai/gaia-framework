#!/usr/bin/env bats
# AF-21-25: 8 Class-1 scripts (bare-legacy → canonical-first/three-tier).
# Covers script-side migration not handled by AF-21-10..-24 SKILL.md sweep.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- All 8 scripts have canonical-first awareness ---

@test "AF-21-25: gaia-readiness-check/finalize.sh has canonical .gaia/ awareness" {
  grep -qF '.gaia/artifacts/planning-artifacts/' "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/finalize.sh"
}

@test "AF-21-25: gaia-infra-design/finalize.sh implements three-tier idiom" {
  grep -qE 'elif \[ -f "docs/planning-artifacts/infrastructure-design\.md" \] && \[ ! -d "\.gaia/artifacts/planning-artifacts" \]' "$PLUGIN_ROOT/skills/gaia-infra-design/scripts/finalize.sh"
  grep -qE 'elif \[ -f "\.gaia/artifacts/planning-artifacts/infrastructure-design\.md" \]' "$PLUGIN_ROOT/skills/gaia-infra-design/scripts/finalize.sh"
}

@test "AF-21-25: gaia-brainstorm/finalize.sh implements three-tier idiom" {
  grep -qF '.gaia/artifacts/creative-artifacts/brainstorm-' "$PLUGIN_ROOT/skills/gaia-brainstorm/scripts/finalize.sh"
  grep -qF '[ ! -d ".gaia/artifacts/creative-artifacts" ]' "$PLUGIN_ROOT/skills/gaia-brainstorm/scripts/finalize.sh"
}

@test "AF-21-25: gaia-domain-research/finalize.sh implements three-tier idiom" {
  grep -qF '.gaia/artifacts/planning-artifacts/domain-research.md' "$PLUGIN_ROOT/skills/gaia-domain-research/scripts/finalize.sh"
}

@test "AF-21-25: gaia-market-research/finalize.sh implements three-tier idiom" {
  grep -qF '.gaia/artifacts/planning-artifacts/market-research.md' "$PLUGIN_ROOT/skills/gaia-market-research/scripts/finalize.sh"
}

@test "AF-21-25: gaia-edit-arch/setup.sh implements three-tier ARCH_PATH idiom" {
  grep -qF '.gaia/artifacts/planning-artifacts/architecture.md' "$PLUGIN_ROOT/skills/gaia-edit-arch/scripts/setup.sh"
  grep -qE 'if \[ -z "\$\{ARCH_PATH:-\}" \]' "$PLUGIN_ROOT/skills/gaia-edit-arch/scripts/setup.sh"
}

@test "AF-21-25: gaia-ci-setup/finalize.sh remediation message uses canonical path" {
  grep -qF '.gaia/artifacts/test-artifacts/ci-setup.md' "$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/finalize.sh"
}

@test "AF-21-25: check-monolith-shard-sync.sh resolves canonical artifacts dir first" {
  grep -qF '.gaia/artifacts/planning-artifacts' "$PLUGIN_ROOT/scripts/check-monolith-shard-sync.sh"
  grep -qE 'if \[ -d "\$ROOT/\.gaia/artifacts/planning-artifacts" \]' "$PLUGIN_ROOT/scripts/check-monolith-shard-sync.sh"
}

@test "AF-21-25: gaia-readiness-check/finalize.sh prd_referenced_file_exists helper canonical-first" {
  # New canonical-first helper checks BOTH canonical and legacy paths.
  grep -qF 'canonical_rel=' "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/finalize.sh"
  grep -qF 'legacy_rel="docs/' "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/finalize.sh"
}
