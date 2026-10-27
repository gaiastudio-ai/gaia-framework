#!/usr/bin/env bats
# review-gate-commit-bound.bats — tests for commit-bound review gate
#
# Covers:
#   AC1 — dual-shape parser (3-col and 4-col Review Gate tables)
#   AC2 — bind-head check (stale rows -> PENDING, all-bound -> COMPLETE)
#   AC3 — non-destructive init (preserve existing verdicts, seed only missing)
#   AC4 — SHA binding on update (default HEAD, "none" outside git)
#   AC5 — carry-forward (self-computed evidence, refuse caller evidence)

load 'test_helper.bash'

setup() {
  common_setup
  export PROJECT_PATH="${TEST_TMP}/project"
  mkdir -p "$PROJECT_PATH"
  export PLUGIN_ROOT
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # Disable proof-of-execution for fixture-level tests
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1: Dual-shape parser reads both table formats
# ---------------------------------------------------------------------------

@test "dual-shape parser exists as sourceable library" {
  local parser="${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  [ -f "$parser" ]
}

@test "dual-shape parser reads three-column row correctly (SHA absent)" {
  local parser="${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  [ -f "$parser" ]

  # shellcheck source=/dev/null
  source "$parser"

  local three_col_row="| Code Review | PASSED | report.md |"
  local result
  result="$(parse_review_gate_row "$three_col_row")"

  grep -q 'status=PASSED' <<< "$result"
  grep -q 'report=report.md' <<< "$result"
  # Three-column row: SHA absent (empty or "absent")
  grep -qE '(reviewed_sha=|sha=)$' <<< "$result" \
    || grep -q 'reviewed_sha=absent' <<< "$result"
}

@test "dual-shape parser reads four-column row correctly (SHA present)" {
  local parser="${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  [ -f "$parser" ]

  # shellcheck source=/dev/null
  source "$parser"

  local four_col_row="| Code Review | PASSED | report.md | abc1234 |"
  local result
  result="$(parse_review_gate_row "$four_col_row")"

  grep -q 'status=PASSED' <<< "$result"
  grep -q 'report=report.md' <<< "$result"
  grep -qE '(reviewed_sha|sha)=abc1234' <<< "$result"
}

@test "dual-shape parser rejects malformed row (too few columns)" {
  local parser="${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  [ -f "$parser" ]

  # shellcheck source=/dev/null
  source "$parser"

  local bad_row="| Code Review | PASSED |"
  run parse_review_gate_row "$bad_row"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC2: Bind-head check — stale rows PENDING, all-bound-on-head COMPLETE
# ---------------------------------------------------------------------------

@test "review-gate-check exists as executable" {
  local checker="${PLUGIN_ROOT}/scripts/review-gate-check"
  [ -x "$checker" ]
}

@test "bind-head check: stale row produces non-COMPLETE verdict" {
  local checker="${PLUGIN_ROOT}/scripts/review-gate-check"
  [ -x "$checker" ]

  local story="${PROJECT_PATH}/docs/implementation-artifacts/E900-S1-test-story/story.md"
  mkdir -p "$(dirname "$story")"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S1"
title: "Test Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | OLD_SHA |
| QA Tests | PASSED | qa.md | HEAD_SHA |
| Security Review | PASSED | sec.md | HEAD_SHA |
| Test Automation | PASSED | ta.md | HEAD_SHA |
| Test Review | PASSED | tr.md | HEAD_SHA |
| Performance Review | PASSED | perf.md | HEAD_SHA |

> Story moves to `done` only when ALL reviews show PASSED.
STORY

  run "$checker" --bind-head HEAD_SHA --ci-sha HEAD_SHA --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'pending\|stale\|not.*complete' <<< "$output"
}

@test "bind-head check: all rows current returns COMPLETE" {
  local checker="${PLUGIN_ROOT}/scripts/review-gate-check"
  [ -x "$checker" ]

  local story="${PROJECT_PATH}/docs/implementation-artifacts/E900-S2-test-story/story.md"
  mkdir -p "$(dirname "$story")"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S2"
title: "Test Story 2"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | HEAD_SHA |
| QA Tests | PASSED | qa.md | HEAD_SHA |
| Security Review | PASSED | sec.md | HEAD_SHA |
| Test Automation | PASSED | ta.md | HEAD_SHA |
| Test Review | PASSED | tr.md | HEAD_SHA |
| Performance Review | PASSED | perf.md | HEAD_SHA |

> Story moves to `done` only when ALL reviews show PASSED.
STORY

  run "$checker" --bind-head HEAD_SHA --ci-sha HEAD_SHA --story "$story"
  [ "$status" -eq 0 ]
  grep -qi 'complete' <<< "$output"
}

# ---------------------------------------------------------------------------
# AC3: Non-destructive init preserves existing verdicts
# ---------------------------------------------------------------------------

@test "init-review-gate preserves existing verdicts and seeds missing rows" {
  local init_script="${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh"
  [ -f "$init_script" ]

  local story="${PROJECT_PATH}/docs/implementation-artifacts/E900-S3-test-story/story.md"
  mkdir -p "$(dirname "$story")"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S3"
title: "Test Story 3"
status: in-progress
---
## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | cr-report.md |
| QA Tests | FAILED | qa-report.md |

> Story moves to `done` only when ALL reviews show PASSED.

## Estimate
STORY

  run bash "$init_script" "$story"
  [ "$status" -eq 0 ]

  # Existing PASSED verdict on Code Review preserved
  grep '| Code Review | PASSED | cr-report.md |' "$story"

  # Existing FAILED verdict on QA Tests preserved
  grep '| QA Tests | FAILED | qa-report.md |' "$story"

  # Missing rows seeded with UNVERIFIED
  grep '| Security Review | UNVERIFIED |' "$story"
  grep '| Test Automation | UNVERIFIED |' "$story"
  grep '| Test Review | UNVERIFIED |' "$story"
  grep '| Performance Review | UNVERIFIED |' "$story"

  # Total row count exactly 6
  local row_count
  row_count=$(grep -c '^| .* | .* |' "$story" | head -1)
  # Must have at least 6 data rows (excluding header and separator)
  [ "$row_count" -ge 6 ]
}

@test "init-review-gate is idempotent (second run produces no changes)" {
  local init_script="${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh"
  [ -f "$init_script" ]

  local story="${PROJECT_PATH}/docs/implementation-artifacts/E900-S4-test-story/story.md"
  mkdir -p "$(dirname "$story")"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S4"
title: "Test Story 4"
status: in-progress
---
## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

> Story moves to `done` only when ALL reviews show PASSED.

## Estimate
STORY

  run bash "$init_script" "$story"
  [ "$status" -eq 0 ]
  local after_first
  after_first="$(cat "$story")"

  run bash "$init_script" "$story"
  [ "$status" -eq 0 ]
  local after_second
  after_second="$(cat "$story")"

  [ "$after_first" = "$after_second" ]
}

# ---------------------------------------------------------------------------
# AC4: Update binds worktree HEAD by default
# ---------------------------------------------------------------------------

@test "update without --sha binds worktree HEAD automatically" {
  local gate="${PLUGIN_ROOT}/scripts/review-gate.sh"
  [ -f "$gate" ]

  # Initialize a git repo so rev-parse HEAD works
  git -C "$PROJECT_PATH" init -q
  git -C "$PROJECT_PATH" config user.email "test@test.local"
  git -C "$PROJECT_PATH" config user.name "Test"
  printf 'init\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add README.md
  git -C "$PROJECT_PATH" commit -q -m "init"
  local expected_sha
  expected_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="${PROJECT_PATH}/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="${impl}/E900-S5-test-story.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S5"
title: "Test Story 5"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — |  |
| QA Tests | UNVERIFIED | — |  |
| Security Review | UNVERIFIED | — |  |
| Test Automation | UNVERIFIED | — |  |
| Test Review | UNVERIFIED | — |  |
| Performance Review | UNVERIFIED | — |  |

> Story moves to `done` only when ALL reviews show PASSED.
STORY

  git -C "$PROJECT_PATH" add .
  git -C "$PROJECT_PATH" commit -q -m "add story"
  expected_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  run bash "$gate" update \
    --story E900-S5 \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]

  # The fourth column must contain the current HEAD SHA
  grep "| Code Review | PASSED |" "$story" | grep "$expected_sha"
}

@test "update records none outside git work tree" {
  local non_git_dir="${TEST_TMP}/non-git"
  mkdir -p "$non_git_dir"
  export PROJECT_PATH="$non_git_dir"

  local impl="${non_git_dir}/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="${impl}/E900-S6-test-story.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S6"
title: "Test Story 6"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — |  |
| QA Tests | UNVERIFIED | — |  |
| Security Review | UNVERIFIED | — |  |
| Test Automation | UNVERIFIED | — |  |
| Test Review | UNVERIFIED | — |  |
| Performance Review | UNVERIFIED | — |  |

> Story moves to `done` only when ALL reviews show PASSED.
STORY

  local gate="${PLUGIN_ROOT}/scripts/review-gate.sh"
  run bash "$gate" update \
    --story E900-S6 \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]

  # SHA recorded as "none"
  grep '| Code Review | PASSED | .* | none |' "$story"
}

# ---------------------------------------------------------------------------
# AC5: Carry-forward self-computes evidence, refuses caller-supplied
# ---------------------------------------------------------------------------

@test "carry-forward verb is recognized" {
  local gate="${PLUGIN_ROOT}/scripts/review-gate.sh"
  [ -f "$gate" ]

  run bash "$gate" carry-forward --help 2>&1
  # Must not be "unknown subcommand"
  ! grep -qi 'unknown.*sub\|unrecognized' <<< "$output"
}

@test "carry-forward: no scope overlap allows carry" {
  local gate="${PLUGIN_ROOT}/scripts/review-gate.sh"
  [ -f "$gate" ]

  # Initialize git with two commits
  git -C "$PROJECT_PATH" init -q
  git -C "$PROJECT_PATH" config user.email "test@test.local"
  git -C "$PROJECT_PATH" config user.name "Test"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  printf 'v1\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add .
  git -C "$PROJECT_PATH" commit -q -m "commit A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Second commit changes only an unrelated file
  printf 'v2\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add .
  git -C "$PROJECT_PATH" commit -q -m "commit B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="${PROJECT_PATH}/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="${impl}/E900-S7-test-story.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "E900-S7"
title: "Test Story 7"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | ${sha_a} |
| QA Tests | PASSED | qa.md | ${sha_b} |
| Security Review | PASSED | sec.md | ${sha_b} |
| Test Automation | PASSED | ta.md | ${sha_b} |
| Test Review | PASSED | tr.md | ${sha_b} |
| Performance Review | PASSED | perf.md | ${sha_b} |

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY

  git -C "$PROJECT_PATH" add .
  git -C "$PROJECT_PATH" commit -q -m "add story"

  # Carry forward Code Review from A to B — diff has no src/ files
  run bash "$gate" carry-forward \
    --story E900-S7 \
    --row "Code Review" \
    --from "$sha_a" \
    --to "$sha_b" \
    --scope "src/**"
  [ "$status" -eq 0 ]

  # The row should now reference sha_b
  grep "$sha_b" "$story" | grep "Code Review"
}

@test "carry-forward refuses caller-supplied evidence" {
  local gate="${PLUGIN_ROOT}/scripts/review-gate.sh"
  [ -f "$gate" ]

  git -C "$PROJECT_PATH" init -q
  git -C "$PROJECT_PATH" config user.email "test@test.local"
  git -C "$PROJECT_PATH" config user.name "Test"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  git -C "$PROJECT_PATH" add .
  git -C "$PROJECT_PATH" commit -q -m "commit A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  printf 'v2\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add .
  git -C "$PROJECT_PATH" commit -q -m "commit B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="${PROJECT_PATH}/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="${impl}/E900-S8-test-story.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "E900-S8"
title: "Test Story 8"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | ${sha_a} |
| QA Tests | UNVERIFIED | — |  |
| Security Review | UNVERIFIED | — |  |
| Test Automation | UNVERIFIED | — |  |
| Test Review | UNVERIFIED | — |  |
| Performance Review | UNVERIFIED | — |  |

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY

  git -C "$PROJECT_PATH" add .
  git -C "$PROJECT_PATH" commit -q -m "add story"

  # Attempt carry-forward with caller-supplied evidence
  run bash "$gate" carry-forward \
    --story E900-S8 \
    --row "Code Review" \
    --from "$sha_a" \
    --to "$sha_b" \
    --evidence "fabricated-evidence"
  [ "$status" -ne 0 ]
  grep -qi 'refuse\|reject\|not.*accept\|caller.*evidence.*denied' <<< "$output"
}
