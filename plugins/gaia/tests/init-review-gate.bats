#!/usr/bin/env bats
# init-review-gate.bats — coverage for
# skills/gaia-dev-story/scripts/init-review-gate.sh
#
# Story: E55-S8 — Auto-reviews YOLO-only + helper scripts + bats coverage
#
# Coverage matrix:
#   - fresh insert: story file with no `## Review Gate` block -> append the
#                   canonical 6-row block
#   - replace existing: file already contains a Review Gate (with mutated
#                       rows) -> replaced with the canonical UNVERIFIED block
#   - idempotent: running twice yields the same final file (byte-identical)
#   - exact 6 rows: parsed table contains exactly 6 review rows
#
# Tests use a synthetic story file in TEST_TMP — never touches the real
# implementation-artifacts directory.

load 'test_helper.bash'

setup() {
  common_setup
  INIT_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/init-review-gate.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts
  STORY_KEY="E99-S1"
  STORY_FILE="docs/implementation-artifacts/${STORY_KEY}-test-story.md"
  export STORY_FILE STORY_KEY
}

teardown() { common_teardown; }

_seed_story_no_gate() {
  cat > "$STORY_FILE" <<'EOF'
---
key: "E99-S1"
title: "Test Story"
status: in-progress
---

# Story: Test Story

## Acceptance Criteria

- [ ] AC1

## Estimate

- **Points:** 1

## Definition of Done

- [ ] All ACs verified
EOF
}

_seed_story_with_gate() {
  cat > "$STORY_FILE" <<'EOF'
---
key: "E99-S1"
title: "Test Story"
status: in-progress
---

# Story: Test Story

## Acceptance Criteria

- [ ] AC1

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | foo |
| Bogus Row | UNVERIFIED | — |

> Story moves to `done` only when ALL reviews show PASSED.

## Estimate

- **Points:** 1
EOF
}

_count_review_rows() {
  # Count table rows under `## Review Gate`. Row = a line starting with `|`
  # that is neither the header (`| Review`) nor the separator (`|---`).
  awk '
    /^## Review Gate/ { in_block = 1; next }
    in_block && /^## / { in_block = 0; next }
    in_block && /^\|/ {
      if ($0 ~ /^\| *Review *\|/) next
      if ($0 ~ /^\|[- ]+\|/) next
      print
    }
  ' "$1" | wc -l | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Fresh insert
# ---------------------------------------------------------------------------

@test "init-review-gate: fresh insert appends canonical block with 6 rows" {
  _seed_story_no_gate
  run "$INIT_SCRIPT" "$STORY_FILE"
  [ "$status" -eq 0 ]
  # Block exists.
  grep -q '^## Review Gate' "$STORY_FILE"
  # All 6 canonical reviews present.
  for r in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    grep -Fq "| $r |" "$STORY_FILE" || {
      echo "missing canonical row: $r" >&2
      cat "$STORY_FILE" >&2
      return 1
    }
  done
  [ "$(_count_review_rows "$STORY_FILE")" = "6" ]
}

# ---------------------------------------------------------------------------
# Replace existing block
# ---------------------------------------------------------------------------

@test "init-review-gate: preserves existing verdicts and seeds only missing rows" {
  _seed_story_with_gate
  run "$INIT_SCRIPT" "$STORY_FILE"
  [ "$status" -eq 0 ]
  # Existing PASSED verdict on Code Review preserved (non-destructive).
  grep -Fq "| Code Review | PASSED | foo |" "$STORY_FILE"
  # Bogus non-canonical row preserved (init does not remove rows).
  grep -Fq "Bogus Row" "$STORY_FILE"
  # Missing canonical rows seeded with UNVERIFIED.
  grep -Fq "| QA Tests | UNVERIFIED |" "$STORY_FILE"
  grep -Fq "| Security Review | UNVERIFIED |" "$STORY_FILE"
  grep -Fq "| Test Automation | UNVERIFIED |" "$STORY_FILE"
  grep -Fq "| Test Review | UNVERIFIED |" "$STORY_FILE"
  grep -Fq "| Performance Review | UNVERIFIED |" "$STORY_FILE"
  # All 6 canonical rows present (plus the bogus row = 7 total).
  [ "$(_count_review_rows "$STORY_FILE")" = "7" ]
  # Exactly one Review Gate block.
  [ "$(grep -c '^## Review Gate' "$STORY_FILE")" = "1" ]
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "init-review-gate: idempotent — second run leaves file byte-identical" {
  _seed_story_no_gate
  run "$INIT_SCRIPT" "$STORY_FILE"
  [ "$status" -eq 0 ]
  cp "$STORY_FILE" "$TEST_TMP/after-first.md"
  run "$INIT_SCRIPT" "$STORY_FILE"
  [ "$status" -eq 0 ]
  diff -u "$TEST_TMP/after-first.md" "$STORY_FILE"
}

# ---------------------------------------------------------------------------
# Surrounding sections preserved
# ---------------------------------------------------------------------------

@test "init-review-gate: preserves surrounding sections (Estimate, DoD)" {
  _seed_story_no_gate
  run "$INIT_SCRIPT" "$STORY_FILE"
  [ "$status" -eq 0 ]
  grep -Fq "## Estimate" "$STORY_FILE"
  grep -Fq "## Definition of Done" "$STORY_FILE"
}
