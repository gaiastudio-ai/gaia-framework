#!/usr/bin/env bats
# conditional-check-hints.bats — TC-DSH-18 regression guard for E55-S7 (AC1-AC4)
#
# Story: E55-S7 (Conditional check advisory hints (Step 6b))
# ADR: ADR-073 (/gaia-dev-story Planning-Gate Halt + Val Auto-Validation Loop)
# PRD: FR-DSH-9 (advisory hints for API/schema/blast-radius), NFR-DSH-5 (single-line gate logs)
#
# Validates:
#   AC1 — schema/migration paths trigger a single advisory line.
#   AC2 — API route paths trigger a single advisory line.
#   AC3 — staged file count >= BLAST_RADIUS_THRESHOLD (default 10) triggers a
#         single blast-radius advisory line.
#   AC4 — Step 6b NEVER halts (exit code is always 0).
#
#   Boundary — 9 staged files DO NOT trigger the blast-radius advisory.
#   No-match — a single non-matching path emits no advisories, exit 0.
#   Multi-match — all three categories matching simultaneously emit all three
#                 advisory lines, still exit 0.
#   Cap — when more than 10 files match the same category, the advisory line
#         lists exactly the first 10 followed by `,...`.
#
#   SKILL.md — Step 6b region present, bounded by canonical begin/end markers,
#              invokes conditional-check-hints.sh, sits between Step 6 (TDD
#              Green) and Step 7 (TDD Refactor), and documents the
#              non-halting contract.
#
# Usage:
#   bats tests/skills/conditional-check-hints.bats
#
# Dependencies: bats-core 1.10+, git (used by the helper).

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/SKILL.md"
  HINTS_SCRIPT="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/conditional-check-hints.sh"

  REGION_BEGIN='<!-- step 6b begin -->'
  REGION_END='<!-- step 6b end -->'

  # Per-test working dir for fixture git repos.
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

extract_step6b_region() {
  awk -v b="$REGION_BEGIN" -v e="$REGION_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# Build a fixture git repo with the given file paths staged. Each path is
# created (with a tiny placeholder body) and `git add`-ed. The repo is
# initialized in the test tmpdir; cwd is left at the repo so the helper
# script's `git diff --cached --name-only` runs against it.
make_staged_repo() {
  local repo="$TEST_TMPDIR/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    for path in "$@"; do
      mkdir -p "$(dirname "$path")"
      printf 'placeholder\n' > "$path"
      git add "$path"
    done
  )
  printf '%s\n' "$repo"
}

# ---------- Preconditions ----------

@test "SKILL.md exists at gaia-dev-story skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "conditional-check-hints.sh helper is shipped and executable" {
  [ -x "$HINTS_SCRIPT" ]
}

# ---------- SKILL.md Step 6b region ----------

@test "Step 6b region markers are present in SKILL.md" {
  grep -qF "$REGION_BEGIN" "$SKILL_FILE"
  grep -qF "$REGION_END" "$SKILL_FILE"
}

@test "Step 6b region invokes conditional-check-hints.sh" {
  region="$(extract_step6b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF "conditional-check-hints.sh"
}

@test "Step 6b region documents the non-halting contract (advisory only)" {
  region="$(extract_step6b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "advisory|informational"
  # Must explicitly state it does not halt.
  echo "$region" | grep -qiE "MUST NOT halt|never halt|does not halt|do not halt|no halt"
}

@test "Step 6b sits between Step 6 (TDD Green) and Step 7 (TDD Refactor)" {
  step6_line=$(grep -nF "### Step 6 -- TDD Green Phase" "$SKILL_FILE" | head -1 | cut -d: -f1)
  s6b_line=$(grep -nF "$REGION_BEGIN" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step7_line=$(grep -nF "### Step 7 -- TDD Refactor Phase" "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step6_line" ]
  [ -n "$s6b_line" ]
  [ -n "$step7_line" ]
  [ "$s6b_line" -gt "$step6_line" ]
  [ "$s6b_line" -lt "$step7_line" ]
}

# ---------- AC1 — schema/migration advisory ----------

@test "AC1: migration path triggers schema/migration advisory and exits 0" {
  repo="$(make_staged_repo "db/migrations/2026_04_28_add_users.sql")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: schema/migration changes detected"
  echo "$output" | grep -qF "db/migrations/2026_04_28_add_users.sql"
  # Single advisory line for this category.
  count=$(echo "$output" | grep -cE "advisory: schema/migration" || true)
  [ "$count" -eq 1 ]
}

# ---------- AC2 — API route advisory ----------

@test "AC2: api route path triggers contract-test advisory and exits 0" {
  repo="$(make_staged_repo "src/routes/api/v1/users.ts")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: api-route changes detected"
  echo "$output" | grep -qF "src/routes/api/v1/users.ts"
  count=$(echo "$output" | grep -cE "advisory: api-route" || true)
  [ "$count" -eq 1 ]
}

# ---------- AC3 — blast-radius advisory ----------

@test "AC3: staged file count >= 10 triggers blast-radius advisory and exits 0" {
  files=()
  for i in 1 2 3 4 5 6 7 8 9 10; do
    files+=("docs/note-$i.md")
  done
  repo="$(make_staged_repo "${files[@]}")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: large blast radius"
  echo "$output" | grep -qE "count=10"
}

# ---------- Boundary — 9 files does NOT trigger ----------

@test "Boundary: 9 staged files DOES NOT trigger blast-radius advisory" {
  files=()
  for i in 1 2 3 4 5 6 7 8 9; do
    files+=("docs/note-$i.md")
  done
  repo="$(make_staged_repo "${files[@]}")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  # Positive assertion: blast-radius advisory must be absent at N=9.
  ! echo "$output" | grep -qE "advisory: large blast radius"
}

# ---------- No-match — non-matching path emits nothing ----------

@test "No-match: a single non-matching staged file emits no advisories, exit 0" {
  repo="$(make_staged_repo "README.md")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  # No advisory lines whatsoever.
  ! echo "$output" | grep -qE "^advisory:"
}

# ---------- Multi-match — all three advisories simultaneously ----------

@test "Multi-match: api+schema+10-file blast emits all three advisories, exit 0" {
  files=("src/routes/api/v1/users.ts" "db/migrations/2026_04_28_add_users.sql")
  for i in 1 2 3 4 5 6 7 8; do
    files+=("docs/note-$i.md")
  done
  repo="$(make_staged_repo "${files[@]}")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: api-route"
  echo "$output" | grep -qE "advisory: schema/migration"
  echo "$output" | grep -qE "advisory: large blast radius"
  echo "$output" | grep -qE "count=10"
}

# ---------- Cap — file list capped at first 10 with ',...' ----------

@test "Cap: more than 10 matching api files emits exactly 10 paths plus ',...'" {
  files=()
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    files+=("src/routes/api/v$i.ts")
  done
  repo="$(make_staged_repo "${files[@]}")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  api_line=$(echo "$output" | grep -E "advisory: api-route")
  [ -n "$api_line" ]
  # The line must end with ',...' indicating truncation.
  echo "$api_line" | grep -qE ',\.\.\.'
  # Count comma separators in the files= field; with cap=10 there are 9 commas
  # between the 10 paths plus 1 trailing ',...' separator, totalling 10.
  files_field="${api_line#*files=}"
  comma_count=$(printf '%s' "$files_field" | tr -cd ',' | wc -c | tr -d ' ')
  [ "$comma_count" -eq 10 ]
}

# ---------- Threshold — BLAST_RADIUS_THRESHOLD env override ----------

@test "BLAST_RADIUS_THRESHOLD=5 lowers the blast-radius trigger" {
  files=()
  for i in 1 2 3 4 5; do
    files+=("docs/note-$i.md")
  done
  repo="$(make_staged_repo "${files[@]}")"
  run bash -c "cd '$repo' && BLAST_RADIUS_THRESHOLD=5 '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: large blast radius.*count=5"
}

# ---------- AC4 — never halts ----------

@test "AC4: helper exits 0 even when all three advisories fire" {
  files=("src/routes/api/v1/users.ts" "db/migrations/2026_04_28_add_users.sql")
  for i in 1 2 3 4 5 6 7 8; do
    files+=("docs/note-$i.md")
  done
  repo="$(make_staged_repo "${files[@]}")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
}

@test "AC4: helper exits 0 with no staged changes (empty diff)" {
  repo="$TEST_TMPDIR/empty-repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
  )
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
}

# ---------- NFR-DSH-5 — step6b_gate stderr line ----------
#
# Per SKILL.md Step 6b: emit a single-line gate log to stderr in the form
#   step6b_gate: advisories={count}
# where {count} is 0, 1, 2, or 3. The line MUST be on stderr (not stdout) so it
# does not pollute the advisory stream consumed by the agent.

@test "NFR-DSH-5: step6b_gate stderr line emitted with advisories=0 on empty diff" {
  repo="$TEST_TMPDIR/empty-repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
  )
  err_file="$TEST_TMPDIR/err.log"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT' 2> '$err_file'"
  [ "$status" -eq 0 ]
  err="$(cat "$err_file")"
  echo "$err" | grep -qE '^step6b_gate: advisories=0$'
  # And the gate log must NOT appear on stdout.
  ! echo "$output" | grep -qE 'step6b_gate:'
}

@test "NFR-DSH-5: step6b_gate=1 when only api-route advisory fires" {
  repo="$(make_staged_repo "src/routes/api/v1/users.ts")"
  err_file="$TEST_TMPDIR/err.log"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT' 2> '$err_file'"
  [ "$status" -eq 0 ]
  err="$(cat "$err_file")"
  echo "$err" | grep -qE '^step6b_gate: advisories=1$'
}

@test "NFR-DSH-5: step6b_gate=2 when api-route + schema/migration advisories fire" {
  repo="$(make_staged_repo "src/routes/api/v1/users.ts" "db/migrations/2026_04_28_add_users.sql")"
  err_file="$TEST_TMPDIR/err.log"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT' 2> '$err_file'"
  [ "$status" -eq 0 ]
  err="$(cat "$err_file")"
  echo "$err" | grep -qE '^step6b_gate: advisories=2$'
}

@test "NFR-DSH-5: step6b_gate=3 when all three advisories fire simultaneously" {
  files=("src/routes/api/v1/users.ts" "db/migrations/2026_04_28_add_users.sql")
  for i in 1 2 3 4 5 6 7 8; do
    files+=("docs/note-$i.md")
  done
  repo="$(make_staged_repo "${files[@]}")"
  err_file="$TEST_TMPDIR/err.log"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT' 2> '$err_file'"
  [ "$status" -eq 0 ]
  err="$(cat "$err_file")"
  echo "$err" | grep -qE '^step6b_gate: advisories=3$'
}

# ---------- Pattern 2 — schema-by-filename branch ----------
#
# The schema/migration pattern has a second arm: a basename containing `schema`
# with extension `.ts` / `.py` / `.sql`, even when the path is OUTSIDE a
# `migrations/` directory (e.g., `db/schema.ts`, `app/schema.py`,
# `models/schema.sql`). All three must trigger the schema/migration advisory.

@test "Pattern 2 schema-by-filename: db/schema.ts triggers schema/migration advisory" {
  repo="$(make_staged_repo "db/schema.ts")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: schema/migration changes detected"
  echo "$output" | grep -qF "db/schema.ts"
}

@test "Pattern 2 schema-by-filename: app/schema.py triggers schema/migration advisory" {
  repo="$(make_staged_repo "app/schema.py")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: schema/migration changes detected"
  echo "$output" | grep -qF "app/schema.py"
}

@test "Pattern 2 schema-by-filename: models/schema.sql (outside migrations/) triggers advisory" {
  repo="$(make_staged_repo "models/schema.sql")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: schema/migration changes detected"
  echo "$output" | grep -qF "models/schema.sql"
}

# ---------- Pattern 1 — multi-extension api-route coverage ----------
#
# The api-route pattern matches `.ts`, `.py`, and `.go` extensions. The base
# AC2 test covers `.ts`; these two cover the `.py` and `.go` arms.

@test "Pattern 1 api-route .py: app/routes/users.py triggers api-route advisory" {
  repo="$(make_staged_repo "app/routes/users.py")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: api-route changes detected"
  echo "$output" | grep -qF "app/routes/users.py"
}

@test "Pattern 1 api-route .go: internal/api/users.go triggers api-route advisory" {
  repo="$(make_staged_repo "internal/api/users.go")"
  run bash -c "cd '$repo' && '$HINTS_SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "advisory: api-route changes detected"
  echo "$output" | grep -qF "internal/api/users.go"
}
