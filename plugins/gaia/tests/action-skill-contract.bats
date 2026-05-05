#!/usr/bin/env bats
# action-skill-contract.bats — drift-prevention contract suite for action skills
# (E66-S5, FR-RSV2-46, ADR-077).
#
# Companion to evidence-judgment-parity.bats. While the parity bats covers the
# six review skills (review semantics — read code, emit verdict), this suite
# covers the five action skills (action semantics — execute tests, emit verdict).
#
# This skeleton ships in E66-S5 with all five entries SKIPped because the
# action skill SKILL.md files have not yet been authored (they land via E73-S1..S5
# across multiple sprints). The SKIP-with-message pattern matches the
# false-confidence guard from evidence-judgment-parity.bats — never silently pass
# with zero assertions.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# Canonical action-skill consumer list — populated by E73-S1..S5 as each
# action skill's SKILL.md is authored. Each entry is the path
# (relative to plugins/gaia/) of the SKILL.md file.
ACTION_SKILLS=(
  "skills/gaia-test-e2e/SKILL.md"
  "skills/gaia-test-perf/SKILL.md"
  "skills/gaia-test-dast/SKILL.md"
  "skills/gaia-test-a11y/SKILL.md"
  "skills/gaia-test-mobile-e2e/SKILL.md"
)

# --- assertion helpers ---

# Assert SKILL.md contains the unifying principle verbatim (FR-DEJ-1, ADR-077).
assert_unifying_principle() {
  local file="$1"
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$file" >/dev/null
}

# Assert verdict-resolver.sh is invoked somewhere in SKILL.md.
assert_verdict_resolver_invocation() {
  local file="$1"
  grep -F 'verdict-resolver.sh' "$file" >/dev/null
}

# Assert tool-availability-probe.sh is integrated.
assert_probe_integration() {
  local file="$1"
  grep -F 'tool-availability-probe.sh' "$file" >/dev/null
}

# Assert SKILL.md frontmatter declares the read-only fork allowlist
# allowed-tools = [Read, Grep, Glob, Bash].
assert_fork_allowlist() {
  local file="$1"
  grep -E '^allowed-tools:' "$file" | grep -E 'Read.*Grep.*Glob.*Bash' >/dev/null
}

# Assert SKILL.md references the analysis-results.json canonical write path
# (or the analysis-results.schema.json reference).
assert_analysis_results_write() {
  local file="$1"
  grep -E 'analysis-results(\.json|\.schema\.json)?' "$file" >/dev/null
}

# --- per-consumer test loop ---
#
# Each test loops over ACTION_SKILLS, SKIPping any entry whose SKILL.md has
# not yet been authored. This matches the false-confidence guard pattern from
# evidence-judgment-parity.bats — the SKIP message identifies the missing
# skill so CI logs surface the staged rollout state.

@test "action-skill-contract: unifying principle string present verbatim" {
  if [ "${#ACTION_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — contract not enforceable"
  fi
  local any_present=0
  for entry in "${ACTION_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    if [ ! -f "$f" ]; then
      continue
    fi
    any_present=1
    assert_unifying_principle "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no action SKILL.md files present yet — skills not yet migrated (E73-S1..S5)"
  fi
}

@test "action-skill-contract: verdict-resolver invocation present" {
  if [ "${#ACTION_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — contract not enforceable"
  fi
  local any_present=0
  for entry in "${ACTION_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    if [ ! -f "$f" ]; then
      continue
    fi
    any_present=1
    assert_verdict_resolver_invocation "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no action SKILL.md files present yet — skills not yet migrated (E73-S1..S5)"
  fi
}

@test "action-skill-contract: tool-availability-probe integration present" {
  if [ "${#ACTION_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — contract not enforceable"
  fi
  local any_present=0
  for entry in "${ACTION_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    if [ ! -f "$f" ]; then
      continue
    fi
    any_present=1
    assert_probe_integration "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no action SKILL.md files present yet — skills not yet migrated (E73-S1..S5)"
  fi
}

@test "action-skill-contract: read-only fork allowlist [Read, Grep, Glob, Bash]" {
  if [ "${#ACTION_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — contract not enforceable"
  fi
  local any_present=0
  for entry in "${ACTION_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    if [ ! -f "$f" ]; then
      continue
    fi
    any_present=1
    assert_fork_allowlist "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no action SKILL.md files present yet — skills not yet migrated (E73-S1..S5)"
  fi
}

@test "action-skill-contract: analysis-results write reference present" {
  if [ "${#ACTION_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — contract not enforceable"
  fi
  local any_present=0
  for entry in "${ACTION_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    if [ ! -f "$f" ]; then
      continue
    fi
    any_present=1
    assert_analysis_results_write "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no action SKILL.md files present yet — skills not yet migrated (E73-S1..S5)"
  fi
}

# Per-skill SKIP messages — emit one SKIP per missing SKILL.md so CI logs
# surface the exact staged rollout state for each action skill.
@test "action-skill-contract: per-skill presence audit" {
  if [ "${#ACTION_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — contract not enforceable"
  fi
  local missing=()
  for entry in "${ACTION_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    if [ ! -f "$f" ]; then
      missing+=("$entry")
    fi
  done
  if [ "${#missing[@]}" -eq "${#ACTION_SKILLS[@]}" ]; then
    skip "all five action SKILL.md files absent — staged rollout via E73-S1..S5 not started"
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    skip "partial rollout — missing: ${missing[*]}"
  fi
  # All five present — no skip, no failure.
}
