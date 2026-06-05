#!/usr/bin/env bats
# AF-2026-05-24-14 PR-A — 11 quick-fix MEDIUM/LOW findings from Test02
#
# F-8:  SV-03 accepts em-dash heading form (## EN — Title)
# F-11: gaia-qa-tests documents required placement schema
# F-16: gaia-run-all-reviews uses ${CLAUDE_PLUGIN_ROOT}/scripts/ paths
# F-17: gaia-init Next Steps message aligned with script write path
# F-20: gaia-run-all-reviews uses one canonical skill name per row
# F-23: tech-debt scanner already checks Finding+Action cols (shipped in F-22)
# F-28: assert-agent-envelope.sh exits 1 when executed unsourced (already correct)
# F-30: tech-debt-review finalize.sh has F-30 carve-out documentation
# F-31: track-b-dispatch.sh defers TTY warning to after stacks-empty check
# F-32: skill-proposal.sh header has F-32 expanded function-output docs
# F-34: readiness-check setup.sh defaults TEST_ARTIFACTS to canonical path
# F-37: gaia-trace SKILL.md prescribes multi-gate summary line
# F-41: F-41 verified-on-disk (no fix needed — see assessment doc)

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."

# --- F-8 ---

@test "F-8: epic_headings_present accepts em-dash heading form" {
  grep -qF 'Em-dash heading normalization' "${PLUGIN_ROOT}/skills/gaia-create-epics/scripts/finalize.sh"
  grep -qF "epic_headings_present" "${PLUGIN_ROOT}/skills/gaia-create-epics/scripts/finalize.sh"
}

@test "F-8: end-to-end — em-dash heading is recognized as canonical" {
  TMPFILE_F8=$(mktemp)
  cat > "$TMPFILE_F8" <<'EOF'
# Epics

## E1 — Foo Bar Baz

Body.
EOF
  result=$(grep -Eq '^##[[:space:]]+(Epic[[:space:]]+[0-9]+|E[0-9]+[[:space:]]+(—|--))' "$TMPFILE_F8" && echo pass || echo fail)
  rm -f "$TMPFILE_F8"
  [ "$result" = "pass" ]
}

# --- F-11 ---

@test "F-11: gaia-qa-tests SKILL.md documents placement schema" {
  grep -qF "Required \`placement\` schema" "${PLUGIN_ROOT}/skills/gaia-qa-tests/SKILL.md"
}

# --- F-16 ---

@test "F-16: gaia-run-all-reviews uses CLAUDE_PLUGIN_ROOT-prefixed script paths" {
  grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh' "${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/review-skip-check.sh' "${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
}

# --- F-17 ---

@test "F-17: gaia-init Next Steps points at .gaia/config/ for test-environment example" {
  grep -qF "  - .gaia/config/test-environment.yaml.example" "${PLUGIN_ROOT}/skills/gaia-init/SKILL.md"
  ! grep -qF "  - .gaia/artifacts/test-artifacts/test-environment.yaml.example" "${PLUGIN_ROOT}/skills/gaia-init/SKILL.md"
}

# --- F-20 ---

@test "F-20: gaia-run-all-reviews short-name mapping uses one canonical name per row" {
  ! grep -qF "(or gaia:gaia-review-security)" "${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  grep -qF "security-review → gaia:gaia-review-security" "${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
}

# --- F-30 ---

@test "F-30: tech-debt-review finalize.sh documents the no-Val-sentinel carve-out" {
  grep -qF "GAIA_FINALIZE_SENTINEL_REQUIRED" "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/finalize.sh"
  grep -qF "fail-closed-on-Val applies" "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/finalize.sh"
}

# --- F-31 ---

@test "F-31: track-b-dispatch.sh defers TTY warning to after stacks-empty check" {
  grep -qF "TTY check moved here from the top" "${PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
  # The TTY warning text should appear AFTER the empty-stacks early-exit
  local tty_line empty_exit_line
  tty_line=$(grep -n "stdout is not a TTY" "${PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/track-b-dispatch.sh" | head -1 | cut -d: -f1)
  empty_exit_line=$(grep -n "emitting empty envelope" "${PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/track-b-dispatch.sh" | head -1 | cut -d: -f1)
  [ "$tty_line" -gt "$empty_exit_line" ]
}

# --- F-32 ---

@test "F-32: skill-proposal.sh header documents output format + failure modes" {
  grep -qF "expanded with output format + failure modes" "${PLUGIN_ROOT}/skills/gaia-retro/scripts/skill-proposal.sh"
  grep -qF "Failure mode:" "${PLUGIN_ROOT}/skills/gaia-retro/scripts/skill-proposal.sh"
  grep -qF "Stdout:" "${PLUGIN_ROOT}/skills/gaia-retro/scripts/skill-proposal.sh"
}

# --- F-34 ---

@test "F-34: readiness-check setup.sh defaults TEST_ARTIFACTS to canonical path" {
  grep -qF 'Default it to the canonical .gaia/artifacts/test-artifacts/' "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/setup.sh"
  grep -qF 'TEST_ARTIFACTS="${TEST_ARTIFACTS:-.gaia/artifacts/test-artifacts}"' "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/setup.sh"
}

# --- F-37 ---

@test "F-37: gaia-trace SKILL.md prescribes multi-gate summary line" {
  grep -qF 'WARNING: N of M gates failed' "${PLUGIN_ROOT}/skills/gaia-trace/SKILL.md"
}

# --- F-23 (already shipped in F-22 fix; assert) ---

@test "F-23: tech-debt scanner [TRIAGED] dedup checks both Finding + Action cols" {
  grep -qF 'printf '"'"'%s'"'"' "$finding $action" | grep -qE' "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/scan-findings.sh"
}

# --- F-28 (already correct; assert) ---

@test "F-28: assert-agent-envelope.sh exits non-zero on direct execution" {
  run bash "${PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh" /tmp/nonexistent.json
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "must be sourced, not executed"
}
