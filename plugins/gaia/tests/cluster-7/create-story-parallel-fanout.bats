#!/usr/bin/env bats
# create-story-parallel-fanout.bats — E79-S2 (TC-CSP-2 / AC5)
#
# Verifies that the SKILL.md Step 4 layout under E79-S2 is structurally safe
# for parallel fan-out: every concurrent /gaia-create-story invocation under
# the same epic produces a file at `epic-{slug}/stories/{key}-{slug}.md`,
# never at the flat path. Because Step 4 derives the per-epic directory via
# `resolve-epic-slug.sh` (a deterministic helper) and then `mkdir -p`s that
# directory before each scaffold, concurrent invocations cannot race into a
# shared parent that is created lazily — every per-epic stories/ directory
# is idempotently created by every invocation.
#
# This story changes SKILL.md prose only — no script source under .../scripts/
# is modified — so the assertions inspect SKILL.md structural properties
# rather than invoking /gaia-create-story end-to-end.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$SKILLS_DIR/gaia-create-story"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  RESOLVER="$SCRIPTS_DIR/lib/resolve-epic-slug.sh"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

@test "TC-CSP-2: SKILL.md exists for gaia-create-story" {
  [ -f "$SKILL_MD" ]
}

@test "TC-CSP-2: resolve-epic-slug.sh from E79-S1 is present and executable" {
  [ -x "$RESOLVER" ]
}

# ---------------------------------------------------------------------------
# Parallel-fanout determinism — every concurrent invocation lands a per-key
# file at the canonical nested path. The structural guarantee is that:
#
#   1. The output path expression uses ${STORY_KEY} and ${SLUG} — both
#      per-invocation values — so two invocations cannot collide on the same
#      output filename.
#   2. The mkdir -p of the per-epic stories/ directory is idempotent under
#      POSIX semantics, so concurrent invocations under the same epic do not
#      race on directory creation.
#   3. The scaffold target lives under the per-epic stories/ directory —
#      under E79's canonical layout — never at the legacy flat path.
# ---------------------------------------------------------------------------

@test "TC-CSP-2: SKILL.md Step 4 output path uses both \${STORY_KEY} (or <story_key>) and \${SLUG} per-invocation" {
  # Both placeholders must appear on the scaffold output line so that two
  # concurrent invocations under the same epic produce distinct filenames.
  run grep -nE 'output[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/epic-\$\{?EPIC_SLUG\}?/stories/(<story_key>|\$\{?STORY_KEY\}?)-\$\{?SLUG\}?\.md"' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-2: SKILL.md Step 4 mkdir -p target is the per-epic stories/ directory (idempotent under concurrent invocations)" {
  # POSIX `mkdir -p` is safe under concurrent invocations targeting the same
  # path. The Step 4 prose must `mkdir -p` the per-epic stories/ directory —
  # not just the implementation-artifacts root.
  run grep -nE 'mkdir -p[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/epic-\$\{?EPIC_SLUG\}?/stories"' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-2: SKILL.md Step 4 has zero residual flat-path scaffolds (no race onto the legacy top-level dir)" {
  # If Step 4 still wrote to the legacy flat path, two concurrent invocations
  # could race onto the same `${IMPLEMENTATION_ARTIFACTS}` directory. The
  # canonical layout sidesteps this by writing under per-epic stories/.
  run grep -nE -- '--output[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/<story_key>-\$\{?SLUG\}?\.md"' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "TC-CSP-2: SKILL.md Step 4 calls the resolver per invocation (no shared mutable state)" {
  # The resolver is a pure function (epic_key + epics_file -> slug). Calling
  # it once per invocation guarantees concurrent invocations cannot observe
  # half-written shared state. The invocation may span multiple lines.
  run bash -c 'grep -nE -A2 "resolve-epic-slug\\.sh" "$1" | grep -qE -- "--epic-key"' _ "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-2: SKILL.md Step 4 mkdir -p PRECEDES scaffold-story.sh (no ENOENT under concurrent first-use)" {
  # Match the actual scaffold-story.sh INVOCATION line (begins with `!scripts/`),
  # not the prose comment.
  mkdir_line="$(grep -nE 'mkdir -p[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/epic-\$\{?EPIC_SLUG\}?/stories"' "$SKILL_MD" | head -1 | cut -d: -f1)"
  scaffold_line="$(grep -nE '!scripts/scaffold-story\.sh' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$mkdir_line" ]
  [ -n "$scaffold_line" ]
  [ "$mkdir_line" -lt "$scaffold_line" ]
}
