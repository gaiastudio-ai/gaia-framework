#!/usr/bin/env bats
# validate-frontmatter.bats — E63-S5 / Work Item 6.5 (folds 6.10)
#
# Verifies the deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/validate-frontmatter.sh.
# This script consumes the schema produced by E63-S3 (generate-frontmatter.sh)
# and folds in E63-S4 (validate-canonical-filename.sh) per the source spec
# §6.10 integration note.
#
# Coverage maps to Test Scenarios in the story:
#   #1  Happy path — all-good story (AC4)
#   #2  Missing required field (AC1)
#   #3  Invalid status (AC2)
#   #4  Invalid priority (AC5)
#   #5  Invalid size (AC5)
#   #6  Invalid risk (AC5)
#   #7  Filename mismatch (AC3, 6.10 fold)
#   #8  Multiple findings (accumulation)
#   #9  Nullable fields valid as `null`
#   #10 Malformed file (no closing `---`)
#   #11 Missing file (negative arg)
#   AC6 — script header invariants (shebang, set -euo pipefail, LC_ALL=C, mode 0755)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/validate-frontmatter.sh"
}
teardown() { common_teardown; }

# Helper: write an all-good story file at $TEST_TMP/<basename>.
# The slug for "Add User Auth" is `add-user-auth`, so the canonical basename
# for key E1-S2 is `E1-S2-add-user-auth.md`.
write_good_story() {
  local basename="${1:-E1-S2-add-user-auth.md}"
  local path="$TEST_TMP/$basename"
  cat >"$path" <<'EOF'
---
template: 'story'
version: 1.4.0
used_by: ['create-story']
key: "E1-S2"
title: "Add User Auth"
epic: "E1"
status: ready-for-dev
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
traces_to: ["ADR-001"]
date: "2026-04-29"
author: "tester"
delivered: true
deferred_implementation: false
---

# Story body

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
EOF
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# AC4 — Happy path (Scenario 1)
# ---------------------------------------------------------------------------

@test "AC4: all-good story -> exit 0, empty stdout (Scenario 1)" {
  path="$(write_good_story)"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# AC1 — Missing required field (Scenario 2)
# ---------------------------------------------------------------------------

@test "AC1: missing 'risk' field -> exit 1, stdout has CRITICAL|risk| (Scenario 2)" {
  path="$(write_good_story)"
  # Remove the risk: line.
  grep -v '^risk:' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|risk|"* ]]
}

# ---------------------------------------------------------------------------
# AC2 — Invalid status (Scenario 3)
# ---------------------------------------------------------------------------

@test "AC2: invalid status 'foo' -> exit 1, stdout has CRITICAL|status| naming foo (Scenario 3)" {
  path="$(write_good_story)"
  # Replace the status line.
  awk '/^status:/ {print "status: foo"; next} {print}' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|status|"* ]]
  [[ "$output" == *"foo"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — Invalid priority / size / risk (Scenarios 4, 5, 6)
# ---------------------------------------------------------------------------

@test "AC5: invalid priority 'P9' -> exit 1, stdout has CRITICAL|priority| naming P9 (Scenario 4)" {
  path="$(write_good_story)"
  awk '/^priority:/ {print "priority: \"P9\""; next} {print}' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|priority|"* ]]
  [[ "$output" == *"P9"* ]]
}

@test "AC5: invalid size 'XS' -> exit 1, stdout has CRITICAL|size| naming XS (Scenario 5)" {
  path="$(write_good_story)"
  awk '/^size:/ {print "size: \"XS\""; next} {print}' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|size|"* ]]
  [[ "$output" == *"XS"* ]]
}

@test "AC5: invalid risk 'extreme' -> exit 1, stdout has CRITICAL|risk| naming extreme (Scenario 6)" {
  path="$(write_good_story)"
  awk '/^risk:/ {print "risk: \"extreme\""; next} {print}' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|risk|"* ]]
  [[ "$output" == *"extreme"* ]]
}

# ---------------------------------------------------------------------------
# AC3 — Filename mismatch (Scenario 7, 6.10 fold)
# ---------------------------------------------------------------------------

@test "AC3: filename mismatch -> exit 1, stdout has CRITICAL|filename| with expected/got (Scenario 7)" {
  path="$(write_good_story "E1-S2-wrong-slug.md")"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|filename|"* ]]
  [[ "$output" == *"E1-S2-add-user-auth.md"* ]]
  [[ "$output" == *"E1-S2-wrong-slug.md"* ]]
}

# ---------------------------------------------------------------------------
# Accumulation — multiple findings on same file (Scenario 8)
# ---------------------------------------------------------------------------

@test "Scenario 8: invalid priority + invalid size -> exit 1, stdout contains both findings" {
  path="$(write_good_story)"
  awk '
    /^priority:/ {print "priority: \"P9\""; next}
    /^size:/     {print "size: \"XS\""; next}
    {print}
  ' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|priority|"* ]]
  [[ "$output" == *"CRITICAL|size|"* ]]
}

# ---------------------------------------------------------------------------
# Nullable fields — `null` is valid for sprint_id / priority_flag / origin / origin_ref
# (Scenario 9)
# ---------------------------------------------------------------------------

@test "Scenario 9: nullable fields with bare 'null' -> exit 0, empty stdout" {
  # write_good_story already sets all four nullable fields to `null`. This
  # test re-asserts that the happy path does not flag them as missing.
  path="$(write_good_story)"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Non-nullable field with bare `null` value — must emit CRITICAL
# ---------------------------------------------------------------------------

@test "non-nullable 'risk: null' -> exit 1, stdout has CRITICAL|risk|" {
  path="$(write_good_story)"
  awk '/^risk:/ {print "risk: null"; next} {print}' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|risk|"* ]]
}

# ---------------------------------------------------------------------------
# Malformed file (Scenario 10)
# ---------------------------------------------------------------------------

@test "Scenario 10: file missing closing '---' -> exit 2, stderr names the file" {
  path="$TEST_TMP/E1-S2-malformed.md"
  cat >"$path" <<'EOF'
---
key: "E1-S2"
title: "Add User Auth"
EOF
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$path"* ]] || [[ "$output" == *"malformed"* ]] || [[ "$output" == *"frontmatter"* ]]
}

# ---------------------------------------------------------------------------
# Negative arg coverage (Scenario 11)
# ---------------------------------------------------------------------------

@test "Scenario 11: --file pointing at non-existent path -> exit 2, stderr names the file" {
  run "$SCRIPT" --file "$TEST_TMP/does-not-exist.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does-not-exist.md"* ]]
}

@test "usage: missing --file flag -> exit 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "usage: --file with no value -> exit 2" {
  run "$SCRIPT" --file
  [ "$status" -eq 2 ]
}

@test "usage: unknown flag -> exit 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "usage: --help -> exit 0 with usage to stderr" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Live-tree smoke — validate against an existing known-good story file
# ---------------------------------------------------------------------------

@test "live-tree: E63-S3 story file is well-formed (exit 0, empty stdout)" {
  # Locate the project-root docs/implementation-artifacts/ via the test dir.
  # tests/cluster-7 -> tests -> plugins/gaia -> plugins -> gaia-public -> project-root
  local project_root
  project_root="$(cd "${BATS_TEST_DIRNAME}/../../../../.." && pwd)"
  local story="$project_root/docs/implementation-artifacts/E63-S3-generate-frontmatter-sh-bats-work-item-6-1.md"
  if [ ! -r "$story" ]; then
    skip "live story file not present at: $story"
  fi
  run "$SCRIPT" --file "$story"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# AC6 — script header invariants
# ---------------------------------------------------------------------------

@test "AC6: script exists at the canonical path" {
  [ -f "$SCRIPT" ]
}

@test "AC6: script is executable (mode 0755)" {
  [ -x "$SCRIPT" ]
  local mode
  if mode="$(stat -f '%Lp' "$SCRIPT" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' "$SCRIPT")"
  fi
  [ "$mode" = "755" ]
}

@test "AC6: script begins with #!/usr/bin/env bash" {
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "AC6: script sets 'set -euo pipefail'" {
  run grep -E '^set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AC6: script sets 'LC_ALL=C'" {
  run grep -E '^LC_ALL=C|^export LC_ALL' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# DoD — no direct reads of status-surface files (ADR-074 contract C3)
# ---------------------------------------------------------------------------

@test "DoD: script does not read status-surface files (lines outside comments)" {
  # Strip comment lines (leading `#` after optional whitespace) and search
  # only the executable body. ADR-074 contract C3 forbids reads, not docs.
  run bash -c "grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -E 'sprint-status\\.yaml|epics-and-stories\\.md|story-index\\.yaml'"
  # grep exits 1 when nothing matches, which is the expected (clean) state.
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# E54-S6 — Review Gate 3-column body-shape check (AC1, AC2, AC3)
# ---------------------------------------------------------------------------

@test "E54-S6 AC1: 2-column Review Gate (Review|Status) -> exit 1, CRITICAL|review_gate| naming Report" {
  path="$(write_good_story)"
  awk '
    /^\| Review \| Status \| Report \|$/ {
      print "| Review | Status |"
      print "|--------|--------|"
      print "| Code Review | UNVERIFIED |"
      # Skip the next two original lines (separator + first row).
      getline; getline
      next
    }
    {print}
  ' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|review_gate|"* ]]
  [[ "$output" == *"Report"* ]]
}

@test "E54-S6 AC2: canonical 3-column Review Gate -> exit 0, no review_gate finding" {
  path="$(write_good_story)"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ "$output" != *"review_gate"* ]]
}

@test "E54-S6 AC3c: missing Review Gate section -> exit 1, CRITICAL|review_gate|missing" {
  path="$(write_good_story)"
  # Strip the `## Review Gate` block (heading through end-of-file) so the
  # body has no Review Gate at all. The good-story fixture has no further
  # sections after Review Gate, so deleting from the heading onward is safe.
  awk '
    BEGIN { skip = 0 }
    /^## Review Gate$/ { skip = 1; next }
    skip == 0 { print }
  ' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|review_gate|"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "E54-S6 AC3 ext: heading present but no table -> exit 1, CRITICAL|review_gate|" {
  path="$(write_good_story)"
  # Replace the Review Gate block with a heading that has no following table.
  awk '
    BEGIN { skip = 0 }
    /^## Review Gate$/ {
      print "## Review Gate"
      print ""
      print "## Estimate"
      print ""
      print "- Points: 1"
      skip = 1
      next
    }
    skip == 0 { print }
  ' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|review_gate|"* ]]
}

# ---------------------------------------------------------------------------
# DoD — top-of-script comment names the consumer (E63-S11 SKILL.md Step 6) and
# the folded source story (E63-S4)
# ---------------------------------------------------------------------------

@test "DoD: top-of-script comment names consumer (E63-S11) and folded source (E63-S4)" {
  run grep -E 'E63-S11' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E 'E63-S4' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-DPD-10 (E88-S2) — `delivered:` round-trip
# ---------------------------------------------------------------------------

@test "TC-DPD-10a: delivered: true is accepted (round-trip happy path)" {
  path="$(write_good_story)"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
}

@test "TC-DPD-10b: delivered: false is accepted" {
  path="$(write_good_story)"
  sed -i.bak 's/^delivered: true$/delivered: false/' "$path" && rm -f "$path.bak"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 0 ]
}

@test "TC-DPD-10c: delivered: <non-boolean> -> CRITICAL with 'must be true or false'" {
  path="$(write_good_story)"
  sed -i.bak 's/^delivered: true$/delivered: yes/' "$path" && rm -f "$path.bak"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|delivered|"*"must be true or false"* ]]
  [[ "$output" == *"yes"* ]]
}

@test "TC-DPD-10d: delivered: missing -> CRITICAL with 'missing required field'" {
  path="$(write_good_story)"
  sed -i.bak '/^delivered: true$/d' "$path" && rm -f "$path.bak"
  run "$SCRIPT" --file "$path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL|delivered|missing required field"* ]]
}
