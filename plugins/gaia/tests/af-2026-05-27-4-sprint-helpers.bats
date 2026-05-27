#!/usr/bin/env bats
# af-2026-05-27-4-sprint-helpers.bats
#
# AF-2026-05-27-4 / Test05 F-033, F-034.
#
# F-033 — after /gaia-sprint-close the live sprint-status.yaml persists with
#   status: closed (the close ceremony archives a COPY, not a move). The next
#   sprint's `sprint-state.sh init` hard-refused on that residual, forcing a
#   manual `rm`. Now init RE-SEEDS over a CLOSED predecessor (state preserved in
#   sprint-archive/) but still REFUSES a non-closed (planned/active/review) one.
# F-034 — new sanctioned setter set-story-sprint.sh writes the story-file
#   sprint_id frontmatter (the field sprint-state.sh inject's drift guard reads).

load 'test_helper.bash'

setup() {
  common_setup
  SS="$SCRIPTS_DIR/sprint-state.sh"
  SETTER="$SCRIPTS_DIR/set-story-sprint.sh"
  YAML="$TEST_TMP/sprint-status.yaml"
  export SPRINT_STATUS_YAML="$YAML"
  IA="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IA"
  export IMPLEMENTATION_ARTIFACTS="$IA"
  export PROJECT_PATH="$TEST_TMP"
}
teardown() { common_teardown; }

_seed_yaml() { # $1 = status
  cat > "$YAML" <<EOF
sprint_id: "sprint-1"
status: $1
total_points: 0
goals: []
items: []
EOF
}

# ---------- F-033: init vs predecessor status ----------

@test "F-033: init refuses when an ACTIVE sprint yaml already exists" {
  _seed_yaml active
  run "$SS" init --sprint-id sprint-2
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite a non-closed sprint"* ]]
}

@test "F-033: init refuses when a PLANNED sprint yaml already exists" {
  _seed_yaml planned
  run "$SS" init --sprint-id sprint-2
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-closed"* ]]
}

@test "F-033: init RE-SEEDS over a CLOSED predecessor (no manual rm needed)" {
  _seed_yaml closed
  run "$SS" init --sprint-id sprint-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-seeding over closed predecessor"* ]]
  # The yaml is now the fresh sprint-2 seed (planned).
  grep -q '^sprint_id: "sprint-2"' "$YAML"
  grep -q '^status: planned' "$YAML"
}

@test "F-033: init still seeds cleanly when NO yaml exists (greenfield unchanged)" {
  rm -f "$YAML"
  run "$SS" init --sprint-id sprint-1
  [ "$status" -eq 0 ]
  grep -q '^sprint_id: "sprint-1"' "$YAML"
  grep -q '^status: planned' "$YAML"
}

# ---------- F-034: set-story-sprint.sh ----------

_write_story() { # $1 = path ; $2 = key ; $3 = sprint_id line (verbatim, or empty to omit)
  local path="$1" key="$2" sid="${3-}"
  mkdir -p "$(dirname "$path")"
  {
    printf -- '---\n'
    printf 'template: %s\n' "'story'"
    printf 'key: "%s"\n' "$key"
    printf 'title: "Foo"\n'
    printf 'status: backlog\n'
    [ -n "$sid" ] && printf '%s\n' "$sid"
    printf 'epic: "%s"\n' "${key%%-*}"
    printf -- '---\n# Story\n'
  } > "$path"
}

@test "F-034: set-story-sprint sets sprint_id (quoted) on a new-layout story" {
  _write_story "$IA/epic-E1-x/E1-S1-foo/story.md" "E1-S1" 'sprint_id: null'
  run bash "$SETTER" E1-S1 --sprint sprint-7
  [ "$status" -eq 0 ]
  grep -q '^sprint_id: "sprint-7"$' "$IA/epic-E1-x/E1-S1-foo/story.md"
}

@test "F-034: set-story-sprint --sprint null clears the field (unquoted bareword)" {
  _write_story "$IA/epic-E1-x/E1-S2-bar/story.md" "E1-S2" 'sprint_id: "sprint-7"'
  run bash "$SETTER" E1-S2 --sprint null
  [ "$status" -eq 0 ]
  grep -q '^sprint_id: null$' "$IA/epic-E1-x/E1-S2-bar/story.md"
}

@test "F-034: set-story-sprint INSERTS sprint_id when the field is absent" {
  _write_story "$IA/E3-S1-baz.md" "E3-S1" ""   # no sprint_id line
  run bash "$SETTER" E3-S1 --sprint sprint-3
  [ "$status" -eq 0 ]
  grep -q '^sprint_id: "sprint-3"$' "$IA/E3-S1-baz.md"
  # frontmatter is still valid (still has the closing fence after insertion)
  [ "$(grep -c '^---$' "$IA/E3-S1-baz.md")" -ge 2 ]
}

@test "F-034: set-story-sprint does NOT touch the story status field" {
  _write_story "$IA/epic-E1-x/E1-S3-qux/story.md" "E1-S3" 'sprint_id: null'
  run bash "$SETTER" E1-S3 --sprint sprint-9
  [ "$status" -eq 0 ]
  grep -q '^status: backlog$' "$IA/epic-E1-x/E1-S3-qux/story.md"
}

@test "F-034: set-story-sprint fails clearly for an unknown story key" {
  run bash "$SETTER" E9-S9 --sprint sprint-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "F-034: set-story-sprint requires the --sprint flag" {
  _write_story "$IA/E4-S1-x.md" "E4-S1" 'sprint_id: null'
  run bash "$SETTER" E4-S1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--sprint"* ]]
}
