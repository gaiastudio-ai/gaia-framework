#!/usr/bin/env bats
# af-2026-05-21-15-trace-threat-model-canonical.bats
#
# Regression coverage for AF-2026-05-21-15: /gaia-trace and /gaia-threat-model
# hardcoded legacy docs/planning-artifacts/ and docs/test-artifacts/ paths.
# Hybrid pattern: gaia-trace is SKILL.md-only (no scripts have legacy refs);
# gaia-threat-model/finalize.sh had bare legacy → three-tier idiom applied.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRACE_SKILL="$PLUGIN_ROOT/skills/gaia-trace/SKILL.md"
  THREAT_MODEL_SKILL="$PLUGIN_ROOT/skills/gaia-threat-model/SKILL.md"
  THREAT_MODEL_FINALIZE="$PLUGIN_ROOT/skills/gaia-threat-model/scripts/finalize.sh"
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# --- SKILL.md prose canonical assertions ---

@test "AF-21-15: gaia-trace/SKILL.md uses canonical .gaia/ paths" {
  grep -qF '.gaia/artifacts/test-artifacts/traceability-matrix.md' "$TRACE_SKILL"
  grep -qF '.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md' "$TRACE_SKILL"
}

@test "AF-21-15: gaia-trace/SKILL.md preserves ADR-072 strategy-fallback (both branches canonical)" {
  # Both flat AND strategy/ canonical roots present
  grep -qF '.gaia/artifacts/test-artifacts/traceability-matrix.md' "$TRACE_SKILL"
  grep -qF '.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md' "$TRACE_SKILL"
  # Both flat AND strategy/ test-plan canonical roots present
  grep -qF '.gaia/artifacts/test-artifacts/test-plan.md' "$TRACE_SKILL"
  grep -qF '.gaia/artifacts/test-artifacts/strategy/test-plan.md' "$TRACE_SKILL"
}

@test "AF-21-15: gaia-trace/SKILL.md preserves ADR-069 sharded-fallback (both branches canonical)" {
  grep -qF '.gaia/artifacts/planning-artifacts/prd.md' "$TRACE_SKILL"
  grep -qF '.gaia/artifacts/planning-artifacts/prd/prd.md' "$TRACE_SKILL"
}

@test "AF-21-15: gaia-trace/SKILL.md has no remaining legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts)' "$TRACE_SKILL"
}

@test "AF-21-15: gaia-threat-model/SKILL.md uses canonical .gaia/ paths" {
  grep -qF '.gaia/artifacts/planning-artifacts/threat-model.md' "$THREAT_MODEL_SKILL"
  grep -qF '.gaia/artifacts/planning-artifacts/architecture.md' "$THREAT_MODEL_SKILL"
}

@test "AF-21-15: gaia-threat-model/SKILL.md has no remaining legacy docs/ write-path literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts)' "$THREAT_MODEL_SKILL"
}

# --- threat-model/finalize.sh three-tier idiom assertions ---

@test "AF-21-15: gaia-threat-model/scripts/finalize.sh implements three-tier idiom verbatim" {
  grep -qE 'if \[ -n "\$\{THREAT_MODEL_ARTIFACT:-\}" \]' "$THREAT_MODEL_FINALIZE"
  grep -qE 'elif \[ -f "docs/planning-artifacts/threat-model\.md" \] && \[ ! -d "\.gaia/artifacts/planning-artifacts" \]' "$THREAT_MODEL_FINALIZE"
  grep -qE 'elif \[ -f "\.gaia/artifacts/planning-artifacts/threat-model\.md" \]' "$THREAT_MODEL_FINALIZE"
}

@test "AF-21-15: threat-model finalize.sh — greenfield → skips checklist" {
  unset THREAT_MODEL_ARTIFACT
  OUTPUT=$(bash "$THREAT_MODEL_FINALIZE" 2>&1 || true)
  echo "$OUTPUT" | grep -qF "no threat-model artifact found"
  ! echo "$OUTPUT" | grep -qF "running 25-item checklist"
}

@test "AF-21-15: threat-model finalize.sh — post-ADR-111 → resolves to canonical" {
  unset THREAT_MODEL_ARTIFACT
  mkdir -p ".gaia/artifacts/planning-artifacts"
  echo "# Threat Model" > ".gaia/artifacts/planning-artifacts/threat-model.md"
  OUTPUT=$(bash "$THREAT_MODEL_FINALIZE" 2>&1 || true)
  echo "$OUTPUT" | grep -qF ".gaia/artifacts/planning-artifacts/threat-model.md"
  [ ! -d "docs" ]
}

@test "AF-21-15: threat-model finalize.sh — pre-ADR-111 → legacy back-compat preserved" {
  unset THREAT_MODEL_ARTIFACT
  mkdir -p "docs/planning-artifacts"
  echo "# Legacy" > "docs/planning-artifacts/threat-model.md"
  OUTPUT=$(bash "$THREAT_MODEL_FINALIZE" 2>&1 || true)
  echo "$OUTPUT" | grep -qF "docs/planning-artifacts/threat-model.md"
  [ ! -d ".gaia" ]
}

@test "AF-21-15: threat-model finalize.sh — both present → canonical wins" {
  unset THREAT_MODEL_ARTIFACT
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/threat-model.md"
  echo "# Legacy" > "docs/planning-artifacts/threat-model.md"
  OUTPUT=$(bash "$THREAT_MODEL_FINALIZE" 2>&1 || true)
  echo "$OUTPUT" | grep -qF "running 25-item checklist against .gaia/artifacts/planning-artifacts/threat-model.md"
}

@test "AF-21-15: threat-model finalize.sh — THREAT_MODEL_ARTIFACT env-var (Tier 1) wins" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts" "custom"
  echo "# C" > ".gaia/artifacts/planning-artifacts/threat-model.md"
  echo "# L" > "docs/planning-artifacts/threat-model.md"
  echo "# Custom" > "custom/my-threat.md"
  export THREAT_MODEL_ARTIFACT="$TEST_TMP/custom/my-threat.md"
  OUTPUT=$(bash "$THREAT_MODEL_FINALIZE" 2>&1 || true)
  unset THREAT_MODEL_ARTIFACT
  echo "$OUTPUT" | grep -qF "running 25-item checklist against $TEST_TMP/custom/my-threat.md"
}
