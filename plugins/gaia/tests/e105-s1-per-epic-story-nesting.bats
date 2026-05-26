#!/usr/bin/env bats
# e105-s1-per-epic-story-nesting.bats — E105-S1
#
# Per-story nested layout `epic-E{N}-{slug}/E{N}-S{M}-{slug}/story.md` with a
# three-tier read-side resolver fallback (new nested > legacy epic-*/stories/ >
# legacy flat). New writes use the nested form; legacy layouts are read-only.
#
# All tests run against an IMPLEMENTATION_ARTIFACTS-overridden TEMP root — they
# NEVER touch the live .gaia tree.
#
# Maps to AC1-AC5, AC-INT1 and TS1-TS6, plus the Val C1 prefix-boundary regression.
# Refs: ADR-127, ADR-119, ADR-070, FR-402, FR-553

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RESOLVER="$REPO_ROOT/plugins/gaia/scripts/resolve-story-file.sh"
  VALIDATE="$REPO_ROOT/plugins/gaia/skills/gaia-create-story/scripts/validate-canonical-filename.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/per-epic-nesting"

  TEST_TMP="$BATS_TEST_TMPDIR/pen-$$"
  mkdir -p "$TEST_TMP"
}

teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# assemble a temp IMPLEMENTATION_ARTIFACTS root from one or more fixture subtrees
mkroot() { # $1 = root name ; remaining = fixture subdirs to copy in
  local root="$TEST_TMP/$1"; shift
  mkdir -p "$root"
  local sub
  for sub in "$@"; do
    cp -R "$FX/$sub/." "$root/"
  done
  printf '%s' "$root"
}

# ---------- AC2 / TS1: resolver finds a NEW-layout story ----------

@test "AC2/TS1: resolver finds a story in the new nested layout" {
  root="$(mkroot r1 new-layout)"
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E900-S1
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'E900-S1-alpha/story\.md$' \
    || { echo "expected new-layout story.md path, got: $output" >&2; false; }
}

# ---------- AC2 / TS2: legacy epic-*/stories/ read-side fallback ----------

@test "AC2/TS2: resolver finds a legacy epic-*/stories/ story (fallback tier 2)" {
  root="$(mkroot r2 legacy-stories)"
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E901-S1
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'stories/E901-S1-beta\.md$'
}

@test "AC2: resolver finds a legacy flat story (fallback tier 3)" {
  root="$(mkroot r3 flat)"
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E902-S1
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'E902-S1-gamma\.md$'
}

# ---------- AC2: precedence — nested wins over legacy stories for same key ----------

@test "AC2: new nested layout wins over a legacy epic-*/stories sibling for the same key" {
  root="$(mkroot r4 new-layout)"
  # add a legacy stories sibling for the SAME key E900-S1
  mkdir -p "$root/epic-E900-demo/stories"
  cat > "$root/epic-E900-demo/stories/E900-S1-alpha.md" <<'EOF'
---
template: 'story'
key: "E900-S1"
title: "Alpha legacy"
status: ready-for-dev
---
EOF
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E900-S1
  [ "$status" -eq 0 ]
  # nested per-story story.md must win
  echo "$output" | grep -Eq 'E900-S1-alpha/story\.md$' \
    || { echo "nested should win over legacy stories, got: $output" >&2; false; }
}

# ---------- Val C1 regression: prefix-boundary + evidence-dir exclusion ----------

@test "C1: resolver does NOT false-match an E*-S*-* evidence dir under stories/" {
  root="$(mkroot rc1 c1-trap)"
  # key E28-S2 must resolve to the REAL nested story, never the evidence dir
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E28-S2
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'E28-S2-real/story\.md$' \
    || { echo "E28-S2 must resolve to the real story, got: $output" >&2; false; }
  # must NOT have matched the evidence dir or the E28-S21 prefix sibling
  ! echo "$output" | grep -Eq 'E28-S21|diff-report' \
    || { echo "E28-S2 must not match E28-S21 evidence dir, got: $output" >&2; false; }
}

@test "WARNING-1: tier-0 excludes a SAME-KEY story.md under epic-*/stories/ (evidence dir)" {
  root="$(mkroot rw1 new-layout)"
  # plant a same-key (E900-S1) evidence dir WITH a literal story.md UNDER stories/
  mkdir -p "$root/epic-E900-demo/stories/E900-S1-evidence"
  printf 'evidence-not-a-story\n' > "$root/epic-E900-demo/stories/E900-S1-evidence/story.md"
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E900-S1
  [ "$status" -eq 0 ]
  # tier-0 must resolve the REAL new-layout story, never the stories/ evidence story.md,
  # and must NOT report spurious ambiguity (exit 2)
  echo "$output" | grep -Eq 'E900-S1-alpha/story\.md$' \
    || { echo "must resolve the real new-layout story, got: $output" >&2; false; }
  ! echo "$output" | grep -Eq 'stories/E900-S1-evidence' \
    || { echo "must exclude the stories/ evidence story.md, got: $output" >&2; false; }
}

@test "C1: key prefix boundary — E28-S2 does not match E28-S21" {
  root="$(mkroot rc2)"
  # only an E28-S21 new-layout story exists; resolving E28-S2 must NOT find it
  mkdir -p "$root/epic-E28-prog/E28-S21-twentyone/reviews"
  cat > "$root/epic-E28-prog/E28-S21-twentyone/story.md" <<'EOF'
---
template: 'story'
key: "E28-S21"
title: "Twenty-one"
status: ready-for-dev
---
EOF
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E28-S2
  # E28-S2 has no story -> must be not-found (exit 1), NOT a false E28-S21 match
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -Eq 'E28-S21'
}

# ---------- AC3 / TS5: validate-canonical-filename accepts the new layout ----------

@test "AC3/TS5: validate-canonical-filename accepts new-layout story.md (key from dir)" {
  root="$(mkroot rv new-layout)"
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$VALIDATE" --file "$root/epic-E900-demo/E900-S1-alpha/story.md"
  [ "$status" -eq 0 ] \
    || { echo "validate should accept new-layout story.md, got status $status: $output" >&2; false; }
}

@test "W2 regression: validate still flags legacy {key}-{slug}.md drift unchanged" {
  root="$(mkroot rvd)"
  mkdir -p "$root"
  # a flat file whose basename does NOT match key-slug -> drift (exit 2)
  cat > "$root/E903-S1-wrongslug.md" <<'EOF'
---
template: 'story'
key: "E903-S1"
title: "Correct Title Here"
status: ready-for-dev
---
EOF
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$VALIDATE" --file "$root/E903-S1-wrongslug.md"
  # basename E903-S1-wrongslug != E903-S1-correct-title-here -> drift exit 2
  [ "$status" -eq 2 ] \
    || { echo "legacy drift should still exit 2, got $status: $output" >&2; false; }
}

# ---------- AC4 / TS4: reviews/ FR-402 type-first names, no check-deps collision ----------

@test "AC4/TS4: per-story reviews/ uses FR-402 type-first names (no {key}-<type> collision)" {
  root="$(mkroot r5 new-layout)"
  reviews="$root/epic-E900-demo/E900-S1-alpha/reviews"
  [ -d "$reviews" ]
  # type-FIRST form present
  [ -f "$reviews/code-review-E900-S1.md" ]
  # no reversed {key}-<type>.md form that would collide with check-deps {key}-*.md glob
  ! ls "$reviews"/E900-S1-*.md >/dev/null 2>&1 \
    || { echo "reviews/ must not use reversed {key}-<type>.md form" >&2; false; }
}

# ---------- AC1 / AC-INT1 / TS3,TS6: create + transition wiring (doc-level) ----------

@test "AC1: gaia-create-story documents the nested per-story write target" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-create-story/SKILL.md"
  grep -Eiq 'E\{?N?\}?-S\{?M?\}?-\{?slug\}?/story\.md|per-story (nest|dir)|E\{N\}-S\{M\}-\{slug\}/story\.md' "$SKILL" \
    || { echo "create-story SKILL.md should document the nested story.md write target" >&2; grep -i 'story.md\|per-story' "$SKILL" >&2; false; }
}

@test "AC-INT1/TS3,TS6: transition-story-status.sh locate glob includes the nested layout" {
  TR="$REPO_ROOT/plugins/gaia/scripts/transition-story-status.sh"
  grep -Eq 'epic-\*/E\*-S\*-\*/story\.md|E\*-S\*-\*/story\.md' "$TR" \
    || { echo "transition locate_story_file should include the nested glob" >&2; false; }
}

# ---------- robustness ----------

@test "resolver: not-found key exits non-zero with actionable error" {
  root="$(mkroot rn new-layout)"
  run env IMPLEMENTATION_ARTIFACTS="$root" bash "$RESOLVER" E999-S9
  [ "$status" -ne 0 ]
}
