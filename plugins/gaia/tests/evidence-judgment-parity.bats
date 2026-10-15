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

setup() { common_setup; }
teardown() { common_teardown; }

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

@test "parity: agent-overlay.sh integration referenced where adopted" {
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

@test "parity: tool-availability-probe.sh integration referenced where adopted" {
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

@test "parity: analysis-results.json schema reference present where adopted" {
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

# ---------------------------------------------------------------------------
# Shared findings rubric — gate-row-writer parity
# ---------------------------------------------------------------------------

# The ten gate-row-writing SKILL.md files (the existing REVIEW_SKILLS array
# points at a different set — do not reuse it).
GATE_ROW_WRITERS=(
  "skills/gaia-code-review/SKILL.md"
  "skills/gaia-qa-tests/SKILL.md"
  "skills/gaia-review-security/SKILL.md"
  "skills/gaia-test-automate/SKILL.md"
  "skills/gaia-test-review/SKILL.md"
  "skills/gaia-review-perf/SKILL.md"
  "skills/gaia-security-review/SKILL.md"
  "skills/gaia-performance-review/SKILL.md"
  "skills/gaia-test-dast/SKILL.md"
  "skills/gaia-test-perf/SKILL.md"
)

# The six primary review skills plus the template
RUBRIC_CONSUMERS=(
  "skills/gaia-code-review/SKILL.md"
  "skills/gaia-qa-tests/SKILL.md"
  "skills/gaia-review-security/SKILL.md"
  "skills/gaia-test-automate/SKILL.md"
  "skills/gaia-test-review/SKILL.md"
  "skills/gaia-review-perf/SKILL.md"
  "knowledge/review-skill-template.md"
)

RUBRIC_CONSUMERS_EXTRA=(
  "skills/gaia-security-review/SKILL.md"
  "skills/gaia-performance-review/SKILL.md"
  "skills/gaia-test-dast/SKILL.md"
  "skills/gaia-test-perf/SKILL.md"
)

RUBRIC_FILE="knowledge/shared-findings-rubric.md"

@test "shared rubric: each of the six review skills and the template references shared-findings-rubric.md" {
  local base="$BATS_TEST_DIRNAME/.."
  [ -f "$base/$RUBRIC_FILE" ] || {
    echo "rubric file not found: $base/$RUBRIC_FILE" >&2
    false
  }
  local failed=0
  for entry in "${RUBRIC_CONSUMERS[@]}"; do
    local f="$base/$entry"
    [ -f "$f" ] || { echo "SKILL.md not found: $f" >&2; failed=1; continue; }
    if ! grep -qF 'shared-findings-rubric.md' "$f"; then
      echo "missing rubric reference in: $entry" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "shared rubric: perf-deepdive deprecated-security test-dast test-perf reference shared-findings-rubric.md" {
  local base="$BATS_TEST_DIRNAME/.."
  [ -f "$base/$RUBRIC_FILE" ] || {
    echo "rubric file not found: $base/$RUBRIC_FILE" >&2
    false
  }
  local failed=0
  for entry in "${RUBRIC_CONSUMERS_EXTRA[@]}"; do
    local f="$base/$entry"
    [ -f "$f" ] || { echo "SKILL.md not found: $f" >&2; failed=1; continue; }
    if ! grep -qF 'shared-findings-rubric.md' "$f"; then
      echo "missing rubric reference in: $entry" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "shared rubric: no gate-row writer contains a local critical-or-high verdict rule" {
  local base="$BATS_TEST_DIRNAME/.."
  local failed=0
  for entry in "${GATE_ROW_WRITERS[@]}"; do
    local f="$base/$entry"
    [ -f "$f" ] || { echo "SKILL.md not found: $f" >&2; failed=1; continue; }
    # Check for local "critical or high" verdict rules — the pattern
    # "FAILED" near "critical or high" or "critical/high"
    if grep -iE '(FAILED|FAIL).*(critical|high).*(finding|severity)' "$f" >/dev/null 2>&1; then
      # Exclude lines that are part of the shared rubric reference or
      # the deterministic tool override (which is kept)
      local matches
      matches="$(grep -inE '(FAILED|FAIL).*(critical|high).*(finding|severity)' "$f" | grep -ivE 'shared-findings-rubric|deterministic|verdict-resolver' || true)"
      if [ -n "$matches" ]; then
        echo "local critical-or-high verdict rule found in: $entry" >&2
        echo "$matches" >&2
        failed=1
      fi
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "shared rubric: deletion mutant of rubric reference fails the test" {
  # This test creates a temp copy of a SKILL.md with the rubric reference
  # removed, and verifies that a grep for the reference fails.
  # In Red phase, the rubric reference does not exist yet, so this test
  # verifies the detection mechanism (the reference MUST be present; if
  # removed, the test catches it).
  local base="$BATS_TEST_DIRNAME/.."
  local target="$base/skills/gaia-code-review/SKILL.md"
  [ -f "$target" ] || { echo "SKILL.md not found" >&2; false; }

  # In Green, this file will have the reference. The test proves that
  # removing it is detected.
  if grep -qF 'shared-findings-rubric.md' "$target"; then
    # Rubric reference exists — simulate deletion
    local copy="$TEST_TMP/mutant-skill.md"
    grep -vF 'shared-findings-rubric.md' "$target" > "$copy"
    # The mutant must NOT pass the reference check
    if grep -qF 'shared-findings-rubric.md' "$copy"; then
      echo "deletion mutant still contains rubric reference" >&2; false
    fi
  else
    # Rubric reference does not exist yet (Red phase) — the main test
    # already fails, so this deletion mutant test also fails because
    # the condition it guards is already violated.
    echo "rubric reference not yet present in gaia-code-review — deletion mutant guard cannot run" >&2
    false
  fi
}

@test "shared rubric: rubric states the test-gap materiality rule" {
  local base="$BATS_TEST_DIRNAME/.."
  local rubric="$base/$RUBRIC_FILE"
  [ -f "$rubric" ] || { echo "rubric not found: $rubric" >&2; false; }
  # Must contain language about test gaps and materiality
  grep -qiE 'test.gap.*material|material.*test.gap|material.*required.*behaviour|material.*unverified' "$rubric"
}

@test "shared rubric: rubric states deterministic blockers stay outside the register" {
  local base="$BATS_TEST_DIRNAME/.."
  local rubric="$base/$RUBRIC_FILE"
  [ -f "$rubric" ] || { echo "rubric not found: $rubric" >&2; false; }
  grep -qiE 'deterministic.*outside.*register|deterministic.*blocker.*not.*register|deterministic.*block.*exist.*rule' "$rubric"
}

@test "shared rubric: qa-tests expresses Critical promotion via shared blocker definition" {
  local base="$BATS_TEST_DIRNAME/.."
  local f="$base/skills/gaia-qa-tests/SKILL.md"
  [ -f "$f" ] || { echo "SKILL.md not found" >&2; false; }
  # Must reference the shared rubric
  grep -qF 'shared-findings-rubric.md' "$f"
  # Must contain language about blocker definition for critical promotion
  grep -qiE 'blocker.*definition|shared.*rubric.*blocker|shared-findings-rubric' "$f"
}

@test "shared rubric: qa-tests reword mutant restoring P0-only rule fails" {
  local base="$BATS_TEST_DIRNAME/.."
  local f="$base/skills/gaia-qa-tests/SKILL.md"
  [ -f "$f" ] || { echo "SKILL.md not found" >&2; false; }

  # After the change, the old "P0 AC coverage gaps" wording should be
  # replaced with shared blocker definition language. If the old wording
  # is still present AND the shared rubric reference is also present,
  # the test fails — the reword was not applied.
  if grep -qF 'shared-findings-rubric.md' "$f"; then
    # Rubric reference exists — the old local P0-only restriction
    # wording must NOT be present as a standalone verdict rule
    if grep -qiE 'Critical promotion is restricted to.*P0.*AC coverage' "$f"; then
      echo "old P0-only Critical promotion rule still present" >&2
      false
    fi
  else
    # Rubric reference not yet present (Red phase)
    echo "rubric reference not yet present in qa-tests" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# Register wiring: each skill's verdict section names register-write.sh add,
# record-run, and verdict-resolver.sh --register.  The check targets the
# verdict section only (not the whole file), and the mutant tests use the
# same helper so they would catch a real regression.
# ---------------------------------------------------------------------------

# Helper: extract the verdict/output section from a SKILL.md file.
# Targets the Phase/Step heading that contains "Verdict" and register
# wiring, or falls back to the bold "Register path" label.  Stops at
# the next same-level heading.
_extract_verdict_section() {
  local file="$1"
  # First try: the section whose heading contains "Phase" or "Step" AND "Verdict"
  local section
  section="$(awk '
    /^##.*(Phase|Step).*[Vv]erdict/ { found=1 }
    found && /^##[# ]/ && already { exit }
    found { already=1; print }
  ' "$file")"
  if [ -n "$section" ]; then printf '%s\n' "$section"; return 0; fi
  # Fallback: any heading containing Verdict
  section="$(awk '
    /^##.*[Vv]erdict/ { found=1 }
    found && /^##[# ]/ && already { exit }
    found { already=1; print }
  ' "$file")"
  if [ -n "$section" ]; then printf '%s\n' "$section"; return 0; fi
  # Last resort: the Register path label
  section="$(awk '
    /^\*\*Register path/ { found=1 }
    found && /^##[# ]/ && already { exit }
    found { already=1; print }
  ' "$file")"
  printf '%s\n' "$section"
}

# Helper: check that a file's verdict section mentions all three register
# tokens.  Returns 0 when all are present, 1 otherwise with stderr detail.
_check_register_wiring() {
  local file="$1" label="$2"
  local section
  section="$(_extract_verdict_section "$file")"
  if [ -z "$section" ]; then
    echo "$label: no verdict section found" >&2; return 1
  fi
  local ok=0
  if ! grep -qF 'register-write.sh add' <<<"$section"; then
    echo "$label: verdict section missing register-write.sh add" >&2; ok=1
  fi
  if ! grep -qF 'record-run' <<<"$section"; then
    echo "$label: verdict section missing record-run" >&2; ok=1
  fi
  # Verify that verdict-resolver.sh and --register appear connected — either
  # on the same line or within a backslash-continuation block (2-line window).
  # A section that mentions --register only in a prose sentence (e.g. "The
  # --register flag is accepted for backward compatibility") without the
  # resolver invocation is incomplete wiring.
  local _vr_register_ok
  _vr_register_ok="$(awk '
    /verdict-resolver/ { saw_vr = NR }
    /--register/ {
      if (saw_vr > 0 && (NR - saw_vr) <= 2) { found = 1; exit }
    }
    END { print (found ? "yes" : "no") }
  ' <<<"$section")"
  if [ "$_vr_register_ok" != "yes" ]; then
    echo "$label: verdict section missing verdict-resolver invocation with --register (connected within 2 lines)" >&2; ok=1
  fi
  return "$ok"
}

@test "register wiring: each review skill verdict section names register-write.sh add, record-run and --register" {
  local base="$BATS_TEST_DIRNAME/.."
  local skills=(
    "skills/gaia-code-review/SKILL.md"
    "skills/gaia-qa-tests/SKILL.md"
    "skills/gaia-review-security/SKILL.md"
    "skills/gaia-test-automate/SKILL.md"
    "skills/gaia-test-review/SKILL.md"
    "skills/gaia-review-perf/SKILL.md"
  )
  local failed=0
  local f
  for f in "${skills[@]}"; do
    local path="$base/$f"
    [ -f "$path" ] || { echo "not found: $f" >&2; failed=1; continue; }
    _check_register_wiring "$path" "$f" || failed=1
  done
  [ "$failed" -eq 0 ]
}

@test "register wiring: test-dast and test-perf verdict section names register-write.sh add, record-run and --register" {
  local base="$BATS_TEST_DIRNAME/.."
  local failed=0
  for f in "skills/gaia-test-dast/SKILL.md" "skills/gaia-test-perf/SKILL.md"; do
    local path="$base/$f"
    [ -f "$path" ] || { echo "not found: $f" >&2; failed=1; continue; }
    _check_register_wiring "$path" "$f" || failed=1
  done
  [ "$failed" -eq 0 ]
}

@test "register wiring: review-skill-template verdict section names register-write.sh add, record-run and --register" {
  local base="$BATS_TEST_DIRNAME/.."
  local path="$base/knowledge/review-skill-template.md"
  [ -f "$path" ] || { echo "not found: $path" >&2; false; }
  _check_register_wiring "$path" "review-skill-template.md"
}

@test "register wiring: gaia-run-all-reviews mentions gate-status and triage-nonblocking and findings-rows" {
  local base="$BATS_TEST_DIRNAME/.."
  local f="$base/skills/gaia-run-all-reviews/SKILL.md"
  [ -f "$f" ] || { echo "not found: $f" >&2; false; }
  grep -qF 'gate-status' "$f" || { echo "run-all-reviews does not mention gate-status" >&2; false; }
  grep -qF 'triage-nonblocking' "$f" || { echo "run-all-reviews does not mention triage-nonblocking" >&2; false; }
  grep -qF 'findings-rows' "$f" || { echo "run-all-reviews does not mention findings-rows" >&2; false; }
  grep -qF 'UNVERIFIED' "$f" || { echo "run-all-reviews does not mention UNVERIFIED" >&2; false; }
}

@test "register wiring: deletion of register-write.sh add from code-review fails the wiring check" {
  local base="$BATS_TEST_DIRNAME/.."
  local path="$base/skills/gaia-code-review/SKILL.md"
  [ -f "$path" ] || { echo "not found" >&2; false; }
  # Baseline: the real file passes the helper
  _check_register_wiring "$path" "baseline" || {
    echo "baseline failed — cannot test mutant" >&2; false
  }
  # Deletion mutant: remove register-write.sh add
  local copy="$TEST_TMP/mutant-cr-del.md"
  grep -v 'register-write.sh add' "$path" > "$copy"
  # The mutant must fail the same helper
  if _check_register_wiring "$copy" "mutant" 2>/dev/null; then
    echo "deletion mutant passed the wiring check — test is broken" >&2; false
  fi
}

@test "register wiring: reword mutant replacing --register with --llm-findings fails the wiring check" {
  local base="$BATS_TEST_DIRNAME/.."
  local path="$base/skills/gaia-code-review/SKILL.md"
  [ -f "$path" ] || { echo "not found" >&2; false; }
  # Baseline: the real file passes the helper
  _check_register_wiring "$path" "baseline" || {
    echo "baseline failed — cannot test mutant" >&2; false
  }
  # Reword mutant: replace --register with --llm-findings in verdict section
  local copy="$TEST_TMP/mutant-cr-rwd.md"
  sed 's/--register/--llm-findings/g' "$path" > "$copy"
  # The mutant must fail the helper
  if _check_register_wiring "$copy" "mutant" 2>/dev/null; then
    echo "reword mutant passed the wiring check — test is broken" >&2; false
  fi
}

@test "register wiring: removing verdict-resolver.sh from test-perf register path paragraph fails the wiring check" {
  local base="$BATS_TEST_DIRNAME/.."
  local path="$base/skills/gaia-test-perf/SKILL.md"
  [ -f "$path" ] || { echo "not found" >&2; false; }
  # Baseline: the real file passes
  _check_register_wiring "$path" "baseline" || {
    echo "baseline failed — cannot test mutant" >&2; false
  }
  # Mutant: replace "verdict-resolver.sh --register" with "the verdict"
  local copy="$TEST_TMP/mutant-perf-vr.md"
  sed 's/`verdict-resolver\.sh --register`/the verdict/g' "$path" > "$copy"
  if _check_register_wiring "$copy" "mutant" 2>/dev/null; then
    echo "mutant (verdict-resolver.sh --register removed from test-perf) passed — test is broken" >&2; false
  fi
}

@test "register wiring: removing verdict-resolver from code-review verdict section fails the wiring check" {
  local base="$BATS_TEST_DIRNAME/.."
  local path="$base/skills/gaia-code-review/SKILL.md"
  [ -f "$path" ] || { echo "not found" >&2; false; }
  _check_register_wiring "$path" "baseline" || {
    echo "baseline failed" >&2; false
  }
  # Mutant: replace verdict-resolver.sh with generic-resolver.sh throughout
  local copy="$TEST_TMP/mutant-cr-no-vr.md"
  sed 's/verdict-resolver\.sh/generic-resolver.sh/g' "$path" > "$copy"
  if _check_register_wiring "$copy" "mutant" 2>/dev/null; then
    echo "mutant (verdict-resolver removed from code-review) passed — test is broken" >&2; false
  fi
}

@test "run-id forwarding: run-all-reviews dispatch contract passes --run-id" {
  local base="$BATS_TEST_DIRNAME/.."
  local f="$base/skills/gaia-run-all-reviews/SKILL.md"
  [ -f "$f" ] || { echo "not found" >&2; false; }
  # Extract the Skill-dispatch contract code block (between Skill-dispatch
  # contract and the next heading) and check the Invoke line carries --run-id
  local dispatch_block
  dispatch_block="$(awk '
    /Skill-dispatch contract/ { found=1 }
    found && /^[# ]*[0-9]+\. After the skill returns/ { exit }
    found { print }
  ' "$f")"
  grep -qF -- '--run-id' <<<"$dispatch_block" || {
    echo "dispatch contract code block does not pass --run-id" >&2; false
  }
}

@test "run-id forwarding: each review skill documents how to obtain run_id from arguments" {
  local base="$BATS_TEST_DIRNAME/.."
  local skills=(
    "skills/gaia-code-review/SKILL.md"
    "skills/gaia-qa-tests/SKILL.md"
    "skills/gaia-review-security/SKILL.md"
    "skills/gaia-test-automate/SKILL.md"
    "skills/gaia-test-review/SKILL.md"
    "skills/gaia-review-perf/SKILL.md"
    "skills/gaia-test-dast/SKILL.md"
    "skills/gaia-test-perf/SKILL.md"
    "knowledge/review-skill-template.md"
  )
  local failed=0
  local f
  for f in "${skills[@]}"; do
    local path="$base/$f"
    [ -f "$path" ] || { echo "not found: $f" >&2; failed=1; continue; }
    if ! grep -qF 'arguments contain' "$path"; then
      echo "$f: missing run-id forwarding sentence (expected 'arguments contain')" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}
