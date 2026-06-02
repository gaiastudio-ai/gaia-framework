#!/usr/bin/env bats
# validate-canonical-filename.bats — E63-S4 / Work Item 6.10
#
# Verifies the deterministic contract of
# gaia-framework/plugins/gaia/skills/gaia-create-story/scripts/validate-canonical-filename.sh.
# This script consumes the slug contract from E63-S1 (slugify.sh) and is folded
# into E63-S5 (validate-frontmatter.sh) as one of its sub-checks.
#
# Test scenarios trace back to the story Test Scenarios table:
#   #1  Matching filename (happy path)         (AC1)
#   #2  Filename drift                         (AC2)
#   #3  Missing frontmatter                    (AC3)
#   #4  Missing title field                    (AC3)
#   #5  Missing key field                      (AC3)
#   #6  Unicode title                          (AC1, AC4 alignment)
#   #7  Multi-space title                      (AC1)
#   #8  Sibling slugify.sh missing             (AC4)
#   #9  Single-quoted YAML title               (AC1, quote tolerance)
#   #10 Unquoted YAML title                    (AC1, quote tolerance)
#   AC5 — script header invariants (shebang, set -euo pipefail, LC_ALL=C, mode 0755)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/validate-canonical-filename.sh"
}
teardown() { common_teardown; }

# Helper: write a story file at $TEST_TMP/<basename> with the given key + title.
write_story() {
  local basename="$1" key="$2" title="$3" title_quote="${4:-double}"
  local path="$TEST_TMP/$basename"
  local title_line
  case "$title_quote" in
    double) title_line="title: \"$title\"" ;;
    single) title_line="title: '$title'" ;;
    none)   title_line="title: $title" ;;
    *) printf 'unknown title_quote: %s\n' "$title_quote" >&2; return 1 ;;
  esac
  cat >"$path" <<EOF
---
key: "$key"
$title_line
status: ready-for-dev
---

# Story body
EOF
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# AC1 — happy path (matching filename)
# ---------------------------------------------------------------------------

@test "AC1: matching basename E1-S2-add-user-auth.md -> exit 0, empty stdout (Scenario 1)" {
  path="$(write_story "E1-S2-add-user-auth.md" "E1-S2" "Add User Auth")"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# AC2 — filename drift (mismatch)
# ---------------------------------------------------------------------------

@test "AC2: drifted basename -> exit 2, stderr names expected and actual (Scenario 2)" {
  path="$(write_story "E1-S2-wrong-slug.md" "E1-S2" "Add User Auth")"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 2 ]
  [[ "$output" == *"E1-S2-add-user-auth.md"* ]]
  [[ "$output" == *"E1-S2-wrong-slug.md"* ]]
  [[ "$output" == *"filename drift"* ]]
}

# ---------------------------------------------------------------------------
# AC3 — missing frontmatter / fields
# ---------------------------------------------------------------------------

@test "AC3a: file without --- fences -> exit 1, stderr 'no frontmatter' (Scenario 3)" {
  path="$TEST_TMP/E1-S2-no-frontmatter.md"
  cat >"$path" <<'EOF'
# Story body without frontmatter

Just a heading and prose.
EOF
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no frontmatter"* ]] || [[ "$output" == *"frontmatter"* ]]
}

@test "AC3b: missing title field -> exit 1, stderr names 'title' (Scenario 4)" {
  path="$TEST_TMP/E1-S2-add-user-auth.md"
  cat >"$path" <<'EOF'
---
key: "E1-S2"
status: ready-for-dev
---

# Body
EOF
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title"* ]]
}

@test "AC3c: missing key field -> exit 1, stderr names 'key' (Scenario 5)" {
  path="$TEST_TMP/E1-S2-add-user-auth.md"
  cat >"$path" <<'EOF'
---
title: "Add User Auth"
status: ready-for-dev
---

# Body
EOF
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"key"* ]]
}

# ---------------------------------------------------------------------------
# Unicode title — must mirror E63-S1 unicode policy (non-ASCII -> hyphens)
# ---------------------------------------------------------------------------

@test "Scenario 6: unicode title -> matching basename E1-S2-caf-r-sum.md (exit 0)" {
  # Bash $'...' escape avoids UTF-8 in the test name (bats 1.13 mangles names
  # with multibyte sequences). The file content still contains the literal
  # UTF-8 bytes for the e-acute.
  local title=$'Caf\xc3\xa9 R\xc3\xa9sum\xc3\xa9'
  path="$(write_story "E1-S2-caf-r-sum.md" "E1-S2" "$title")"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Multi-space / punctuation title (Scenario 7)
# ---------------------------------------------------------------------------

@test "Scenario 7: multi-space title -> matching basename E1-S2-multiple-spaces.md (exit 0)" {
  path="$(write_story "E1-S2-multiple-spaces.md" "E1-S2" "  Multiple   Spaces!  ")"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# AC4 — sibling slugify.sh missing/non-executable
# ---------------------------------------------------------------------------

@test "AC4: missing sibling slugify.sh -> exit 1, stderr names slugify.sh" {
  # Stage a copy of the validate script in a directory without slugify.sh, so
  # the sibling-lookup must fail.
  local stage="$TEST_TMP/no-sibling"
  mkdir -p "$stage"
  cp "$SCRIPT" "$stage/validate-canonical-filename.sh"
  chmod +x "$stage/validate-canonical-filename.sh"

  path="$(write_story "E1-S2-add-user-auth.md" "E1-S2" "Add User Auth")"
  run "$stage/validate-canonical-filename.sh" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"slugify.sh"* ]]
}

# ---------------------------------------------------------------------------
# Quote tolerance — single-quoted, unquoted YAML titles (Scenarios 9, 10)
# ---------------------------------------------------------------------------

@test "Scenario 9: single-quoted YAML title -> exit 0 (quote-tolerant parse)" {
  path="$(write_story "E1-S2-add-user-auth.md" "E1-S2" "Add User Auth" single)"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "Scenario 10: unquoted YAML title -> exit 0 (quote-tolerant parse)" {
  path="$(write_story "E1-S2-add-user-auth.md" "E1-S2" "Add User Auth" none)"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Usage error coverage
# ---------------------------------------------------------------------------

@test "usage: missing --file flag -> exit non-zero" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "usage: --file with no value -> exit non-zero" {
  run "$SCRIPT" --file
  [ "$status" -ne 0 ]
}

@test "usage: file does not exist -> exit non-zero" {
  run "$SCRIPT" --file "$TEST_TMP/does-not-exist.md"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — script header invariants
# ---------------------------------------------------------------------------

@test "AC5: script exists at the canonical path" {
  [ -f "$SCRIPT" ]
}

@test "AC5: script is executable (mode 0755)" {
  [ -x "$SCRIPT" ]
  local mode
  if mode="$(stat -f '%Lp' "$SCRIPT" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' "$SCRIPT")"
  fi
  [ "$mode" = "755" ]
}

@test "AC5: script begins with #!/usr/bin/env bash" {
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "AC5: script sets 'set -euo pipefail'" {
  run grep -E '^set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AC5: script sets 'LC_ALL=C'" {
  run grep -E '^LC_ALL=C|^export LC_ALL' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# E55-S13 D5 (TC-DSF-5): /gaia-create-story SKILL.md Step 4 prose MUST
# include a "Canonical basename preview" sub-step that displays the
# slugify.sh output BEFORE the scaffold step writes the file. Without
# this preview, authors discover slug-mismatches only after
# validate-canonical-filename.sh rejects the write — by which point the
# file is on disk under a wrong name and must be renamed.
#
# This is a documentation-layer fix per Val F5 option (c); the
# validate-canonical-filename.sh strictness contract is preserved
# verbatim (options a and b were rejected in the story's AC5 narrative).
@test "TC-DSF-5: gaia-create-story SKILL.md Step 4 contains 'Canonical basename preview' sub-step" {
  local skill="$SKILLS_DIR/gaia-create-story/SKILL.md"
  [ -f "$skill" ]
  run grep -E -i 'canonical basename preview' "$skill"
  [ "$status" -eq 0 ]
}

# TC-DSF-5b: the preview MUST appear before the scaffold-story.sh invocation.
@test "TC-DSF-5b: 'Canonical basename preview' is positioned before scaffold-story.sh in Step 4" {
  local skill="$SKILLS_DIR/gaia-create-story/SKILL.md"
  local preview_line scaffold_line
  preview_line=$(grep -n -i 'canonical basename preview' "$skill" | head -1 | cut -d: -f1)
  scaffold_line=$(grep -n 'scaffold-story.sh' "$skill" | head -1 | cut -d: -f1)
  [ -n "$preview_line" ]
  [ -n "$scaffold_line" ]
  [ "$preview_line" -lt "$scaffold_line" ]
}
