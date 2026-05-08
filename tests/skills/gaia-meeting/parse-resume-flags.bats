#!/usr/bin/env bats
# parse-resume-flags.bats — gaia-meeting --resume / --continue / --interject / --wrap-up parser
# (E76-S7, AC3, TC-MTG-CHKPT-3, TC-MTG-CHKPT-4, TC-MTG-CHKPT-5)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/parse-resume-flags.sh"
}

@test "Pre-flight: parse-resume-flags.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC3: --resume <id> --continue resolves to action=continue" {
  run "$HELPER" --resume 2026-05-08-test --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume_id=2026-05-08-test"* ]]
  [[ "$output" == *"action=continue"* ]]
}

@test "AC3: --resume <id> --interject \"text\" resolves to action=interject with payload" {
  run "$HELPER" --resume 2026-05-08-test --interject "review the auth ADR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=interject"* ]]
  [[ "$output" == *"interject_text=review the auth ADR"* ]]
}

@test "AC3: --resume <id> --wrap-up resolves to action=wrap_up" {
  run "$HELPER" --resume 2026-05-08-test --wrap-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=wrap_up"* ]]
}

@test "AC3: --continue without --resume exits non-zero (resume is mandatory)" {
  run "$HELPER" --continue
  [ "$status" -ne 0 ]
}

@test "AC3: --interject without --resume exits non-zero" {
  run "$HELPER" --interject "hello"
  [ "$status" -ne 0 ]
}

@test "AC3: --wrap-up without --resume exits non-zero" {
  run "$HELPER" --wrap-up
  [ "$status" -ne 0 ]
}

@test "AC3: stacking --continue and --wrap-up exits non-zero" {
  run "$HELPER" --resume id --continue --wrap-up
  [ "$status" -ne 0 ]
}

@test "AC3: bare --resume <id> with no action resolves to action=resume_default" {
  run "$HELPER" --resume 2026-05-08-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=resume_default"* ]]
}

@test "AC3: no flags at all -> action=fresh" {
  run "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=fresh"* ]]
}
