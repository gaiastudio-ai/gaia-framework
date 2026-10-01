#!/usr/bin/env bats
# gaia-changelog-story-link.bats — structural tests for changelog SKILL.md
# story cross-reference via commit bodies.
#
# Asserts that the changelog skill reads commit bodies (not just subjects)
# and recognises the Story: body-line pattern for cross-referencing story keys.

load 'test_helper.bash'

setup() {
  common_setup
  CHANGELOG_SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-changelog" && pwd)/SKILL.md"
  [ -f "$CHANGELOG_SKILL" ] || { echo "SKILL.md not found at $CHANGELOG_SKILL" >&2; return 1; }
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Step 1 — MAIN and FALLBACK git-log commands must BOTH use body-reading
# format and must NOT use bare --oneline.
# ---------------------------------------------------------------------------

@test "changelog Step 1 main (..HEAD) log command uses body-reading format" {
  step1="$(awk '/^### Step 1 — Gather/,/^### Step (1\.5|2)/' "$CHANGELOG_SKILL")"
  [ -n "$step1" ]
  # The MAIN command contains ..HEAD and a --format with %b or %B.
  main_cmd="$(grep -E '\.\.HEAD.*--format=' <<<"$step1" | head -1)"
  [ -n "$main_cmd" ]
  grep -qE '%[bB]' <<<"$main_cmd"
  # Must NOT use bare --oneline (truncates to subject, hides body).
  ! grep -qF -- '--oneline' <<<"$main_cmd"
}

@test "changelog Step 1 fallback log command uses body-reading format" {
  step1="$(awk '/^### Step 1 — Gather/,/^### Step (1\.5|2)/' "$CHANGELOG_SKILL")"
  [ -n "$step1" ]
  # The FALLBACK command: a git log line with --format but without ..HEAD.
  fallback_cmd="$(grep -E 'git log.*--format=' <<<"$step1" | grep -v '\.\.HEAD' | head -1)"
  [ -n "$fallback_cmd" ]
  grep -qE '%[bB]' <<<"$fallback_cmd"
  ! grep -qF -- '--oneline' <<<"$fallback_cmd"
}

# ---------------------------------------------------------------------------
# Critical Rules must mention Story: body line
# ---------------------------------------------------------------------------

@test "changelog Critical Rules mention Story: body-line cross-reference" {
  rules="$(awk '/^## Critical Rules/{flag=1; next} /^## /{flag=0} flag' "$CHANGELOG_SKILL")"
  [ -n "$rules" ]
  grep -qi 'Story:' <<<"$rules"
  grep -qi 'body' <<<"$rules"
}

# ---------------------------------------------------------------------------
# Step 2 must have the "Story: body-line cross-reference" paragraph
# ---------------------------------------------------------------------------

@test "changelog Step 2 has Story: body-line cross-reference paragraph" {
  step2="$(awk '/^### Step 2/{flag=1; next} /^### Step [0-9]/{flag=0} flag' "$CHANGELOG_SKILL")"
  [ -n "$step2" ]
  grep -qF 'Story: body-line cross-reference' <<<"$step2"
  # Must mention both plain and link forms.
  grep -qE 'Story:.*\[' <<<"$step2"
}

# ---------------------------------------------------------------------------
# Tag-range preservation — the range from last tag must remain
# ---------------------------------------------------------------------------

@test "changelog Step 1 preserves the tag-range git-log invocation" {
  step1="$(awk '/^### Step 1 — Gather/,/^### Step (1\.5|2)/' "$CHANGELOG_SKILL")"
  [ -n "$step1" ]
  grep -qE 'git describe|\.\.HEAD' <<<"$step1"
}
