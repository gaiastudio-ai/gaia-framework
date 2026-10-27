#!/usr/bin/env bats
# review-gate-commit-bound.bats — tests for commit-bound review gate
#
# Covers all five ACs: dual-shape parser, bind-head check, non-destructive
# init, SHA binding on update, and carry-forward with self-computed evidence.

load 'test_helper.bash'

setup() {
  common_setup
  export PROJECT_PATH="${TEST_TMP}/project"
  mkdir -p "$PROJECT_PATH"
  export PLUGIN_ROOT
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
}

teardown() { common_teardown; }

# Helper: create a git repo with an initial commit.
_init_git() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "Test"
  printf 'init\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "init"
}

# Helper: create a flat story file with all 6 canonical rows (4-col).
_seed_story_4col() {
  local dir="$1" key="$2" sha="${3:-}"
  local impl="$dir/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/${key}-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "${key}"
title: "Test Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | ${sha} |
| QA Tests | PASSED | qa.md | ${sha} |
| Security Review | PASSED | sec.md | ${sha} |
| Test Automation | PASSED | ta.md | ${sha} |
| Test Review | PASSED | tr.md | ${sha} |
| Performance Review | PASSED | perf.md | ${sha} |

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY
  printf '%s' "$story"
}

# Helper: create a story with 3-column (legacy) table.
_seed_story_3col() {
  local dir="$1" key="$2"
  local impl="$dir/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/${key}-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "${key}"
title: "Test Story"
status: review
---
## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | cr.md |
| QA Tests | PASSED | qa.md |
| Security Review | PASSED | sec.md |
| Test Automation | PASSED | ta.md |
| Test Review | PASSED | tr.md |
| Performance Review | PASSED | perf.md |

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY
  printf '%s' "$story"
}

# Helper: write a project-config.yaml with scope_globs for a given gate.
# Usage: _write_scope_config <dir> <gate-slug> <glob> [<glob2> ...]
_write_scope_config() {
  local dir="$1" slug="$2"; shift 2
  mkdir -p "$dir/.gaia/config"
  local cfg="$dir/.gaia/config/project-config.yaml"
  cat > "$cfg" <<YAML
review_gate:
  scope_globs:
    ${slug}:
YAML
  local g
  for g in "$@"; do
    printf '      - "%s"\n' "$g" >> "$cfg"
  done
  export PROJECT_CONFIG="$cfg"
}

# ---------------------------------------------------------------------------
# AC1: Dual-shape parser
# ---------------------------------------------------------------------------

@test "dual-shape parser exists as sourceable library" {
  [ -f "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh" ]
}

@test "dual-shape parser reads three-column row with SHA exactly absent" {
  # shellcheck source=/dev/null
  source "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  local result
  result="$(parse_review_gate_row "| Code Review | PASSED | report.md |")"
  grep -q 'status=PASSED' <<< "$result"
  grep -q 'report=report.md' <<< "$result"
  grep -q 'reviewed_sha=absent' <<< "$result"
}

@test "dual-shape parser reads four-column row with SHA present" {
  # shellcheck source=/dev/null
  source "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  local result
  result="$(parse_review_gate_row "| Code Review | PASSED | report.md | abc1234 |")"
  grep -q 'status=PASSED' <<< "$result"
  grep -q 'report=report.md' <<< "$result"
  grep -q 'reviewed_sha=abc1234' <<< "$result"
}

@test "dual-shape parser rejects 2-column row explicitly" {
  # shellcheck source=/dev/null
  source "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  run parse_review_gate_row "| Code Review | PASSED |"
  [ "$status" -ne 0 ]
  grep -qi 'fewer than 3' <<< "$output"
}

@test "dual-shape parser rejects 5-column row explicitly" {
  # shellcheck source=/dev/null
  source "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  run parse_review_gate_row "| Code Review | PASSED | report.md | abc | extra |"
  [ "$status" -ne 0 ]
  grep -qi 'more than 4' <<< "$output"
}

# ---------------------------------------------------------------------------
# AC2: Bind-head check
# ---------------------------------------------------------------------------

@test "review-gate-check.sh exists as executable" {
  [ -x "${PLUGIN_ROOT}/scripts/review-gate-check.sh" ]
}

@test "bind-head: stale row produces PENDING (real git repo)" {
  _init_git "$PROJECT_PATH"
  local sha_old
  sha_old="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "v2"
  local sha_head
  sha_head="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S1" "$sha_old")"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_head" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'pending\|stale' <<< "$output"
}

@test "bind-head: all rows current returns COMPLETE (real git repo)" {
  _init_git "$PROJECT_PATH"
  local sha_head
  sha_head="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S2" "$sha_head")"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_head" --ci-sha none --story "$story"
  [ "$status" -eq 0 ]
  grep -qi 'complete' <<< "$output"
}

@test "bind-head: FAILED row produces BLOCKED" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S10" "$sha")"
  sed -i.bak "s/| Code Review | PASSED | cr.md | ${sha} |/| Code Review | FAILED | cr.md | ${sha} |/" "$story"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -eq 1 ]
  grep -qi 'blocked' <<< "$output"
}

@test "bind-head: UNVERIFIED row produces PENDING" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S11" "$sha")"
  sed -i.bak "s/| Code Review | PASSED | cr.md | ${sha} |/| Code Review | UNVERIFIED | — |  |/" "$story"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -eq 2 ]
  grep -qi 'pending' <<< "$output"
}

@test "bind-head: 3-col PASSED row reads PENDING (no SHA is stale)" {
  local story
  story="$(_seed_story_3col "$PROJECT_PATH" "E900-S12")"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "abcd1234" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'pending\|stale' <<< "$output"
}

@test "bind-head: CI SHA mismatch produces not COMPLETE" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S13" "$sha")"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha "0000000000000000000000000000000000000000" --story "$story"
  [ "$status" -ne 0 ]
}

@test "bind-head: --ci-sha none with CI configured is refused" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S14" "$sha")"
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain:
    - id: staging
      name: Staging
      branch: staging
YAML
  PROJECT_PATH="$PROJECT_PATH" PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml" \
    run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
      --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'not accepted\|ci.*configured\|promotion' <<< "$output"
}

@test "bind-head: missing canonical row produces error" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  # Create a story missing Performance Review row.
  local impl="$PROJECT_PATH/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S36-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "E900-S36"
title: "Test Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | ${sha} |
| QA Tests | PASSED | qa.md | ${sha} |
| Security Review | PASSED | sec.md | ${sha} |
| Test Automation | PASSED | ta.md | ${sha} |
| Test Review | PASSED | tr.md | ${sha} |

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'missing.*canonical\|Performance Review' <<< "$output"
}

@test "bind-head: --bind-head none is refused" {
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head none --ci-sha none --story /dev/null
  [ "$status" -ne 0 ]
  grep -qi 'not.*none\|must be.*sha' <<< "$output"
}

@test "bind-head: unknown verdict not treated as pass" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S15" "$sha")"
  sed -i.bak "s/| Code Review | PASSED | cr.md | ${sha} |/| Code Review | BOGUS | cr.md | ${sha} |/" "$story"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3: Non-destructive init
# ---------------------------------------------------------------------------

@test "init preserves existing verdicts and seeds only missing rows" {
  local init_script="${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh"
  [ -f "$init_script" ]
  local story="${PROJECT_PATH}/story.md"
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
  grep -F '| Code Review | PASSED | cr-report.md |' "$story"
  grep -F '| QA Tests | FAILED | qa-report.md |' "$story"
  grep -F '| Security Review | UNVERIFIED |' "$story"
  grep -F '| Test Automation | UNVERIFIED |' "$story"
  grep -F '| Test Review | UNVERIFIED |' "$story"
  grep -F '| Performance Review | UNVERIFIED |' "$story"
  # Count data rows (after the separator, before end of table).
  local row_count
  row_count="$(awk '
    /^## Review Gate/ { in_rg = 1; next }
    in_rg && /^## / { in_rg = 0 }
    in_rg && /^\|---/ { after_sep = 1; next }
    in_rg && after_sep && /^\| / { count++ }
    in_rg && after_sep && !/^\|/ { after_sep = 0 }
    END { print count + 0 }
  ' "$story")"
  [ "$row_count" -eq 6 ]
}

@test "init idempotent: seed then rerun produces no changes" {
  local init_script="${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh"
  local story="${PROJECT_PATH}/story-idem.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S4"
title: "Test Story 4"
status: in-progress
---
## Acceptance Criteria

- [ ] AC1

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

@test "init seeds 4-column header on fresh story" {
  local init_script="${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh"
  local story="${PROJECT_PATH}/story-4col.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S16"
title: "Test Story"
status: in-progress
---
## Estimate
STORY
  run bash "$init_script" "$story"
  [ "$status" -eq 0 ]
  grep -q '| Review | Status | Report | Reviewed SHA |' "$story"
}

# ---------------------------------------------------------------------------
# AC4: Update binds worktree HEAD
# ---------------------------------------------------------------------------

@test "update without --sha binds worktree HEAD automatically" {
  _init_git "$PROJECT_PATH"
  local impl="${PROJECT_PATH}/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="${impl}/E900-S5-test.md"
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
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "add story"
  local expected_sha
  expected_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story E900-S5 --gate "Code Review" --verdict PASSED \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  grep "Code Review" "$story" | grep -q "$expected_sha"
}

@test "update records none outside git work tree" {
  local non_git="${TEST_TMP}/non-git"
  mkdir -p "$non_git/docs/implementation-artifacts"
  export PROJECT_PATH="$non_git"
  local story="$non_git/docs/implementation-artifacts/E900-S6-test.md"
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
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story E900-S6 --gate "Code Review" --verdict PASSED \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  grep '| Code Review | PASSED |' "$story" | grep -q '| none |'
}

@test "update on 3-column table upgrades header to 4 columns" {
  _init_git "$PROJECT_PATH"
  local story
  story="$(_seed_story_3col "$PROJECT_PATH" "E900-S17")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story E900-S17 --gate "Code Review" --verdict PASSED \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  grep -q '| Review | Status | Report | Reviewed SHA |' "$story"
}

@test "update refuses --sha with pipe character" {
  _init_git "$PROJECT_PATH"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S18" "abc1234")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story E900-S18 --gate "Code Review" --verdict PASSED \
    --sha "abc|injected" --report-missing-reason "test"
  [ "$status" -ne 0 ]
  grep -qi 'pipe\|corrupt' <<< "$output"
}

@test "update refuses --sha with leading dash" {
  _init_git "$PROJECT_PATH"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S19" "abc1234")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story E900-S19 --gate "Code Review" --verdict PASSED \
    --sha "--output=/tmp/x" --report-missing-reason "test"
  [ "$status" -ne 0 ]
  [ ! -f /tmp/x ]
}

# ---------------------------------------------------------------------------
# AC5: Carry-forward
# ---------------------------------------------------------------------------

@test "carry-forward verb is wired (not just --help exit)" {
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward 2>&1
  [ "$status" -ne 0 ]
  grep -qi 'requires\|--row\|--from' <<< "$output"
  ! grep -qi 'unknown.*sub' <<< "$output"
}

@test "carry-forward refuses caller-supplied evidence" {
  _init_git "$PROJECT_PATH"
  local sha_a sha_b
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S8" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S8 --row "Code Review" --from "$sha_a" --to "$sha_b" \
    --evidence "fabricated"
  [ "$status" -ne 0 ]
  grep -qi 'refuse' <<< "$output"
}

@test "carry-forward refuses FAILED row" {
  _init_git "$PROJECT_PATH"
  local sha_a sha_b
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S20" "$sha_a")"
  sed -i.bak "s/| Code Review | PASSED | cr.md | ${sha_a} |/| Code Review | FAILED | cr.md | ${sha_a} |/" "$story"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "nonexistent/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S20 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'not PASSED' <<< "$output"
}

@test "carry-forward refuses UNVERIFIED row" {
  _init_git "$PROJECT_PATH"
  local sha_a sha_b
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S21" "$sha_a")"
  sed -i.bak "s/| Code Review | PASSED | cr.md | ${sha_a} |/| Code Review | UNVERIFIED | — |  |/" "$story"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "nonexistent/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S21 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'not PASSED' <<< "$output"
}

@test "carry-forward refuses mismatched --from SHA" {
  _init_git "$PROJECT_PATH"
  local sha_a sha_b
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S22" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "nonexistent/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S22 --row "Code Review" --from "$sha_b" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'mismatch' <<< "$output"
}

@test "carry-forward: no scope overlap succeeds and preserves report path" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  printf 'v1\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S7" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S7 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]
  grep "Code Review" "$story" | grep -q "$sha_b"
  grep "Code Review" "$story" | grep -q "cr.md"
}

@test "carry-forward: scope overlap is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/main.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S23" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S23 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'scope\|overlap\|re-run' <<< "$output"
}

@test "carry-forward: --from with argument injection refused, no file created" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S24" "$sha")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S24 --row "Code Review" \
    --from "--output=/tmp/x" --to "$sha"
  [ "$status" -ne 0 ]
  [ ! -f /tmp/x ]
}

@test "carry-forward: review-gate-check treats to-SHA as bound (COMPLETE)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  printf 'v1\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="$PROJECT_PATH/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S25-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "E900-S25"
title: "Test Story"
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
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S25 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_b" --ci-sha none --story "$story"
  [ "$status" -eq 0 ]
  grep -qi 'complete' <<< "$output"
}

@test "carry-forward: no configured scope refuses (fail closed)" {
  _init_git "$PROJECT_PATH"
  local sha_a sha_b
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S30" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  # No scope config at all — should refuse.

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S30 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'no scope globs configured\|fail.*closed' <<< "$output"
}

@test "carry-forward: glob **/*.sh matches deep path overlap" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src/deep"
  printf 'v1\n' > "$PROJECT_PATH/src/deep/util.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/deep/util.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S31" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "**/*.sh"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S31 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'scope\|overlap\|re-run' <<< "$output"
}

@test "carry-forward: glob src/**/main.sh matches nested path overlap" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src/sub"
  printf 'v1\n' > "$PROJECT_PATH/src/sub/main.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/sub/main.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S32" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**/main.sh"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S32 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'scope\|overlap\|re-run' <<< "$output"
}

@test "carry-forward: glob *.sh matches root-level files only" {
  _init_git "$PROJECT_PATH"
  printf 'v1\n' > "$PROJECT_PATH/build.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/build.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S33" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "*.sh"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S33 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'scope\|overlap\|re-run' <<< "$output"
}

@test "carry-forward: dotted filename in scope is matched correctly" {
  _init_git "$PROJECT_PATH"
  printf 'v1\n' > "$PROJECT_PATH/.env.local"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/.env.local"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S34" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" ".env.*"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S34 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'scope\|overlap\|re-run' <<< "$output"
}

@test "carry-forward: anchored glob does not prefix-match" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/abc.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/abc.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S35" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  # Glob "src/a" should NOT match "src/abc.sh" (must be anchored)
  _write_scope_config "$PROJECT_PATH" "code-review" "src/a"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S35 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5: Carry-forward sidecar record
# ---------------------------------------------------------------------------

@test "carry-forward: sidecar record written with all required fields" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  printf 'v1\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S40" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S40 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  local story_dir
  story_dir="$(dirname "$story")"
  local sidecar="${story_dir}/review-gate-carry.jsonl"
  [ -f "$sidecar" ]
  # Check all required fields are present in the sidecar record.
  local record
  record="$(cat "$sidecar")"
  grep -q '"row":"Code Review"' <<< "$record"
  grep -q "\"from_sha\":\"${sha_a}\"" <<< "$record"
  grep -q "\"to_sha\":\"${sha_b}\"" <<< "$record"
  grep -q '"evidence":{' <<< "$record"
  grep -q '"changed_paths":' <<< "$record"
  grep -q '"scope_globs":' <<< "$record"
  grep -q '"timestamp":"' <<< "$record"
  # Verify evidence contains the actual changed path and configured glob.
  grep -q 'unrelated.txt' <<< "$record"
  grep -q 'src/\*\*' <<< "$record"
}

@test "carry-forward: forged table row with no sidecar is NOT bound" {
  # A row whose table SHA was manually changed to bind-head without
  # going through carry-forward (no sidecar record).
  _init_git "$PROJECT_PATH"
  local sha_a sha_b
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Create story with Code Review on sha_a (old), others on sha_b (head).
  local impl="$PROJECT_PATH/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S41-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "E900-S41"
title: "Test Story"
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

  # Code Review is on sha_a, head is sha_b. No carry-forward done.
  # The row is stale — no sidecar record to prove a legitimate carry.
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_b" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'pending\|stale' <<< "$output"
}

@test "carry-forward: checker reads sidecar and treats carried row as bound" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  printf 'v1\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="$PROJECT_PATH/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S42-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "E900-S42"
title: "Test Story"
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
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  # Do the carry-forward (writes sidecar).
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S42 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  # The checker should now treat Code Review as bound via the carry.
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_b" --ci-sha none --story "$story"
  [ "$status" -eq 0 ]
  grep -qi 'complete' <<< "$output"
}
