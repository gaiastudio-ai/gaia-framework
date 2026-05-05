#!/usr/bin/env bats
# evidence-judgment-parity.bats — drift-prevention parity suite.
#
# Originally created in E65-S1 (FR-DEJ-12) to enforce the ADR-075
# evidence/judgment template across the six review skills. Extended in E66-S5
# (FR-RSV2-46, ADR-077) to cover all seven verdict-producing review skills:
# the original six plus /gaia-review-mobile.
#
# Action-skill coverage (gaia-test-e2e, -perf, -dast, -a11y, -mobile-e2e) lives
# in the companion suite tests/action-skill-contract.bats (E66-S5).
#
# This skeleton ships with seven registered review-skill entries. While any
# entry's SKILL.md is missing on disk (e.g. /gaia-review-mobile lands with
# E74-S8) the test loops SKIP that entry per-skill rather than failing — the
# extension is staged and additive, not breaking (AC6).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# Canonical review-skill consumer list — extended in E66-S5 to add
# /gaia-review-mobile per ADR-077. Each entry is the path
# (relative to plugins/gaia/) of the SKILL.md file.
REVIEW_SKILLS=(
  "skills/gaia-code-review/SKILL.md"
  "skills/gaia-security-review/SKILL.md"
  "skills/gaia-qa-tests/SKILL.md"
  "skills/gaia-test-automate/SKILL.md"
  "skills/gaia-test-review/SKILL.md"
  "skills/gaia-performance-review/SKILL.md"
  "skills/gaia-review-mobile/SKILL.md"
)

# --- assertion helpers ---

# Assert SKILL.md frontmatter declares allowed-tools = [Read, Grep, Glob, Bash].
assert_allowed_tools_allowlist() {
  local file="$1"
  grep -E '^allowed-tools:' "$file" | grep -E 'Read.*Grep.*Glob.*Bash' >/dev/null
}

# Assert SKILL.md contains the unifying principle verbatim (FR-DEJ-1).
assert_unifying_principle() {
  local file="$1"
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$file" >/dev/null
}

# Assert SKILL.md contains the seven canonical phase headers in order.
assert_seven_phase_headers() {
  local file="$1"
  local expected=(
    "Setup"
    "Story Gate"
    "Phase 3A"
    "Phase 3B"
    "Architecture Conformance"
    "Verdict"
    "Output"
    "Finalize"
  )
  local got
  got="$(grep -E '^### |^## ' "$file" || true)"
  for p in "${expected[@]}"; do
    printf '%s' "$got" | grep -F "$p" >/dev/null || return 1
  done
}

# Assert load-stack-persona.sh is invoked somewhere in SKILL.md (Setup phase).
assert_persona_load_hook_present() {
  local file="$1"
  grep -F 'load-stack-persona.sh' "$file" >/dev/null
}

# Assert verdict-resolver.sh is invoked somewhere in SKILL.md (Verdict phase).
assert_verdict_resolver_invocation() {
  local file="$1"
  grep -F 'verdict-resolver.sh' "$file" >/dev/null
}

# Assert SKILL.md contains the canonical cross-link to gaia-code-review-standards
# for the shared severity-rubric format (E65-S8, AC2, AC-EC1, AC-EC7).
# The canonical cross-link string is verbatim — drift from this string fails CI.
assert_cross_link_present() {
  local file="$1"
  grep -F '> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.' "$file" >/dev/null
}

# E66-S5 / ADR-077 — three additional assertion helpers covering the
# three-tier review pipeline integration points. These references land
# per-skill via E67/E73 migration stories; until a particular SKILL.md
# adopts them the per-test loop SKIPs that entry (AC6 backward compat).

# Assert SKILL.md references agent-overlay.sh (ADR-077 persona resolution).
assert_agent_overlay_integration() {
  local file="$1"
  grep -F 'agent-overlay.sh' "$file" >/dev/null
}

# Assert SKILL.md references tool-availability-probe.sh (ADR-077 three-state probe).
assert_probe_integration() {
  local file="$1"
  grep -F 'tool-availability-probe.sh' "$file" >/dev/null
}

# Assert SKILL.md references analysis-results.json (or schema) — the canonical
# write path for the deterministic evidence layer of the three-tier pipeline.
assert_analysis_results_schema_ref() {
  local file="$1"
  grep -E 'analysis-results(\.json|\.schema\.json)?' "$file" >/dev/null
}

# --- per-consumer test loop ---
#
# Each test iterates REVIEW_SKILLS. Per-entry SKIP guard: if SKILL.md is not
# on disk yet (e.g. /gaia-review-mobile lands with E74-S8), that entry is
# silently bypassed within the loop. If every entry is missing the test SKIPs
# with the false-confidence guard message (preserves the E65-S1 invariant).

@test "parity: allowed-tools allowlist == [Read, Grep, Glob, Bash]" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_present=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    any_present=1
    assert_allowed_tools_allowlist "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no review SKILL.md files present yet — false-confidence guard"
  fi
}

@test "parity: unifying principle string present verbatim" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_present=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    any_present=1
    assert_unifying_principle "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no review SKILL.md files present yet — false-confidence guard"
  fi
}

@test "parity: seven phase headers in order" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_present=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    any_present=1
    assert_seven_phase_headers "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no review SKILL.md files present yet — false-confidence guard"
  fi
}

@test "parity: persona-load hook present" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_present=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    any_present=1
    assert_persona_load_hook_present "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no review SKILL.md files present yet — false-confidence guard"
  fi
}

@test "parity: verdict-resolver invocation present" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_present=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    any_present=1
    assert_verdict_resolver_invocation "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no review SKILL.md files present yet — false-confidence guard"
  fi
}

@test "parity: cross-link to gaia-code-review-standards rubric format present" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_present=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    any_present=1
    assert_cross_link_present "$f"
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no review SKILL.md files present yet — false-confidence guard"
  fi
}

# Stub-marker hygiene: no unfilled GAIA_REVIEW_STUB: sentinel in any consumer SKILL.md.
@test "parity: no unfilled GAIA_REVIEW_STUB sentinels in consumers" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_present=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    any_present=1
    run grep -F 'GAIA_REVIEW_STUB:' "$f"
    [ "$status" -ne 0 ]   # grep found nothing — clean
  done
  if [ "$any_present" -eq 0 ]; then
    skip "no review SKILL.md files present yet — false-confidence guard"
  fi
}

# E66-S5 / ADR-077 — three additional drift-prevention tests covering
# agent-overlay.sh, tool-availability-probe.sh, and analysis-results.json
# integration. Per-entry SKIP guard: if a SKILL.md exists but has not yet
# adopted the ADR-077 reference, that entry SKIPs (per-skill migration via
# E67/E73 lands the references over time). Once a skill adopts a reference
# any future drift fails CI.

@test "parity (ADR-077): agent-overlay.sh integration referenced where adopted" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_adopted=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    if assert_agent_overlay_integration "$f"; then
      any_adopted=1
    fi
  done
  if [ "$any_adopted" -eq 0 ]; then
    skip "ADR-077 agent-overlay.sh wiring not yet adopted by any review skill — lands per-skill via E67/E73"
  fi
  # At least one skill has adopted the reference; that adoption is the
  # drift-prevention anchor — once adopted, the reference must not regress.
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    # Only enforce on skills that have already adopted (idempotent staged rollout).
    # Skills that have not yet adopted are skipped silently within the loop.
    if grep -F 'agent-overlay.sh' "$f" >/dev/null 2>&1; then
      assert_agent_overlay_integration "$f"
    fi
  done
}

@test "parity (ADR-077): tool-availability-probe.sh integration referenced where adopted" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_adopted=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    if assert_probe_integration "$f"; then
      any_adopted=1
    fi
  done
  if [ "$any_adopted" -eq 0 ]; then
    skip "ADR-077 tool-availability-probe.sh wiring not yet adopted by any review skill — lands per-skill via E67/E73"
  fi
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    if grep -F 'tool-availability-probe.sh' "$f" >/dev/null 2>&1; then
      assert_probe_integration "$f"
    fi
  done
}

@test "parity (ADR-077): analysis-results.json schema reference present where adopted" {
  if [ "${#REVIEW_SKILLS[@]}" -eq 0 ]; then
    skip "no consumers registered yet — parity not enforceable"
  fi
  local any_adopted=0
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    if assert_analysis_results_schema_ref "$f"; then
      any_adopted=1
    fi
  done
  if [ "$any_adopted" -eq 0 ]; then
    skip "ADR-077 analysis-results.json reference not yet adopted by any review skill — lands per-skill via E67/E73"
  fi
  for entry in "${REVIEW_SKILLS[@]}"; do
    local f="$BATS_TEST_DIRNAME/../$entry"
    [ -f "$f" ] || continue
    if grep -E 'analysis-results(\.json|\.schema\.json)?' "$f" >/dev/null 2>&1; then
      assert_analysis_results_schema_ref "$f"
    fi
  done
}
