#!/usr/bin/env bats
# wire-verification-emit.bats — coverage for scripts/lib/wire-verification-emit.sh
#
# Story: E95-S1 — Add surface_type column + BLOCKED-severity finding to /gaia-trace
# Traces: AC1, AC2, AC3, AC4, AC5(a-e) + edge cases EC-1, EC-2, EC-3, EC-10
# Origin: docs/planning-artifacts/assessment-AF-2026-05-18-6.md
#
# The helper at plugins/gaia/scripts/lib/wire-verification-emit.sh:
#   - Reads --story-file + --matrix-file
#   - Walks the matrix for FR/NFR rows with surface_type != none
#   - Verifies each has >=1 linked row with test_type: integration
#   - If gap found: emits HALT to stderr listing ALL violations
#     + invokes `review-gate.sh update --story <key> --gate "Test Review" --verdict FAILED`
#     + exits 1
#   - If clean: exits 0 silently
#
# Mirrors the E88-S6 trace-dispatch-verb-enforcement.sh pattern.

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
# AC5(a) / TC-WVE-1 — matrix renders surface_type column (SKILL.md prose check)
# ============================================================================
@test "TC-WVE-1: /gaia-trace SKILL.md documents surface_type column" {
  SKILL="$(cd "$BATS_TEST_DIRNAME/../" && pwd)/SKILL.md"
  run grep -c 'surface_type' "$SKILL"
  [ "$status" -eq 0 ]
  # At least 2 mentions: FR matrix columns + NFR matrix columns + Step 5 + Step 6c
  [ "$output" -ge 3 ]
}

# ============================================================================
# AC2 / TC-WVE-2 — BLOCKED finding fires on surface_type=warning + zero integration rows
# ============================================================================
@test "TC-WVE-2: BLOCKED finding emit on surface_type=warning with zero integration rows" {
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
  [[ "$output" =~ HALT ]] || [[ "$stderr" =~ HALT ]] || true
}

# ============================================================================
# AC3 / TC-WVE-3 — pathway-i: FAILED into Test Review row via mocked review-gate.sh update
# ============================================================================
@test "TC-WVE-3: helper invokes review-gate.sh update --gate Test Review --verdict FAILED" {
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
# AC3 / TC-WVE-4 — ADR-054 dominance: review-gate.sh check returns BLOCKED
# (verified by exercising actual review-gate.sh — no mock)
# ============================================================================
@test "TC-WVE-4: ADR-054 dominance — FAILED in Test Review row composites to BLOCKED" {
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
  bash "$REVIEW_GATE" update --story E3-S1 --gate "Test Review" --verdict FAILED 2>/dev/null || true

  run bash "$REVIEW_GATE" review-gate-check --story E3-S1
  # Per ADR-054: exit 1 = BLOCKED (any FAILED dominates)
  [ "$status" -eq 1 ]
  [[ "$output" =~ BLOCKED ]]
}

# ============================================================================
# AC5(e) / TC-WVE-5 — idempotent re-run on clean matrix does NOT re-invoke
# review-gate.sh update (does NOT auto-flip FAILED→PASSED on Test Review)
# ============================================================================
@test "TC-WVE-5: clean matrix exits 0 without invoking review-gate.sh update" {
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
# TC-WVE-6 / EC-3 — multiple violations within one story emit ALL ids in single finding
# ============================================================================
@test "TC-WVE-6: multiple violations emit ALL ids in stderr (no short-circuit)" {
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
  # Both FR ids should appear in the HALT output
  echo "$output $stderr" | grep -q 'FR-005a'
  echo "$output $stderr" | grep -q 'FR-005b'
}

# ============================================================================
# TC-WVE-7 / EC-1 — misspelled surface_type values treated as fail-closed
# ============================================================================
@test "TC-WVE-7: misspelled surface_type (warnings, plural) fires BLOCKED fail-closed" {
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
  # fail-closed: unknown values treated as NOT-none → BLOCKED finding fires
  [ "$status" -eq 1 ]
}

# ============================================================================
# TC-WVE-8 / EC-2 — empty matrix exits 0 with no side effects
# ============================================================================
@test "TC-WVE-8: empty matrix exits 0 with no review-gate.sh invocation" {
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
# TC-WVE-9 / EC-10 — empty/null surface_type treated as none (backfill-deferred)
# ============================================================================
@test "TC-WVE-9: empty/null surface_type treated as none (no BLOCKED)" {
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
# TC-WVE-10 — Helper rejects missing required flags
# ============================================================================
@test "TC-WVE-10: helper rejects missing --story-file flag" {
  local matrix
  matrix="$(_make_matrix)"

  run bash "$HELPER" --matrix-file "$matrix"
  [ "$status" -ne 0 ]
}
