#!/usr/bin/env bats
# review-gate-commit-bound.bats — tests for commit-bound review gate
#
# Covers all five ACs: dual-shape parser, bind-head check, non-destructive
# init, SHA binding on update, and carry-forward with self-computed evidence.

load 'test_helper.bash'

setup_file() {
  _litter_snapshot_before
  printf '%s\n' "$BASH_VERSION" >&3
}

setup() {
  common_setup
  export PROJECT_PATH="${TEST_TMP}/project"
  mkdir -p "$PROJECT_PATH"
  export PLUGIN_ROOT
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
  # Default config with no CI so --ci-sha none is accepted in most tests.
  # Tests that exercise CI detection override this.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: test
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"
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
    --sha "--output=${BATS_TEST_TMPDIR}/x" --report-missing-reason "test"
  [ "$status" -ne 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/x" ]
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
    --from "--output=${BATS_TEST_TMPDIR}/x" --to "$sha"
  [ "$status" -ne 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/x" ]
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

@test "stale row with SHA mismatch is PENDING" {
  # A row reviewed on sha_a, but the head moved to sha_b. No carry-forward.
  _init_git "$PROJECT_PATH"
  local sha_a sha_b
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

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

  # Code Review is on sha_a, head is sha_b. The row is stale.
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_b" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'pending\|stale' <<< "$output"
}

@test "carry-forward rebinds row to to-SHA and checker returns COMPLETE" {
  # Carry-forward writes the to-SHA directly into the table row. The checker
  # reads the table column — no sidecar lookup needed for binding.
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

  # Carry-forward writes to-SHA into the table row.
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S42 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  # The checker reads the table directly and finds the row bound to sha_b.
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_b" --ci-sha none --story "$story"
  [ "$status" -eq 0 ]
  grep -qi 'complete' <<< "$output"
}

# ---------------------------------------------------------------------------
# Per-row scope selection (different globs per gate)
# ---------------------------------------------------------------------------

@test "carry-forward uses the row's own scope globs, not another row's" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src" "$PROJECT_PATH/docs"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  printf 'v1\n' > "$PROJECT_PATH/docs/guide.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S43" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # code-review scopes docs/**; qa-tests scopes src/**. Only src/a.sh changed.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<YAML
review_gate:
  scope_globs:
    code-review:
      - "docs/**"
    qa-tests:
      - "src/**"
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  # Carry Code Review should succeed (docs/** has no overlap with src/a.sh).
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S43 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  # Carry QA Tests should FAIL (src/** overlaps with src/a.sh).
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S43 --row "QA Tests" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Glob shape tests (zero-directory **, character classes, renames)
# ---------------------------------------------------------------------------

@test "carry-forward: globstar matches zero directories (src/**/main.sh matches src/main.sh)" {
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
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S44" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**/main.sh"

  # src/main.sh changed and src/**/main.sh must match it (zero dirs).
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S44 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

@test "carry-forward: leading **/*.sh matches root-level file" {
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
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S45" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "**/*.sh"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S45 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

@test "carry-forward: character class [ab].sh matches a.sh" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S46" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/[ab].sh"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S46 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

@test "carry-forward: renamed-out-of-scope file is caught (--no-renames)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src/auth" "$PROJECT_PATH/lib"
  printf 'v1\n' > "$PROJECT_PATH/src/auth/check.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  git -C "$PROJECT_PATH" mv "$PROJECT_PATH/src/auth/check.sh" "$PROJECT_PATH/lib/check.sh"
  printf 'v2\n' >> "$PROJECT_PATH/lib/check.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S47" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/auth/**"

  # The file was moved out of src/auth/, but --no-renames lists the deletion
  # under the old path, which matches the scope.
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S47 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Table parser: 5-cell row rejection (table-level)
# ---------------------------------------------------------------------------

@test "table parser rejects 5-cell row in a story table" {
  local dir="$TEST_TMP/tp5"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S48"
---
## Review Gate

| Review | Status | Report | Reviewed SHA | Extra |
|--------|--------|--------|--------------|-------|
| Code Review | PASSED | cr.md | abc123 | bad |
STORY

  # shellcheck source=/dev/null
  source "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  run parse_review_gate_table "$dir/story.md"
  [ "$status" -ne 0 ]
  grep -qi 'more than 4' <<< "$output"
}

@test "table parser rejects 2-cell row with error message" {
  local dir="$TEST_TMP/tp2"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S49"
---
## Review Gate

| Review | Status |
|--------|--------|
| Code Review | PASSED |
STORY

  # shellcheck source=/dev/null
  source "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  run parse_review_gate_table "$dir/story.md"
  [ "$status" -ne 0 ]
  grep -qi 'fewer than 3' <<< "$output"
}

# ---------------------------------------------------------------------------
# CI detection: worktree mode + flow-style
# ---------------------------------------------------------------------------

@test "ci-sha none refused when config not found (fail closed)" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S50" "$sha")"
  # Remove config and unset all config env vars.
  rm -rf "$PROJECT_PATH/.gaia/config"
  unset PROJECT_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'not accepted' <<< "$output"
}

@test "ci-sha none refused with flow-style promotion_chain" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S51" "$sha")"
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain: [{id: staging, branch: staging}]
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'not accepted' <<< "$output"
}

@test "ci-sha none refused in worktree mode (config at project root, not worktree)" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S52" "$sha")"

  # Config lives at PROJECT_PATH (project root), worktree is a subdir.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
YAML
  local wt="$PROJECT_PATH/wt"
  mkdir -p "$wt"
  export PROJECT_PATH="$wt"
  unset PROJECT_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT

  # The walk-up from wt/ should find PROJECT_PATH/../.gaia/config.
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'not accepted' <<< "$output"
}

# ---------------------------------------------------------------------------
# Real-writer fixtures: checker on init + update output
# ---------------------------------------------------------------------------

@test "checker returns COMPLETE on real-writer table (init + update)" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Create a story with just the frontmatter (flat layout so update finds it).
  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S53-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S53"
title: "Test Story"
status: review
---
STORY

  # Seed with init-review-gate.sh (the real writer).
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"

  # Update all 6 gates to PASSED with the real writer.
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S53 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  # The checker should return COMPLETE.
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -eq 0 ]
  grep -qi 'complete' <<< "$output"
}

@test "checker returns PENDING on real-writer table after a new commit" {
  _init_git "$PROJECT_PATH"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S54-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S54"
title: "Test Story"
status: review
---
STORY

  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S54 --gate "$gate" --verdict PASSED --sha "$sha_a"
  done

  # Make a new commit so HEAD moves.
  printf 'v2\n' > "$PROJECT_PATH/README.md"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "v2"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # All rows were reviewed on sha_a but head is now sha_b → PENDING.
  run "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_b" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'pending' <<< "$output"
}

# ---------------------------------------------------------------------------
# validate-frontmatter accepts 4-column header
# ---------------------------------------------------------------------------

@test "validate-frontmatter accepts 4-column Review Gate header" {
  local dir="$TEST_TMP/vf4"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S55"
title: "Test Story"
status: review
priority: "P1"
size: "M"
points: 3
risk: "low"
sprint_id: "sprint-1"
priority_flag: null
delivered: false
deferred_implementation: false
manual_verification: false
date: "2026-01-01"
author: "Test Author"
---

## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
| QA Tests | UNVERIFIED | — | absent |
| Security Review | UNVERIFIED | — | absent |
| Test Automation | UNVERIFIED | — | absent |
| Test Review | UNVERIFIED | — | absent |
| Performance Review | UNVERIFIED | — | absent |

> Story moves to `done` only when ALL reviews show PASSED.
STORY

  export PROJECT_PATH="$dir"
  run bash "${PLUGIN_ROOT}/skills/gaia-create-story/scripts/validate-frontmatter.sh" "$dir/story.md"
  # Must not emit a CRITICAL about Review Gate columns.
  if grep -qi 'CRITICAL.*review_gate' <<< "$output"; then
    echo "CRITICAL review_gate finding emitted — 4-column header should be accepted"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Sidecar: written before row rebind, symlink refused
# ---------------------------------------------------------------------------

@test "carry-forward refuses symlinked sidecar" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/x.sh"
  printf 'v1\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S56" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  # Create a symlink where the sidecar would go (target under test tmpdir).
  local story_dir
  story_dir="$(dirname "$story")"
  ln -sf "${BATS_TEST_TMPDIR}/attack-target" "${story_dir}/review-gate-carry.jsonl"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S56 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'symlink' <<< "$output"
}

@test "init-review-gate.sh seeds 4-cell rows under 4-column header" {
  local dir="$TEST_TMP/init4"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S57"
title: "Test Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | abc1234 |

> Story moves to `done` only when ALL reviews show PASSED.
STORY

  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$dir/story.md"

  # All seeded rows must be 4-cell (pipe-delimited, 4 data columns).
  local seeded_count
  seeded_count="$(awk '
    /^## Review Gate/ { in_s = 1; next }
    in_s && /^## / { in_s = 0 }
    in_s && /^\| / && !/^[[:space:]]*\|[[:space:]]*-/ {
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, c, /\|/)
      if (n == 4 || (n >= 4 && c[1] !~ /Review/)) count++
    }
    END { print count+0 }
  ' "$dir/story.md")"
  # 1 existing + 5 seeded = 6 rows, all with 4 columns.
  [ "$seeded_count" -ge 6 ]

  # No 3-cell data row should exist.
  local three_cell
  three_cell="$(awk '
    /^## Review Gate/ { in_s = 1; next }
    in_s && /^## / { in_s = 0 }
    in_s && /^\| / && !/^[[:space:]]*\|[[:space:]]*-/ && !/Review.*Status.*Report/ {
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, c, /\|/)
      if (n < 4) count++
    }
    END { print count+0 }
  ' "$dir/story.md")"
  [ "$three_cell" -eq 0 ]
}

# ---------------------------------------------------------------------------
# YAML inline comment in scope globs is stripped
# ---------------------------------------------------------------------------

@test "carry-forward: YAML inline comment in scope glob is stripped" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/main.sh"
  printf 'v1\n' > "$PROJECT_PATH/unrelated.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/main.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S58" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Write config with a trailing YAML comment.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - "src/**"  # app code
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  # src/main.sh changed, glob "src/**" (after stripping comment) should match.
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S58 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Special-character file names in diff
# ---------------------------------------------------------------------------

@test "carry-forward: file with space in name is matched by scope glob" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/my file.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/my file.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S59" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S59 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

@test "carry-forward: file with non-ASCII name is matched by scope glob" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/cafe\xCC\x81.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/cafe\xCC\x81.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S60" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S60 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

@test "carry-forward: file with quote in name is matched by scope glob" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/q\"x.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/q\"x.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S61" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S61 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# 3000-path diff
# ---------------------------------------------------------------------------

@test "carry-forward: 3000-path diff with in-scope file first is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src" "$PROJECT_PATH/other"
  # Create the in-scope file first (alphabetically earliest).
  printf 'v1\n' > "$PROJECT_PATH/src/aaa.sh"
  local i
  for i in $(seq 1 200); do
    printf 'v1\n' > "$PROJECT_PATH/other/file-$(printf '%04d' "$i").txt"
  done
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/aaa.sh"
  for i in $(seq 1 200); do
    printf 'v2\n' > "$PROJECT_PATH/other/file-$(printf '%04d' "$i").txt"
  done
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S62" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S62 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

@test "carry-forward: 3000-path diff with in-scope file last is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src" "$PROJECT_PATH/aaa"
  # Create the in-scope file last (alphabetically last).
  printf 'v1\n' > "$PROJECT_PATH/src/zzz.sh"
  local i
  for i in $(seq 1 200); do
    printf 'v1\n' > "$PROJECT_PATH/aaa/file-$(printf '%04d' "$i").txt"
  done
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/zzz.sh"
  for i in $(seq 1 200); do
    printf 'v2\n' > "$PROJECT_PATH/aaa/file-$(printf '%04d' "$i").txt"
  done
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S63" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S63 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Invalid pattern refused
# ---------------------------------------------------------------------------

@test "carry-forward: unclosed bracket pattern is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S64" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/["

  # Unclosed bracket is an invalid pattern; git exits non-zero.
  # The carry must refuse (fail closed), not silently accept.
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S64 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Forged sidecar line has no binding effect
# ---------------------------------------------------------------------------

@test "carry-forward: forged sidecar line does not bind a stale row" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Seed all rows at sha_b (HEAD) so every row is already bound EXCEPT
  # Code Review, which is seeded at sha_a. This isolates the forged sidecar
  # as the only factor that could bind Code Review.
  local impl="$PROJECT_PATH/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S65-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "E900-S65"
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

  # Plant a forged sidecar record claiming carry to sha_b for Code Review.
  local story_dir
  story_dir="$(dirname "$story")"
  printf '{"row":"Code Review","from_sha":"%s","to_sha":"%s","evidence":{"changed_paths":[],"scope_globs":["src/**"]},"timestamp":"2026-01-01T00:00:00Z"}\n' \
    "$sha_a" "$sha_b" > "${story_dir}/review-gate-carry.jsonl"

  # Code Review still says sha_a in the table. The checker must report it as
  # stale because binding comes from the table SHA column, not the sidecar.
  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha_b" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'pending' <<< "$output"
  # Only Code Review should be stale.
  grep -qi 'code review' <<< "$output"
}

# ---------------------------------------------------------------------------
# Evidence changed_paths is a proper JSON array with multi-file diffs
# ---------------------------------------------------------------------------

@test "carry-forward: evidence changed_paths has correct count for multi-file diff" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/other"
  printf 'v1\n' > "$PROJECT_PATH/other/a.txt"
  printf 'v1\n' > "$PROJECT_PATH/other/b.txt"
  printf 'v1\n' > "$PROJECT_PATH/other/c.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/other/a.txt"
  printf 'v2\n' > "$PROJECT_PATH/other/b.txt"
  printf 'v2\n' > "$PROJECT_PATH/other/c.txt"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S66" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  # Scope is "nonexistent/**" so no overlap — carry succeeds.
  _write_scope_config "$PROJECT_PATH" "code-review" "nonexistent/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S66 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  # Check the sidecar evidence: changed_paths must be an array of 3 paths.
  local sidecar
  sidecar="$(dirname "$story")/review-gate-carry.jsonl"
  [ -f "$sidecar" ]
  # Count array elements: each path is a separate JSON string in the array.
  local path_count
  path_count="$(awk -F'"' '{ for(i=1;i<=NF;i++) if($i ~ /^other\//) c++ } END { print c+0 }' "$sidecar")"
  [ "$path_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# GIT_LITERAL_PATHSPECS security test
# ---------------------------------------------------------------------------

@test "carry-forward: GIT_LITERAL_PATHSPECS does not bypass scope check" {
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
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S67" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  # With GIT_LITERAL_PATHSPECS exported, an unprotected :(glob) pathspec
  # would become a literal string, nothing would match, and the carry
  # would be accepted. The script must unset this variable.
  export GIT_LITERAL_PATHSPECS=1
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S67 --row "Code Review" --from "$sha_a" --to "$sha_b"
  unset GIT_LITERAL_PATHSPECS
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# ? glob matches one character, * does not cross /
# ---------------------------------------------------------------------------

@test "carry-forward: ? glob matches exactly one character" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S68" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/?.sh"

  # src/a.sh matches src/?.sh — must be refused.
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S68 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

@test "carry-forward: * glob does not cross directory separator" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src/sub"
  printf 'v1\n' > "$PROJECT_PATH/src/sub/deep.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/sub/deep.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S69" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  # src/*.sh should NOT match src/sub/deep.sh (star doesn't cross /).
  _write_scope_config "$PROJECT_PATH" "code-review" "src/*.sh"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S69 --row "Code Review" --from "$sha_a" --to "$sha_b"
  # No overlap: star doesn't match across directories. Carry succeeds.
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# CI detection: fail-closed edge cases
# ---------------------------------------------------------------------------

@test "ci-sha none refused when config is unreadable (chmod 000)" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Seed a story with all rows PASSED, bound to HEAD.
  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S70-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S70"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S70 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  chmod 000 "$PROJECT_PATH/.gaia/config/project-config.yaml"
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  chmod 644 "$PROJECT_PATH/.gaia/config/project-config.yaml"
  # Unreadable config → fail closed → ci-sha none refused.
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

@test "ci-sha none refused when config is garbled binary" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Seed a story with all rows PASSED, bound to HEAD.
  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S71-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S71"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S71 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  # Overwrite config with binary content.
  printf '\x00\x01\x02\x03garbled' > "$PROJECT_PATH/.gaia/config/project-config.yaml"
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  # Garbled config → fail closed → ci-sha none refused.
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

@test "ci-sha none refused when promotion chain entry has name before id" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Seed a story with all rows PASSED, bound to HEAD.
  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S72-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S72"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S72 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain:
    - name: Staging
      id: staging
    - name: Production
      id: production
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  # promotion_chain with entries → CI configured → none refused.
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

@test "ci-sha none refused with flow-mapped ci_cd" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Seed a story with all rows PASSED, bound to HEAD.
  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S73-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S73"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S73 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
ci_cd: {promotion_chain: [{id: staging}]}
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

@test "ci-sha none refused when GAIA_SHARED_CONFIG has CI" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Seed a story with all rows PASSED, bound to HEAD.
  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S74-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S74"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S74 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  # Walk-up config has no CI.
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: test
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  # Shared config has CI.
  local shared_cfg="${BATS_TEST_TMPDIR}/shared-config.yaml"
  cat > "$shared_cfg" <<'YAML'
ci_cd:
  promotion_chain:
    - id: staging
YAML
  export GAIA_SHARED_CONFIG="$shared_cfg"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  unset GAIA_SHARED_CONFIG
  # Shared config has CI → none refused.
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

@test "ci-sha none refused with quoted ci_cd key" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  # Seed a story with all rows PASSED, bound to HEAD.
  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S75-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S75"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S75 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
"ci_cd":
  promotion_chain:
    - id: staging
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  # Quoted key → promotion_chain present → fail closed.
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

# ---------------------------------------------------------------------------
# Resolver integration tests
# ---------------------------------------------------------------------------

@test "carry-forward: flow-style scope glob list is resolved" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S76" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Write flow-style scope globs.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review: ["src/**", "lib/**"]
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S76 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# update usage includes --sha
# ---------------------------------------------------------------------------

@test "update usage synopsis includes --sha" {
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" --help
  [ "$status" -eq 0 ]
  grep -q '\-\-sha' <<< "$output"
}

# ---------------------------------------------------------------------------
# less-than-3-cell row returns non-zero exit code
# ---------------------------------------------------------------------------

@test "table parser exits non-zero on 2-cell row" {
  source "${PLUGIN_ROOT}/scripts/lib/review-gate-table.sh"
  run parse_review_gate_row "| Code Review | PASSED |"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Evidence JSON: tab and newline in file names produce valid JSON
# ---------------------------------------------------------------------------

@test "carry-forward: evidence sidecar is valid JSON with tab and newline in paths" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/docs"
  printf 'v1\n' > "$PROJECT_PATH/docs/readme.txt"
  # Create files with tab and newline in their names.
  printf 'v1\n' > "$(printf '%s/docs/ta\tb.txt' "$PROJECT_PATH")"
  printf 'v1\n' > "$(printf '%s/docs/nl\nx.txt' "$PROJECT_PATH")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/docs/readme.txt"
  printf 'v2\n' > "$(printf '%s/docs/ta\tb.txt' "$PROJECT_PATH")"
  printf 'v2\n' > "$(printf '%s/docs/nl\nx.txt' "$PROJECT_PATH")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S79" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  # Carry should succeed (changed files are in docs/, not src/).
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S79 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  # Validate that the sidecar is valid JSON with correct path count.
  local sidecar
  sidecar="$(dirname "$story")/review-gate-carry.jsonl"
  [ -f "$sidecar" ]
  # jq must parse it without error.
  run jq -e '.evidence.changed_paths | length' "$sidecar"
  [ "$status" -eq 0 ]
  # Should have 3 changed paths.
  [ "$output" = "3" ]
}

# ---------------------------------------------------------------------------
# Resolver: commented-out scope glob does not win
# ---------------------------------------------------------------------------

@test "carry-forward: commented-out scope glob line is ignored by yq resolver" {
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
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S80" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Write config with a commented-out code-review key above the real one.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    # code-review: ["legacy/**"]
    code-review:
      - "src/**"
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  # src/main.sh changed, and the real scope is src/** → refused.
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S80 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Resolver: inline comment after flow list is ignored
# ---------------------------------------------------------------------------

@test "carry-forward: inline comment after flow scope glob is ignored" {
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
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S81" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Flow list with an inline comment: the scope is src/**, not "app".
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review: ["src/**"]   # see [app]
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S81 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Resolver: character class in scope glob is preserved
# ---------------------------------------------------------------------------

@test "carry-forward: character class in scope glob is not broken" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src/a"
  printf 'v1\n' > "$PROJECT_PATH/src/a/x.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a/x.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S82" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Scope with a character class: src/[ab]/**
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review: ["src/[ab]/**"]
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  # src/a/x.sh changed and matches src/[ab]/** → refused.
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S82 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Resolver: missing scope key is refused
# ---------------------------------------------------------------------------

@test "carry-forward: missing scope key for gate slug is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S83" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Scope configured for security-review, not code-review.
  _write_scope_config "$PROJECT_PATH" "security-review" "src/**"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S83 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'no scope globs configured' <<< "$output"
}

# ---------------------------------------------------------------------------
# Glob validation: additional invalid patterns
# ---------------------------------------------------------------------------

@test "carry-forward: empty bracket class is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S84" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[]'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S84 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob' <<< "$output"
}

@test "carry-forward: negated empty bracket class is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S85" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[!]'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S85 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob' <<< "$output"
}

@test "carry-forward: trailing backslash pattern is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S86" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Use printf to produce a literal backslash at end of the glob.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  printf 'review_gate:\n  scope_globs:\n    code-review:\n      - "src/\\\\"\n' \
    > "$PROJECT_PATH/.gaia/config/project-config.yaml"
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S86 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob' <<< "$output"
}

@test "carry-forward: reversed character range is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S87" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[z-a]*'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S87 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob' <<< "$output"
}

@test "carry-forward: valid bracket class with ] as first char is accepted" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/docs/readme.txt" 2>/dev/null || {
    mkdir -p "$PROJECT_PATH/docs"
    printf 'v2\n' > "$PROJECT_PATH/docs/readme.txt"
  }
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S88" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # src/[]a]* is a valid POSIX bracket class: ] as first char is literal.
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[]a]*'

  # Changed file is docs/readme.txt, not in src/ → accepted (carry succeeds).
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S88 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# CI detection: unreadable GAIA_SHARED_CONFIG fails closed
# ---------------------------------------------------------------------------

@test "ci-sha none refused when GAIA_SHARED_CONFIG is unreadable" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S89-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S89"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S89 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  # Walk-up config has no CI.
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: test
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  # Shared config exists but is unreadable.
  local shared_cfg="${BATS_TEST_TMPDIR}/shared-config.yaml"
  cat > "$shared_cfg" <<'YAML'
ci_cd:
  promotion_chain:
    - id: staging
YAML
  chmod 000 "$shared_cfg"
  export GAIA_SHARED_CONFIG="$shared_cfg"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  chmod 644 "$shared_cfg"
  unset GAIA_SHARED_CONFIG
  # Unreadable shared config → fail closed → none refused.
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

# ---------------------------------------------------------------------------
# CI detection: commented-out promotion_chain on Linux shape
# ---------------------------------------------------------------------------

@test "ci-sha none refused with commented-out promotion_chain above real chain" {
  _init_git "$PROJECT_PATH"
  local sha
  sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local impl="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local story="$impl/E900-S90-test.md"
  cat > "$story" <<'STORY'
---
template: 'story'
key: "E900-S90"
title: "Test Story"
status: review
---
STORY
  bash "${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/init-review-gate.sh" "$story"
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
      --story E900-S90 --gate "$gate" --verdict PASSED --sha "$sha"
  done

  # Config with a commented-out promotion_chain above a real one.
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
ci_cd:
  # promotion_chain:
  promotion_chain:
    - id: staging
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate-check.sh" \
    --bind-head "$sha" --ci-sha none --story "$story"
  [ "$status" -ne 0 ]
  grep -qi 'not accepted when CI is configured\|blocked' <<< "$output"
}

# ---------------------------------------------------------------------------
# Scope with multiple globs: only non-first glob matches the change
# (kills resolver-first-item mutant that returns only [0])
# ---------------------------------------------------------------------------

@test "carry-forward: non-first scope glob matching the change is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S91" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Scope: first glob does NOT match the change, second does.
  # A resolver that returns only the first item would miss this overlap.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review: ["lib/**", "src/**"]
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S91 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'includes files in scope' <<< "$output"
}

# ---------------------------------------------------------------------------
# Evidence round-trip: a tab in a file name is recorded byte-identically
# (kills evidence-tab-mangling mutant that replaces tabs with spaces)
# ---------------------------------------------------------------------------

@test "carry-forward: evidence records tab in path byte-identically" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/docs"
  printf 'v1\n' > "$PROJECT_PATH/docs/readme.txt"
  # File with a literal tab in the name.
  printf 'v1\n' > "$(printf '%s/docs/t\tab.txt' "$PROJECT_PATH")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/docs/readme.txt"
  printf 'v2\n' > "$(printf '%s/docs/t\tab.txt' "$PROJECT_PATH")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S92" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" "src/**"

  # Carry succeeds (changed files are in docs/, not src/).
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S92 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -eq 0 ]

  # The sidecar must contain the literal tab, not a space.
  local sidecar
  sidecar="$(dirname "$story")/review-gate-carry.jsonl"
  [ -f "$sidecar" ]
  # jq must parse it and the tab-containing name must be present.
  run jq -e '.evidence.changed_paths | map(select(contains("\t"))) | length > 0' "$sidecar"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # Verify no space-substituted variant exists in place of the tab.
  run jq -e '.evidence.changed_paths | map(select(test("t tab\\.txt"))) | length' "$sidecar"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Scope-globs item validation: non-string items are refused
# ---------------------------------------------------------------------------

@test "carry-forward: map item in scope_globs is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S93" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  # Config with a map item instead of a string.
  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - {path: "src/**"}
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S93 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'non-empty string\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: nested list item in scope_globs is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S94" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - ["src/**", "lib/**"]
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S94 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'non-empty string\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: numeric item in scope_globs is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S95" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - 123
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S95 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'non-empty string\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: boolean item in scope_globs is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S96" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - true
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S96 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'non-empty string\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: null item in scope_globs is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S97" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - null
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S97 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'non-empty string\|refusing\|fail closed\|no scope globs' <<< "$output"
}

@test "carry-forward: empty string item in scope_globs is refused (fail closed)" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S98" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - ""
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S98 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'non-empty string\|refusing\|fail closed\|no scope globs' <<< "$output"
}

@test "carry-forward: whitespace-only string item in scope_globs is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S99" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  mkdir -p "$PROJECT_PATH/.gaia/config"
  cat > "$PROJECT_PATH/.gaia/config/project-config.yaml" <<'YAML'
review_gate:
  scope_globs:
    code-review:
      - "   "
YAML
  export PROJECT_CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S99 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'non-empty string\|refusing\|fail closed\|no scope globs' <<< "$output"
}

# ---------------------------------------------------------------------------
# Glob validator: POSIX bracket expressions and unclosed class after ]
# ---------------------------------------------------------------------------

@test "carry-forward: POSIX bracket expression [:bogus:] is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S100" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[[:bogus:]]*'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S100 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: unclosed POSIX bracket expression [:alpha: is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S101" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[[:alpha:]'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S101 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: POSIX equivalence class [=c=] is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S102" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[[=a=]]*'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S102 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: POSIX collating element [.elem.] is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S103" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[[.a.]]*'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S103 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: reversed range after literal ] in class is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S104" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[]-!]*'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S104 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob\|refusing\|fail closed' <<< "$output"
}

@test "carry-forward: class never closed after bracket content is refused" {
  _init_git "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/src"
  printf 'v1\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "A"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT_PATH/src/a.sh"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "B"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "E900-S105" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  _write_scope_config "$PROJECT_PATH" "code-review" 'src/[abc*'

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" carry-forward \
    --story E900-S105 --row "Code Review" --from "$sha_a" --to "$sha_b"
  [ "$status" -ne 0 ]
  grep -qi 'invalid scope glob\|refusing\|fail closed' <<< "$output"
}

# ---------------------------------------------------------------------------
# Story-resolution + key-mismatch + caller-supplied SHA + non-descendant SHA
# ---------------------------------------------------------------------------

# AC1: code-review SKILL.md Critical Rules references resolve-story-file.sh
@test "code-review SKILL.md Critical Rules references resolve-story-file.sh (not inline glob)" {
  local skill_md="${PLUGIN_ROOT}/skills/gaia-code-review/SKILL.md"
  [ -f "$skill_md" ]
  local section
  section="$(sed -n '/^## Critical Rules/,/^## [^C]/p' "$skill_md")"
  grep -q 'resolve-story-file\.sh' <<< "$section"
  # No inline flat-glob for story resolution (exclude resolver tier descriptions)
  ! grep -v 'resolve-story-file\|fallback\|legacy' <<< "$section" | grep -q '{story_key}-\*\.md'
}

# AC2: performance-review SKILL.md Critical Rules references resolve-story-file.sh
@test "performance-review SKILL.md Critical Rules references resolve-story-file.sh (not inline glob)" {
  local skill_md="${PLUGIN_ROOT}/skills/gaia-performance-review/SKILL.md"
  [ -f "$skill_md" ]
  local section
  section="$(sed -n '/^## Critical Rules/,/^## [^C]/p' "$skill_md")"
  grep -q 'resolve-story-file\.sh' <<< "$section"
  ! grep -v 'resolve-story-file\|fallback\|legacy' <<< "$section" | grep -q '{story_key}-\*\.md'
}

# Helper: seed a minimal fixture project so resolve-config.sh succeeds
# inside setup.sh. Follows the pattern from quality-gates.bats.
_seed_setup_fixture() {
  local root="$1"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"
  mkdir -p "$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$root/_memory/checkpoints"
  mkdir -p "$root/skill/config"
  cat > "$root/skill/config/project-config.yaml" <<YAML
project_root: ${root}
project_path: ${root}
memory_path: ${root}/_memory
checkpoint_path: ${root}/_memory/checkpoints
installed_path: ${root}/_gaia
framework_version: 1.227.0
date: 2026-11-17
test_artifacts: ${root}/.gaia/artifacts/test-artifacts
planning_artifacts: ${root}/.gaia/artifacts/planning-artifacts
implementation_artifacts: ${root}/.gaia/artifacts/implementation-artifacts
YAML
}

# AC3a: setup.sh exits non-zero when story key has no matching file
@test "code-review setup.sh exits non-zero when story key has no matching file" {
  local _K="E900-S901" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/ac3a"
  _seed_setup_fixture "$tmproot"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    bash "$setup_sh" "$_K"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# AC3b: setup.sh exits zero when story key resolves to nested-layout fixture (regression guard)
@test "code-review setup.sh exits zero when story key resolves to nested-layout fixture" {
  local _K="E900-S902" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/ac3b"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Test Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    bash "$setup_sh" "$_K"
  [ "$status" -eq 0 ]
}

# AC4a: setup.sh exits non-zero on frontmatter key mismatch
@test "code-review setup.sh exits non-zero on frontmatter key mismatch" {
  local _K="E900-S903" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local _K2="E900-S904" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/ac4a"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K2}"
title: "Mismatched Key"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    bash "$setup_sh" "$_K"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

# AC3+AC4 via ARGUMENTS env var — missing key (must fail)
@test "code-review setup.sh fails when ARGUMENTS names a missing story key" {
  local _K="E900-S905" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/ac3envmiss"
  _seed_setup_fixture "$tmproot"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K" \
    bash "$setup_sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# AC3+AC4 via ARGUMENTS env var — matching key resolves (regression guard)
@test "code-review setup.sh resolves story key from ARGUMENTS env var" {
  local _K="E900-S911" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/ac3envok"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Env Arg Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K" \
    bash "$setup_sh"
  [ "$status" -eq 0 ]
}

# AC3e: no key at all — backward compatible, exits 0 (regression guard)
@test "code-review setup.sh exits zero when no story key is provided (regression guard)" {
  local tmproot="${TEST_TMP}/ac3e"
  _seed_setup_fixture "$tmproot"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    bash "$setup_sh"
  [ "$status" -eq 0 ]
}

# Legacy-flat resolver warns on stderr; mismatch guard must still fire
@test "code-review setup.sh detects key mismatch even when resolver emits stderr warnings" {
  local _K="E900-S912" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local _K2="E900-S913" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/ac4legacyflat"
  _seed_setup_fixture "$tmproot"
  # Place story as a flat file inside impl_root (tier 2) so the resolver
  # emits "WARNING: legacy-flat path" on stderr while returning exit 0.
  # Frontmatter key is _K2, but we call with _K → mismatch.
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  cat > "$impl/${_K}-slug.md" <<STORY
---
template: 'story'
key: "${_K2}"
title: "Legacy Flat Mismatch"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    bash "$setup_sh" "$_K"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

# AC4b: code-review SKILL.md Phase 1 contains key-mismatch halt prose
@test "code-review SKILL.md Phase 1 contains key-mismatch halt prose" {
  local skill_md="${PLUGIN_ROOT}/skills/gaia-code-review/SKILL.md"
  local section
  section="$(sed -n '/^### Phase 1/,/^### /p' "$skill_md")"
  # Must mention key mismatch and halt
  grep -qi 'frontmatter.*key.*does not match\|halting to prevent cross-story\|mismatch.*halt\|halt.*mismatch' <<< "$section"
}

# AC5 (prose): code-review gate-update code block passes --sha
@test "code-review gate-update code block passes --sha (prose)" {
  local skill_md="${PLUGIN_ROOT}/skills/gaia-code-review/SKILL.md"
  # Extract from "Gate row update" to the next heading
  local section
  section="$(sed -n '/Gate row update/,/^### \|^## /p' "$skill_md")"
  grep -q '\-\-sha' <<< "$section"
}

# AC5 (functional regression): explicit --sha records the caller SHA
@test "explicit --sha records the caller SHA not CWD HEAD (regression)" {
  local _K="E900-S906" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  _init_git "$PROJECT_PATH"
  local impl="${PROJECT_PATH}/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="${impl}/${_K}-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "${_K}"
title: "SHA Test"
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

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  local explicit_sha
  explicit_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'extra\n' > "$PROJECT_PATH/extra.txt"
  git -C "$PROJECT_PATH" add extra.txt && git -C "$PROJECT_PATH" commit -q -m "extra"
  local head_sha
  head_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  [ "$explicit_sha" != "$head_sha" ]

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story "$_K" --gate "Code Review" --verdict PASSED \
    --sha "$explicit_sha" \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  grep "Code Review" "$story" | grep -q "$explicit_sha"
  ! grep "Code Review" "$story" | grep -q "$head_sha"
}

# AC7a: non-descendant SHA warning emitted to stderr
@test "review-gate.sh emits non-descendant SHA warning to stderr" {
  local _K="E900-S907" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  _init_git "$PROJECT_PATH"
  git -C "$PROJECT_PATH" checkout -q -b branch-a
  printf 'a\n' > "$PROJECT_PATH/a.txt"
  git -C "$PROJECT_PATH" add a.txt && git -C "$PROJECT_PATH" commit -q -m "a"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  git -C "$PROJECT_PATH" checkout -q -b branch-b HEAD~1
  printf 'b\n' > "$PROJECT_PATH/b.txt"
  git -C "$PROJECT_PATH" add b.txt && git -C "$PROJECT_PATH" commit -q -m "b"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  git -C "$PROJECT_PATH" checkout -q branch-a

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "$_K" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story "$_K" --gate "Code Review" --verdict PASSED \
    --sha "$sha_b" \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"not a descendant"* ]]
  grep "Code Review" "$story" | grep -q "$sha_b"
}

# AC7b: descendant SHA emits no warning
@test "review-gate.sh emits no warning for descendant SHA" {
  local _K="E900-S908" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  _init_git "$PROJECT_PATH"
  printf 'first\n' > "$PROJECT_PATH/first.txt"
  git -C "$PROJECT_PATH" add first.txt && git -C "$PROJECT_PATH" commit -q -m "first"
  local sha_a
  sha_a="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  printf 'second\n' > "$PROJECT_PATH/second.txt"
  git -C "$PROJECT_PATH" add second.txt && git -C "$PROJECT_PATH" commit -q -m "second"
  local sha_b
  sha_b="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "$_K" "$sha_a")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story "$_K" --gate "Code Review" --verdict PASSED \
    --sha "$sha_b" \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not a descendant"* ]]
}

# AC7c: unknown prior SHA — silent, row written
@test "review-gate.sh silently writes row when prior SHA is unknown to repo" {
  local _K="E900-S909" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  _init_git "$PROJECT_PATH"
  local real_sha
  real_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
  local fake_sha="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "$_K" "$fake_sha")"
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "story"
  real_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story "$_K" --gate "Code Review" --verdict PASSED \
    --sha "$real_sha" \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not a descendant"* ]]
  grep "Code Review" "$story" | grep -q "$real_sha"
}

# AC7d: non-git directory — silent, row written
@test "review-gate.sh silently writes row outside a git work tree" {
  local _K="E900-S910" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local non_git="${TEST_TMP}/non-git-ac7d"
  mkdir -p "$non_git/docs/implementation-artifacts"
  export PROJECT_PATH="$non_git"
  local story="${non_git}/docs/implementation-artifacts/${_K}-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "${_K}"
title: "Non-Git Test"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr.md | abc1234 |
| QA Tests | PASSED | qa.md | abc1234 |
| Security Review | PASSED | sec.md | abc1234 |
| Test Automation | PASSED | ta.md | abc1234 |
| Test Review | PASSED | tr.md | abc1234 |
| Performance Review | PASSED | perf.md | abc1234 |

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story "$_K" --gate "Code Review" --verdict PASSED \
    --sha "1234567890abcdef1234567890abcdef12345678" \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not a descendant"* ]]
}

# AC8: all nine review skills use resolve-story-file.sh (no inline flat-glob)
@test "all ten review skills use resolve-story-file.sh, no inline flat-glob, and halt on key mismatch" {
  local skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-security-review"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-test-automate"
    "gaia-review-mobile"
    "gaia-run-all-reviews"
  )
  for skill in "${skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    [ -f "$skill_md" ] || { echo "MISSING: $skill_md"; return 1; }
    # Extract Critical Rules section (or Step 1 for run-all-reviews)
    local section
    if [ "$skill" = "gaia-run-all-reviews" ]; then
      section="$(sed -n '/^### Step 1/,/^### Step 2/p' "$skill_md")"
    else
      section="$(sed -n '/^## Critical Rules/,/^## [^C]/p' "$skill_md")"
    fi
    # Must reference resolve-story-file.sh
    if ! grep -q 'resolve-story-file\.sh' <<< "$section"; then
      echo "FAIL: $skill Critical Rules/Step 1 does not reference resolve-story-file.sh"
      return 1
    fi
    # Must NOT contain inline flat-glob for story resolution
    if grep -v 'resolve-story-file\|fallback\|legacy' <<< "$section" | grep -q '{story_key}-\*\.md'; then
      echo "FAIL: $skill Critical Rules/Step 1 still has inline {story_key}-*.md glob for resolution"
      return 1
    fi
    # Must instruct halt on frontmatter key mismatch (key differs → halt
    # before any write). gaia-test-automate and gaia-review-mobile may
    # use different wording; accept any mention of key + differ/mismatch + halt.
    if ! grep -qiE 'key.*differ.*halt|halt.*key.*differ|key.*mismatch.*halt|halt.*mismatch|differ.*halt.*before' <<< "$section"; then
      echo "FAIL: $skill Critical Rules/Step 1 missing key-mismatch halt instruction"
      return 1
    fi
  done
}

# AC9: every review-gate.sh update call that writes a canonical gate row
# must pass --sha (the pre-computed worktree HEAD). Scans BOTH code blocks
# AND prose lines in each file. Plan-ledger writes (--plan-id) and
# review-mobile's non-canonical gate are excluded.
_extract_code_blocks() {
  awk '/^[[:space:]]*```bash/{ in_block=1; next } /^[[:space:]]*```/{ in_block=0; next } in_block' "$1"
}

# Canonical gate names for filtering prose mentions
_CANONICAL_GATES='Code Review|QA Tests|Security Review|Test Automation|Test Review|Performance Review'

# Helper: extract all gate-writing review-gate.sh update mentions from a
# SKILL.md, in both code blocks AND prose. Returns one logical line per
# call (continuation lines joined). Excludes plan-ledger and non-canonical.
_extract_gate_update_calls() {
  local file="$1"
  # 1. Code blocks: join continuations, filter
  _extract_code_blocks "$file" \
    | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' \
    | grep 'review-gate\.sh.*update' \
    | grep -v '\-\-plan-id' \
    | grep -v 'Mobile Review' \
    | grep -E "\-\-gate|\-\-verdict" || true
  # 2. Prose lines (outside code blocks): any line mentioning
  #    review-gate.sh update with a canonical gate name
  awk '/^[[:space:]]*```/{ in_block=!in_block; next } !in_block' "$file" \
    | grep 'review-gate\.sh.*update' \
    | grep -v '\-\-plan-id' \
    | grep -v 'Mobile Review' \
    | grep -v 'fails to update' \
    | grep -E "$_CANONICAL_GATES" \
    | grep -E '\-\-gate|\-\-verdict' || true
}

@test "every canonical gate-row write passes --sha in all 8 skills" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-security-review"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    [ -f "$skill_md" ] || { echo "MISSING: $skill_md"; return 1; }
    local call_lines
    call_lines="$(_extract_gate_update_calls "$skill_md")"
    [ -z "$call_lines" ] && continue
    while IFS= read -r line; do
      if ! grep -q '\-\-sha' <<< "$line"; then
        echo "FAIL: $skill: review-gate.sh update missing --sha: $(echo "$line" | head -c 120)"
        return 1
      fi
    done <<< "$call_lines"
  done
}

@test "every canonical gate-row write passes --report in all 7 skills" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    [ -f "$skill_md" ] || { echo "MISSING: $skill_md"; return 1; }
    local call_lines
    call_lines="$(_extract_gate_update_calls "$skill_md")"
    [ -z "$call_lines" ] && continue
    while IFS= read -r line; do
      if ! grep -q '\-\-report' <<< "$line"; then
        echo "FAIL: $skill: review-gate.sh update missing --report: $(echo "$line" | head -c 120)"
        return 1
      fi
    done <<< "$call_lines"
  done
}

@test "test-execution gate-row writes pass --execution-evidence" {
  local rr_md="${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  local rr_section
  rr_section="$(sed -n '/Substep 2\.3/,/Substep 2\.4\|^### /p' "$rr_md")"
  if ! grep -q '\-\-execution-evidence' <<< "$rr_section"; then
    echo "FAIL: run-all-reviews Substep 2.3 missing --execution-evidence"
    return 1
  fi
  # Individual skills
  for skill in "gaia-qa-tests" "gaia-test-review"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    local section
    section="$(sed -n '/_sha=\|[Gg]ate row update\|Invoke.*review-gate/,/review-gate-check\|^### \|^## /p' "$skill_md")"
    if ! grep -q '\-\-execution-evidence' <<< "$section"; then
      echo "FAIL: $skill gate-update block missing --execution-evidence"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Multi-token ARGUMENTS / extra positional args — setup.sh key extraction
# ---------------------------------------------------------------------------

# (a) ARGUMENTS with extra flags + matching nested fixture → exit 0
@test "code-review setup.sh handles multi-token ARGUMENTS with matching story" {
  local _K="E900-S914" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/multiarg_a"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Multi-Arg Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K --run-id round-x --packet /tmp/p.md" \
    bash "$setup_sh"
  [ "$status" -eq 0 ]
}

# (b) positional $1 = key plus extra positional args → exit 0
@test "code-review setup.sh handles extra positional args after story key" {
  local _K="E900-S915" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/multiarg_b"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Extra Args Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    bash "$setup_sh" "$_K" "--run-id" "round-x" "--packet" "/tmp/p.md"
  [ "$status" -eq 0 ]
}

# (c) ARGUMENTS whose first token is not a story key → no key → exit 0
@test "code-review setup.sh treats ARGUMENTS with no key-shaped first token as no key" {
  local tmproot="${TEST_TMP}/multiarg_c"
  _seed_setup_fixture "$tmproot"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="--run-id round-x --packet /tmp/p.md" \
    bash "$setup_sh"
  [ "$status" -eq 0 ]
}

# (d) multi-token ARGUMENTS whose first key-shaped token has no story → non-zero
@test "code-review setup.sh fails when ARGUMENTS key token has no matching story" {
  local _K="E900-S916" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/multiarg_d"
  _seed_setup_fixture "$tmproot"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K --run-id round-x" \
    bash "$setup_sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# Gate-write blocks must use STORY_WORKTREE_PATH, not STORY_WORKTREE
# ---------------------------------------------------------------------------

@test "canonical gate-write blocks use STORY_WORKTREE_PATH not STORY_WORKTREE" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    [ -f "$skill_md" ] || { echo "MISSING: $skill_md"; return 1; }
    local section
    section="$(sed -n '/_sha=\|[Gg]ate row update\|Invoke.*review-gate/,/review-gate-check\|^### \|^## /p' "$skill_md")"
    # Must use STORY_WORKTREE_PATH
    if ! grep -q 'STORY_WORKTREE_PATH' <<< "$section"; then
      echo "FAIL: $skill gate block missing STORY_WORKTREE_PATH"
      return 1
    fi
    # Must NOT contain the old STORY_WORKTREE fallback pattern
    if grep -q 'STORY_WORKTREE:-' <<< "$section"; then
      echo "FAIL: $skill gate block still uses STORY_WORKTREE:- fallback"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# ARGUMENTS injection safety — setup.sh never evals content as code
# ---------------------------------------------------------------------------

@test "setup.sh does not execute shell metacharacters in ARGUMENTS" {
  local _K="E900-S917" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/rf6_inject"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Injection Test"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  # Canary: ARGUMENTS contains backticks, $(), ;, < metacharacters after the key.
  # None must execute — the pwned* files must NOT be created.
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="${_K} "'`touch '"$tmproot"'/pwned1` $(touch '"$tmproot"'/pwned2); touch '"$tmproot"'/pwned3 <x' \
    bash "$setup_sh"
  # Setup should succeed (key resolved) or fail benignly — never execute injected code
  [ ! -f "$tmproot/pwned1" ]
  [ ! -f "$tmproot/pwned2" ]
  [ ! -f "$tmproot/pwned3" ]
}

@test "gaia-code-review SKILL.md Setup bang line does not pass ARGUMENTS" {
  local skill_md="${PLUGIN_ROOT}/skills/gaia-code-review/SKILL.md"
  local setup_line
  setup_line="$(grep '^!' "$skill_md" | head -1)"
  # Must reference setup.sh
  [[ "$setup_line" == *"setup.sh"* ]]
  # Must NOT pass ${ARGUMENTS} (setup.sh reads ARGUMENTS from its env)
  [[ "$setup_line" != *'${ARGUMENTS}'* ]]
  [[ "$setup_line" != *'$ARGUMENTS'* ]]
}

# ---------------------------------------------------------------------------
# Missing key: line in frontmatter → warn and continue, not silent skip
# ---------------------------------------------------------------------------

@test "setup.sh warns and continues when the story file has no key: line" {
  local _K="E900-S918" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/rf2_nokey"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  # Story file WITHOUT a key: line in frontmatter
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
title: "No Key Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    bash "$setup_sh" "$_K"
  # Must exit 0 (missing key is not a mismatch — warn and continue)
  [ "$status" -eq 0 ]
  # Must emit a warning about being unable to verify the key
  [[ "$output" == *"cannot verify frontmatter key"* ]] || [[ "$output" == *"no key: line"* ]]
}

# ---------------------------------------------------------------------------
# Gate blocks must refuse when worktree HEAD cannot resolve
# ---------------------------------------------------------------------------

@test "all 7 gate-write blocks contain the worktree-head refusal guard" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    local section
    # Extract the gate-update section including the SHA pre-computation guard.
    # Use _sha= as start anchor (the guard) through the next heading or gate-check.
    section="$(sed -n '/_sha=\|[Gg]ate row update\|Invoke.*review-gate/,/review-gate-check\|^### \|^## /p' "$skill_md")"
    # Must contain the pre-validation guard (resolve + length check before gate call)
    if ! grep -q 'rev-parse --verify' <<< "$section"; then
      echo "FAIL: $skill gate block missing rev-parse --verify guard"
      return 1
    fi
    if ! grep -q 'refusing to record' <<< "$section"; then
      echo "FAIL: $skill gate block missing refusal message"
      return 1
    fi
    # Must NOT have rev-parse inlined in the --sha argument of review-gate.sh
    # (the SHA must be pre-computed and validated before the gate call)
    if grep 'review-gate\.sh.*update' <<< "$section" | grep -q 'rev-parse'; then
      echo "FAIL: $skill still inlines rev-parse in the review-gate.sh call"
      return 1
    fi
  done
}

# The gate-write guard tests now exercise the REAL published block via the
# extract-from-SKILL.md harness, so they break when the published guard breaks.

@test "gate write refuses when worktree arg points at a missing dir (extracted block)" {
  local _K="E900-S970" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/rf3func_a"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$tmproot/does-not-exist" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]] || [[ "$output" == *"not a directory"* ]]
  [ ! -f "$tmproot/captured-sha" ]
}

@test "gate write refuses when worktree arg points at a non-git dir (extracted block)" {
  local _K="E900-S971" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/rf3func_b"
  mkdir -p "$tmproot/main" "$tmproot/not-a-repo"
  _init_git "$tmproot/main"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$tmproot/not-a-repo" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git"* ]] || [[ "$output" == *"not a work tree"* ]]
  [ ! -f "$tmproot/captured-sha" ]
}

@test "gate write passes exact worktree HEAD SHA (extracted block)" {
  local _K="E900-S972" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/rf3func_c"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  local wt="$tmproot/repo"
  _seed_worktree_fixture "$wt" "$_K"
  _seed_project_root_for_stub "$tmproot" "$_K"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"

  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$wt" "$tmproot" "$tmproot/main"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
}

# ---------------------------------------------------------------------------
# Worktree delivery — setup.sh parses --worktree
# ---------------------------------------------------------------------------

# Helper: seed a fixture git repo on a feat/ branch for a given story key.
_seed_worktree_fixture() {
  local dir="$1" key="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "Test"
  printf 'init\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "init"
  git -C "$dir" checkout -q -b "feat/${key}-worktree-test"
  printf 'wt content\n' > "$dir/work.txt"
  git -C "$dir" add work.txt
  git -C "$dir" commit -q -m "worktree commit"
}

# (a) orchestrated: setup.sh with --worktree <valid fixture worktree> → 0
@test "setup.sh validates --worktree and accepts a valid story worktree" {
  local _K="E900-S920" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/wt_valid"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Worktree Test"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local wt="$tmproot/worktree"
  _seed_worktree_fixture "$wt" "$_K"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K --run-id r --packet /tmp/p.md --worktree $wt" \
    bash "$setup_sh"
  [ "$status" -eq 0 ]
  # Must confirm the worktree was validated (not silently ignored)
  [[ "$output" == *"worktree validated"* ]] || [[ "$output" == *"story worktree:"* ]]
}

# (b) setup.sh accepts --worktree with spaces in the path
@test "setup.sh validates --worktree with spaces in the path" {
  local _K="E900-S921" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/wt_spaces"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Worktree Spaces Test"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
STORY
  local wt="$tmproot/path with spaces/worktree"
  _seed_worktree_fixture "$wt" "$_K"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  # --worktree is LAST, its value is the remainder of the string (supports spaces)
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K --run-id r --packet /tmp/p.md --worktree $wt" \
    bash "$setup_sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"worktree validated"* ]] || [[ "$output" == *"story worktree:"* ]]
}

# (c) --worktree pointing at a missing dir → non-zero
@test "setup.sh refuses --worktree pointing at a missing directory" {
  local _K="E900-S922" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/wt_missing"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Worktree Missing Test"
status: review
---
STORY
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K --run-id r --worktree $tmproot/does-not-exist" \
    bash "$setup_sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]] || [[ "$output" == *"not a directory"* ]]
}

# (c) --worktree pointing at a non-git dir → non-zero
@test "setup.sh refuses --worktree pointing at a non-git directory" {
  local _K="E900-S923" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/wt_nongit"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Worktree NonGit Test"
status: review
---
STORY
  mkdir -p "$tmproot/plain-dir"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K --run-id r --worktree $tmproot/plain-dir" \
    bash "$setup_sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git"* ]] || [[ "$output" == *"not a work tree"* ]]
}

# (c) --worktree on a branch not matching the story key → non-zero
@test "setup.sh refuses --worktree on a branch not matching the story key" {
  local _K="E900-S924" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local _OTHER="E900-S999" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/wt_wrongbranch"
  _seed_setup_fixture "$tmproot"
  local impl="$tmproot/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl/epic-E900-fixture/${_K}-slug"
  cat > "$impl/epic-E900-fixture/${_K}-slug/story.md" <<STORY
---
template: 'story'
key: "${_K}"
title: "Worktree WrongBranch Test"
status: review
---
STORY
  # Worktree is on a feat/ branch for a DIFFERENT story key
  local wt="$tmproot/wt-other"
  _seed_worktree_fixture "$wt" "$_OTHER"
  local setup_sh="${PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh"
  run env CLAUDE_SKILL_DIR="$tmproot/skill" \
    PROJECT_PATH="$tmproot" PROJECT_ROOT="$tmproot" \
    ARGUMENTS="$_K --run-id r --worktree $wt" \
    bash "$setup_sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch"* ]] || [[ "$output" == *"does not match"* ]]
}

# ---------------------------------------------------------------------------
# Gate-write snippet extraction and execution from SKILL.md
# ---------------------------------------------------------------------------

# Helper: extract the first bash code block after "Gate row update" (or the
# Invoke.*review-gate pattern for review-security/review-perf) in a SKILL.md.
# Substitutes the documented placeholders so the block is runnable.
_extract_gate_block() {
  local skill_md="$1" story_key="$2" worktree_val="$3"
  awk '
    /[Gg]ate row update|Invoke.*review-gate.*update.*story|proof-of-execution contract/ { found = 1 }
    found && /^[[:space:]]*```bash$/ { in_b = 1; next }
    found && in_b && /^[[:space:]]*```$/ { exit }
    found && in_b { print }
  ' "$skill_md" \
    | sed "s/{story_key}/$story_key/g" \
    | sed "s/{worktree}/$(printf '%s' "$worktree_val" | sed 's/[&/\]/\\&/g')/g" \
    | sed 's/{PASSED|FAILED}/PASSED/g' \
    | sed 's/{verdict}/PASSED/g' \
    | sed 's/{gate_name}/Code Review/g' \
    | sed 's/<absolute-path-to-per-review-report>/"\/tmp\/fake-report.md"/g' \
    | sed 's/\[--execution-evidence.*\]//g'
}

# Helper: set up the stub plugin root with fake resume-checkpoint.sh and
# a review-gate.sh that records every argument it receives.
# Helper: seed .gaia/config and a minimal story file at the project root level
# so the gate block's project-root walk-up and story-file verification succeed.
_seed_project_root_for_stub() {
  local root="$1" key="$2"
  mkdir -p "$root/.gaia/config" "$root/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${key}-slug"
  cat > "$root/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: stub-fixture
YAML
  cat > "$root/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${key}-slug/story.md" <<STORY
---
key: "${key}"
status: review
---
STORY
}

_setup_gate_stubs() {
  local tmproot="$1"
  mkdir -p "$tmproot/fake-plugin/scripts"
  cat > "$tmproot/fake-plugin/scripts/resume-checkpoint.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmproot/fake-plugin/scripts/resume-checkpoint.sh"

  cat > "$tmproot/fake-plugin/scripts/review-gate.sh" <<STUB
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
  case "\$1" in --sha) shift; printf '%s' "\$1" > "${tmproot}/captured-sha"; shift ;; *) shift ;; esac
done
exit 0
STUB
  chmod +x "$tmproot/fake-plugin/scripts/review-gate.sh"
  # Symlink resolve-story-file.sh so the gate block's story verification works
  ln -sf "$PLUGIN_ROOT/scripts/resolve-story-file.sh" "$tmproot/fake-plugin/scripts/resolve-story-file.sh"
}

# Helper: build and run the extracted gate-write snippet.
# Usage: _run_extracted_gate <skill_name> <story_key> <worktree_value> <tmproot> [<cwd>]
# Sets $status and $output via bats `run`.
_run_extracted_gate() {
  local skill_name="$1" story_key="$2" wt_val="$3" tmproot="$4" cwd="${5:-$tmproot}"
  local skill_md="$PLUGIN_ROOT/skills/$skill_name/SKILL.md"
  local gate_code
  gate_code="$(_extract_gate_block "$skill_md" "$story_key" "$wt_val")"
  [ -n "$gate_code" ] || { echo "gate block extraction produced empty output for $skill_name"; return 1; }
  local script="$tmproot/gate-test-${skill_name}.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'cd "%s" || exit 99\n' "$cwd"
    printf '[ -n "${PROJECT_PATH:-}" ] && export PROJECT_PATH || true\n'
    printf 'REPORT_PATH="/tmp/fake-report.md"\n'
    printf 'EXECUTION_EVIDENCE_PATH="/tmp/fake-evidence.json"\n'
    printf '%s\n' "$gate_code"
  } > "$script"
  chmod +x "$script"
  CLAUDE_PLUGIN_ROOT="$tmproot/fake-plugin" \
    run bash "$script"
}

# (a) {worktree} = valid fixture worktree → stub receives that worktree HEAD
@test "gate-write snippet with valid worktree records correct SHA (code-review)" {
  local _K="E900-S930" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_a_cr"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  local wt="$tmproot/wt"
  _seed_worktree_fixture "$wt" "$_K"
  _seed_project_root_for_stub "$tmproot" "$_K"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$wt" "$tmproot" "$tmproot/main"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
}

@test "gate-write snippet with valid worktree records correct SHA (run-all-reviews)" {
  local _K="E900-S932" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_a_rar"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  local wt="$tmproot/wt"
  _seed_project_root_for_stub "$tmproot" "$_K"
  _seed_worktree_fixture "$wt" "$_K"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-run-all-reviews" "$_K" "$wt" "$tmproot" "$tmproot/main"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
}

# (b) {worktree} with spaces → works
@test "gate-write snippet with worktree path containing spaces records correct SHA" {
  local _K="E900-S933" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_b"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  _seed_project_root_for_stub "$tmproot" "$_K"
  local wt="$tmproot/path with spaces/wt"
  _seed_worktree_fixture "$wt" "$_K"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$wt" "$tmproot" "$tmproot/main"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
}

# (c) {worktree} = missing dir → non-zero, no stub call
@test "gate-write snippet with missing worktree dir refuses" {
  local _K="E900-S934" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_c_miss"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$tmproot/does-not-exist" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [ ! -f "$tmproot/captured-sha" ]
  [[ "$output" == *"does not exist"* ]] || [[ "$output" == *"not a directory"* ]]
}

# (c) {worktree} = non-git dir → non-zero, no stub call
@test "gate-write snippet with non-git worktree dir refuses" {
  local _K="E900-S935" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_c_nongit"
  mkdir -p "$tmproot/main" "$tmproot/plain-dir"
  _init_git "$tmproot/main"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$tmproot/plain-dir" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [ ! -f "$tmproot/captured-sha" ]
  [[ "$output" == *"not a git"* ]] || [[ "$output" == *"not a work tree"* ]]
}

# (c) {worktree} = wrong branch → non-zero, no stub call
@test "gate-write snippet with wrong-branch worktree refuses" {
  local _K="E900-S936" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local _OTHER="E900-S999" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_c_branch"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  local wt="$tmproot/wt-other"
  _seed_worktree_fixture "$wt" "$_OTHER"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-code-review" "$_K" "$wt" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [ ! -f "$tmproot/captured-sha" ]
  [[ "$output" == *"branch"* ]] || [[ "$output" == *"does not match"* ]]
}

# (d) empty {worktree}, stale STORY_WORKTREE_PATH exported pointing at another repo,
#     and a matching worktree list entry → uses the worktree-list entry, NOT the stale export
@test "gate-write snippet ignores stale STORY_WORKTREE_PATH and uses worktree list (code-review)" {
  local _K="E900-S937" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_d_cr"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"

  # Create the CORRECT linked worktree
  git -C "$tmproot/main" worktree add "$tmproot/real-wt" -b "feat/${_K}-standalone" 2>/dev/null
  printf 'real\n' > "$tmproot/real-wt/file.txt"
  git -C "$tmproot/real-wt" add file.txt
  git -C "$tmproot/real-wt" commit -q -m "real wt commit"
  local expected_sha
  expected_sha="$(git -C "$tmproot/real-wt" rev-parse HEAD)"

  # Create a STALE repo that STORY_WORKTREE_PATH will point at
  mkdir -p "$tmproot/stale-repo"
  _init_git "$tmproot/stale-repo"
  local stale_sha
  stale_sha="$(git -C "$tmproot/stale-repo" rev-parse HEAD)"

  _setup_real_plugin_stubs "$tmproot"
  _seed_project_root_for_stub "$tmproot" "$_K"
  # Export the STALE STORY_WORKTREE_PATH — the block must ignore it
  export STORY_WORKTREE_PATH="$tmproot/stale-repo"
  PROJECT_PATH="$tmproot/main" \
    _run_extracted_gate_real "gaia-code-review" "$_K" "" "$tmproot" "$tmproot/main"
  unset STORY_WORKTREE_PATH
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  # Must be the REAL worktree HEAD, not the stale export
  [ "$captured" = "$expected_sha" ]
  [ "$captured" != "$stale_sha" ]
}

@test "gate-write snippet ignores stale STORY_WORKTREE_PATH and uses worktree list (run-all-reviews)" {
  local _K="E900-S938" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_d_rar"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"

  git -C "$tmproot/main" worktree add "$tmproot/real-wt" -b "feat/${_K}-standalone" 2>/dev/null
  printf 'real\n' > "$tmproot/real-wt/file.txt"
  git -C "$tmproot/real-wt" add file.txt
  git -C "$tmproot/real-wt" commit -q -m "real wt commit"
  local expected_sha
  expected_sha="$(git -C "$tmproot/real-wt" rev-parse HEAD)"

  mkdir -p "$tmproot/stale-repo"
  _init_git "$tmproot/stale-repo"
  local stale_sha
  stale_sha="$(git -C "$tmproot/stale-repo" rev-parse HEAD)"

  _seed_project_root_for_stub "$tmproot" "$_K"
  _setup_real_plugin_stubs "$tmproot"
  export STORY_WORKTREE_PATH="$tmproot/stale-repo"
  PROJECT_PATH="$tmproot/main" \
    _run_extracted_gate_real "gaia-run-all-reviews" "$_K" "" "$tmproot" "$tmproot/main"
  unset STORY_WORKTREE_PATH
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
  [ "$captured" != "$stale_sha" ]
}

# (e) empty {worktree}, no match → refuses, no stub call
@test "gate-write snippet with empty worktree and no match refuses (code-review)" {
  local _K="E900-S939" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_e_cr"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  _setup_real_plugin_stubs "$tmproot"
  PROJECT_PATH="$tmproot/main" \
    _run_extracted_gate_real "gaia-code-review" "$_K" "" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [ ! -f "$tmproot/captured-sha" ]
  [[ "$output" == *"cannot resolve story worktree"* ]] || [[ "$output" == *"pass --worktree"* ]]
}

@test "gate-write snippet with empty worktree and no match refuses (run-all-reviews)" {
  local _K="E900-S940" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_e_rar"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  _setup_real_plugin_stubs "$tmproot"
  PROJECT_PATH="$tmproot/main" \
    _run_extracted_gate_real "gaia-run-all-reviews" "$_K" "" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [ ! -f "$tmproot/captured-sha" ]
  [[ "$output" == *"cannot resolve story worktree"* ]] || [[ "$output" == *"pass --worktree"* ]]
}

# Every canonical gate-write block starts with _wt_arg="{worktree}"
@test "every canonical gate-write block has the _wt_arg worktree assignment line" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-security-review"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    local block
    block="$(awk '
      /[Gg]ate row update|Invoke.*review-gate.*update.*story|proof-of-execution contract/ { found = 1 }
      found && /^[[:space:]]*```bash$/ { in_b = 1; next }
      found && in_b && /^[[:space:]]*```$/ { exit }
      found && in_b { print }
    ' "$skill_md")"
    if ! grep -q '_wt_arg=.*{worktree}' <<< "$block"; then
      echo "FAIL: $skill gate block missing _wt_arg=\"{worktree}\" line"
      return 1
    fi
    if ! grep -q 'unset STORY_WORKTREE_PATH' <<< "$block"; then
      echo "FAIL: $skill gate block missing unset STORY_WORKTREE_PATH"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Prose: dispatch contract and input documentation
# ---------------------------------------------------------------------------

# (e) run-all-reviews dispatch contract includes --worktree
@test "run-all-reviews dispatch contract includes --worktree in args template" {
  local skill_md="${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  # The Skill-dispatch contract args template must include --worktree
  grep -q 'args:.*--worktree\|--worktree.*{code_tree}\|--worktree.*code.tree' "$skill_md"
}

# (e) each gate-writing skill documents --worktree
@test "each gate-writing skill documents --worktree as an accepted argument" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-security-review"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    if ! grep -q '\-\-worktree' "$skill_md"; then
      echo "FAIL: $skill does not document --worktree"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Deprecated security-review alias: extracted snippet tests
# ---------------------------------------------------------------------------

@test "gate-write snippet with valid worktree records correct SHA (security-review alias)" {
  local _K="E900-S941" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_a_sra"
  mkdir -p "$tmproot/main"
  _seed_project_root_for_stub "$tmproot" "$_K"
  _init_git "$tmproot/main"
  local wt="$tmproot/wt"
  _seed_worktree_fixture "$wt" "$_K"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  _setup_gate_stubs "$tmproot"
  _run_extracted_gate "gaia-security-review" "$_K" "$wt" "$tmproot" "$tmproot/main"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
}

@test "gate-write snippet ignores stale STORY_WORKTREE_PATH and uses worktree list (security-review alias)" {
  local _K="E900-S942" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_d_sra"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"

  git -C "$tmproot/main" worktree add "$tmproot/real-wt" -b "feat/${_K}-standalone" 2>/dev/null
  printf 'real\n' > "$tmproot/real-wt/file.txt"
  git -C "$tmproot/real-wt" add file.txt
  git -C "$tmproot/real-wt" commit -q -m "real wt commit"
  local expected_sha
  expected_sha="$(git -C "$tmproot/real-wt" rev-parse HEAD)"

  mkdir -p "$tmproot/stale-repo"
  _init_git "$tmproot/stale-repo"
  local stale_sha
  stale_sha="$(git -C "$tmproot/stale-repo" rev-parse HEAD)"
  _seed_project_root_for_stub "$tmproot" "$_K"

  _setup_real_plugin_stubs "$tmproot"
  export STORY_WORKTREE_PATH="$tmproot/stale-repo"
  PROJECT_PATH="$tmproot/main" \
    _run_extracted_gate_real "gaia-security-review" "$_K" "" "$tmproot" "$tmproot/main"
  unset STORY_WORKTREE_PATH
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
  [ "$captured" != "$stale_sha" ]
}

@test "gate-write snippet with empty worktree and no match refuses (security-review alias)" {
  local _K="E900-S943" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_e_sra"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"
  _setup_real_plugin_stubs "$tmproot"
  PROJECT_PATH="$tmproot/main" \
    _run_extracted_gate_real "gaia-security-review" "$_K" "" "$tmproot" "$tmproot/main"
  [ "$status" -ne 0 ]
  [ ! -f "$tmproot/captured-sha" ]
  [[ "$output" == *"cannot resolve story worktree"* ]] || [[ "$output" == *"pass --worktree"* ]]
}

# ---------------------------------------------------------------------------
# Explicitly empty --sha is refused by review-gate.sh update
# ---------------------------------------------------------------------------

@test "review-gate.sh update refuses --sha with explicitly empty value" {
  local _K="E900-S950" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local story
  story="$(_seed_story_4col "$PROJECT_PATH" "$_K" "abc1234")"
  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story "$_K" --gate "Code Review" --verdict PASSED \
    --sha "" --report-missing-reason "test fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"blank"* ]]
  # Row must NOT have changed
  grep '| Code Review | PASSED | cr.md | abc1234 |' "$story"
}

@test "review-gate.sh update still auto-binds HEAD when --sha is omitted" {
  local _K="E900-S951" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  _init_git "$PROJECT_PATH"
  local impl="${PROJECT_PATH}/docs/implementation-artifacts"
  mkdir -p "$impl"
  local story="${impl}/${_K}-test.md"
  cat > "$story" <<STORY
---
template: 'story'
key: "${_K}"
title: "Test"
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

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY
  git -C "$PROJECT_PATH" add . && git -C "$PROJECT_PATH" commit -q -m "add story"
  local expected_sha
  expected_sha="$(git -C "$PROJECT_PATH" rev-parse HEAD)"

  run bash "${PLUGIN_ROOT}/scripts/review-gate.sh" update \
    --story "$_K" --gate "Code Review" --verdict PASSED \
    --report-missing-reason "test fixture"
  [ "$status" -eq 0 ]
  grep "Code Review" "$story" | grep -q "$expected_sha"
}

# ---------------------------------------------------------------------------
# Standalone worktree resolution via checkpoint and find-worktree
# ---------------------------------------------------------------------------

@test "gate-write snippet resolves worktree from checkpoint via find-worktree (checkpoint wins over worktree-list)" {
  local _K="E900-S952" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_cp"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"

  # Worktree A: alphabetically FIRST path so worktree-list finds it first.
  # This is the WRONG one — the checkpoint does NOT point here.
  git -C "$tmproot/main" worktree add "$tmproot/aaa-wt-listed" -b "feat/${_K}-from-list" 2>/dev/null
  printf 'listed-content\n' > "$tmproot/aaa-wt-listed/file.txt"
  git -C "$tmproot/aaa-wt-listed" add file.txt
  git -C "$tmproot/aaa-wt-listed" commit -q -m "listed wt commit"
  local listed_sha
  listed_sha="$(git -C "$tmproot/aaa-wt-listed" rev-parse HEAD)"

  # Worktree B: alphabetically LAST path. The checkpoint points HERE.
  git -C "$tmproot/main" worktree add "$tmproot/zzz-wt-checkpoint" -b "feat/${_K}-from-checkpoint" 2>/dev/null
  printf 'checkpoint-content\n' > "$tmproot/zzz-wt-checkpoint/file.txt"
  git -C "$tmproot/zzz-wt-checkpoint" add file.txt
  git -C "$tmproot/zzz-wt-checkpoint" commit -q -m "checkpoint wt commit"
  local checkpoint_sha
  checkpoint_sha="$(git -C "$tmproot/zzz-wt-checkpoint" rev-parse HEAD)"

  # Checkpoint fixture points at zzz-wt-checkpoint
  local cp_root="$tmproot/main/.gaia/memory/checkpoints/gaia-dev-story"
  mkdir -p "$cp_root"
  cat > "$cp_root/latest-step-review.json" <<JSON
{"key_variables":{"story_key":"${_K}","worktree_path":"${tmproot}/zzz-wt-checkpoint"},"step":"review"}
JSON

  _setup_real_plugin_stubs "$tmproot"
  _seed_project_root_for_stub "$tmproot" "$_K"
  PROJECT_PATH="$tmproot/main" PROJECT_ROOT="$tmproot/main" \
    _run_extracted_gate_real "gaia-code-review" "$_K" "" "$tmproot" "$tmproot/main"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  # Must be the CHECKPOINT worktree's SHA, not the worktree-list one
  [ "$captured" = "$checkpoint_sha" ]
  [ "$captured" != "$listed_sha" ]
}

@test "gate-write snippet resolves worktree from non-git cwd via find-worktree" {
  local _K="E900-S953" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_nongit_cwd"
  mkdir -p "$tmproot/main"
  _init_git "$tmproot/main"

  git -C "$tmproot/main" worktree add "$tmproot/wt" -b "feat/${_K}-standalone" 2>/dev/null
  printf 'wt\n' > "$tmproot/wt/file.txt"
  git -C "$tmproot/wt" add file.txt
  git -C "$tmproot/wt" commit -q -m "wt commit"
  local expected_sha
  expected_sha="$(git -C "$tmproot/wt" rev-parse HEAD)"

  _seed_project_root_for_stub "$tmproot" "$_K"
  _setup_real_plugin_stubs "$tmproot"
  mkdir -p "$tmproot/nongit"
  PROJECT_PATH="$tmproot/main" \
    _run_extracted_gate_real "gaia-code-review" "$_K" "" "$tmproot" "$tmproot/nongit"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
}

# ---------------------------------------------------------------------------
# Gate-write snippet from wrong CWD records the story worktree SHA
# ---------------------------------------------------------------------------

@test "gate-write snippet from wrong CWD records story worktree SHA not CWD HEAD" {
  local _K="E900-S954" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_wrongcwd"
  _seed_project_root_for_stub "$tmproot" "$_K"

  # Story worktree
  local wt="$tmproot/wt"
  _seed_worktree_fixture "$wt" "$_K"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"

  # Different git repo (wrong CWD)
  mkdir -p "$tmproot/other-repo"
  _init_git "$tmproot/other-repo"
  local wrong_sha
  wrong_sha="$(git -C "$tmproot/other-repo" rev-parse HEAD)"

  _setup_gate_stubs "$tmproot"
  # Pass explicit worktree; run from the wrong repo
  _run_extracted_gate "gaia-code-review" "$_K" "$wt" "$tmproot" "$tmproot/other-repo"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
  [ "$captured" != "$wrong_sha" ]
}

# ---------------------------------------------------------------------------
# Every run-all-reviews gate-write block computes its own _wt_arg guard
# ---------------------------------------------------------------------------

@test "run-all-reviews every review-gate.sh update block has its own _wt_arg guard" {
  local skill_md="${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  # Count all fenced bash blocks that contain review-gate.sh update with --sha
  local blocks_with_sha
  blocks_with_sha="$(awk '
    /^[[:space:]]*```bash$/ { in_b = 1; buf = ""; next }
    /^[[:space:]]*```$/ { if (in_b && buf ~ /review-gate\.sh.*update/ && buf ~ /--sha/) count++; in_b = 0; next }
    in_b { buf = buf "\n" $0 }
    END { print count+0 }
  ' "$skill_md")"
  # Count those that also have _wt_arg
  local blocks_with_guard
  blocks_with_guard="$(awk '
    /^[[:space:]]*```bash$/ { in_b = 1; buf = ""; next }
    /^[[:space:]]*```$/ { if (in_b && buf ~ /review-gate\.sh.*update/ && buf ~ /--sha/ && buf ~ /_wt_arg/) count++; in_b = 0; next }
    in_b { buf = buf "\n" $0 }
    END { print count+0 }
  ' "$skill_md")"
  [ "$blocks_with_sha" -gt 0 ] || { echo "FAIL: no blocks with --sha found"; return 1; }
  if [ "$blocks_with_guard" -ne "$blocks_with_sha" ]; then
    echo "FAIL: $blocks_with_sha blocks use --sha but only $blocks_with_guard have _wt_arg guard"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Standalone resolution via find-worktree from non-git CWD, PROJECT_PATH unset
# ---------------------------------------------------------------------------

# Helper: set up a fake plugin root that delegates to the REAL plugin tree
# for everything (so find-worktree works) except review-gate.sh, which is
# a stub that records --sha.
_setup_real_plugin_stubs() {
  local tmproot="$1"
  local real_plugin="$PLUGIN_ROOT"
  local fake="$tmproot/fake-plugin"
  mkdir -p "$fake"
  # Symlink everything from the real plugin root
  ln -sf "$real_plugin/scripts" "$fake/scripts"
  ln -sf "$real_plugin/skills" "$fake/skills"
  ln -sf "$real_plugin/agents" "$fake/agents" 2>/dev/null || true
  ln -sf "$real_plugin/knowledge" "$fake/knowledge" 2>/dev/null || true
  # Override review-gate.sh with a stub that captures --sha
  mkdir -p "$fake/scripts-override"
  cat > "$fake/scripts-override/review-gate.sh" <<STUB
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
  case "\$1" in --sha) shift; printf '%s' "\$1" > "${tmproot}/captured-sha"; shift ;; *) shift ;; esac
done
exit 0
STUB
  chmod +x "$fake/scripts-override/review-gate.sh"
}

# Helper: run extracted gate with the real plugin tree (find-worktree works),
# but review-gate.sh calls go to the stub.
_run_extracted_gate_real() {
  local skill_name="$1" story_key="$2" wt_val="$3" tmproot="$4" cwd="${5:-$tmproot}"
  local skill_md="$PLUGIN_ROOT/skills/$skill_name/SKILL.md"
  local gate_code
  gate_code="$(_extract_gate_block "$skill_md" "$story_key" "$wt_val")"
  [ -n "$gate_code" ] || { echo "gate block extraction produced empty output for $skill_name"; return 1; }
  # Replace the review-gate.sh call with the stub path
  gate_code="$(printf '%s' "$gate_code" | sed "s|\${CLAUDE_PLUGIN_ROOT}/scripts/review-gate\.sh|${tmproot}/fake-plugin/scripts-override/review-gate.sh|g" | sed "s|bash scripts/review-gate\.sh|bash ${tmproot}/fake-plugin/scripts-override/review-gate.sh|g")"
  local script="$tmproot/gate-test-real-${skill_name}.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'cd "%s" || exit 99\n' "$cwd"
    printf '[ -n "${PROJECT_PATH:-}" ] && export PROJECT_PATH || true\n'
    printf 'REPORT_PATH="/tmp/fake-report.md"\n'
    printf 'EXECUTION_EVIDENCE_PATH="/tmp/fake-evidence.json"\n'
    printf '%s\n' "$gate_code"
  } > "$script"
  chmod +x "$script"
  CLAUDE_PLUGIN_ROOT="$tmproot/fake-plugin" \
    run bash "$script"
}

@test "gate-write snippet resolves worktree via find-worktree from non-git cwd with PROJECT_PATH unset" {
  local _K="E900-S960" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_findwt"
  # Create a git repo that will serve as the code repo
  mkdir -p "$tmproot/code-repo"
  _init_git "$tmproot/code-repo"
  # Add a linked worktree for the story
  git -C "$tmproot/code-repo" worktree add "$tmproot/wt" -b "feat/${_K}-findwt" 2>/dev/null
  printf 'wt\n' > "$tmproot/wt/file.txt"
  git -C "$tmproot/wt" add file.txt
  git -C "$tmproot/wt" commit -q -m "wt commit"
  local expected_sha
  expected_sha="$(git -C "$tmproot/wt" rev-parse HEAD)"

  _setup_real_plugin_stubs "$tmproot"
  _seed_project_root_for_stub "$tmproot" "$_K"

  # Create a config fixture so find-worktree's config-path fallback resolves
  # the code repo when PROJECT_PATH is unset.
  mkdir -p "$tmproot/nongit/.gaia/config"
  cat > "$tmproot/nongit/.gaia/config/project-config.yaml" <<YAML
project:
  name: test
YAML
  # The resolve-config.sh used by find-worktree needs CLAUDE_SKILL_DIR or
  # PROJECT_ROOT to find config. Set PROJECT_ROOT to the non-git dir so
  # find-worktree resolves code-repo from config.
  # Create config at BOTH .gaia/config/ (for _discover_shared_config) and
  # skill/config/ (for resolve-config.sh CLAUDE_SKILL_DIR fallback).
  mkdir -p "$tmproot/nongit/.gaia/config" "$tmproot/nongit/skill/config" "$tmproot/nongit/_memory/checkpoints"
  local _cfg_body
  _cfg_body="$(cat <<YAML
project_root: ${tmproot}/nongit
project_path: ${tmproot}/code-repo
memory_path: ${tmproot}/nongit/_memory
checkpoint_path: ${tmproot}/nongit/_memory/checkpoints
installed_path: ${tmproot}/nongit/_gaia
framework_version: 1.227.0
date: 2026-11-18
YAML
)"
  printf '%s\n' "$_cfg_body" > "$tmproot/nongit/.gaia/config/project-config.yaml"
  printf '%s\n' "$_cfg_body" > "$tmproot/nongit/skill/config/project-config.yaml"

  # Run from a NON-git directory with PROJECT_PATH UNSET.
  # Build the script inline so we can pass the right env vars directly.
  unset PROJECT_PATH
  local skill_md="$PLUGIN_ROOT/skills/gaia-code-review/SKILL.md"
  local gate_code
  gate_code="$(_extract_gate_block "$skill_md" "$_K" "")"
  gate_code="$(printf '%s' "$gate_code" | sed "s|\${CLAUDE_PLUGIN_ROOT}/scripts/review-gate\.sh|${tmproot}/fake-plugin/scripts-override/review-gate.sh|g")"
  local script="$tmproot/gate-findwt.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'unset PROJECT_PATH PROJECT_CONFIG CLAUDE_PROJECT_ROOT\n'
    printf 'cd "%s" || exit 99\n' "$tmproot/nongit"
    printf 'REPORT_PATH="/tmp/fake-report.md"\n'
    printf 'EXECUTION_EVIDENCE_PATH="/tmp/fake-evidence.json"\n'
    printf '%s\n' "$gate_code"
  } > "$script"
  chmod +x "$script"
  CLAUDE_PLUGIN_ROOT="$tmproot/fake-plugin" \
  CLAUDE_SKILL_DIR="$tmproot/nongit/skill" \
  PROJECT_ROOT="$tmproot/nongit" \
    run bash "$script"
  [ "$status" -eq 0 ]
  [ -f "$tmproot/captured-sha" ]
  local captured
  captured="$(cat "$tmproot/captured-sha")"
  [ "$captured" = "$expected_sha" ]
}

@test "gate-write snippet via find-worktree refuses when no match from non-git cwd" {
  local _K="E900-S961" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/gwb_findwt_none"
  # Create a git repo with NO matching worktree
  mkdir -p "$tmproot/code-repo"
  _init_git "$tmproot/code-repo"

  _setup_real_plugin_stubs "$tmproot"

  mkdir -p "$tmproot/nongit/.gaia/config" "$tmproot/nongit/skill/config" "$tmproot/nongit/_memory/checkpoints"
  local _cfg_body2
  _cfg_body2="$(cat <<YAML
project_root: ${tmproot}/nongit
project_path: ${tmproot}/code-repo
memory_path: ${tmproot}/nongit/_memory
checkpoint_path: ${tmproot}/nongit/_memory/checkpoints
installed_path: ${tmproot}/nongit/_gaia
framework_version: 1.227.0
date: 2026-11-18
YAML
)"
  printf '%s\n' "$_cfg_body2" > "$tmproot/nongit/.gaia/config/project-config.yaml"
  printf '%s\n' "$_cfg_body2" > "$tmproot/nongit/skill/config/project-config.yaml"

  unset PROJECT_PATH
  local skill_md="$PLUGIN_ROOT/skills/gaia-code-review/SKILL.md"
  local gate_code
  gate_code="$(_extract_gate_block "$skill_md" "$_K" "")"
  gate_code="$(printf '%s' "$gate_code" | sed "s|\${CLAUDE_PLUGIN_ROOT}/scripts/review-gate\.sh|${tmproot}/fake-plugin/scripts-override/review-gate.sh|g")"
  local script="$tmproot/gate-findwt-none.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'unset PROJECT_PATH PROJECT_CONFIG CLAUDE_PROJECT_ROOT\n'
    printf 'cd "%s" || exit 99\n' "$tmproot/nongit"
    printf 'REPORT_PATH="/tmp/fake-report.md"\n'
    printf 'EXECUTION_EVIDENCE_PATH="/tmp/fake-evidence.json"\n'
    printf '%s\n' "$gate_code"
  } > "$script"
  chmod +x "$script"
  CLAUDE_PLUGIN_ROOT="$tmproot/fake-plugin" \
  CLAUDE_SKILL_DIR="$tmproot/nongit/skill" \
  PROJECT_ROOT="$tmproot/nongit" \
    run bash "$script"
  [ "$status" -ne 0 ]
  [ ! -f "$tmproot/captured-sha" ]
  [[ "$output" == *"cannot resolve story worktree"* ]] || [[ "$output" == *"pass --worktree"* ]]
}

# ---------------------------------------------------------------------------
# Project-root derivation: gate writes resolve PROJECT_ROOT from the worktree
# ---------------------------------------------------------------------------

# Helper: seed a full fixture project with a story file, config, and a linked
# story worktree. The project root is at $1, the story key is $2.
# Returns (via stdout): the linked worktree path.
_seed_project_fixture() {
  local root="$1" key="$2"
  mkdir -p "$root/.gaia/config" "$root/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${key}-slug"
  cat > "$root/.gaia/config/project-config.yaml" <<YAML
project:
  name: fixture
YAML
  cat > "$root/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${key}-slug/story.md" <<STORY
---
template: 'story'
key: "${key}"
title: "Fixture Story"
status: review
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | absent |
| QA Tests | UNVERIFIED | — | absent |
| Security Review | UNVERIFIED | — | absent |
| Test Automation | UNVERIFIED | — | absent |
| Test Review | UNVERIFIED | — | absent |
| Performance Review | UNVERIFIED | — | absent |

> Story moves to \`done\` only when ALL reviews show PASSED.
STORY
  # Create a code repo inside the project root
  mkdir -p "$root/code-repo"
  git init -q "$root/code-repo"
  git -C "$root/code-repo" config user.email "test@test.local"
  git -C "$root/code-repo" config user.name "Test"
  printf 'init\n' > "$root/code-repo/f.txt"
  git -C "$root/code-repo" add .
  git -C "$root/code-repo" commit -q -m "init"
  # Linked worktree under .gaia-worktrees (the documented layout)
  local wt="$root/.gaia-worktrees/${key}"
  git -C "$root/code-repo" worktree add "$wt" -b "feat/${key}-fixture" >/dev/null 2>&1
  printf 'wt\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -q -m "worktree commit"
  printf '%s\n' "$wt"
}

# Helper: run extracted gate block with the REAL review-gate.sh (no stub).
_run_extracted_gate_live() {
  local skill_name="$1" story_key="$2" wt_val="$3" cwd="$4"
  local skill_md="$PLUGIN_ROOT/skills/$skill_name/SKILL.md"
  local gate_code
  gate_code="$(_extract_gate_block "$skill_md" "$story_key" "$wt_val")"
  [ -n "$gate_code" ] || { echo "gate block extraction produced empty output for $skill_name"; return 1; }
  local tmpscript
  tmpscript="${TEST_TMP}/gate-live-${skill_name}-$$.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'cd "%s" || exit 99\n' "$cwd"
    printf '[ -n "${PROJECT_PATH:-}" ] && export PROJECT_PATH || true\n'
    printf 'export REVIEW_GATE_PROOF_OF_EXECUTION=off\n'
    printf 'REPORT_PATH="/tmp/fake-report.md"\n'
    printf 'EXECUTION_EVIDENCE_PATH="/tmp/fake-evidence.json"\n'
    printf '%s\n' "$gate_code"
  } > "$tmpscript"
  chmod +x "$tmpscript"
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    run bash "$tmpscript"
}

# (i) cwd=project root, PROJECT_PATH unset, {worktree}=worktree -> row written
@test "gate write with real review-gate.sh: cwd=project root, PROJECT_PATH unset, explicit worktree" {
  local _K="E900-S980" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_i"
  local wt
  wt="$(_seed_project_fixture "$tmproot/project" "$_K")"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  unset PROJECT_PATH
  _run_extracted_gate_live "gaia-code-review" "$_K" "$wt" "$tmproot/project"
  [ "$status" -eq 0 ]
  local story="$tmproot/project/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${_K}-slug/story.md"
  grep 'Code Review' "$story" | grep -q "$expected_sha"
}

# (ii) cwd=project root, PROJECT_PATH=worktree (documented dev-story path)
@test "gate write with real review-gate.sh: cwd=project root, PROJECT_PATH=worktree" {
  local _K="E900-S981" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_ii"
  local wt
  wt="$(_seed_project_fixture "$tmproot/project" "$_K")"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  export PROJECT_PATH="$wt"
  _run_extracted_gate_live "gaia-code-review" "$_K" "$wt" "$tmproot/project"
  unset PROJECT_PATH
  [ "$status" -eq 0 ]
  local story="$tmproot/project/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${_K}-slug/story.md"
  grep 'Code Review' "$story" | grep -q "$expected_sha"
}

# (iii) cwd=worktree
@test "gate write with real review-gate.sh: cwd=worktree" {
  local _K="E900-S982" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_iii"
  local wt
  wt="$(_seed_project_fixture "$tmproot/project" "$_K")"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  unset PROJECT_PATH
  _run_extracted_gate_live "gaia-code-review" "$_K" "$wt" "$wt"
  [ "$status" -eq 0 ]
  local story="$tmproot/project/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${_K}-slug/story.md"
  grep 'Code Review' "$story" | grep -q "$expected_sha"
}

# (iv) worktree under WRONG project -> refused
@test "gate write with real review-gate.sh: worktree under wrong project is refused" {
  local _K="E900-S983" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_iv"
  # Create a wrong project with .gaia/config but no story for _K
  mkdir -p "$tmproot/wrong-project/.gaia/config" "$tmproot/wrong-project/code-repo"
  cat > "$tmproot/wrong-project/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: wrong
YAML
  git init -q "$tmproot/wrong-project/code-repo"
  git -C "$tmproot/wrong-project/code-repo" config user.email "t@t"
  git -C "$tmproot/wrong-project/code-repo" config user.name T
  printf 'x\n' > "$tmproot/wrong-project/code-repo/f"
  git -C "$tmproot/wrong-project/code-repo" add .
  git -C "$tmproot/wrong-project/code-repo" commit -q -m init
  local wrong_wt="$tmproot/wrong-project/.gaia-worktrees/${_K}"
  git -C "$tmproot/wrong-project/code-repo" worktree add "$wrong_wt" -b "feat/${_K}-wrong" 2>/dev/null
  printf 'wt\n' > "$wrong_wt/w.txt"
  git -C "$wrong_wt" add .
  git -C "$wrong_wt" commit -q -m wt
  unset PROJECT_PATH
  _run_extracted_gate_live "gaia-code-review" "$_K" "$wrong_wt" "$tmproot/wrong-project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong project"* ]] || [[ "$output" == *"not found"* ]]
}

# (v) no .gaia/config above worktree -> refused
@test "gate write with real review-gate.sh: no .gaia/config above worktree is refused" {
  local _K="E900-S985" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_v"
  _seed_worktree_fixture "$tmproot/bare-wt" "$_K"
  unset PROJECT_PATH
  _run_extracted_gate_live "gaia-code-review" "$_K" "$tmproot/bare-wt" "$tmproot"
  [ "$status" -ne 0 ]
  [[ "$output" == *".gaia/config"* ]] || [[ "$output" == *"no .gaia"* ]] || [[ "$output" == *"refusing"* ]]
}

# (ii) with run-all-reviews block
@test "gate write with real review-gate.sh: run-all-reviews block cwd=project root, PROJECT_PATH=worktree" {
  local _K="E900-S986" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_rar"
  local wt
  wt="$(_seed_project_fixture "$tmproot/project" "$_K")"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  export PROJECT_PATH="$wt"
  _run_extracted_gate_live "gaia-run-all-reviews" "$_K" "$wt" "$tmproot/project"
  unset PROJECT_PATH
  [ "$status" -eq 0 ]
}

# Every canonical gate block passes PROJECT_ROOT on each review-gate.sh call
@test "every canonical gate block passes PROJECT_ROOT on each review-gate.sh call" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-security-review"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    # Extract ALL bash blocks that call review-gate.sh update
    local blocks
    blocks="$(awk '
      /^[[:space:]]*```bash$/ { in_b = 1; buf = ""; next }
      /^[[:space:]]*```$/ { if (in_b && buf ~ /review-gate\.sh.*update/) print buf; in_b = 0; next }
      in_b { buf = buf "\n" $0 }
    ' "$skill_md")"
    [ -n "$blocks" ] || continue
    # Each review-gate.sh update line must have PROJECT_ROOT= prefix
    local gate_lines
    gate_lines="$(printf '%s' "$blocks" | grep 'review-gate\.sh.*update')"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if ! grep -q 'PROJECT_ROOT=' <<< "$line"; then
        echo "FAIL: $skill: review-gate.sh update missing PROJECT_ROOT= prefix: $(echo "$line" | head -c 120)"
        return 1
      fi
    done <<< "$gate_lines"
  done
}

# ---------------------------------------------------------------------------
# Walk-up canonicalisation: relative paths and iteration cap
# ---------------------------------------------------------------------------

@test "gate write with relative worktree path resolves and writes the row" {
  local _K="E900-S990" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_rel"
  local wt
  wt="$(_seed_project_fixture "$tmproot/project" "$_K")"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  # Compute the relative path from the project root to the worktree
  local rel_wt
  rel_wt="$(python3 -c "import os; print(os.path.relpath('$wt', '$tmproot/project'))")"
  unset PROJECT_PATH
  _run_extracted_gate_live "gaia-code-review" "$_K" "$rel_wt" "$tmproot/project"
  [ "$status" -eq 0 ]
  local story="$tmproot/project/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${_K}-slug/story.md"
  grep 'Code Review' "$story" | grep -q "$expected_sha"
}

@test "gate write with relative worktree from cwd with another .gaia/config uses the worktree's project" {
  local _K="E900-S991" # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local tmproot="${TEST_TMP}/proot_relother"
  local wt
  wt="$(_seed_project_fixture "$tmproot/real-project" "$_K")"
  local expected_sha
  expected_sha="$(git -C "$wt" rev-parse HEAD)"
  mkdir -p "$tmproot/other-project/.gaia/config"
  cat > "$tmproot/other-project/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: other
YAML
  local rel_wt
  rel_wt="$(python3 -c "import os; print(os.path.relpath('$wt', '$tmproot/other-project'))")"
  unset PROJECT_PATH
  # CWD has its own .gaia/config — the canonicalised walk-up must still
  # find real-project (not stop at CWD).
  _run_extracted_gate_live "gaia-code-review" "$_K" "$rel_wt" "$tmproot/other-project"
  [ "$status" -eq 0 ]
  local story="$tmproot/real-project/.gaia/artifacts/implementation-artifacts/epic-E900-fixture/${_K}-slug/story.md"
  grep 'Code Review' "$story" | grep -q "$expected_sha"
}

@test "every canonical gate block canonicalises the worktree path before walking up" {
  local -a gate_skills=(
    "gaia-code-review"
    "gaia-performance-review"
    "gaia-qa-tests"
    "gaia-review-security"
    "gaia-security-review"
    "gaia-test-review"
    "gaia-review-perf"
    "gaia-run-all-reviews"
  )
  for skill in "${gate_skills[@]}"; do
    local skill_md="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
    local blocks
    blocks="$(awk '
      /^[[:space:]]*```bash$/ { in_b = 1; buf = ""; next }
      /^[[:space:]]*```$/ { if (in_b && buf ~ /review-gate\.sh.*update/) print buf; in_b = 0; next }
      in_b { buf = buf "\n" $0 }
    ' "$skill_md")"
    [ -n "$blocks" ] || continue
    # Each block that walks up must canonicalise first (cd + pwd -P)
    if ! grep -q 'pwd -P' <<< "$blocks"; then
      echo "FAIL: $skill gate block missing pwd -P canonicalisation"
      return 1
    fi
  done
}
