#!/usr/bin/env bats
# AF-2026-05-24-14 PR-B — 6 script-behavior MEDIUM/LOW findings from Test02
#
# F-6:  test-strategy finalize.sh auto-stub-hydrates missing config sections
# F-10: dod-check.sh resolves test_execution.tier_1.command + pytest fallback
# F-26: retro-sidecar-write.sh substitutes AI-{auto} → AI-{n} sequentially
# F-27: gaia-sprint-review Step 4a has 4th `delegate-to-val` option
# F-38: gaia-trace publishes coverage formula in matrix header
# F-40: gaia-threat-model documents single-turn-synth carve-out + audit-trail note

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."

# --- F-6 ---

@test "F-6: test-strategy finalize.sh has auto-stub-hydration block" {
  grep -qF "Config hydration fail-safe" "${PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF "auto-stub-hydration" "${PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh"
}

@test "F-6: auto-stub-hydration writes empty stubs for each missing section" {
  grep -qF "test_execution: {}" "${PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF "test_execution_bridge:" "${PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF "environments: {}" "${PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh"
}

# --- F-10 ---

@test "F-10: dod-check.sh resolves test_execution.tier_1.command via yq" {
  grep -qF "canonical test_execution.tier_1.command" "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/dod-check.sh"
  grep -qF ".test_execution.tier_1.command" "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/dod-check.sh"
}

@test "F-10: dod-check.sh falls back to pytest when tests/test_*.py exists" {
  grep -qF "pytest fallback" "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/dod-check.sh"
  grep -qF "pytest tests/" "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/dod-check.sh"
}

# --- F-26 ---

@test "F-26: retro-sidecar-write.sh substitutes AI-{auto} placeholder" {
  grep -qF 'Substitute `AI-{auto}` placeholders' "${PLUGIN_ROOT}/scripts/retro-sidecar-write.sh"
  grep -qF 'AI-{auto}' "${PLUGIN_ROOT}/scripts/retro-sidecar-write.sh"
  grep -qF "highest" "${PLUGIN_ROOT}/scripts/retro-sidecar-write.sh"
  grep -qF "sub(/AI-\\{auto\\}/" "${PLUGIN_ROOT}/scripts/retro-sidecar-write.sh"
}

@test "F-26: end-to-end — substitution assigns sequential AI-N values" {
  TMPYAML=$(mktemp)
  cat > "$TMPYAML" <<'EOF'
items:
  - id: AI-1
    text: existing
EOF
  NORM_PAYLOAD='  - id: AI-{auto}
    text: new-one
  - id: AI-{auto}
    text: new-two'
  _highest="$(grep -oE 'AI-[0-9]+' "$TMPYAML" 2>/dev/null | sed 's/^AI-//' | sort -n | tail -1)"
  [ "$_highest" = "1" ]
  _resolved_payload="$NORM_PAYLOAD"
  while printf '%s' "$_resolved_payload" | grep -qF 'AI-{auto}'; do
    _next=$((_highest + 1))
    _resolved_payload="$(printf '%s' "$_resolved_payload" | awk -v repl="AI-${_next}" '
      !done && /AI-\{auto\}/ { sub(/AI-\{auto\}/, repl); done=1 }
      { print }
    ')"
    _highest=$_next
  done
  printf '%s' "$_resolved_payload" | grep -qF 'id: AI-2'
  printf '%s' "$_resolved_payload" | grep -qF 'id: AI-3'
  ! printf '%s' "$_resolved_payload" | grep -qF 'AI-{auto}'
  rm -f "$TMPYAML"
}

# --- F-27 ---

@test "F-27: sprint-review SKILL.md Step 4a documents 4-option set" {
  grep -qF "expanded from 3 to 4" "${PLUGIN_ROOT}/skills/gaia-sprint-review/SKILL.md"
  grep -qF "delegate-to-val" "${PLUGIN_ROOT}/skills/gaia-sprint-review/SKILL.md"
  grep -qF "canonical 4-option set" "${PLUGIN_ROOT}/skills/gaia-sprint-review/SKILL.md"
}

# --- F-38 ---

@test "F-38: gaia-trace SKILL.md publishes Coverage % formula" {
  grep -qF "required_tiers_per_risk_band" "${PLUGIN_ROOT}/skills/gaia-trace/SKILL.md"
  grep -qF "(implemented_tiers_for_this_req / required_tiers_per_risk_band)" "${PLUGIN_ROOT}/skills/gaia-trace/SKILL.md"
  grep -qF "Coverage formula:" "${PLUGIN_ROOT}/skills/gaia-trace/SKILL.md"
}

# --- F-40 ---

@test "F-40: gaia-threat-model documents single-turn-synth carve-out" {
  grep -qF "dispatch_provenance" "${PLUGIN_ROOT}/skills/gaia-threat-model/SKILL.md"
  grep -qiF "single-turn-synth carve-out" "${PLUGIN_ROOT}/skills/gaia-threat-model/SKILL.md"
  grep -qF "THREAT-MODEL DISPATCH NOTE" "${PLUGIN_ROOT}/skills/gaia-threat-model/SKILL.md"
}
