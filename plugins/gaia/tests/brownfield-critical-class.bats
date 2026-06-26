#!/usr/bin/env bats
# brownfield-critical-class.bats — unit tests for the brownfield
# critical-class classifier (finding-content vs tooling-error).
#
# The classifier is a shared deterministic helper that inspects the SHAPE
# of a finding or error envelope and returns one of two classes:
#   finding-content  — a gap-entry-shaped finding about the scanned codebase
#   tooling-error    — a scanner crash, tool unavailable, or malformed entry
#
# The YOLO downgrade decision reads this classifier's output rather than
# re-judging each CRITICAL via LLM prose interpretation.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLASSIFIER="$PLUGIN_ROOT/scripts/lib/brownfield-critical-class.sh"
  SKILL="$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
}

teardown() { common_teardown; }

# ============================================================================
# Unit tests: classifier function (AC1)
# ============================================================================

@test "classifier returns finding-content for a gap-entry-shaped finding (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/gap-entry.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "DC-001",
  "category": "doc-code-drift",
  "severity": "CRITICAL",
  "title": "README claims Python 3.8 but pyproject.toml requires 3.11",
  "evidence": {
    "file": "README.md",
    "line_range": "12"
  }
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "finding-content" ]
}

@test "classifier returns tooling-error for an error-shaped envelope (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/error-envelope.json"
  cat > "$fixture" <<'JSON'
{
  "status": "CRITICAL",
  "summary": "grype scanner crashed with exit code 137 — out of memory",
  "artifacts": [],
  "findings": [],
  "next": null
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

@test "classifier returns tooling-error for a finding missing gap_id (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/no-gap-id.json"
  cat > "$fixture" <<'JSON'
{
  "category": "security",
  "severity": "CRITICAL",
  "title": "Scanner unavailable",
  "evidence": {
    "file": "src/app.py"
  }
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

@test "classifier returns tooling-error for a finding missing category (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/no-category.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "SEC-001",
  "severity": "CRITICAL",
  "title": "Scan incomplete",
  "evidence": {
    "file": "src/main.py"
  }
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

@test "classifier returns tooling-error for a finding missing evidence (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/no-evidence.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "RB-001",
  "category": "runtime-behavior",
  "severity": "CRITICAL",
  "title": "Tool not available on host"
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

@test "classifier returns tooling-error for a finding with evidence missing file (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/no-evidence-file.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "ISEAM-001",
  "category": "integration-seam",
  "severity": "CRITICAL",
  "title": "Integration test harness unreachable",
  "evidence": {
    "snippet": "connection refused"
  }
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

@test "classifier returns tooling-error for malformed JSON (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/malformed.json"
  printf 'this is not json\n' > "$fixture"

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

@test "classifier returns tooling-error for missing file path (AC1)" {
  source "$CLASSIFIER"

  run bfcc_classify_critical "$TEST_TMP/nonexistent.json"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

@test "classifier returns tooling-error for empty input path (AC1)" {
  source "$CLASSIFIER"

  run bfcc_classify_critical ""
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

# ============================================================================
# Determinism: same input produces same output (AC1)
# ============================================================================

@test "classifier is deterministic — same input yields identical output across runs (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/determinism.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "HC-001",
  "category": "hardcoded-value",
  "severity": "CRITICAL",
  "title": "AWS secret key hardcoded in config.py",
  "evidence": {
    "file": "src/config.py",
    "line_range": "42-44"
  }
}
JSON

  local result1 result2 result3
  result1="$(bfcc_classify_critical "$fixture")"
  result2="$(bfcc_classify_critical "$fixture")"
  result3="$(bfcc_classify_critical "$fixture")"

  [ "$result1" = "finding-content" ]
  [ "$result1" = "$result2" ]
  [ "$result2" = "$result3" ]
}

# ============================================================================
# Edge: gap_id present but pattern invalid (AC1)
# ============================================================================

@test "classifier returns tooling-error when gap_id present but not pattern-valid (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/bad-gap-id.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "not-a-valid-id",
  "category": "security",
  "severity": "CRITICAL",
  "title": "Some finding",
  "evidence": {
    "file": "src/app.py"
  }
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

# ============================================================================
# Edge: category present but not in the canonical enum (AC1)
# ============================================================================

@test "classifier returns tooling-error when category is not in the schema enum (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/bad-category.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "SEC-001",
  "category": "unknown-category",
  "severity": "CRITICAL",
  "title": "Some finding",
  "evidence": {
    "file": "src/app.py"
  }
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

# ============================================================================
# Downgrade-scope tests: phase-aware behavior (AC2)
# ============================================================================

@test "finding-content at downgrade phase 3 is classified for downgrade (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/phase3.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "DC-002",
  "category": "doc-code-drift",
  "severity": "CRITICAL",
  "title": "README contradicts package.json version",
  "evidence": {
    "file": "README.md",
    "line_range": "5"
  }
}
JSON

  run bfcc_should_downgrade "$fixture" "3"
  [ "$status" -eq 0 ]
  [ "$output" = "downgrade" ]
}

@test "finding-content at downgrade phase 6 is classified for downgrade (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/phase6.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "SEC-003",
  "category": "security",
  "severity": "CRITICAL",
  "title": "CI pre-merge gate is a no-op stub",
  "evidence": {
    "file": ".github/workflows/ci.yml",
    "line_range": "1-3"
  }
}
JSON

  run bfcc_should_downgrade "$fixture" "6"
  [ "$status" -eq 0 ]
  [ "$output" = "downgrade" ]
}

@test "finding-content at downgrade phase 8b is classified for downgrade (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/phase8b.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "DC-004",
  "category": "doc-code-drift",
  "severity": "CRITICAL",
  "title": "PRD acceptance criteria are untestable",
  "evidence": {
    "file": ".gaia/artifacts/planning-artifacts/prd.md",
    "line_range": "100-120"
  }
}
JSON

  run bfcc_should_downgrade "$fixture" "8b"
  [ "$status" -eq 0 ]
  [ "$output" = "downgrade" ]
}

@test "tooling-error at downgrade phase 3 still halts (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/tooling-p3.json"
  cat > "$fixture" <<'JSON'
{
  "status": "CRITICAL",
  "summary": "scanner crashed with exit code 1",
  "artifacts": [],
  "findings": [],
  "next": null
}
JSON

  run bfcc_should_downgrade "$fixture" "3"
  [ "$status" -eq 0 ]
  [ "$output" = "halt" ]
}

@test "finding-content at phase 4 halts regardless of class (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/phase4.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "DC-005",
  "category": "doc-code-drift",
  "severity": "CRITICAL",
  "title": "Test infrastructure broken",
  "evidence": {
    "file": "tests/conftest.py",
    "line_range": "1"
  }
}
JSON

  run bfcc_should_downgrade "$fixture" "4"
  [ "$status" -eq 0 ]
  [ "$output" = "halt" ]
}

@test "finding-content at phase 8c halts regardless of class (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/phase8c.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "DC-006",
  "category": "doc-code-drift",
  "severity": "CRITICAL",
  "title": "PRD claim contradicted by code",
  "evidence": {
    "file": "src/api.py",
    "line_range": "50-60"
  }
}
JSON

  run bfcc_should_downgrade "$fixture" "8c"
  [ "$status" -eq 0 ]
  [ "$output" = "halt" ]
}

@test "tooling-error at any unrecognized phase halts (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/unknown-phase.json"
  cat > "$fixture" <<'JSON'
{
  "status": "CRITICAL",
  "summary": "tool unavailable",
  "artifacts": [],
  "findings": [],
  "next": null
}
JSON

  run bfcc_should_downgrade "$fixture" "99"
  [ "$status" -eq 0 ]
  [ "$output" = "halt" ]
}

# ============================================================================
# SKILL.md prose-coverage: deterministic classifier as SSOT (AC2)
# ============================================================================

@test "SKILL.md references the shared classifier as the deterministic source of truth (AC2)" {
  grep -q 'brownfield-critical-class.sh' "$SKILL"
  grep -q 'bfcc_classify_critical' "$SKILL"
}

@test "SKILL.md documents that the orchestrator applies the classifier verdict, not re-judges (AC2)" {
  grep -qi 'deterministic.*classifier\|classifier.*deterministic' "$SKILL"
  grep -qi 'does not re-judge\|not re-judge' "$SKILL"
}

@test "SKILL.md documents the finding shape as the discriminator (AC2)" {
  grep -qi 'gap-entry.*shape\|shape.*gap-entry\|finding.*shape\|shape.*finding' "$SKILL"
}

# ============================================================================
# Main-guard: classifier script is not directly executable (AC3)
# ============================================================================

@test "classifier script has a main guard preventing direct execution (AC3)" {
  # The script should refuse direct execution and exit non-zero
  run bash "$CLASSIFIER"
  [ "$status" -ne 0 ]
}

# ============================================================================
# Edge: whitespace-only evidence.file is malformed (AC1)
# ============================================================================

@test "classifier returns tooling-error when evidence.file is whitespace-only (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/ws-evidence-file.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "DC-010",
  "category": "doc-code-drift",
  "severity": "CRITICAL",
  "title": "Whitespace-only file path",
  "evidence": {
    "file": "   "
  }
}
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

# ============================================================================
# Edge: valid JSON but wrong top-level shape (array, not object) (AC1)
# ============================================================================

@test "classifier returns tooling-error for a top-level JSON array (AC1)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/json-array.json"
  cat > "$fixture" <<'JSON'
[
  {
    "gap_id": "DC-011",
    "category": "doc-code-drift",
    "severity": "CRITICAL",
    "title": "Array-wrapped finding",
    "evidence": { "file": "src/app.py" }
  }
]
JSON

  run bfcc_classify_critical "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "tooling-error" ]
}

# ============================================================================
# Edge: empty phase in bfcc_should_downgrade always halts (AC2)
# ============================================================================

@test "should-downgrade with empty phase halts unconditionally (AC2)" {
  source "$CLASSIFIER"

  local fixture="$TEST_TMP/empty-phase.json"
  cat > "$fixture" <<'JSON'
{
  "gap_id": "DC-012",
  "category": "doc-code-drift",
  "severity": "CRITICAL",
  "title": "Valid finding but no phase supplied",
  "evidence": {
    "file": "README.md",
    "line_range": "1"
  }
}
JSON

  run bfcc_should_downgrade "$fixture" ""
  [ "$status" -eq 0 ]
  [ "$output" = "halt" ]
}
