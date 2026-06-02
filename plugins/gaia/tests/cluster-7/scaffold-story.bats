#!/usr/bin/env bats
# scaffold-story.bats — E63-S9 / Work Item 6.4
#
# Verifies the deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/scaffold-story.sh.
#
# Test scenarios trace back to the story Test Scenarios table:
#   #1  Clean scaffold                    (AC1)
#   #2  Content placeholders present      (AC2)
#   #3  Stdout enumeration                (AC2)
#   #4  Idempotent re-run                 (AC3)
#   #5  Missing template                  (AC4)
#   #6  Malformed frontmatter YAML        (AC4)
#   #7  Missing parent directory          (AC4)
#   #8  Status override attempt           (AC1, ADR-074 C3)
#   #9  Frontmatter via stdin             (AC1)
#   #11 Scope guard — no out-of-scope writes
#   header invariants                    (shebang, set -euo pipefail, LC_ALL=C, mode 0755)
#   deterministic Review Gate rows       (AC1)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/scaffold-story.sh"
  TEMPLATE="$SKILLS_DIR/gaia-create-story/story-template.md"

  # Canonical fixture frontmatter for E99-S1.
  FRONTMATTER_YAML='---
template: '\''story'\''
version: 1.4.0
used_by: ['\''create-story'\'']
key: "E99-S1"
title: "Scaffold story end-to-end"
epic: "E99"
status: backlog
priority: "P1"
size: "M"
points: 3
risk: "medium"
sprint_id: null
priority_flag: null
origin: null
origin_ref: null
depends_on: []
blocks: []
traces_to: []
date: "2026-04-29"
author: "gaia-create-story"
---'
  export FRONTMATTER_YAML
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — clean scaffold (Scenario 1)
# ---------------------------------------------------------------------------

@test "AC1: clean scaffold writes output, replaces tokens, preserves DoD verbatim" {
  out_file="$TEST_TMP/E99-S1-scaffold-story-end-to-end.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  [ -f "$out_file" ]
  # Frontmatter token replacement
  run grep -F 'key: "E99-S1"' "$out_file"
  [ "$status" -eq 0 ]
  run grep -F 'title: "Scaffold story end-to-end"' "$out_file"
  [ "$status" -eq 0 ]
  run grep -F 'epic: "E99"' "$out_file"
  [ "$status" -eq 0 ]
  run grep -F 'priority: "P1"' "$out_file"
  [ "$status" -eq 0 ]
  run grep -F 'status: backlog' "$out_file"
  [ "$status" -eq 0 ]
  # Header line under heading
  run grep -F '> **Epic:** E99' "$out_file"
  [ "$status" -eq 0 ]
  run grep -F '> **Priority:** P1' "$out_file"
  [ "$status" -eq 0 ]
  # DoD verbatim — use `--` to separate flags from pattern (BSD grep on macOS
  # treats a leading `-` in the pattern as a flag otherwise).
  run grep -F -- '- [ ] All acceptance criteria verified and checked off' "$out_file"
  [ "$status" -eq 0 ]
  run grep -F -- '- [ ] Code compiles / builds without errors' "$out_file"
  [ "$status" -eq 0 ]
}

@test "AC1: Review Gate has six canonical UNVERIFIED rows" {
  out_file="$TEST_TMP/E99-S1-scaffold.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  for review in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    run grep -F "| $review | UNVERIFIED |" "$out_file"
    [ "$status" -eq 0 ]
  done
}

@test "AC1: Estimate section shows resolved points value" {
  out_file="$TEST_TMP/E99-S1-scaffold.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  run grep -F -- '- **Points:** 3' "$out_file"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — content placeholders + stdout enumeration (Scenarios 2, 3)
# ---------------------------------------------------------------------------

@test "AC2: each of seven content sections contains exactly one CONTENT_PLACEHOLDER line" {
  out_file="$TEST_TMP/E99-S1-scaffold.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  for section in "User Story" "Acceptance Criteria" "Tasks / Subtasks" "Dev Notes" "Technical Notes" "Dependencies" "Test Scenarios"; do
    # The heading must be present.
    run grep -F "## $section" "$out_file"
    [ "$status" -eq 0 ]
  done
  # Count CONTENT_PLACEHOLDER occurrences — exactly 7 (one per content section).
  count="$(grep -c '^{CONTENT_PLACEHOLDER}$' "$out_file" || true)"
  [ "$count" = "7" ]
}

@test "AC2: stdout lists seven content section names in declaration order" {
  out_file="$TEST_TMP/E99-S1-scaffold.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  expected="User Story
Acceptance Criteria
Tasks / Subtasks
Dev Notes
Technical Notes
Dependencies
Test Scenarios"
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# AC3 — idempotent re-run (Scenario 4)
# ---------------------------------------------------------------------------

@test "AC3: two invocations with identical inputs produce byte-identical output" {
  out_file_1="$TEST_TMP/run1.md"
  out_file_2="$TEST_TMP/run2.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file_1" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file_2" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  run cmp "$out_file_1" "$out_file_2"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4 — error paths (Scenarios 5, 6, 7)
# ---------------------------------------------------------------------------

@test "AC4: missing template file exits non-zero with stderr 'template not found'; no output created" {
  out_file="$TEST_TMP/should-not-exist.md"
  run "$SCRIPT" --template "/nonexistent/path/template.md" --output "$out_file" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -ne 0 ]
  [[ "$output" == *"template not found"* ]]
  [ ! -f "$out_file" ]
}

@test "AC4: malformed frontmatter YAML exits non-zero with stderr message; no output created" {
  out_file="$TEST_TMP/should-not-exist.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "not: : valid: yaml"
  [ "$status" -ne 0 ]
  [ ! -f "$out_file" ]
}

@test "AC4: missing parent directory of --output exits non-zero; no output created" {
  out_file="/tmp/gaia-scaffold-does-not-exist-$$/foo.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -ne 0 ]
  [[ "$output" == *"parent"* ]] || [[ "$output" == *"directory"* ]]
  [ ! -f "$out_file" ]
}

# ---------------------------------------------------------------------------
# Status override discipline (ADR-074 C3, Scenario 8)
# ---------------------------------------------------------------------------

@test "Status override: caller-supplied status: in-progress is overridden to backlog" {
  out_file="$TEST_TMP/E99-S1-status-override.md"
  override_yaml='---
key: "E99-S1"
title: "Status override probe"
epic: "E99"
status: in-progress
priority: "P1"
size: "M"
points: 3
risk: "medium"
date: "2026-04-29"
author: "gaia-create-story"
---'
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file" --frontmatter "$override_yaml"
  [ "$status" -eq 0 ]
  run grep -F 'status: backlog' "$out_file"
  [ "$status" -eq 0 ]
  run grep -F 'status: in-progress' "$out_file"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Frontmatter via stdin (Scenario 9)
# ---------------------------------------------------------------------------

@test "Stdin: --frontmatter - reads YAML from stdin equivalently" {
  out_file_arg="$TEST_TMP/by-arg.md"
  out_file_stdin="$TEST_TMP/by-stdin.md"
  run "$SCRIPT" --template "$TEMPLATE" --output "$out_file_arg" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' \"\$FRONTMATTER_YAML\" | '$SCRIPT' --template '$TEMPLATE' --output '$out_file_stdin' --frontmatter -"
  [ "$status" -eq 0 ]
  run cmp "$out_file_arg" "$out_file_stdin"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Scope guard — script writes only to --output (and its mktemp staging)
# ---------------------------------------------------------------------------

@test "Scope guard: script never opens out-of-scope files for writing" {
  # The script must never use cat/sed/awk/yq with write redirection or `mv`
  # against any of the canonical out-of-scope status surfaces. Comment
  # references (the script header documents the contract) are allowed; only
  # write/mv operations against these literals are forbidden.
  run grep -nE '(>+|mv[[:space:]])[^|]*(sprint-status\.yaml|epics-and-stories\.md|story-index\.yaml|test-plan\.md)' "$SCRIPT"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Header invariants
# ---------------------------------------------------------------------------

@test "Header: script exists at canonical path" {
  [ -f "$SCRIPT" ]
}

@test "Header: script is executable (mode 0755)" {
  [ -x "$SCRIPT" ]
  local mode
  if mode="$(stat -f '%Lp' "$SCRIPT" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' "$SCRIPT")"
  fi
  [ "$mode" = "755" ]
}

@test "Header: script begins with #!/usr/bin/env bash" {
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "Header: script sets 'set -euo pipefail'" {
  run grep -E '^set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Header: script sets 'LC_ALL=C'" {
  run grep -E '^LC_ALL=C|^export LC_ALL' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Usage errors
# ---------------------------------------------------------------------------

@test "Usage: missing --template exits non-zero" {
  run "$SCRIPT" --output "$TEST_TMP/x.md" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -ne 0 ]
}

@test "Usage: missing --output exits non-zero" {
  run "$SCRIPT" --template "$TEMPLATE" --frontmatter "$FRONTMATTER_YAML"
  [ "$status" -ne 0 ]
}

@test "Usage: missing --frontmatter exits non-zero" {
  run "$SCRIPT" --template "$TEMPLATE" --output "$TEST_TMP/x.md"
  [ "$status" -ne 0 ]
}

@test "Usage: unknown flag exits non-zero" {
  run "$SCRIPT" --template "$TEMPLATE" --output "$TEST_TMP/x.md" --frontmatter "$FRONTMATTER_YAML" --bogus value
  [ "$status" -ne 0 ]
}

@test "Usage: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--template"* ]]
  [[ "$output" == *"--output"* ]]
  [[ "$output" == *"--frontmatter"* ]]
}
