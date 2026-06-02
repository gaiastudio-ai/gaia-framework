#!/usr/bin/env bats
# file-list-diff-check.bats — unit tests for plugins/gaia/scripts/file-list-diff-check.sh (E65-S1)
# Covers TC-DEJ-DIVERGENCE-1, EC-8, EC-9.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/file-list-diff-check.sh"
  STORY="$TEST_TMP/E65-S1-story.md"
}
teardown() { common_teardown; }

write_story_with_filelist() {
  cat > "$STORY" <<'EOF'
---
key: E65-S1
---
# Title

## File List

- `gaia-public/plugins/gaia/scripts/a.ts`
- `gaia-public/plugins/gaia/scripts/c.ts`

## Other
EOF
}

write_story_no_filelist() {
  cat > "$STORY" <<'EOF'
---
key: E65-S1
---
# Title

## Dev Notes
nothing here
EOF
}

write_story_empty_filelist() {
  cat > "$STORY" <<'EOF'
---
key: E65-S1
---
# Title

## File List

## Dev Notes
EOF
}

# Create a fake git repo with two files modified in a feature branch
init_git_repo() {
  cd "$TEST_TMP"
  git init -q .
  git config user.email test@example.com
  git config user.name test
  mkdir -p gaia-public/plugins/gaia/scripts
  echo orig > gaia-public/plugins/gaia/scripts/a.ts
  echo orig > gaia-public/plugins/gaia/scripts/b.ts
  git add -A
  git commit -q -m "init"
  git checkout -q -b feat/E65-S1
  echo changed > gaia-public/plugins/gaia/scripts/a.ts
  echo new > gaia-public/plugins/gaia/scripts/b.ts
  git commit -aq -m "feat: changes"
}

@test "file-list-diff-check.sh: --help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"file-list-diff-check.sh"* ]]
}

@test "TC-DEJ-DIVERGENCE-1: File List lists a.ts; git diff shows a.ts + b.ts -> emits divergence Warning naming b.ts" {
  init_git_repo
  write_story_with_filelist
  run "$SCRIPT" --story-file "$STORY" --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"divergence"* ]] || [[ "$output" == *"Warning"* ]]
  [[ "$output" == *"b.ts"* ]]
}

@test "EC-8: not in a git repo -> stderr 'git diff unavailable'; exit 0" {
  cd "$TEST_TMP"   # no git init
  write_story_with_filelist
  run --separate-stderr "$SCRIPT" --story-file "$STORY"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"git diff unavailable"* ]]
}

@test "EC-9a: missing File List section -> divergence Warning reason=no-file-list" {
  init_git_repo
  write_story_no_filelist
  run "$SCRIPT" --story-file "$STORY" --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-file-list"* ]]
}

@test "EC-9b: empty File List section -> divergence Warning reason=empty-file-list" {
  init_git_repo
  write_story_empty_filelist
  run "$SCRIPT" --story-file "$STORY" --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty-file-list"* ]] || [[ "$output" == *"no-file-list"* ]]
}

@test "file-list-diff-check.sh: missing --story-file -> exit 1" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "file-list-diff-check.sh: paths with spaces don't crash" {
  init_git_repo
  cat > "$STORY" <<'EOF'
---
key: E65-S1
---

## File List

- `path with spaces/foo bar.ts`

EOF
  run "$SCRIPT" --story-file "$STORY" --base main
  [ "$status" -eq 0 ]
}
