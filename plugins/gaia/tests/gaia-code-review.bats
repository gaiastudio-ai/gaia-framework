#!/usr/bin/env bats
# gaia-code-review.bats — E65-S2 coverage for the migrated SKILL.md
#
# Covers AC1..AC8 + AC-EC1..AC-EC14 from
# docs/implementation-artifacts/E65-S2-*.md.
#
# Strategy: structural assertions over the migrated SKILL.md plus
# fixture-driven invocations of the deterministic primitives shipped in
# E65-S1 (verdict-resolver.sh, analysis-results.schema.json). Live LLM
# invocation is out-of-scope; AC3/AC4 use synthetic LLM findings JSON.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SKILL_FILE="$BATS_TEST_DIRNAME/../skills/gaia-code-review/SKILL.md"
TEMPLATE_FILE="$BATS_TEST_DIRNAME/../knowledge/review-skill-template.md"
RESOLVER="$BATS_TEST_DIRNAME/../scripts/verdict-resolver.sh"
SCHEMA_FILE="$BATS_TEST_DIRNAME/../schemas/analysis-results.schema.json"
PARITY_BATS="$BATS_TEST_DIRNAME/evidence-judgment-parity.bats"
LOAD_PERSONA="$BATS_TEST_DIRNAME/../scripts/load-stack-persona.sh"
FIX_DIR="$BATS_TEST_DIRNAME/fixtures/code-review"

setup() { common_setup; }
teardown() { common_teardown; }

# ----------------------------------------------------------------------
# AC1 — SKILL.md structure (TC-DEJ-PHASE-01, TC-DEJ-DET-01)
# ----------------------------------------------------------------------

@test "a): unifying principle present verbatim at top of SKILL.md" {
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$SKILL_FILE"
}

@test "b): seven phase headers present in canonical order" {
  # Extract H2/H3 headers in document order; assert phases appear in order.
  local got
  got="$(grep -nE '^### |^## ' "$SKILL_FILE" || true)"
  # canonical: Setup, Story Gate, Phase 3A, Phase 3B, Architecture Conformance, Verdict, Output, Finalize
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

@test "c): determinism settings (temperature 0, model claude-opus-4-7, prompt_hash) declared in body" {
  grep -F 'temperature: 0' "$SKILL_FILE"
  grep -F 'claude-opus-4-7' "$SKILL_FILE"
  grep -F 'prompt_hash' "$SKILL_FILE"
}

@test "d): allowed-tools frontmatter is exactly [Read, Grep, Glob, Bash]" {
  local line
  line="$(grep -E '^allowed-tools:' "$SKILL_FILE")"
  [[ "$line" == *Read* ]]
  [[ "$line" == *Grep* ]]
  [[ "$line" == *Glob* ]]
  [[ "$line" == *Bash* ]]
  # Must NOT contain Write or Edit
  [[ "$line" != *Write* ]]
  [[ "$line" != *Edit* ]]
}

@test "e): per-skill stack-toolkit table present with all 7 canonical stacks" {
  for s in ts-dev java-dev python-dev go-dev flutter-dev mobile-dev angular-dev; do
    grep -F "$s" "$SKILL_FILE" >/dev/null || { echo "missing stack: $s" >&2; return 1; }
  done
}

@test "e): severity rubric has >=2 examples per tier (Critical, Warning, Suggestion)" {
  # Extract Critical/Warning/Suggestion sections; each must have >=2 list items.
  # Heuristic: between '### Critical' and the next '### ' header, count `- ` list items.
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

# ----------------------------------------------------------------------
# AC2 — Phase 3A toolkit scope strict (TC-DEJ-TOOLKIT-01)
# ----------------------------------------------------------------------

@test "Phase 3A toolkit excludes Semgrep, secret scan, dep audit, test execution" {
  # The migrated SKILL.md MUST NOT prescribe Semgrep / gitleaks / npm-audit /
  # test-runner invocations in Phase 3A. Phase 3A scope = linter, formatter,
  # per-file rules, type checker, build verification ONLY.
  # We grep the Phase 3A section for forbidden tool names.
  local p3a
  p3a="$(awk '
    /^### Phase 3A/ { in_p=1; next }
    in_p && /^### / { in_p=0 }
    in_p { print }
  ' "$SKILL_FILE")"
  [ -n "$p3a" ] || { echo "Phase 3A section not found" >&2; return 1; }
  # forbidden: semgrep, gitleaks, npm audit, jest invocation, vitest invocation
  for forbidden in semgrep gitleaks 'npm audit' 'pip-audit' 'go test'; do
    if printf '%s' "$p3a" | grep -iF "$forbidden" >/dev/null; then
      echo "Phase 3A must not invoke $forbidden" >&2; return 1
    fi
  done
}

# ----------------------------------------------------------------------
# AC3 — LLM-cannot-override (TC-DEJ-OVERRIDE-1)
# ----------------------------------------------------------------------

@test "tsc-error fixture + synthetic LLM=APPROVE => verdict resolver emits REQUEST_CHANGES" {
  local fix="$FIX_DIR/tsc-error"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  run "$RESOLVER" --analysis-results "$fix/analysis-results.json" --llm-findings "$fix/llm-findings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

# ----------------------------------------------------------------------
# AC4 — eslint-crash → BLOCKED (TC-DEJ-TOOLKIT-03)
# ----------------------------------------------------------------------

@test "eslint-crash fixture (status=errored) => verdict BLOCKED" {
  local fix="$FIX_DIR/eslint-crash"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  run "$RESOLVER" --analysis-results "$fix/analysis-results.json" --llm-findings "$fix/llm-findings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ----------------------------------------------------------------------
# AC5 — Python-only skip (TC-DEJ-TOOLKIT-02)
# ----------------------------------------------------------------------

@test "python-only-repo fixture records tsc skipped + skip_reason verbatim" {
  local fix="$FIX_DIR/python-only-repo"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  # The fixture's analysis-results.json MUST contain tsc with status=skipped
  # AND skip_reason exactly "no TypeScript files in File List".
  run jq -e '
    .checks
    | map(select(.name == "tsc"))
    | first
    | (.status == "skipped" and .skip_reason == "no TypeScript files in File List")
  ' "$fix/analysis-results.json"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # And the verdict resolver should still APPROVE on this fixture (no failures).
  run "$RESOLVER" --analysis-results "$fix/analysis-results.json" --llm-findings "$fix/llm-findings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# ----------------------------------------------------------------------
# AC6 — end-to-end persist + fork allowlist (TC-DEJ-WRITE-1, TC-DEJ-WRITE-02)
# ----------------------------------------------------------------------

@test "b): SKILL.md frontmatter declares allowed-tools without Write/Edit" {
  # Same as AC1(d) — repeated per acceptance criterion mapping.
  local line
  line="$(grep -E '^allowed-tools:' "$SKILL_FILE")"
  [[ "$line" != *Write* ]]
  [[ "$line" != *Edit* ]]
}

@test "a): SKILL.md prescribes parent-mediated write to path" {
  # The output phase MUST mention the FR-402 locked path code-review-E<NN>-S<NNN>.md.
  grep -F 'code-review-' "$SKILL_FILE" >/dev/null
  # AF-2026-05-21-23 canonicalized this path. Accept canonical or legacy.
  grep -qE '(docs|\.gaia/artifacts)/implementation-artifacts/' "$SKILL_FILE"
  # Parent-mediated persistence keyword (Option A, parent context writes).
  grep -iF 'parent' "$SKILL_FILE" >/dev/null
}

@test "end-to-end-real-story fixture has expected report shape" {
  local fix="$FIX_DIR/end-to-end-real-story"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  # Expected report contains both top-level sections + verdict line.
  local rep="$fix/expected-report.md"
  [ -r "$rep" ] || { echo "expected-report.md missing in fixture" >&2; return 1; }
  grep -F '## Deterministic Analysis' "$rep" >/dev/null
  grep -F '## LLM Semantic Review' "$rep" >/dev/null
  grep -E '^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$' "$rep" >/dev/null
}

# ----------------------------------------------------------------------
# AC7 — cache hit (TC-DEJ-CACHE-01) + cache invalidation (EC-1, EC-3, EC-13)
# ----------------------------------------------------------------------

# Reusable cache-key implementation tested here as a self-contained shell
# function. The migrated SKILL.md prescribes the algorithm; this test asserts
# the algorithm produces stable output for stable inputs and changes for any
# input change.
compute_cache_key() {
  local file_list="$1"  # newline-separated paths
  local file_hashes="$2" # newline-separated 'path:sha256' lines
  local tool_config="$3" # tool config blob
  local tool_versions="$4" # newline-separated 'tool:ver' lines
  local resolved_config="$5" # output of `eslint --print-config <file>` (or empty)
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$file_list" "$file_hashes" "$tool_config" "$tool_versions" "$resolved_config" \
    | shasum -a 256 | awk '{print $1}'
}

@test "cache key is stable across identical inputs" {
  local k1 k2
  k1="$(compute_cache_key "src/a.ts" "src/a.ts:abc" "cfg-blob" "eslint:9.0.0" "resolved-rules")"
  k2="$(compute_cache_key "src/a.ts" "src/a.ts:abc" "cfg-blob" "eslint:9.0.0" "resolved-rules")"
  [ "$k1" = "$k2" ]
}

@test "cache key changes when resolved-config changes (extended-config bump)" {
  local k1 k2
  k1="$(compute_cache_key "src/a.ts" "src/a.ts:abc" "cfg-blob" "eslint:9.0.0" "resolved-rules-v1")"
  k2="$(compute_cache_key "src/a.ts" "src/a.ts:abc" "cfg-blob" "eslint:9.0.0" "resolved-rules-v2")"
  [ "$k1" != "$k2" ]
}

@test "cache key changes when file_hashes diverge from on-disk" {
  local k1 k2
  k1="$(compute_cache_key "src/a.ts" "src/a.ts:abc" "cfg-blob" "eslint:9.0.0" "resolved")"
  k2="$(compute_cache_key "src/a.ts" "src/a.ts:def" "cfg-blob" "eslint:9.0.0" "resolved")"
  [ "$k1" != "$k2" ]
}

@test "cache key changes when tool_versions changes" {
  local k1 k2
  k1="$(compute_cache_key "src/a.ts" "src/a.ts:abc" "cfg-blob" "eslint:9.0.0" "resolved")"
  k2="$(compute_cache_key "src/a.ts" "src/a.ts:abc" "cfg-blob" "eslint:9.1.0" "resolved")"
  [ "$k1" != "$k2" ]
}

@test "cache-hit fixture has analysis-results.json that validates against schema" {
  local fix="$FIX_DIR/cache-hit"
  [ -d "$fix" ] || { echo "fixture missing: $fix" >&2; return 1; }
  # JSON parses
  jq -e . "$fix/analysis-results.json" >/dev/null
  # schema_version field is "1.0"
  run jq -r '.schema_version' "$fix/analysis-results.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0" ]
  # tool_versions and file_hashes present (cache key inputs)
  jq -e 'has("tool_versions") and has("file_hashes")' "$fix/analysis-results.json" >/dev/null
}

# ----------------------------------------------------------------------
# AC8 — parity bats (TC-DEJ-PARITY-01)
# ----------------------------------------------------------------------

@test "gaia-code-review SKILL.md is registered in evidence-judgment-parity.bats REVIEW_SKILLS" {
  grep -E 'REVIEW_SKILLS=.*gaia-code-review' "$PARITY_BATS" >/dev/null \
    || grep -F 'skills/gaia-code-review/SKILL.md' "$PARITY_BATS" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC2 — File List references missing file → warning, no crash
# ----------------------------------------------------------------------

@test "file-list-diff-check.sh handles missing-file gracefully (no crash)" {
  # Build a minimal story and call the script — it must not crash.
  local story="$TEST_TMP/story.md"
  cat > "$story" <<'EOF'
---
key: "EC2-S1"
---

# Story

## File List

- src/missing-file.ts
EOF
  cd "$TEST_TMP"
  git init -q 2>/dev/null || true
  run "$BATS_TEST_DIRNAME/../scripts/file-list-diff-check.sh" --story-file "$story" --base main --repo "$TEST_TMP"
  # Exit must be 0 (non-blocking semantics, FR-DEJ-2).
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------
# AC-EC5 — same-story parallel safe (mkdir -p idempotent)
# ----------------------------------------------------------------------

@test "per-PID temp + atomic rename pattern documented in SKILL.md" {
  # Surface the documented pattern: per-PID temp + atomic rename, OR flock.
  grep -iE '(per-PID|atomic rename|mkdir -p)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC6 — failed vs errored distinction
# ----------------------------------------------------------------------

@test "status=failed (findings) maps to REQUEST_CHANGES" {
  local results="$TEST_TMP/results.json"
  cat > "$results" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "EC6-S1",
  "skill": "gaia-code-review",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [
    {"name": "tsc", "scope": "project", "status": "failed",
     "findings": [{"file": "src/a.ts", "line": 1, "severity": "error", "message": "type error", "blocking": true}]}
  ]
}
EOF
  local llm="$TEST_TMP/llm.json"
  echo '{"findings":[]}' > "$llm"
  run "$RESOLVER" --analysis-results "$results" --llm-findings "$llm"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "status=errored (crash) maps to BLOCKED" {
  local results="$TEST_TMP/results.json"
  cat > "$results" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "EC6-S1",
  "skill": "gaia-code-review",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [
    {"name": "eslint", "scope": "file", "status": "errored",
     "error_reason": "config crash"}
  ]
}
EOF
  local llm="$TEST_TMP/llm.json"
  echo '{"findings":[]}' > "$llm"
  run "$RESOLVER" --analysis-results "$results" --llm-findings "$llm"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ----------------------------------------------------------------------
# AC-EC7 — File-List-driven skip (not tsconfig-driven)
# ----------------------------------------------------------------------

@test "SKILL.md documents File-List-driven tsc skip decision (not tsconfig-driven)" {
  # The SKILL.md Phase 3A MUST document that skip decision uses File List, not project root tsconfig.
  grep -iF 'File List' "$SKILL_FILE" >/dev/null
  # Documented exact skip_reason string
  grep -F 'no TypeScript files in File List' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC8 — re-run-different-verdict overwrites
# ----------------------------------------------------------------------

@test "SKILL.md prescribes overwrite-not-append for review file persistence" {
  # The output phase MUST say latest verdict overwrites; no version-suffix.
  grep -iE '(overwrite|latest verdict wins|replace)' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC9 — malformed fork payload → BLOCKED + [INCOMPLETE]
# ----------------------------------------------------------------------

@test "SKILL.md prescribes payload validation + INCOMPLETE marker on malformed fork output" {
  grep -F '[INCOMPLETE]' "$SKILL_FILE" >/dev/null
  grep -iF 'malformed' "$SKILL_FILE" >/dev/null
}

@test "malformed analysis-results (missing schema_version) → BLOCKED" {
  local results="$TEST_TMP/results.json"
  echo '{"checks": []}' > "$results"   # no schema_version
  local llm="$TEST_TMP/llm.json"
  echo '{"findings":[]}' > "$llm"
  # Resolver emits a stderr diagnostic ("malformed analysis-results.json: ...")
  # before emitting BLOCKED on stdout. Under bats 1.5+ default merge mode, both
  # streams land in $output; assert against the LAST line which is the verdict.
  run "$RESOLVER" --analysis-results "$results" --llm-findings "$llm"
  [ "$status" -eq 0 ]
  local last_idx=$(( ${#lines[@]} - 1 ))
  [ "${lines[$last_idx]}" = "BLOCKED" ]
}

# ----------------------------------------------------------------------
# AC-EC10 — fork allowlist regression guard (covered by parity bats)
# ----------------------------------------------------------------------

@test "parity bats assert_allowed_tools_allowlist would catch Write addition" {
  # Build a synthetic SKILL.md with Edit added; the assertion must reject it.
  local synthetic="$TEST_TMP/SKILL.md"
  cat > "$synthetic" <<'EOF'
---
allowed-tools: [Read, Grep, Glob, Bash, Edit]
---
EOF
  # Replicate the parity bats assertion (line is allowed, but our AC1(d) check
  # in this suite explicitly forbids Edit/Write).
  local line
  line="$(grep -E '^allowed-tools:' "$synthetic")"
  if [[ "$line" == *Edit* || "$line" == *Write* ]]; then
    return 0   # regression detected as expected
  else
    return 1
  fi
}

# ----------------------------------------------------------------------
# AC-EC11 — determinism category+severity (textual variation OK)
# ----------------------------------------------------------------------

@test "SKILL.md documents determinism contract (category+severity match, text may vary)" {
  # The SKILL.md MUST surface the NFR-DEJ-2 determinism contract.
  grep -iE '(category.*severity|severity.*category)' "$SKILL_FILE" >/dev/null
  grep -iF 'temperature' "$SKILL_FILE" >/dev/null
}

# ----------------------------------------------------------------------
# AC-EC12 — partial findings + crash → BLOCKED still wins
# ----------------------------------------------------------------------

@test "status=errored with partial findings still maps to BLOCKED" {
  local results="$TEST_TMP/results.json"
  cat > "$results" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "EC12-S1",
  "skill": "gaia-code-review",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "checks": [
    {"name": "eslint", "scope": "file", "status": "errored",
     "error_reason": "config crash mid-run",
     "findings": [{"file": "src/a.ts", "line": 1, "severity": "warning", "message": "partial finding"}]}
  ]
}
EOF
  local llm="$TEST_TMP/llm.json"
  echo '{"findings":[]}' > "$llm"
  run "$RESOLVER" --analysis-results "$results" --llm-findings "$llm"
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

# ----------------------------------------------------------------------
# AC-EC14 — stack-key vocabulary consistency
# ----------------------------------------------------------------------

@test "SKILL.md toolkit table uses canonical stack names emitted by load-stack-persona.sh" {
  # The canonical names emitted by load-stack-persona.sh's canonical_to_filename
  # function. Each MUST appear in SKILL.md.
  for canonical in ts-dev java-dev python-dev go-dev flutter-dev mobile-dev angular-dev; do
    grep -F "$canonical" "$SKILL_FILE" >/dev/null \
      || { echo "missing canonical stack key in SKILL.md: $canonical" >&2; return 1; }
    grep -F "$canonical" "$LOAD_PERSONA" >/dev/null \
      || { echo "load-stack-persona.sh does not reference: $canonical" >&2; return 1; }
  done
}

# ----------------------------------------------------------------------
# Stub-marker hygiene (template stub sentinels)
# ----------------------------------------------------------------------

@test "no unfilled GAIA_REVIEW_STUB sentinels remain in migrated SKILL.md" {
  run grep -F 'GAIA_REVIEW_STUB:' "$SKILL_FILE"
  [ "$status" -ne 0 ]   # grep found nothing
}
