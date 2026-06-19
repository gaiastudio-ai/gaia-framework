#!/usr/bin/env bats
# retired-migrate-stories.bats — E97-S2
#
# Asserts the one-shot migration tool migrate-stories-to-canonical-layout.sh
# has been retired to scripts/retired/ with a tombstone README, and that no
# stale references to the script's original path remain in SKILL.md files or
# CI workflows.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
}

teardown() {
  common_teardown
}

@test "script moved to scripts/retired/" {
  [ -f "$PLUGIN_ROOT/scripts/retired/migrate-stories-to-canonical-layout.sh" ]
}

@test "script no longer at original path" {
  [ ! -f "$PLUGIN_ROOT/scripts/migrate-stories-to-canonical-layout.sh" ]
}

@test "tombstone README exists in scripts/retired/" {
  [ -f "$PLUGIN_ROOT/scripts/retired/README.md" ]
}

@test "tombstone README documents retire + completion date" {
  run grep -E "(E97-S2|2026-05-21|one-shot)" "$PLUGIN_ROOT/scripts/retired/README.md"
  [ "$status" -eq 0 ]
}

@test "no references to migrate-stories-to-canonical-layout.sh in SKILL.md / runbooks" {
  # Exclude the tombstone README (which legitimately mentions the script),
  # the retired script itself, and CHANGELOG.md (which historically
  # documents the E97-S2 retirement — that is precisely what AC3 expects
  # to remain on disk, not a stale operational reference).
  run bash -c "grep -rln 'migrate-stories-to-canonical-layout' '$PLUGIN_ROOT/' \
    --include='*.md' \
    --include='*.yaml' \
    --include='*.yml' \
    2>/dev/null \
    | grep -v 'scripts/retired/' \
    | grep -v 'tests/retired-migrate-stories\\.bats' \
    | grep -v 'tests/migrate-stories-to-canonical-layout\\.bats' \
    | grep -v 'CHANGELOG\\.md'"
  # Empty output => zero stale refs => grep -v chain exits non-zero on empty
  [ -z "$output" ]
}
