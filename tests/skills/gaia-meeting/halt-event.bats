#!/usr/bin/env bats
# halt-event.bats — gaia-meeting structured halt-event emitter (E76-S6)
#
# AC9 / FR-MTG-28 / NFR-MTG-1: every hard guardrail emits a single structured
# halt event of the form
#   HALT condition=<NAME> agent=<ID|—> fr=<FR-MTG-ID> detail=<text>
# The halt event is the terminal live-stream event — no subsequent turn output.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/halt-event.sh"
}

@test "Pre-flight: halt-event.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC9: emits canonical HALT line with all four required fields" {
  run "$HELPER" \
    --condition CHARTER-MISSING \
    --fr FR-MTG-28 \
    --detail "charter not provided"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"condition=CHARTER-MISSING"* ]]
  [[ "$output" == *"fr=FR-MTG-28"* ]]
  [[ "$output" == *"detail=charter not provided"* ]]
}

@test "AC9: agent field defaults to em-dash when not provided" {
  run "$HELPER" \
    --condition RESEARCH-MISSING \
    --fr FR-MTG-28 \
    --detail "no prelude"
  [ "$status" -eq 0 ]
  # Em-dash for non-agent halts
  [[ "$output" == *"agent=—"* ]]
}

@test "AC9: agent field carries agent-id when provided" {
  run "$HELPER" \
    --condition CITE-OR-FLAG \
    --agent theo \
    --fr FR-MTG-28 \
    --detail "unflagged-inference"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=theo"* ]]
}

@test "AC9: WRITE-BOUNDARY-VIOLATION condition is recognized" {
  run "$HELPER" \
    --condition WRITE-BOUNDARY-VIOLATION \
    --fr FR-MTG-31 \
    --detail "sprint-status.yaml refused"
  [ "$status" -eq 0 ]
  [[ "$output" == *"condition=WRITE-BOUNDARY-VIOLATION"* ]]
  [[ "$output" == *"fr=FR-MTG-31"* ]]
}

@test "AC9: emits a single line with no trailing turn header" {
  run "$HELPER" --condition CHARTER-MISSING --fr FR-MTG-28 --detail "x"
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$line_count" = "1" ]
}

@test "AC9: missing --condition fails with exit 3" {
  run "$HELPER" --fr FR-MTG-28 --detail "x"
  [ "$status" -eq 3 ]
}

@test "AC9: missing --fr fails with exit 3" {
  run "$HELPER" --condition CHARTER-MISSING --detail "x"
  [ "$status" -eq 3 ]
}

@test "AC9: missing --detail fails with exit 3" {
  run "$HELPER" --condition CHARTER-MISSING --fr FR-MTG-28
  [ "$status" -eq 3 ]
}
