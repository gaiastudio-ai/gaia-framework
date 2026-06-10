#!/usr/bin/env bats
# scaffold-story-ampersand-escape.bats
#
# Regression guard for the `awk gsub replacement-&` corruption: when a story
# title contains an ampersand (or any token replacement value does), the `&`
# is interpreted by gsub as "the matched text" and silently re-inserts the
# placeholder (`{story_title}`) instead of preserving the literal `&`.
#
# The fix adds an esc_repl() awk function that escapes `\` and `&` in every
# replacement value passed to gsub() in token_sub().

load 'test_helper.bash'

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-create-story/scripts" && pwd)/scaffold-story.sh"

setup() {
  common_setup
  TPL="$TEST_TMP/story.md.tmpl"
  OUT="$TEST_TMP/story.md"
  # Minimal template exercising the three high-risk token-substitution sites.
  cat > "$TPL" <<'EOF'
---
key: {story_key}
title: {story_title}
epic: {epic_key}
---
# Story: {story_title}
EOF
}

teardown() { common_teardown; }

_fm() {
  local title="$1" epic="$2"
  cat <<EOF
key: E14-S31
title: ${title}
epic: ${epic}
status: ready-for-dev
priority: P0
size: M
points: 3
risk: medium
created: 2026-06-09
author: dev-agent
origin: null
origin_ref: null
depends_on: []
blocks: []
traces_to: []
EOF
}

# ---------------------------------------------------------------------------
# Baseline: a plain title (no special chars) still substitutes correctly.
# ---------------------------------------------------------------------------

@test "baseline: plain title substitutes correctly" {
  run "$SCRIPT" --template "$TPL" --output "$OUT" \
    --frontmatter "$(_fm 'Plain title' 'E14 — Profile core')"
  [ "$status" -eq 0 ]
  grep -q '^title: Plain title$' "$OUT"
  grep -q '^# Story: Plain title$' "$OUT"
  ! grep -q '{story_title}' "$OUT"
}

# ---------------------------------------------------------------------------
# Bug repro: a title containing `&` must keep the literal `&` and must NOT
# re-insert the placeholder text `{story_title}`.
# ---------------------------------------------------------------------------

@test "ampersand in title: literal & preserved, {story_title} NOT reinserted" {
  run "$SCRIPT" --template "$TPL" --output "$OUT" \
    --frontmatter "$(_fm 'Named profile registry & resolveProfileHome seam' 'E14 — Profile core')"
  [ "$status" -eq 0 ]
  grep -q '^title: Named profile registry & resolveProfileHome seam$' "$OUT"
  grep -q '^# Story: Named profile registry & resolveProfileHome seam$' "$OUT"
  ! grep -q '{story_title}' "$OUT"
}

@test "ampersand in title appears in BOTH frontmatter title and # Story heading" {
  run "$SCRIPT" --template "$TPL" --output "$OUT" \
    --frontmatter "$(_fm 'Foo & Bar' 'E14 — Profile core')"
  [ "$status" -eq 0 ]
  # Exactly 2 occurrences of the literal " & " — one per substitution site.
  run grep -cF ' & ' "$OUT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Multiple `&` in the same value — each must be escaped independently.
# ---------------------------------------------------------------------------

@test "multiple ampersands in title each preserved literally" {
  run "$SCRIPT" --template "$TPL" --output "$OUT" \
    --frontmatter "$(_fm 'A & B & C' 'E14 — Profile core')"
  [ "$status" -eq 0 ]
  grep -q '^title: A & B & C$' "$OUT"
  ! grep -q '{story_title}' "$OUT"
}

# ---------------------------------------------------------------------------
# An epic-key value containing `&` must also be safely substituted (every
# token_sub call routes through esc_repl, not just the story_title one).
# ---------------------------------------------------------------------------

@test "ampersand in epic value also safe (every replacement is escaped)" {
  run "$SCRIPT" --template "$TPL" --output "$OUT" \
    --frontmatter "$(_fm 'Plain title' 'E14 — Profile & registry')"
  [ "$status" -eq 0 ]
  # The epic value contains an em-dash and an `&`. Don't re-insert {epic_key}.
  ! grep -q '{epic_key}' "$OUT"
  grep -q 'Profile & registry' "$OUT"
}
