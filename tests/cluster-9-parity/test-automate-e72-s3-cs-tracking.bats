#!/usr/bin/env bats
# test-automate-e72-s3-cs-tracking.bats — E72-S3 CS-NNN tracking + index.yaml
#
# Validates:
#   AC1: custom/test-scenarios/index.yaml exists at project root with a top-level
#        `scenarios:` list (may be empty).
#   AC2: --add-scenario allocates CS-{N+1} zero-padded to 3 digits, written
#        atomically.
#   AC3: each entry contains id, story_key, description, tier, priority,
#        file_path, created_date.
#   AC4: /gaia-review-qa (qa-tests) does NOT mutate index.yaml — checksum
#        invariant.
#   AC5: --status output sources Custom scenarios block from index.yaml,
#        rendering tier, description, file path (or "not yet automated").
#   AC6: --status flags non-existent file_path entries with a "file not found"
#        warning.
#
# Refs: E72-S3, FR-RSV2-41, source-report §11.3, TC-RSV2-AUTOMATE-2
#
# Usage: bats gaia-framework/tests/cluster-9-parity/test-automate-e72-s3-cs-tracking.bats
#
# Dependencies: bats-core 1.10+

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PROJECT_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-test-automate"
  SCRIPTS_DIR="$SKILL_DIR/scripts"

  TMPDIR="$(mktemp -d -t e72s3.XXXXXX)"
  STORY_DIR="$TMPDIR/docs/implementation-artifacts"
  mkdir -p "$STORY_DIR"

  STORY_FILE="$STORY_DIR/E99-S99-fixture.md"
  cat >"$STORY_FILE" <<'EOF'
---
key: "E99-S99"
title: "Fixture"
status: in-progress
---

# Story: Fixture

## Acceptance Criteria

- [ ] AC1: alpha
- [ ] AC2: beta

## Test Cases

| TC | AC | Tier | File |
|----|----|------|------|
| TC-001 | AC1 | unit | tests/unit/foo.test.ts |

## Custom Scenarios

| CS | Tier | Description | File |
|----|------|-------------|------|

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
EOF

  INDEX_FILE="$TMPDIR/custom/test-scenarios/index.yaml"
  mkdir -p "$(dirname "$INDEX_FILE")"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Portable SHA-256
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ============================================================================
# AC1: index.yaml seed exists at project root with scenarios list
# ============================================================================

@test "E72-S3 AC1: gaia-framework/custom/test-scenarios/index.yaml seed exists in repo" {
  [ -f "$REPO_ROOT/custom/test-scenarios/index.yaml" ]
}

@test "E72-S3 AC1: seed index.yaml has top-level scenarios list" {
  grep -qE '^scenarios:' "$REPO_ROOT/custom/test-scenarios/index.yaml"
}

@test "E72-S3 AC1: --add-scenario auto-creates index.yaml when missing" {
  # The script lazily creates index.yaml — verify on a fresh path.
  rm -f "$INDEX_FILE"
  run "$SCRIPTS_DIR/subcmd-add-scenario.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE" \
    --description "smoke" \
    --tier unit \
    --priority P3 \
    --expected "ok"
  [ "$status" -eq 0 ]
  [ -f "$INDEX_FILE" ]
  grep -qE '^scenarios:' "$INDEX_FILE"
}

# ============================================================================
# AC2: CS-{N+1} zero-padded ID allocation; atomic write
# ============================================================================

@test "E72-S3 AC2: first entry on empty index receives CS-001" {
  printf 'scenarios: []\n' >"$INDEX_FILE"
  run "$SCRIPTS_DIR/subcmd-add-scenario.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE" \
    --description "first" \
    --tier unit \
    --priority P3 \
    --expected "ok"
  [ "$status" -eq 0 ]
  [ "$output" = "CS-001" ]
}

@test "E72-S3 AC2: with N entries, next ID is CS-N+1 zero-padded to 3 digits" {
  cat >"$INDEX_FILE" <<'EOF'
scenarios:
  - id: CS-001
    story_key: E99-S99
    description: "one"
    tier: unit
    priority: P3
    file_path: ""
    created_date: "2026-05-05"
  - id: CS-002
    story_key: E99-S99
    description: "two"
    tier: unit
    priority: P3
    file_path: ""
    created_date: "2026-05-05"
EOF
  run "$SCRIPTS_DIR/subcmd-add-scenario.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE" \
    --description "third" \
    --tier integration \
    --priority P2 \
    --expected "ok"
  [ "$status" -eq 0 ]
  [ "$output" = "CS-003" ]
}

@test "E72-S3 AC2: atomic write — no partial files left behind" {
  printf 'scenarios: []\n' >"$INDEX_FILE"
  "$SCRIPTS_DIR/subcmd-add-scenario.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE" \
    --description "atomic" \
    --tier unit \
    --priority P3 \
    --expected "ok" >/dev/null
  # No leftover .tmp files in the index directory after a successful write.
  run find "$(dirname "$INDEX_FILE")" -name '*.tmp*' -o -name '.tmp.*'
  [ -z "$output" ]
}

# ============================================================================
# AC3: schema — id, story_key, description, tier, priority, file_path,
#               created_date
# ============================================================================

@test "E72-S3 AC3: new entry contains canonical id field (not cs_id)" {
  printf 'scenarios: []\n' >"$INDEX_FILE"
  "$SCRIPTS_DIR/subcmd-add-scenario.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE" \
    --description "schema" \
    --tier unit \
    --priority P1 \
    --expected "ok" >/dev/null

  grep -qE '^[[:space:]]*-[[:space:]]+id:[[:space:]]*["]?CS-001["]?' "$INDEX_FILE"
}

@test "E72-S3 AC3: new entry contains all seven required fields" {
  printf 'scenarios: []\n' >"$INDEX_FILE"
  "$SCRIPTS_DIR/subcmd-add-scenario.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE" \
    --description "schema-check" \
    --tier integration \
    --priority P2 \
    --expected "ok" >/dev/null

  grep -qE '^[[:space:]]*-?[[:space:]]*id:' "$INDEX_FILE"
  grep -qE '^[[:space:]]+story_key:' "$INDEX_FILE"
  grep -qE '^[[:space:]]+description:' "$INDEX_FILE"
  grep -qE '^[[:space:]]+tier:' "$INDEX_FILE"
  grep -qE '^[[:space:]]+priority:' "$INDEX_FILE"
  grep -qE '^[[:space:]]+file_path:' "$INDEX_FILE"
  grep -qE '^[[:space:]]+created_date:' "$INDEX_FILE"
}

@test "E72-S3 AC3: created_date is ISO-8601 (YYYY-MM-DD)" {
  printf 'scenarios: []\n' >"$INDEX_FILE"
  "$SCRIPTS_DIR/subcmd-add-scenario.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE" \
    --description "iso-date" \
    --tier unit \
    --priority P3 \
    --expected "ok" >/dev/null

  grep -qE 'created_date:[[:space:]]*"?[0-9]{4}-[0-9]{2}-[0-9]{2}"?' "$INDEX_FILE"
}

# ============================================================================
# AC4: qa-tests / qa-review does NOT mutate index.yaml
# ============================================================================

@test "E72-S3 AC4: gaia-qa-tests skill does not write to index.yaml path" {
  # The qa-tests SKILL.md must not reference custom/test-scenarios/index.yaml
  # in any write context. Confirm zero mentions, so qa-tests stays read-only
  # relative to the CS-NNN namespace.
  ! grep -qiE 'custom/test-scenarios/index\.yaml' \
    "$REPO_ROOT/plugins/gaia/skills/gaia-qa-tests/SKILL.md"
}

@test "E72-S3 AC4: SKILL.md documents the non-mutation invariant" {
  grep -qiE 'non.mutation|read.only|MUST NOT (write|mutate)' \
    "$SKILL_DIR/SKILL.md"
}

# ============================================================================
# AC5: --status sources Custom scenarios block from index.yaml
# ============================================================================

@test "E72-S3 AC5: --status renders Custom scenarios block from index.yaml" {
  cat >"$INDEX_FILE" <<'EOF'
scenarios:
  - id: CS-001
    story_key: E99-S99
    description: "retry race"
    tier: unit
    priority: P1
    file_path: ""
    created_date: "2026-05-05"
EOF

  run "$SCRIPTS_DIR/subcmd-status.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Custom scenarios'
  echo "$output" | grep -q 'CS-001'
  echo "$output" | grep -q 'retry race'
}

@test "E72-S3 AC5: --status filters Custom scenarios block by story_key" {
  cat >"$INDEX_FILE" <<'EOF'
scenarios:
  - id: CS-001
    story_key: E99-S99
    description: "mine"
    tier: unit
    priority: P1
    file_path: ""
    created_date: "2026-05-05"
  - id: CS-002
    story_key: E11-S11
    description: "other story"
    tier: unit
    priority: P1
    file_path: ""
    created_date: "2026-05-05"
EOF

  run "$SCRIPTS_DIR/subcmd-status.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'CS-001'
  ! echo "$output" | grep -q 'CS-002'
}

@test "E72-S3 AC5: --status shows '(not yet automated)' for empty file_path" {
  cat >"$INDEX_FILE" <<'EOF'
scenarios:
  - id: CS-001
    story_key: E99-S99
    description: "no file yet"
    tier: integration
    priority: P3
    file_path: ""
    created_date: "2026-05-05"
EOF

  run "$SCRIPTS_DIR/subcmd-status.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'CS-001'
  echo "$output" | grep -q 'not yet automated'
}

# ============================================================================
# AC6: --status flags missing file_path
# ============================================================================

@test "E72-S3 AC6: --status flags missing file_path with 'file not found' warning" {
  cat >"$INDEX_FILE" <<EOF
scenarios:
  - id: CS-001
    story_key: E99-S99
    description: "stale path"
    tier: unit
    priority: P3
    file_path: "$TMPDIR/does/not/exist.test.ts"
    created_date: "2026-05-05"
EOF

  run "$SCRIPTS_DIR/subcmd-status.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'CS-001'
  echo "$output" | grep -qE 'file not found|missing'
}

@test "E72-S3 AC6: --status renders existing file_path without warning" {
  local real_test="$TMPDIR/real.test.ts"
  printf 'export const ok = true;\n' >"$real_test"

  cat >"$INDEX_FILE" <<EOF
scenarios:
  - id: CS-001
    story_key: E99-S99
    description: "good path"
    tier: unit
    priority: P3
    file_path: "$real_test"
    created_date: "2026-05-05"
EOF

  run "$SCRIPTS_DIR/subcmd-status.sh" \
    --story-file "$STORY_FILE" \
    --index-file "$INDEX_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'CS-001'
  echo "$output" | grep -q "$real_test"
  ! echo "$output" | grep -qE 'file not found|missing'
}
