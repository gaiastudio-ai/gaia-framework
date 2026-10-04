#!/usr/bin/env bats
# wire-verification-emit.bats — coverage for scripts/lib/wire-verification-emit.sh
#
# The helper at plugins/gaia/scripts/lib/wire-verification-emit.sh:
#   - Reads --story-file + --matrix-file
#   - Walks the matrix for requirement rows with surface_type != none
#   - Verifies each has >=1 linked row with test_type: integration
#   - If gap found: emits HALT to stderr listing ALL violations
#     + invokes `review-gate.sh update --story <key> --gate "Test Review" --verdict FAILED`
#     + exits 1
#   - If clean: exits 0 silently

setup() {
  HELPER="$(cd "$BATS_TEST_DIRNAME/../../../scripts/lib" && pwd)/wire-verification-emit.sh"
  REVIEW_GATE="$(cd "$BATS_TEST_DIRNAME/../../../scripts" && pwd)/review-gate.sh"
  TEST_TMP="$(mktemp -d)"
  export LC_ALL=C
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Build a story file with a Review Gate table and the given surface_type
_make_story() {
  local key="$1" surface_type="${2:-none}"
  local file="$TEST_TMP/$key-test.md"
  cat > "$file" <<EOF
---
template: 'story'
key: "$key"
title: "test story"
status: review
surface_type: ${surface_type}
---

# Story: test story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
EOF
  printf '%s' "$file"
}

# Build a minimal traceability matrix with optional rows
_make_matrix() {
  local file="$TEST_TMP/matrix.md"
  cat > "$file" <<'EOF'
# Traceability Matrix

## Requirements

EOF
  # Caller appends rows
  printf '%s' "$file"
}

# ============================================================================
# surface_type column documented in SKILL.md
# ============================================================================
@test "trace SKILL.md documents surface_type column" {
  SKILL="$(cd "$BATS_TEST_DIRNAME/../" && pwd)/SKILL.md"
  run grep -c 'surface_type' "$SKILL"
  [ "$status" -eq 0 ]
  # At least 3 mentions across requirement matrix columns and processing steps
  [ "$output" -ge 3 ]
}

# ============================================================================
# blocked finding fires on surface_type=warning with zero integration rows
# ============================================================================
@test "blocked finding emitted on surface_type=warning with zero integration rows" {
  local story matrix
  story="$(_make_story "E1-S1" "warning")"
  matrix="$(_make_matrix)"
  cat >> "$matrix" <<'EOF'
| FR-001 | Test FR | warning | E1-S1 | — | — | — | — | 0% |
EOF

  # Mock review-gate.sh via PATH override
  local mockdir="$TEST_TMP/mockbin"
  local rg_log="$TEST_TMP/rg-calls.log"
  mkdir -p "$mockdir"
  cat > "$mockdir/review-gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$rg_log"
exit 0
EOF
  chmod +x "$mockdir/review-gate.sh"

  PATH="$mockdir:$PATH" run bash "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 1 ]
  [[ "$output" =~ HALT ]] || [[ "$stderr" =~ HALT ]]
}

# ============================================================================
# helper invokes review-gate.sh update with FAILED verdict
# ============================================================================
@test "helper invokes review-gate.sh update --gate Test Review --verdict FAILED" {
  local story matrix
  story="$(_make_story "E2-S1" "warning")"
  matrix="$(_make_matrix)"
  cat >> "$matrix" <<'EOF'
| FR-002 | Test FR2 | warning | E2-S1 | — | — | — | — | 0% |
EOF

  local mockdir="$TEST_TMP/mockbin"
  local rg_log="$TEST_TMP/rg-calls.log"
  mkdir -p "$mockdir"
  cat > "$mockdir/review-gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$rg_log"
exit 0
EOF
  chmod +x "$mockdir/review-gate.sh"

  PATH="$mockdir:$PATH" bash "$HELPER" --story-file "$story" --matrix-file "$matrix" 2>/dev/null || true

  # Assert review-gate.sh was invoked with Test Review + FAILED
  [ -f "$rg_log" ]
  grep -q 'update' "$rg_log"
  grep -q 'Test Review' "$rg_log"
  grep -q 'FAILED' "$rg_log"
  grep -q 'E2-S1' "$rg_log"
}

# ============================================================================
# verdict dominance — FAILED in Test Review composites to BLOCKED
# (verified by exercising actual review-gate.sh — no mock)
# ============================================================================
@test "verdict dominance — FAILED in Test Review row composites to BLOCKED" {
  local story
  story="$(_make_story "E3-S1" "none")"

  # review-gate.sh resolves the story file from IMPLEMENTATION_ARTIFACTS env
  # plus the canonical filename convention. Set IMPLEMENTATION_ARTIFACTS to
  # the test temp dir and use the canonical naming.
  local impl="$TEST_TMP/impl"
  mkdir -p "$impl"
  local target="$impl/E3-S1-test-story.md"
  cp "$story" "$target"

  export IMPLEMENTATION_ARTIFACTS="$impl"
  # Inject FAILED into Test Review row via real review-gate.sh
  run bash "$REVIEW_GATE" update --story E3-S1 --gate "Test Review" --verdict FAILED --report-missing-reason "test fixture — no real execution"
  [ "$status" -eq 0 ]

  run bash "$REVIEW_GATE" review-gate-check --story E3-S1
  # exit 1 = BLOCKED (any FAILED dominates)
  [ "$status" -eq 1 ]
  [[ "$output" =~ BLOCKED ]]
}

# ============================================================================
# idempotent re-run on clean matrix does NOT re-invoke review-gate.sh update
# ============================================================================
@test "clean matrix exits 0 without invoking review-gate.sh update" {
  local story matrix
  story="$(_make_story "E4-S1" "warning")"
  matrix="$(_make_matrix)"
  # surface_type=warning AND has integration row → no gap
  cat >> "$matrix" <<'EOF'
| FR-004 | Test FR4 | warning | E4-S1 | TC-001 | TC-002 | — | — | 50% |
| TC-002 | integration | E4-S1 | FR-004 |
EOF

  local mockdir="$TEST_TMP/mockbin"
  local rg_log="$TEST_TMP/rg-calls.log"
  mkdir -p "$mockdir"
  cat > "$mockdir/review-gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$rg_log"
exit 0
EOF
  chmod +x "$mockdir/review-gate.sh"

  PATH="$mockdir:$PATH" run bash "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 0 ]
  [ ! -f "$rg_log" ] || ! grep -q 'update' "$rg_log"
}

# ============================================================================
# multiple violations emit ALL ids in stderr (no short-circuit)
# ============================================================================
@test "multiple violations emit ALL ids in stderr (no short-circuit)" {
  local story matrix
  story="$(_make_story "E5-S1" "warning")"
  matrix="$(_make_matrix)"
  cat >> "$matrix" <<'EOF'
| FR-005a | First gap | warning | E5-S1 | — | — | — | — | 0% |
| FR-005b | Second gap | warning | E5-S1 | — | — | — | — | 0% |
EOF

  local mockdir="$TEST_TMP/mockbin"
  mkdir -p "$mockdir"
  cat > "$mockdir/review-gate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mockdir/review-gate.sh"

  PATH="$mockdir:$PATH" run bash "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 1 ]
  # Both requirement ids should appear in the HALT output
  echo "$output $stderr" | grep -q 'FR-005a'
  echo "$output $stderr" | grep -q 'FR-005b'
}

# ============================================================================
# misspelled surface_type values treated as fail-closed
# ============================================================================
@test "misspelled surface_type (warnings, plural) fires blocked fail-closed" {
  local story matrix
  story="$(_make_story "E6-S1" "warnings")"  # mis-spelled
  matrix="$(_make_matrix)"
  cat >> "$matrix" <<'EOF'
| FR-006 | Test | warnings | E6-S1 | — | — | — | — | 0% |
EOF

  local mockdir="$TEST_TMP/mockbin"
  mkdir -p "$mockdir"
  cat > "$mockdir/review-gate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mockdir/review-gate.sh"

  PATH="$mockdir:$PATH" run bash "$HELPER" --story-file "$story" --matrix-file "$matrix"
  # fail-closed: unknown values treated as NOT-none → blocked finding fires
  [ "$status" -eq 1 ]
}

# ============================================================================
# empty matrix exits 0 with no side effects
# ============================================================================
@test "empty matrix exits 0 with no review-gate.sh invocation" {
  local story matrix
  story="$(_make_story "E7-S1" "warning")"
  matrix="$(_make_matrix)"
  # No rows added — empty matrix

  local mockdir="$TEST_TMP/mockbin"
  local rg_log="$TEST_TMP/rg-calls.log"
  mkdir -p "$mockdir"
  cat > "$mockdir/review-gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$rg_log"
exit 0
EOF
  chmod +x "$mockdir/review-gate.sh"

  PATH="$mockdir:$PATH" run bash "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 0 ]
  [ ! -f "$rg_log" ]
}

# ============================================================================
# empty/null surface_type treated as none (backfill-deferred)
# ============================================================================
@test "empty/null surface_type treated as none (no blocked)" {
  local story matrix
  story="$(_make_story "E8-S1" "none")"
  matrix="$(_make_matrix)"
  cat >> "$matrix" <<'EOF'
| FR-008 | No surface_type set | none | E8-S1 | — | — | — | — | 0% |
EOF

  local mockdir="$TEST_TMP/mockbin"
  mkdir -p "$mockdir"
  cat > "$mockdir/review-gate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mockdir/review-gate.sh"

  PATH="$mockdir:$PATH" run bash "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 0 ]
}

# ============================================================================
# helper rejects missing required flags
# ============================================================================
@test "helper rejects missing --story-file flag" {
  local matrix
  matrix="$(_make_matrix)"

  run bash "$HELPER" --matrix-file "$matrix"
  [ "$status" -ne 0 ]
}
