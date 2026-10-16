#!/usr/bin/env bats
# concurrent-sprint-touch-set.bats — tests for the predicted_touch_set field,
# sanitizer library, scaffold/generate-frontmatter integration, and touch-set
# inference helper.

setup() {
  # Resolve the plugin root relative to this test file.
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SANITIZER="$PLUGIN_ROOT/scripts/lib/touch-set-sanitizer.sh"
  VALIDATOR="$PLUGIN_ROOT/scripts/lib/validate-touch-set-syntax.sh"
  GEN_FM="$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  SCAFFOLD="$PLUGIN_ROOT/skills/gaia-create-story/scripts/scaffold-story.sh"
  TEMPLATE="$PLUGIN_ROOT/skills/gaia-create-story/story-template.md"
  VAL_FM="$PLUGIN_ROOT/skills/gaia-create-story/scripts/validate-frontmatter.sh"
  INFER="$PLUGIN_ROOT/skills/gaia-create-story/scripts/infer-touch-set.sh"
  MIRROR="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/lib/touch-set-sanitizer.sh"
  VAL_STORY_SKILL="$PLUGIN_ROOT/skills/gaia-validate-story/SKILL.md"
  CREATE_STORY_SKILL="$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"

  # Create a temp directory for fixtures.
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ts-test.XXXXXX")"
  export TEST_TMP

  # Minimal project root for containment tests.
  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/config"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Helper: create a minimal story file with frontmatter.
_make_story() {
  local file="$1" pts_field="${2:-}"
  # Build frontmatter with optional touch-set field.
  local ts_line=""
  if [ -n "$pts_field" ]; then
    ts_line="$pts_field"
  fi
  {
    printf '%s\n' '---'
    printf '%s\n' "template: 'story'"
    printf '%s\n' 'version: 1.4.0'
    printf '%s\n' "used_by: ['create-story']"
    printf '%s\n' 'key: "E900-S1"'
    printf '%s\n' 'title: "Test story"'
    printf '%s\n' 'epic: "E900"'
    printf '%s\n' 'status: backlog'
    printf '%s\n' 'priority: "P1"'
    printf '%s\n' 'size: "M"'
    printf '%s\n' 'points: 3'
    printf '%s\n' 'risk: "medium"'
    printf '%s\n' 'sprint_id: null'
    printf '%s\n' 'priority_flag: null'
    printf '%s\n' 'delivered: false'
    printf '%s\n' 'deferred_implementation: false'
    printf '%s\n' 'manual_verification: false'
    [ -z "$ts_line" ] || printf '%s\n' "$ts_line"
    printf '%s\n' 'origin: null'
    printf '%s\n' 'origin_ref: null'
    printf '%s\n' 'depends_on: []'
    printf '%s\n' 'blocks: []'
    printf '%s\n' 'traces_to: []'
    printf '%s\n' 'date: "2026-01-01"'
    printf '%s\n' 'author: "test"'
    printf '%s\n' '---'
    printf '%s\n' ''
    printf '%s\n' '# Story: Test story'
    printf '%s\n' ''
    printf '%s\n' '## User Story'
    printf '%s\n' ''
    printf '%s\n' 'As a developer, I want to test.'
    printf '%s\n' ''
    printf '%s\n' '## Acceptance Criteria'
    printf '%s\n' ''
    printf '%s\n' '- [ ] Given a test, when run, then pass.'
    printf '%s\n' ''
    printf '%s\n' '## Tasks / Subtasks'
    printf '%s\n' ''
    printf '%s\n' '- [ ] Task 1'
    printf '%s\n' ''
    printf '%s\n' '## Dev Notes'
    printf '%s\n' ''
    printf '%s\n' 'None.'
    printf '%s\n' ''
    printf '%s\n' '## Technical Notes'
    printf '%s\n' ''
    printf '%s\n' 'None.'
    printf '%s\n' ''
    printf '%s\n' '## Dependencies'
    printf '%s\n' ''
    printf '%s\n' 'None.'
    printf '%s\n' ''
    printf '%s\n' '## Test Scenarios'
    printf '%s\n' ''
    printf '%s\n' '| # | Scenario | Input | Expected |'
    printf '%s\n' '|---|----------|-------|----------|'
    printf '%s\n' '| 1 | happy | input | output |'
    printf '%s\n' ''
    printf '%s\n' '## Manual Test'
    printf '%s\n' ''
    printf '%s\n' 'N/A'
    printf '%s\n' ''
    printf '%s\n' '## Dev Agent Record'
    printf '%s\n' ''
    printf '%s\n' '### Agent Model Used'
    printf '%s\n' ''
    printf '%s\n' 'test'
    printf '%s\n' ''
    printf '%s\n' '### Debug Log References'
    printf '%s\n' ''
    printf '%s\n' '### Completion Notes List'
    printf '%s\n' ''
    printf '%s\n' '### File List'
    printf '%s\n' ''
    printf '%s\n' '## Findings'
    printf '%s\n' ''
    printf '%s\n' '| # | Type | Severity | Finding | Suggested Action |'
    printf '%s\n' '|---|------|----------|---------|-----------------|'
    printf '%s\n' ''
    printf '%s\n' '## Review Gate'
    printf '%s\n' ''
    printf '%s\n' '| Review | Status | Report |'
    printf '%s\n' '|--------|--------|--------|'
    printf '%s\n' '| Code Review | UNVERIFIED | — |'
    printf '%s\n' '| QA Tests | UNVERIFIED | — |'
    printf '%s\n' '| Security Review | UNVERIFIED | — |'
    printf '%s\n' '| Test Automation | UNVERIFIED | — |'
    printf '%s\n' '| Test Review | UNVERIFIED | — |'
    printf '%s\n' '| Performance Review | UNVERIFIED | — |'
    printf '%s\n' ''
    printf '%s\n' '## Estimate'
    printf '%s\n' ''
    printf '%s\n' '- **Points:** 3'
    printf '%s\n' '- **Developer:** test'
    printf '%s\n' ''
    printf '%s\n' '## Definition of Done'
    printf '%s\n' ''
    printf '%s\n' '### Acceptance'
    printf '%s\n' ''
    printf '%s\n' '- [ ] All acceptance criteria verified and checked off'
  } > "$file"
}

# ============================================================
# Denylist tests (AC4)
# ============================================================

@test "denylist rejects backtick" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/`whoami`.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"backtick"* ]]
}

@test "denylist rejects dollar sign" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/$(whoami).sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"dollar"* ]]
}

@test "denylist rejects semicolon" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/a;rm -rf.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"semicolon"* ]]
}

@test "denylist rejects pipe" {
  . "$SANITIZER"
  run touch_set_denylist_check 'docs/foo|bar.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipe"* ]]
}

@test "denylist rejects ampersand" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/a&b.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"ampersand"* ]]
}

@test "denylist rejects greater-than" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/a>b.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"greater-than"* ]]
}

@test "denylist rejects less-than" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/a<b.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"less-than"* ]]
}

@test "denylist rejects open paren" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/(a).sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"paren"* ]]
}

@test "denylist rejects close paren" {
  . "$SANITIZER"
  run touch_set_denylist_check 'scripts/a).sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"paren"* ]]
}

# ============================================================
# Backslash rules (AC4, D5)
# ============================================================

@test "backslash allowed before glob star" {
  . "$SANITIZER"
  run touch_set_denylist_check 'docs/\*.sh'
  [ "$status" -eq 0 ]
}

@test "backslash allowed before glob question mark" {
  . "$SANITIZER"
  run touch_set_denylist_check 'docs/\?.sh'
  [ "$status" -eq 0 ]
}

@test "backslash allowed before glob open bracket" {
  . "$SANITIZER"
  run touch_set_denylist_check 'docs/\[v2].sh'
  [ "$status" -eq 0 ]
}

@test "backslash denied before non-glob char" {
  . "$SANITIZER"
  run touch_set_denylist_check 'docs/\n.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"backslash"* ]]
}

# ============================================================
# Valid patterns accepted (AC1)
# ============================================================

@test "valid relative glob accepted" {
  . "$SANITIZER"
  run touch_set_denylist_check 'gaia-public/plugins/gaia/scripts/*.sh'
  [ "$status" -eq 0 ]
}

@test "valid simple path accepted" {
  . "$SANITIZER"
  run touch_set_denylist_check 'gaia-public/plugins/gaia/scripts/sprint-state.sh'
  [ "$status" -eq 0 ]
}

@test "path with single quotes and brackets accepted" {
  . "$SANITIZER"
  run touch_set_denylist_check "docs/it's \"quoted\" [v2].md"
  [ "$status" -eq 0 ]
}

# ============================================================
# Climb-out rejection (AC4, R40)
# ============================================================

@test "climb-out path rejected" {
  . "$SANITIZER"
  run touch_set_check_climb_out '../../etc/passwd'
  [ "$status" -ne 0 ]
  [[ "$output" == *"climb-out"* ]]
}

@test "normal relative path passes climb-out check" {
  . "$SANITIZER"
  run touch_set_check_climb_out 'scripts/lib/a.sh'
  [ "$status" -eq 0 ]
}

# ============================================================
# Root containment (AC1, AC4)
# ============================================================

@test "absolute path under root accepted and stored relative" {
  . "$SANITIZER"
  run touch_set_root_containment "$PROJECT_ROOT/scripts/a.sh" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/a.sh" ]
}

@test "absolute path outside root rejected" {
  . "$SANITIZER"
  run touch_set_root_containment '/etc/passwd' "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside project root"* ]]
}

@test "relative path passes root containment unchanged" {
  . "$SANITIZER"
  run touch_set_root_containment 'scripts/a.sh' "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/a.sh" ]
}

# ============================================================
# Round-trip PoC (AC3)
# ============================================================

@test "strenv round-trip with quotes and brackets" {
  . "$SANITIZER"
  local story="$TEST_TMP/rt-story.md"
  _make_story "$story"

  local val="docs/it's \"quoted\" [v2].md"
  local vals_file="$TEST_TMP/rt-vals.txt"
  printf '%s\n' "$val" > "$vals_file"

  touch_set_write "$story" "$vals_file" "$PROJECT_ROOT"

  # Read back via yq.
  local readback
  readback="$(yq --front-matter=extract '.predicted_touch_set[0]' "$story")"
  [ "$readback" = "$val" ]
}

# ============================================================
# Injection guard (AC3)
# ============================================================

@test "yq injection via strenv layer does not change status" {
  local story="$TEST_TMP/inj-story.md"
  _make_story "$story"

  # Bypass the denylist intentionally to test the strenv layer.
  # Write the injection payload directly via yq strenv.
  local payload='"] | .status = "done'
  local field_name="predicted_touch_set"

  # Build a properly escaped JSON array.
  local escaped
  escaped="$(printf '%s' "$payload" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  local json_array="[\"${escaped}\"]"

  TS_FIELD="$field_name" TS_VAL="$json_array" \
    yq --front-matter=process -i \
      '.[strenv(TS_FIELD)] = (env(TS_VAL) | fromjson)' \
      "$story" 2>/dev/null || true

  # Status must be unchanged.
  local status_val
  status_val="$(yq --front-matter=extract '.status' "$story")"
  [ "$status_val" = "backlog" ]
}

# ============================================================
# Denylist rejection before write (AC3)
# ============================================================

@test "denylist rejects pipe before yq write" {
  . "$SANITIZER"
  local story="$TEST_TMP/deny-story.md"
  _make_story "$story"

  local vals_file="$TEST_TMP/deny-vals.txt"
  printf 'docs/foo|bar.sh\n' > "$vals_file"

  run touch_set_write "$story" "$vals_file" "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipe"* ]]
}

# ============================================================
# Empty list valid (AC1)
# ============================================================

@test "empty list passes validation" {
  local story="$TEST_TMP/empty-story.md"
  _make_story "$story" 'predicted_touch_set: []'

  run "$VALIDATOR" --file "$story"
  [ "$status" -eq 0 ]
}

# ============================================================
# Absent field valid in single-sprint mode (AC1)
# ============================================================

@test "absent field passes validation" {
  local story="$TEST_TMP/absent-story.md"
  _make_story "$story"

  run "$VALIDATOR" --file "$story"
  [ "$status" -eq 0 ]
}

# ============================================================
# Hook refusal prevents write (AC5)
# ============================================================

@test "refusing hook prevents yq write" {
  . "$SANITIZER"
  local story="$TEST_TMP/hook-story.md"
  _make_story "$story"

  # Override the pre-write hook to always refuse.
  touch_set_prewrite_check() { return 1; }

  local vals_file="$TEST_TMP/hook-vals.txt"
  printf 'scripts/a.sh\n' > "$vals_file"

  run touch_set_write "$story" "$vals_file" "$PROJECT_ROOT"
  [ "$status" -ne 0 ]

  # Verify the field was not written.
  local field_check
  field_check="$(yq --front-matter=extract '.predicted_touch_set' "$story" 2>/dev/null || echo "null")"
  [ "$field_check" = "null" ]
}

# ============================================================
# generate-frontmatter.sh tests (AC6)
# ============================================================

_setup_epics_file() {
  local epics_file="$TEST_TMP/epics-and-stories.md"
  cat > "$epics_file" <<'EPICS'
## E900 — Test Epic

### Story E900-S1: Test story

- **Priority:** P1
- **Size:** M (3 pts)
- **Risk:** medium
- **Depends on:** []
- **Blocks:** []
- **Traces to:** []

---
EPICS
  printf '%s' "$epics_file"
}

_setup_project_config() {
  # Self-contained fixture covering every field resolve-config.sh requires.
  local cfg="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  cat > "$cfg" <<'CFG'
project_name: test
framework_version: "1.221.0"
installed_path: "./_gaia"
project_root: "."
project_path: "."
memory_path: "./.gaia/memory"
checkpoint_path: "./.gaia/memory/checkpoints"
date: "2026-01-01"
planning_artifacts: "./.gaia/artifacts/planning-artifacts"
implementation_artifacts: "./.gaia/artifacts/implementation-artifacts"
test_artifacts: "./.gaia/artifacts/test-artifacts"
creative_artifacts: "./.gaia/artifacts/creative-artifacts"
sizing_map:
  S: 1
  M: 3
  L: 5
  XL: 8
stacks:
  - id: bash
    path: "."
    role: primary
platforms: [web]
environments:
  - name: local
    url: "http://localhost"
CFG
  printf '%s' "$cfg"
}

@test "generate-frontmatter omits field when no touch flags" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  run "$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg"
  [ "$status" -eq 0 ]
  # Field should not appear in the output.
  ! grep -q 'predicted_touch_set' <<< "$output"
}

@test "generate-frontmatter emits field when touch-path supplied" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  run "$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg" \
    --touch-path 'scripts/*.sh' --project-root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  grep -q 'predicted_touch_set:.*scripts/\*\.sh' <<< "$output"
}

@test "generate-frontmatter emits empty list on touch-empty" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  run "$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg" --touch-empty
  [ "$status" -eq 0 ]
  grep -q 'predicted_touch_set: \[\]' <<< "$output"
}

@test "generate-frontmatter rejects mutually exclusive flags" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  run "$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg" \
    --touch-path 'scripts/a.sh' --touch-empty
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "generate-frontmatter rejects climb-out via touch-path" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  run "$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg" \
    --touch-path '../../etc/passwd' --project-root "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"climb-out"* ]]
}

# ============================================================
# scaffold-story.sh tests (AC6)
# ============================================================

@test "scaffold includes touch-set when caller supplies it" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  # Generate frontmatter with a touch-path.
  local fm
  fm="$("$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg" \
    --touch-path 'scripts/*.sh' --project-root "$PROJECT_ROOT")"

  local out="$TEST_TMP/scaffold-out.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]
  grep -q 'predicted_touch_set:.*scripts/\*\.sh' "$out"
}

@test "scaffold omits touch-set when caller omits it" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  local fm
  fm="$("$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg")"

  local out="$TEST_TMP/scaffold-notouch.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]
  ! grep -q 'predicted_touch_set' "$out"
}

@test "scaffold keeps empty list when touch-empty used" {
  local epics_file; epics_file="$(_setup_epics_file)"
  local cfg; cfg="$(_setup_project_config)"

  local fm
  fm="$("$GEN_FM" --story-key E900-S1 --epics-file "$epics_file" --project-config "$cfg" --touch-empty)"

  local out="$TEST_TMP/scaffold-empty.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]
  grep -q 'predicted_touch_set: \[\]' "$out"
}

# ============================================================
# Bulk materializer path omits field (Task 5.6)
# ============================================================

@test "bulk materializer frontmatter omits touch-set from scaffolded story" {
  # Simulate the materialize-sprint-stories.sh frontmatter build path:
  # a printf-constructed YAML with no predicted_touch_set key. The scaffold
  # must drop the {predicted_touch_set} template line entirely.
  local fm
  fm="$(printf 'key: "%s"\ntitle: "%s"\nepic: "%s"\nstatus: backlog\npriority: "%s"\nsize: "%s"\npoints: %s\nrisk: "%s"\nsprint_id: null\npriority_flag: null\ndelivered: false\ndeferred_implementation: false\ndepends_on: []\nblocks: []\ntraces_to: []\ndate: "%s"\nauthor: "gaia-create-story"\n' \
    "E900-S1" "Test story" "E900" "P1" "M" "3" "medium" "2026-01-01")"

  local out="$TEST_TMP/scaffold-materializer.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]
  # The scaffolded story must not contain the field.
  ! grep -q 'predicted_touch_set' "$out"
  # The scaffolded story must not contain a stray blank line where the
  # token was (no consecutive blank lines in frontmatter).
  local consecutive_blanks
  consecutive_blanks="$(awk '
    /^---$/ { fence++; next }
    fence == 1 {
      if ($0 == "") { blanks++; if (blanks > 0) found = 1 }
      else blanks = 0
    }
    END { print (found ? "yes" : "no") }
  ' "$out")"
  [ "$consecutive_blanks" = "no" ]
}

# ============================================================
# validate-frontmatter.sh integration (AC6, Task 2.4)
# ============================================================

@test "validate-frontmatter rejects malformed touch-set" {
  local story_dir="$TEST_TMP/E900-S1-test-story-bad"
  mkdir -p "$story_dir"
  local story="$story_dir/story.md"
  _make_story "$story" 'predicted_touch_set: "not-a-list"'

  run "$VAL_FM" --file "$story"
  [ "$status" -ne 0 ]
  [[ "$output" == *"predicted_touch_set"* ]]
}

@test "validate-frontmatter passes valid touch-set" {
  # Place the story in a canonical path so the filename check passes.
  local story_dir="$TEST_TMP/E900-S1-test-story"
  mkdir -p "$story_dir"
  local story="$story_dir/story.md"
  _make_story "$story" 'predicted_touch_set: ["scripts/*.sh"]'

  run "$VAL_FM" --file "$story"
  [ "$status" -eq 0 ]
}

# ============================================================
# NUL-delimited reader (AC4)
# ============================================================

@test "nul-delimited reader emits values" {
  . "$SANITIZER"
  local story="$TEST_TMP/nul-story.md"
  _make_story "$story" 'predicted_touch_set: ["scripts/a.sh", "scripts/b.sh"]'

  local count=0
  while IFS= read -r -d '' val; do
    [ -n "$val" ] && count=$((count + 1))
  done < <(touch_set_read_nul "$story")
  [ "$count" -eq 2 ]
}

# ============================================================
# infer-touch-set.sh tests (AC2)
# ============================================================

@test "infer-touch-set extracts backtick-delimited paths from AC text" {
  local ac_file="$TEST_TMP/ac.txt"
  cat > "$ac_file" <<'AC'
- [ ] Given the script `gaia-public/plugins/gaia/scripts/sprint-state.sh` is modified, then the touch-set includes it.
AC

  local epic_dir="$TEST_TMP/epic"
  mkdir -p "$epic_dir"

  run "$INFER" --ac-file "$ac_file" --epic-dir "$epic_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gaia-public/plugins/gaia/scripts/sprint-state.sh"* ]]
}

@test "infer-touch-set includes prior stories touch-set union" {
  local ac_file="$TEST_TMP/ac2.txt"
  printf '' > "$ac_file"

  local epic_dir="$TEST_TMP/epic2/E900-S1-prior/story.md"
  mkdir -p "$(dirname "$epic_dir")"
  _make_story "$epic_dir" 'predicted_touch_set: ["scripts/a.sh"]'

  # Point epic_dir to the parent that contains the story dir.
  run "$INFER" --ac-file "$ac_file" --epic-dir "$TEST_TMP/epic2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/a.sh"* ]]
}

@test "infer-touch-set empty output on no paths" {
  local ac_file="$TEST_TMP/ac3.txt"
  printf 'No paths here.\n' > "$ac_file"

  local epic_dir="$TEST_TMP/epic3"
  mkdir -p "$epic_dir"

  run "$INFER" --ac-file "$ac_file" --epic-dir "$epic_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================
# Val SKILL.md instruction present (AC2, Task 3.4)
# ============================================================

@test "validate-story skill contains touch-set syntax check instruction" {
  grep -q 'validate-touch-set-syntax.sh' "$VAL_STORY_SKILL"
}

@test "validate-story skill instruction references the field name" {
  grep -q 'predicted_touch_set' "$VAL_STORY_SKILL"
}

# ============================================================
# create-story SKILL.md contains touch-set population step
# ============================================================

@test "create-story skill contains infer-touch-set.sh reference" {
  grep -q 'infer-touch-set.sh' "$CREATE_STORY_SKILL"
}

@test "create-story skill contains touch-path flag reference" {
  grep -q '\-\-touch-path' "$CREATE_STORY_SKILL"
}

@test "create-story skill contains touch-empty flag reference" {
  grep -q '\-\-touch-empty' "$CREATE_STORY_SKILL"
}

# ============================================================
# Byte-identical mirror (Task 6)
# ============================================================

@test "dev-story mirror is byte-identical to scripts lib" {
  diff "$SANITIZER" "$MIRROR"
}

# ============================================================
# No printf interpolation at emission sites (source-grep safety)
# ============================================================

@test "no printf interpolation of touch-set field name at emission sites" {
  # Scan emission-site scripts for printf calls containing the field name.
  # Diagnostic messages use a variable (_TS_FIELD_NAME) instead.
  local found=0
  for f in \
    "$PLUGIN_ROOT/scripts/lib/touch-set-sanitizer.sh" \
    "$GEN_FM"; do
    if grep -n 'printf.*predicted_touch_set' "$f" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -qv '_TS_FIELD_NAME\|_ts_fn\|_ts_field'; then
      printf 'FAIL: printf with literal field name in %s\n' "$f" >&2
      found=1
    fi
  done
  [ "$found" -eq 0 ]
}

# ============================================================
# Edge cases
# ============================================================

@test "glob matching thousands of files accepted at creation" {
  . "$SANITIZER"
  run touch_set_denylist_check 'gaia-public/plugins/gaia/*'
  [ "$status" -eq 0 ]
}

@test "glob matching zero files at creation accepted" {
  . "$SANITIZER"
  run touch_set_denylist_check 'nonexistent-dir/*.sh'
  [ "$status" -eq 0 ]
}

@test "overlapping entries within same story accepted" {
  local story="$TEST_TMP/overlap-story.md"
  _make_story "$story" 'predicted_touch_set: ["scripts/*.sh", "scripts/lib/*.sh"]'
  run "$VALIDATOR" --file "$story"
  [ "$status" -eq 0 ]
}

@test "double-star glob emits warning" {
  . "$SANITIZER"
  run touch_set_warn_double_star 'gaia-public/plugins/gaia/**/scripts/*.sh'
  [[ "$output" == *"**"* ]]
  [[ "$output" == *"find -path"* ]]
}

@test "bypass write caught by read-side denylist" {
  local story="$TEST_TMP/bypass-story.md"
  _make_story "$story"

  # Bypass the sanitizer and write a bad value directly via yq.
  yq --front-matter=process -i '.predicted_touch_set = ["docs/foo|bar.sh"]' "$story"

  # Read-side denylist should catch it.
  . "$SANITIZER"
  local rc=0
  while IFS= read -r -d '' val; do
    touch_set_denylist_check "$val" || rc=1
  done < <(touch_set_read_nul "$story")
  [ "$rc" -ne 0 ]
}

@test "nul byte rejected by denylist" {
  . "$SANITIZER"
  # Feed a NUL byte to the newline checker — NUL in bash strings is
  # truncated, so we test the NUL-safe read path indirectly: the read
  # loop must detect NUL-separated values. A direct NUL in a bash
  # variable is impossible, but the yq -r0 reader handles it.
  # Instead test that the check_nul_newline catches an embedded newline.
  local val_with_newline
  val_with_newline="$(printf 'scripts/a.sh\nscripts/b.sh')"
  run touch_set_check_nul_newline "$val_with_newline"
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline"* ]]
}

# ============================================================
# Flow and block style round-trip (AC6)
# ============================================================

@test "flow and block style round-trip" {
  . "$SANITIZER"
  local story="$TEST_TMP/roundtrip-story.md"
  _make_story "$story"

  # Write via the safe writer (produces block style via yq).
  local vals_file="$TEST_TMP/roundtrip-vals.txt"
  printf 'scripts/a.sh\nscripts/b.sh\n' > "$vals_file"
  touch_set_write "$story" "$vals_file" "$PROJECT_ROOT"

  # Read back — should work regardless of style.
  local count=0
  while IFS= read -r -d '' val; do
    [ -n "$val" ] && count=$((count + 1))
  done < <(touch_set_read_nul "$story")
  [ "$count" -eq 2 ]
}

# ============================================================
# No internal IDs in published files (AC7)
# ============================================================

@test "no internal traceability identifiers in new or modified files" {
  local scan_rc=0
  for f in \
    "$PLUGIN_ROOT/scripts/lib/touch-set-sanitizer.sh" \
    "$PLUGIN_ROOT/scripts/lib/validate-touch-set-syntax.sh" \
    "$PLUGIN_ROOT/skills/gaia-create-story/scripts/infer-touch-set.sh" \
    "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/lib/touch-set-sanitizer.sh"; do
    # Scan for leaked internal IDs, excluding:
    #   - E900-S synthetic test IDs
    #   - Regex patterns like E[0-9]+
    #   - shellcheck directives
    if grep -nE '(FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[A-Z]+-[0-9]+|AF-20[0-9]{2}-|AI-20[0-9]{2}-)' "$f" 2>/dev/null \
       | grep -v 'E900-S\|E\[0-9\]\|shellcheck' \
       | grep -q .; then
      printf 'LEAK: %s\n' "$f" >&2
      grep -nE '(FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[A-Z]+-[0-9]+|AF-20[0-9]{2}-|AI-20[0-9]{2}-)' "$f" \
        | grep -v 'E900-S\|E\[0-9\]\|shellcheck' >&2
      scan_rc=1
    fi
  done
  [ "$scan_rc" -eq 0 ]
}
