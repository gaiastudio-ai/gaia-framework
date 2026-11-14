#!/usr/bin/env bats
# sample-test.bats — fixture test for mutation adapter tests.
# References sample-script.sh by name (covering-test selection key).

@test "check_value returns 0 for zero input" {
  source "$BATS_TEST_DIRNAME/sample-script.sh" 2>/dev/null || true
  run check_value 0
  [ "$status" -eq 0 ]
}

@test "compare_strings detects equal strings" {
  source "$BATS_TEST_DIRNAME/sample-script.sh" 2>/dev/null || true
  run compare_strings "hello" "hello"
  [ "$status" -eq 0 ]
  [[ "$output" == *"equal"* ]]
}
