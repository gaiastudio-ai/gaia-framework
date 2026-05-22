#!/usr/bin/env bats
# gaia-security-review.bats — E65-S3 coverage for the migrated SKILL.md
#
# Covers AC1..AC5 + AC-EC1..AC-EC13 from
# docs/implementation-artifacts/E65-S3-*.md.
#
# Strategy mirrors gaia-code-review.bats (E65-S2): structural assertions over
# the migrated SKILL.md plus fixture-driven invocations of the deterministic
# primitives shipped in E65-S1 (verdict-resolver.sh, analysis-results.schema.json).
# Live LLM invocation is out-of-scope; AC3..AC5 use synthetic LLM findings JSON.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SKILL_FILE="$BATS_TEST_DIRNAME/../skills/gaia-security-review/SKILL.md"
RESOLVER="$BATS_TEST_DIRNAME/../scripts/verdict-resolver.sh"
SCHEMA_FILE="$BATS_TEST_DIRNAME/../schemas/analysis-results.schema.json"
PARITY_BATS="$BATS_TEST_DIRNAME/evidence-judgment-parity.bats"
LOAD_PERSONA="$BATS_TEST_DIRNAME/../scripts/load-stack-persona.sh"
FIX_DIR="$BATS_TEST_DIRNAME/fixtures/security-review"

setup() { common_setup; }
teardown() { common_teardown; }

# ----------------------------------------------------------------------
# AC1 — SKILL.md structure (TC-DEJ-PHASE-S3, TC-DEJ-DET-S3)
# ----------------------------------------------------------------------

@test "AC1 (a): unifying principle present verbatim" {
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$SKILL_FILE"
}

@test "AC1 (b): seven phase headers present in canonical order" {
  local got
  got="$(grep -nE '^### |^## ' "$SKILL_FILE" || true)"
  local expected=(Setup "Story Gate" "Phase 3A" "Phase 3B" "Architecture Conformance" Verdict Output Finalize)
  local prev_line=0
  for p in "${expected[@]}"; do
    local line
    line="$(printf '%s\n' "$got" | grep -F "$p" | head -1 | cut -d: -f1)"
    [ -n "$line" ] || { echo "missing phase header: $p" >&2; return 1; }
    [ "$line" -gt "$prev_line" ] || { echo "phase out of order: $p (line=$line, prev=$prev_line)" >&2; return 1; }
    prev_line="$line"
  done
}

@test "AC1 (c): determinism settings (temperature 0, model claude-opus-4-7, prompt_hash)" {
  grep -F 'temperature: 0' "$SKILL_FILE"
  grep -F 'claude-opus-4-7' "$SKILL_FILE"
  grep -F 'prompt_hash' "$SKILL_FILE"
}

@test "AC1 (d): allowed-tools is exactly [Read, Grep, Glob, Bash] (no Write/Edit)" {
  local line
  line="$(grep -E '^allowed-tools:' "$SKILL_FILE")"
  [[ "$line" == *Read* ]]
  [[ "$line" == *Grep* ]]
  [[ "$line" == *Glob* ]]
  [[ "$line" == *Bash* ]]
  [[ "$line" != *Write* ]]
  [[ "$line" != *Edit* ]]
}

@test "AC1 (e): per-skill stack-toolkit table covers all 7 canonical stacks" {
  for s in ts-dev java-dev python-dev go-dev flutter-dev mobile-dev angular-dev; do
    grep -F "$s" "$SKILL_FILE" >/dev/null || { echo "missing stack: $s" >&2; return 1; }
  done
}

# AC3 — severity rubric: >=2 examples per tier (Critical, Warning, Suggestion)
@test "AC3: severity rubric has >=2 examples per tier" {
  count_examples() {
    local tier="$1"
    awk -v tier="$tier" '
      $0 ~ "^### "tier"$" { in_section=1; next }
      in_section && /^### / { in_section=0 }
      in_section && /^- / { count++ }
      END { print count+0 }
    ' "$SKILL_FILE"
  }
  local c w s
  c="$(count_examples Critical)"
  w="$(count_examples Warning)"
  s="$(count_examples Suggestion)"
  [ "$c" -ge 2 ] || { echo "Critical examples: $c (<2)" >&2; return 1; }
  [ "$w" -ge 2 ] || { echo "Warning examples: $w (<2)" >&2; return 1; }
  [ "$s" -ge 2 ] || { echo "Suggestion examples: $s (<2)" >&2; return 1; }
}

@test "AC3: severity rubric mentions OWASP categories A01, A02, A03, A05, A07" {
  for cat in A01 A02 A03 A05 A07; do
    grep -F "$cat" "$SKILL_FILE" >/dev/null || { echo "missing OWASP category: $cat" >&2; return 1; }
  done
}

# ----------------------------------------------------------------------
# AC2 — Phase 3A toolkit scope = Semgrep + secret scan + dep audit
# ----------------------------------------------------------------------

@test "AC2: Phase 3A invokes Semgrep + secret scanner + dep audit" {
  local p3a
  p3a="$(awk '
    /^### Phase 3A/ { in_p=1; next }
    in_p && /^### / { in_p=0 }
    in_p { print }
  ' "$SKILL_FILE")"
  [ -n "$p3a" ] || { echo "Phase 3A section not found" >&2; return 1; }
  printf '%s' "$p3a" | grep -iF 'semgrep' >/dev/null || { echo "Phase 3A must invoke semgrep" >&2; return 1; }
  printf '%s' "$p3a" | grep -iE '(gitleaks|trufflehog)' >/dev/null || { echo "Phase 3A must invoke secret scanner" >&2; return 1; }
  printf '%s' "$p3a" | grep -iE '(npm audit|pip-audit|govulncheck)' >/dev/null || { echo "Phase 3A must invoke dep audit" >&2; return 1; }
}

@test "AC2: Phase 3A excludes code-review tools (eslint/prettier/tsc as primary)" {
  # Phase 3A scope is security-only; code-review's eslint/prettier/tsc are NOT
  # the primary toolkit. They MAY appear in cross-references to E65-S2.
  # Strict check: the canonical security tools must be present.
  grep -iF 'semgrep' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC1 — Semgrep noise threshold documented
# ----------------------------------------------------------------------

@test "AC-EC1: SKILL.md documents Semgrep critical-promotion threshold (confidence-high + severity-high)" {
  grep -iE '(confidence.*high|rule_confidence)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC2 — Secret-scan scope: working tree, NOT git history
# ----------------------------------------------------------------------

@test "AC-EC2: SKILL.md documents secret-scan scope = File List + working tree, NOT git history" {
  grep -iE '(working tree|working-tree)' "$SKILL_FILE" >/dev/null
  grep -iE '(NOT git history|not git history|exclude.*history)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC3 — Advisory DB fingerprint in cache key
# ----------------------------------------------------------------------

@test "AC-EC3: SKILL.md includes advisory_db_fingerprint in cache key" {
  grep -iF 'advisory_db_fingerprint' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC4 — Test-fixture secret downgrade to Suggestion
# ----------------------------------------------------------------------

@test "AC-EC4: SKILL.md documents test-fixture path downgrade for secret findings" {
  grep -iE '(test fixture|test-fixture|tests/)' "$SKILL_FILE" >/dev/null
  grep -iF 'Suggestion' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC5 — Semgrep crash → BLOCKED (verdict resolver fixture)
# ----------------------------------------------------------------------

@test "AC-EC5: semgrep-crash fixture (status=errored) => verdict BLOCKED" {
  local fix="$FIX_DIR/semgrep-crash"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  run "$RESOLVER" --analysis-results "$fix/analysis-results.json" --llm-findings "$fix/llm-findings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ----------------------------------------------------------------------
# AC-EC7 — Transitive dev-only CVE downgrade documented
# ----------------------------------------------------------------------

@test "AC-EC7: SKILL.md documents transitive dev-only CVE downgrade rule" {
  grep -iE '(dev-only|transitive)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC8 — Per-stack dep-audit selection (canonical names)
# ----------------------------------------------------------------------

@test "AC-EC8: SKILL.md toolkit table uses canonical stack names emitted by load-stack-persona.sh" {
  for canonical in ts-dev java-dev python-dev go-dev flutter-dev mobile-dev angular-dev; do
    grep -F "$canonical" "$SKILL_FILE" >/dev/null \
      || { echo "missing canonical stack key in SKILL.md: $canonical" >&2; return 1; }
    grep -F "$canonical" "$LOAD_PERSONA" >/dev/null \
      || { echo "load-stack-persona.sh does not reference: $canonical" >&2; return 1; }
  done
}

# ----------------------------------------------------------------------
# AC-EC9 — Missing custom Semgrep rules: silent skip
# ----------------------------------------------------------------------

@test "AC-EC9: SKILL.md documents skip when .semgrep/ custom rules absent" {
  grep -F '.semgrep/' "$SKILL_FILE" >/dev/null
  grep -iE '(skip|skip_reason)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC10 — Phase 3A budget enforcement per tool
# ----------------------------------------------------------------------

@test "AC-EC10: SKILL.md documents per-tool wall-clock caps (Semgrep 30s, secret scan 15s, dep audit 15s)" {
  grep -iE '(30s|≤30s)' "$SKILL_FILE" >/dev/null
  grep -iE '(15s|≤15s)' "$SKILL_FILE" >/dev/null
}

@test "AC-EC10: tool-timeout fixture (status=errored on timeout) => verdict BLOCKED" {
  local fix="$FIX_DIR/tool-timeout"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  run "$RESOLVER" --analysis-results "$fix/analysis-results.json" --llm-findings "$fix/llm-findings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ----------------------------------------------------------------------
# AC-EC11 — Finding deduplication by (file, line, finding-type)
# ----------------------------------------------------------------------

@test "AC-EC11: SKILL.md documents dedup tuple (file, line, finding-type)" {
  grep -iE '(dedup|deduplicat)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC12 — Entropy false-positive downgrade
# ----------------------------------------------------------------------

@test "AC-EC12: SKILL.md documents entropy false-positive downgrade (hex hash, base64 UUID)" {
  grep -iE '(entropy|hex hash|base64)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC13 — Path normalization to repo-relative
# ----------------------------------------------------------------------

@test "AC-EC13: SKILL.md documents path normalization to repo-relative across tools" {
  grep -iE '(repo-relative|path normalization|normaliz)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC4 — parity bats registers gaia-security-review
# ----------------------------------------------------------------------

@test "AC4: gaia-security-review SKILL.md is registered in evidence-judgment-parity.bats REVIEW_SKILLS" {
  grep -F 'skills/gaia-security-review/SKILL.md' "$PARITY_BATS" >/dev/null
}

# ----------------------------------------------------------------------
# AC5 — End-to-end persist + fork allowlist (FR-402, NFR-DEJ-4)
# ----------------------------------------------------------------------

@test "AC5 (a): SKILL.md prescribes parent-mediated write to FR-402 path security-review-{key}.md (canonical post-AF-21-22)" {
  grep -F 'security-review-' "$SKILL_FILE" >/dev/null
  # AF-2026-05-21-22 canonicalized this path. Accept canonical or legacy.
  grep -qE '(docs|\.gaia/artifacts)/implementation-artifacts/' "$SKILL_FILE"
  grep -iF 'parent' "$SKILL_FILE" >/dev/null
}

@test "AC5 (b): end-to-end-real-story fixture has expected report shape" {
  local fix="$FIX_DIR/end-to-end-real-story"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  local rep="$fix/expected-report.md"
  [ -r "$rep" ] || { echo "expected-report.md missing in fixture" >&2; return 1; }
  grep -F '## Deterministic Analysis' "$rep" >/dev/null
  grep -F '## LLM Semantic Review' "$rep" >/dev/null
  grep -E '^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$' "$rep" >/dev/null
}

# ----------------------------------------------------------------------
# Verdict-resolver smoke: LLM-cannot-override on Semgrep failure
# ----------------------------------------------------------------------

@test "AC-EC1 (resolver): semgrep-noise fixture with synthetic LLM=APPROVE => verdict matches resolver precedence" {
  local fix="$FIX_DIR/semgrep-noise"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  run "$RESOLVER" --analysis-results "$fix/analysis-results.json" --llm-findings "$fix/llm-findings.json"
  [ "$status" -eq 0 ]
  # All Semgrep findings in this fixture have confidence=low; LLM does NOT
  # promote to Critical → verdict APPROVE (no blocking findings).
  [ "$output" = "APPROVE" ]
}

# ----------------------------------------------------------------------
# Stub-marker hygiene
# ----------------------------------------------------------------------

@test "no unfilled GAIA_REVIEW_STUB sentinels remain in migrated SKILL.md" {
  run grep -F 'GAIA_REVIEW_STUB:' "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

# ======================================================================
# E66-S4 — V2 (ADR-077) migration assertions
# ======================================================================
# These tests harden the V2 sibling-reference contract. They cover:
#   AC1 (TC-RSV2-FOUND-SEC-01): unifying principle + seven-phase + determinism
#   AC2 (TC-RSV2-PROBE-SEC-01): toolkit wired through tool-availability-probe.sh
#   AC3 (TC-RSV2-FOUND-SEC-02): >=2 OWASP severity examples per tier
#   AC4 (TC-RSV2-FOUND-SEC-03): fork-write fix — parent-context persistence
#   AC5 (TC-RSV2-FOUND-SEC-04): cache key includes advisory_db_fingerprint
#   AC6 (TC-RSV2-OVERLAY-SEC-01): agent-overlay.sh -> Zara wiring
#   AC7 (TC-RSV2-FOUND-SEC-05): verdict-resolver.sh + schema_version 1.0
#   AC8 (TC-RSV2-FOUND-SEC-06): parity bats hook present
#   AC9 (TC-RSV2-FOUND-SEC-07): Migration Checklist for E67 sibling consumption

REVIEW_COMMON_DIR="$BATS_TEST_DIRNAME/../scripts/review-common"
PROBE_SCRIPT="$BATS_TEST_DIRNAME/../scripts/tool-availability-probe.sh"
OVERLAY_SCRIPT="$REVIEW_COMMON_DIR/agent-overlay.sh"

@test "RSV2 AC2/PROBE-SEC-01: SKILL.md references tool-availability-probe.sh for Phase 3A toolkit" {
  grep -F 'tool-availability-probe.sh' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC2/PROBE-SEC-01: SKILL.md documents three-state probe taxonomy (available/expected_and_missing/ran_and_errored/not_applicable)" {
  grep -iE '(expected.and.missing|expected_and_missing)' "$SKILL_FILE" >/dev/null
  grep -iE '(ran.and.errored|ran_and_errored)' "$SKILL_FILE" >/dev/null
  grep -iE '(not.applicable|not_applicable)' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC2: SKILL.md references review-common shared library wiring" {
  grep -F 'review-common' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC2: SKILL.md references live-secret-classifier.sh credential prefix matcher" {
  grep -F 'live-secret-classifier.sh' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC2: SKILL.md references threat-model-validator.sh" {
  grep -F 'threat-model-validator.sh' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC5: cache key composition explicitly enumerates story_key, tool_name, tool_version, file_list_hash, advisory_db_fingerprint" {
  grep -F 'advisory_db_fingerprint' "$SKILL_FILE" >/dev/null
  grep -iE '(story_key|story.key)' "$SKILL_FILE" >/dev/null
  grep -F 'tool_versions' "$SKILL_FILE" >/dev/null
  grep -iE '(file.hashes|file_list_hash|file_hashes)' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC6/OVERLAY-SEC-01: SKILL.md references agent-overlay.sh for Zara persona resolution" {
  grep -F 'agent-overlay.sh' "$SKILL_FILE" >/dev/null
  grep -iE '(zara|gaia-review-security)' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC6/OVERLAY-SEC-01: agent-overlay.sh resolves gaia-review-security -> zara" {
  [ -x "$OVERLAY_SCRIPT" ] || skip "agent-overlay.sh not executable"
  run "$OVERLAY_SCRIPT" --skill gaia-review-security
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent_id":"zara"'* ]]
  [[ "$output" == *'"sidecar_path":"_memory/zara-sidecar.md"'* ]]
}

@test "RSV2 AC7: SKILL.md prescribes analysis-results.schema.json schema_version 1.0 validation" {
  grep -F 'analysis-results.schema.json' "$SKILL_FILE" >/dev/null
  grep -iE 'schema_version.*1\.0|schema-version.*1\.0|"1\.0"' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC8: parity bats has gaia-security-review registered in REVIEW_SKILLS" {
  grep -F 'skills/gaia-security-review/SKILL.md' "$PARITY_BATS" >/dev/null
}

@test "RSV2 AC9: SKILL.md or companion includes a Migration Checklist for E67 sibling consumption" {
  grep -iE '(migration checklist|migration check.list)' "$SKILL_FILE" >/dev/null
}

@test "RSV2 AC4: fork allowlist remains exactly [Read, Grep, Glob, Bash] with parent-mediated write" {
  local line
  line="$(grep -E '^allowed-tools:' "$SKILL_FILE")"
  [[ "$line" == *Read* ]]
  [[ "$line" == *Grep* ]]
  [[ "$line" == *Glob* ]]
  [[ "$line" == *Bash* ]]
  [[ "$line" != *Write* ]]
  [[ "$line" != *Edit* ]]
  # Parent-mediated write language present.
  grep -iE '(parent.mediated|parent.context|parent write)' "$SKILL_FILE" >/dev/null
}
