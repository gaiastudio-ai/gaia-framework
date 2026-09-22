#!/usr/bin/env bats
# stream-header.bats — gaia-meeting per-turn header renderer (E76-S1)
#
# AC6 / TC-MTG-STREAM-1: header carries round / turn / speaker / role / per-turn cost / running total
# AC7 / TC-MTG-STREAM-3: user interjection name resolves via meeting.user_name override -> git config user.name
# NFR-MTG-1: cadence counter advances per emitted turn (not per round-robin slot)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/turn-header.sh"
  RESOLVE_USER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/resolve-user-name.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: turn-header.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "Pre-flight: resolve-user-name.sh exists and is executable" {
  [ -x "$RESOLVE_USER" ]
}

@test "the turn header carries all six required fields" {
  run "$HELPER" --round 1 --turn 1 --speaker "Theo" --role "Architect" --turn-cost 100 --running-total 100
  [ "$status" -eq 0 ]
  [[ "$output" == *"round 1"* ]]
  [[ "$output" == *"turn 1"* ]]
  [[ "$output" == *"Theo"* ]]
  [[ "$output" == *"Architect"* ]]
  [[ "$output" == *"100"* ]]
}

@test "the turn header begins with an opening bracket and ends with a closing bracket on one line" {
  run "$HELPER" --round 2 --turn 7 --speaker "Derek" --role "PM" --turn-cost 250 --running-total 1750
  [ "$status" -eq 0 ]
  # Single line, bracketed
  [[ "$output" == "["*"]" ]]
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$line_count" = "1" ]
}

@test "the turn header carries per-turn and running-total tokens for parser stability" {
  run "$HELPER" --round 1 --turn 3 --speaker "Nate" --role "ScrumMaster" --turn-cost 50 --running-total 300
  [ "$status" -eq 0 ]
  [[ "$output" == *"per-turn"* ]]
  [[ "$output" == *"running-total"* ]]
}

@test "a configured meeting user name overrides the git-configured user name" {
  cat > "$TMP/settings.json" <<'JSON'
{
  "meeting": {
    "user_name": "OverrideName"
  }
}
JSON
  run "$RESOLVE_USER" --settings "$TMP/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "OverrideName" ]
}

@test "a missing settings file falls through to the git-configured user name" {
  # Set up an isolated git config
  cd "$TMP"
  git init -q
  git config user.name "FallbackUser"
  run "$RESOLVE_USER" --settings "$TMP/nonexistent.json"
  [ "$status" -eq 0 ]
  [ "$output" = "FallbackUser" ]
}

@test "a settings file without a meeting user name falls through to git" {
  cat > "$TMP/settings.json" <<'JSON'
{
  "other": "value"
}
JSON
  cd "$TMP"
  git init -q
  git config user.name "GitUserOnly"
  run "$RESOLVE_USER" --settings "$TMP/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "GitUserOnly" ]
}

@test "the cadence counter is documented as counting emitted turns rather than slots" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
  [ -f "$SKILL_FILE" ]
  grep -qE "per.emitted.turn|per emitted turn" "$SKILL_FILE"
}
