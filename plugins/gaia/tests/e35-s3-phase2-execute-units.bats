#!/usr/bin/env bats
# e35-s3-phase2-execute-units.bats
#
# Supplementary public-function unit tests for NFR-052 coverage gate.
# Directly exercises the public functions added by E35-S3 in phase2-execute.sh:
#
#   - extract_frontmatter
#   - fm_value
#   - fm_nested_value
#   - fm_array
#   - json_array_field
#   - sha256_of
#   - normalize_path
#
# Pattern: source function definitions via awk extraction, then call each
# function directly (same approach as e35-s2-approval-gate-units.bats).

load 'test_helper.bash'

setup() {
  common_setup
  # Isolate the semaphore state so tests never take real slots.
  export GAIA_STATE_DIR="$TEST_TMP/.gaia/state"
  mkdir -p "$GAIA_STATE_DIR"
}
teardown() { common_teardown; }

PHASE2_SH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-test-automate/scripts" && pwd)/phase2-execute.sh"

# ---------------------------------------------------------------------------
# Helper: extract function definitions from phase2-execute.sh
# ---------------------------------------------------------------------------

_load_phase2_functions() {
  # Source only the function definitions we need, not the global execution code.
  SCRIPT_NAME="phase2-execute.sh"

  # Stub out die/log/info so they don't cause side effects
  die()  { printf 'HALT: %s\n' "$*" >&2; return 1; }
  log()  { :; }
  info() { :; }

  # Extract function definitions by matching "name() {" at column 0.
  # Uses a brace-depth counter to handle nested braces correctly.
  eval "$(awk '
    /^(extract_frontmatter|fm_value|fm_nested_value|fm_array|json_array_field|sha256_of|normalize_path)\(\)/ {
      printing = 1
      depth = 0
    }
    printing {
      print
      # Count opening and closing braces (simple approximation)
      n = gsub(/{/, "{")
      c = gsub(/}/, "}")
      depth += n - c
      if (depth <= 0 && n + c > 0) { printing = 0 }
    }
  ' "$PHASE2_SH")"
}

# ---------------------------------------------------------------------------
# extract_frontmatter
# ---------------------------------------------------------------------------

@test "extract_frontmatter: extracts YAML between --- delimiters" {
  _load_phase2_functions
  local f="$TEST_TMP/plan.md"
  cat > "$f" <<'EOF'
---
key: value
nested:
  child: data
---

# Body text
EOF
  result="$(extract_frontmatter "$f")"
  [[ "$result" == *"key: value"* ]]
  [[ "$result" == *"child: data"* ]]
  [[ "$result" != *"Body text"* ]]
}

@test "extract_frontmatter: returns empty on missing frontmatter" {
  _load_phase2_functions
  local f="$TEST_TMP/nofront.md"
  printf '# Just a heading\n\nSome text.\n' > "$f"
  result="$(extract_frontmatter "$f")"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# fm_value
# ---------------------------------------------------------------------------

@test "fm_value: extracts simple unquoted value" {
  _load_phase2_functions
  local fm="plan_id: abc-123
phase: plan"
  result="$(fm_value "$fm" "plan_id")"
  [ "$result" = "abc-123" ]
}

@test "fm_value: extracts quoted value" {
  _load_phase2_functions
  local fm='plan_id: "uuid-456"
phase: "approved"'
  result="$(fm_value "$fm" "phase")"
  [ "$result" = "approved" ]
}

@test "fm_value: returns empty for missing key" {
  _load_phase2_functions
  local fm="plan_id: abc"
  result="$(fm_value "$fm" "nonexistent")"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# fm_nested_value
# ---------------------------------------------------------------------------

@test "fm_nested_value: extracts nested child value" {
  _load_phase2_functions
  local fm="approval:
  verdict: PASSED
  verdict_plan_id: plan-123"
  result="$(fm_nested_value "$fm" "approval" "verdict")"
  [ "$result" = "PASSED" ]
}

@test "fm_nested_value: extracts second child" {
  _load_phase2_functions
  local fm="approval:
  verdict: PASSED
  verdict_plan_id: plan-123"
  result="$(fm_nested_value "$fm" "approval" "verdict_plan_id")"
  [ "$result" = "plan-123" ]
}

@test "fm_nested_value: returns empty for wrong parent" {
  _load_phase2_functions
  local fm="approval:
  verdict: PASSED"
  result="$(fm_nested_value "$fm" "wrong_parent" "verdict")"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# fm_array
# ---------------------------------------------------------------------------

@test "fm_array: extracts inline JSON array" {
  _load_phase2_functions
  local fm='analyzed_sources: [{"path":"a.sh","sha256":"abc123"}]'
  result="$(fm_array "$fm" "analyzed_sources")"
  [[ "$result" == *'"path"'* ]]
  [[ "$result" == *'"sha256"'* ]]
}

@test "fm_array: returns empty for missing key" {
  _load_phase2_functions
  local fm="other_key: value"
  result="$(fm_array "$fm" "analyzed_sources")"
  [ -z "$result" ]
}

@test "fm_array: handles empty inline array" {
  _load_phase2_functions
  local fm='analyzed_sources: []'
  result="$(fm_array "$fm" "analyzed_sources")"
  [ "$result" = "[]" ]
}

# ---------------------------------------------------------------------------
# json_array_field
# ---------------------------------------------------------------------------

@test "json_array_field: extracts path field from JSON array" {
  _load_phase2_functions
  local json='[{"path":"/src/a.sh","sha256":"abc"},{"path":"/src/b.sh","sha256":"def"}]'
  result="$(json_array_field "$json" "path")"
  [[ "$result" == *"/src/a.sh"* ]]
  [[ "$result" == *"/src/b.sh"* ]]
}

@test "json_array_field: returns empty for missing field" {
  _load_phase2_functions
  local json='[{"path":"/a.sh"}]'
  result="$(json_array_field "$json" "nonexistent")"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# sha256_of
# ---------------------------------------------------------------------------

@test "sha256_of: returns correct hex digest" {
  _load_phase2_functions
  local f="$TEST_TMP/sha-test.txt"
  printf 'hello\n' > "$f"
  result="$(sha256_of "$f")"
  # Verify it is a 64-char hex string
  [ "${#result}" -eq 64 ]
  [[ "$result" =~ ^[a-f0-9]+$ ]]
}

@test "sha256_of: same content produces same hash" {
  _load_phase2_functions
  local f1="$TEST_TMP/sha1.txt"
  local f2="$TEST_TMP/sha2.txt"
  printf 'identical content\n' > "$f1"
  printf 'identical content\n' > "$f2"
  h1="$(sha256_of "$f1")"
  h2="$(sha256_of "$f2")"
  [ "$h1" = "$h2" ]
}

@test "sha256_of: different content produces different hash" {
  _load_phase2_functions
  local f1="$TEST_TMP/sha-a.txt"
  local f2="$TEST_TMP/sha-b.txt"
  printf 'content A\n' > "$f1"
  printf 'content B\n' > "$f2"
  h1="$(sha256_of "$f1")"
  h2="$(sha256_of "$f2")"
  [ "$h1" != "$h2" ]
}

# ---------------------------------------------------------------------------
# normalize_path
# ---------------------------------------------------------------------------

@test "normalize_path: resolves parent directory traversal" {
  _load_phase2_functions
  result="$(normalize_path "/a/b/c/../d")"
  [ "$result" = "/a/b/d" ]
}

@test "normalize_path: resolves multiple parent traversals" {
  _load_phase2_functions
  result="$(normalize_path "/a/b/c/../../d")"
  [ "$result" = "/a/d" ]
}

@test "normalize_path: removes dot segments" {
  _load_phase2_functions
  result="$(normalize_path "/a/./b/./c")"
  [ "$result" = "/a/b/c" ]
}

@test "normalize_path: handles deep traversal" {
  _load_phase2_functions
  result="$(normalize_path "/a/b/c/../../../etc/passwd")"
  [ "$result" = "/etc/passwd" ]
}

@test "normalize_path: handles root-level traversal" {
  _load_phase2_functions
  result="$(normalize_path "/a/../../../etc/passwd")"
  [ "$result" = "/etc/passwd" ]
}

@test "normalize_path: preserves clean absolute path" {
  _load_phase2_functions
  result="$(normalize_path "/usr/local/bin/tool")"
  [ "$result" = "/usr/local/bin/tool" ]
}
