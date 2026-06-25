#!/usr/bin/env bats
# config-brownfield-flag-coverage.bats
#
# Schema-coverage assertion: every brownfield.* key declared in the project
# config schema MUST be documented in the gaia-config-brownfield SKILL.md
# supported-keys list and the current-state render block.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$PLUGIN_ROOT/skills/gaia-config-brownfield/SKILL.md"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helper: extract the "Supported keys (enums enforced)" section from SKILL.md
# ---------------------------------------------------------------------------
_supported_keys_section() {
  sed -n '/Supported keys/,/^- [^b]/p' "$SKILL" | head -40
}

# ---------------------------------------------------------------------------
# Boolean flags that MUST appear in the supported-keys list (AC1)
# ---------------------------------------------------------------------------

@test "supported-keys list documents deterministic_tools (AC1)" {
  grep -qE 'brownfield\.deterministic_tools' "$SKILL"
}

@test "supported-keys list documents prewarm_enabled (AC1)" {
  grep -qE 'brownfield\.prewarm_enabled' "$SKILL"
}

@test "supported-keys list documents sarif_merge_enabled (AC1)" {
  grep -qE 'brownfield\.sarif_merge_enabled' "$SKILL"
}

@test "supported-keys list documents dedup_enabled (AC1)" {
  grep -qE 'brownfield\.dedup_enabled' "$SKILL"
}

@test "supported-keys list documents grype_enabled (AC1)" {
  grep -qE 'brownfield\.grype_enabled' "$SKILL"
}

@test "supported-keys list documents sbom_completeness_enabled (AC1)" {
  grep -qE 'brownfield\.sbom_completeness_enabled' "$SKILL"
}

@test "supported-keys list documents detect_signals_enabled (AC1)" {
  grep -qE 'brownfield\.detect_signals_enabled' "$SKILL"
}

@test "supported-keys list documents deadcode_go_enabled (AC1)" {
  grep -qE 'brownfield\.deadcode_go_enabled' "$SKILL"
}

@test "supported-keys list documents deadcode_python_enabled (AC1)" {
  grep -qE 'brownfield\.deadcode_python_enabled' "$SKILL"
}

@test "supported-keys list documents deadcode_jvm_enabled (AC1)" {
  grep -qE 'brownfield\.deadcode_jvm_enabled' "$SKILL"
}

@test "supported-keys list documents phase_4b_cross_stack_enabled (AC1)" {
  grep -qE 'brownfield\.phase_4b_cross_stack_enabled' "$SKILL"
}

@test "supported-keys list documents phase_4b_enabled (AC1)" {
  grep -qE 'brownfield\.phase_4b_enabled' "$SKILL"
}

@test "supported-keys list documents defectdojo_enabled (AC1)" {
  grep -qE 'brownfield\.defectdojo_enabled' "$SKILL"
}

# ---------------------------------------------------------------------------
# Enum / string keys that MUST appear in the supported-keys list (AC2)
# ---------------------------------------------------------------------------

@test "supported-keys list documents tools.runner with enum (AC2)" {
  grep -qE 'brownfield\.tools\.runner.*docker.*native|brownfield\.tools\.runner.*native.*docker' "$SKILL"
}

@test "supported-keys list documents tools.image (AC2)" {
  grep -qE 'brownfield\.tools\.image' "$SKILL"
}

@test "supported-keys list documents scanner_tier with enum (AC2)" {
  grep -qE 'brownfield\.scanner_tier' "$SKILL"
}

# ---------------------------------------------------------------------------
# DefectDojo companion string keys (AC3)
# ---------------------------------------------------------------------------

@test "supported-keys list documents defectdojo_api_url (AC3)" {
  grep -qE 'brownfield\.defectdojo_api_url' "$SKILL"
}

@test "supported-keys list documents defectdojo_api_token (AC3)" {
  grep -qE 'brownfield\.defectdojo_api_token' "$SKILL"
}

@test "supported-keys list documents defectdojo_engagement_id (AC3)" {
  grep -qE 'brownfield\.defectdojo_engagement_id' "$SKILL"
}

# ---------------------------------------------------------------------------
# Render block coverage: the Step-2a current-state display MUST list every
# flag so show/set/clear print full state (AC4)
# ---------------------------------------------------------------------------

_render_block() {
  sed -n '/current brownfield:/,/^```$/p' "$SKILL"
}

@test "render block lists prewarm_enabled (AC4)" {
  _render_block | grep -qF 'prewarm_enabled'
}

@test "render block lists sarif_merge_enabled (AC4)" {
  _render_block | grep -qF 'sarif_merge_enabled'
}

@test "render block lists dedup_enabled (AC4)" {
  _render_block | grep -qF 'dedup_enabled'
}

@test "render block lists sbom_completeness_enabled (AC4)" {
  _render_block | grep -qF 'sbom_completeness_enabled'
}

@test "render block lists detect_signals_enabled (AC4)" {
  _render_block | grep -qF 'detect_signals_enabled'
}

@test "render block lists deadcode_go_enabled (AC4)" {
  _render_block | grep -qF 'deadcode_go_enabled'
}

@test "render block lists deadcode_python_enabled (AC4)" {
  _render_block | grep -qF 'deadcode_python_enabled'
}

@test "render block lists deadcode_jvm_enabled (AC4)" {
  _render_block | grep -qF 'deadcode_jvm_enabled'
}

@test "render block lists phase_4b_cross_stack_enabled (AC4)" {
  _render_block | grep -qF 'phase_4b_cross_stack_enabled'
}

@test "render block lists phase_4b_enabled (AC4)" {
  _render_block | grep -qF 'phase_4b_enabled'
}

@test "render block lists defectdojo_enabled (AC4)" {
  _render_block | grep -qF 'defectdojo_enabled'
}

@test "render block lists defectdojo_api_url (AC4)" {
  _render_block | grep -qF 'defectdojo_api_url'
}

@test "render block lists defectdojo_api_token (AC4)" {
  _render_block | grep -qF 'defectdojo_api_token'
}

@test "render block lists defectdojo_engagement_id (AC4)" {
  _render_block | grep -qF 'defectdojo_engagement_id'
}

# ---------------------------------------------------------------------------
# Regression: the 5 already-present flags must remain (AC5)
# ---------------------------------------------------------------------------

@test "regression: deterministic_tools still in supported-keys (AC5)" {
  grep -qE '^\s*- `brownfield\.deterministic_tools`' "$SKILL"
}

@test "regression: tools.runner still in supported-keys (AC5)" {
  grep -qE '^\s*- `brownfield\.tools\.runner`' "$SKILL"
}

@test "regression: tools.image still in supported-keys (AC5)" {
  grep -qE '^\s*- `brownfield\.tools\.image`' "$SKILL"
}

@test "regression: grype_enabled still in supported-keys (AC5)" {
  grep -qE '^\s*- `brownfield\.grype_enabled`' "$SKILL"
}

@test "regression: scanner_tier still in supported-keys (AC5)" {
  grep -qE '^\s*- `brownfield\.scanner_tier`' "$SKILL"
}
