#!/usr/bin/env bash
# issue-1403-title-quote-escaping.bats
#
# A story title containing a double-quote was written into sprint-status.yaml
# (and story-index.yaml) as a double-quoted YAML scalar with the inner quotes
# left UNESCAPED, producing invalid YAML. yq then failed and /gaia-sprint-close
# (and every other yq reader/writer) was blocked. The fix emits free-text
# fields (title, epic, author) as single-quoted YAML scalars with inner `'`
# doubled, so embedded `"` and `'` round-trip safely.

load 'test_helper.bash'

setup() {
  common_setup
  SPRINT_STATE="$SCRIPTS_DIR/sprint-state.sh"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"
  export SPRINT_STATE_SCRIPT_DIR="$SCRIPTS_DIR"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART" "$MEMORY_PATH"
  # The exact #1403 repro: an embedded double-quote + em-dash. (No apostrophe —
  # the story-file frontmatter reader strips surrounding quotes but does not
  # un-double inner '\'''\'', so a double-quote is the field-sourced hazard this
  # fix targets; apostrophe-in-frontmatter decoding is a separate reader concern.)
  NASTY_TITLE='Export worker errors every poll — column "user_email" does not exist'
}
teardown() { common_teardown; }

# A YAML validity check that does not depend on yq being installed: prefer yq,
# fall back to python3.
_assert_valid_yaml() {
  local f="$1"
  if command -v yq >/dev/null 2>&1; then
    yq '.' "$f" >/dev/null 2>&1
  else
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
  fi
}

_read_title_via_yaml() {
  # Echo the round-tripped title for the first story entry.
  local f="$1"
  if command -v yq >/dev/null 2>&1; then
    yq -r '.stories[0].title' "$f" 2>/dev/null
  else
    python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(d["stories"][0]["title"])' "$f" 2>/dev/null
  fi
}

seed_backlog_story() {
  local key="$1" title="$2"
  cat > "$ART/${key}-fake.md" <<EOF
---
template: 'story'
key: "$key"
title: '$(printf '%s' "$title" | sed "s/'/''/g")'
status: ready-for-dev
sprint_id: "sprint-test"
points: 3
risk: "medium"
---

# Story: $key
EOF
}

seed_yaml_with_header() {
  cat > "$ART/sprint-status.yaml" <<EOF
sprint_id: "sprint-test"
velocity_capacity: 10
total_points: 0
capacity_utilization: "0%"
stories:
EOF
}

@test "issue-1403: inject of a quote-containing title yields VALID yaml" {
  seed_backlog_story INJQ "$NASTY_TITLE"
  seed_yaml_with_header
  run "$SPRINT_STATE" inject --story INJQ
  [ "$status" -eq 0 ] || { echo "inject failed: $output"; false; }
  # The whole file must parse.
  _assert_valid_yaml "$ART/sprint-status.yaml" \
    || { echo "INVALID YAML after inject:"; cat "$ART/sprint-status.yaml"; false; }
}

@test "issue-1403: the quote-containing title round-trips intact" {
  seed_backlog_story INJQ2 "$NASTY_TITLE"
  seed_yaml_with_header
  run "$SPRINT_STATE" inject --story INJQ2
  [ "$status" -eq 0 ]
  local got; got="$(_read_title_via_yaml "$ART/sprint-status.yaml")"
  [ "$got" = "$NASTY_TITLE" ] || { echo "title mismatch: got [$got] want [$NASTY_TITLE]"; false; }
}

@test "issue-1403: yq can read sprint_id after a quote-containing inject (close.sh unblocked)" {
  seed_backlog_story INJQ3 "$NASTY_TITLE"
  seed_yaml_with_header
  run "$SPRINT_STATE" inject --story INJQ3
  [ "$status" -eq 0 ]
  # The headline symptom: yq '.sprint_id' must succeed on the file.
  if command -v yq >/dev/null 2>&1; then
    run yq -r '.sprint_id' "$ART/sprint-status.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "sprint-test" ]
  else
    skip "yq not installed"
  fi
}

# --- transition-story-status.sh story-index.yaml writer (the sibling site) ---

@test "issue-1403: transition-story-status.sh defines the yaml_single_quote helper" {
  grep -q 'yaml_single_quote()' "$TRANSITION"
  # And the story-index emitter no longer wraps title in a raw double-quoted
  # scalar (which would corrupt on an inner ").
  ! grep -qE '^\s+printf .[[:space:]]*title: \\"%s\\"' "$TRANSITION"
}

@test "issue-1403: sprint-state.sh defines the yaml_single_quote helper" {
  grep -q 'yaml_single_quote()' "$SPRINT_STATE"
}

@test "issue-1403: yaml_single_quote doubles inner apostrophes (unit)" {
  # Source the helper out of the script without executing the pipeline.
  helper="$(awk '/^yaml_single_quote\(\) \{/,/^\}/' "$SPRINT_STATE")"
  eval "$helper"
  run yaml_single_quote "it's a \"test\""
  # Inner ' doubled, whole value single-quoted; the " is left as-is (safe in a
  # single-quoted YAML scalar).
  [ "$output" = "'it''s a \"test\"'" ]
}
