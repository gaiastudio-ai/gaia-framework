#!/usr/bin/env bats
# detect-open-questions.bats — unit tests for E44-S7 open-question detector.
# Covers AC1..AC4 and selected AC-EC items (AC-EC2 unreadable, AC-EC4 HTML
# comments, AC-EC7 binary, plus the word-boundary false-positive guard
# called out in Subtask 2.3 / VCP-OQD-06 and the checked-checkbox guard
# called out in VCP-OQD-07).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/detect-open-questions.sh"
}
teardown() { common_teardown; }

@test "detect-open-questions.sh: --help exits 0 and shows usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "detect-open-questions.sh: missing argument exits non-zero" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "detect-open-questions.sh: AC-EC2 unreadable file exits non-zero with stderr" {
  run "$SCRIPT" "$TEST_TMP/does-not-exist.md"
  [ "$status" -ne 0 ]
}

@test "detect-open-questions.sh: AC1 single TBD reports line + context" {
  cat > "$TEST_TMP/a.md" <<'EOF'
# Spec

Throughput: 100 rps
Performance target: TBD
Latency p95: 200 ms
EOF
  run "$SCRIPT" "$TEST_TMP/a.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Open Questions Detected:"* ]]
  [[ "$output" == *"TBD"* ]]
  [[ "$output" == *"L4"* ]]
  [[ "$output" == *"Performance target: TBD"* ]]
}

@test "detect-open-questions.sh: AC2 mixed markers — 1 TBD + 2 TODO + 3 unchecked = 6 findings" {
  cat > "$TEST_TMP/b.md" <<'EOF'
# Mixed

Goal: TBD
- TODO research vendor X
- TODO survey users
- [ ] Define metric A
- [ ] Define metric B
- [ ] Define metric C
EOF
  run "$SCRIPT" "$TEST_TMP/b.md"
  [ "$status" -eq 0 ]
  # Group counts in header lines
  [[ "$output" == *"TBD (1 found)"* ]]
  [[ "$output" == *"TODO (2 found)"* ]]
  [[ "$output" == *"Unchecked checkboxes (3 found)"* ]]
}

@test "detect-open-questions.sh: AC3 clean artifact — silent, exit 0" {
  cat > "$TEST_TMP/clean.md" <<'EOF'
# Clean Spec

Throughput target: 100 rps.
Latency p95: 200 ms.
- [x] Defined metric A
- [X] Defined metric B
EOF
  run "$SCRIPT" "$TEST_TMP/clean.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect-open-questions.sh: AC4 empty Open Questions section is NOT flagged" {
  cat > "$TEST_TMP/empty-oq.md" <<'EOF'
# Spec

## Overview

Some content.

## Open Questions

## Decisions

Done.
EOF
  run "$SCRIPT" "$TEST_TMP/empty-oq.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect-open-questions.sh: AC4 non-empty Open Questions section IS flagged" {
  cat > "$TEST_TMP/full-oq.md" <<'EOF'
# Spec

## Open Questions

Should we use vendor X or build in-house?

## Decisions

Done.
EOF
  run "$SCRIPT" "$TEST_TMP/full-oq.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Open Questions sections"* ]]
  [[ "$output" == *"L3"* ]]
}

@test "detect-open-questions.sh: word boundaries — STUBBORN/ATODOLIST/METHODOLOGY do not hit" {
  cat > "$TEST_TMP/wb.md" <<'EOF'
# Tone

A STUBBORN bug.
The ATODOLIST naming is bad.
Apply our METHODOLOGY consistently.
EOF
  run "$SCRIPT" "$TEST_TMP/wb.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect-open-questions.sh: checked checkboxes are not flagged" {
  cat > "$TEST_TMP/checked.md" <<'EOF'
# Tasks

- [x] First
- [X] Second
EOF
  run "$SCRIPT" "$TEST_TMP/checked.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect-open-questions.sh: needs decision literal is flagged case-insensitively" {
  cat > "$TEST_TMP/nd.md" <<'EOF'
# Spec

Pricing model (needs decision).
Tier names (NEEDS DECISION).
EOF
  run "$SCRIPT" "$TEST_TMP/nd.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs-decision"* ]] || [[ "$output" == *"needs decision"* ]]
}

@test "detect-open-questions.sh: AC-EC4 markers inside HTML comments are flagged" {
  cat > "$TEST_TMP/html.md" <<'EOF'
# Spec

<!-- TBD: pricing tiers -->
EOF
  run "$SCRIPT" "$TEST_TMP/html.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TBD"* ]]
  [[ "$output" == *"L3"* ]]
}

@test "detect-open-questions.sh: non-modification — file unchanged after scan" {
  cat > "$TEST_TMP/c.md" <<'EOF'
Goal: TBD
- [ ] open
EOF
  before="$(shasum -a 256 "$TEST_TMP/c.md" | awk '{print $1}')"
  "$SCRIPT" "$TEST_TMP/c.md" >/dev/null || true
  after="$(shasum -a 256 "$TEST_TMP/c.md" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "detect-open-questions.sh: AC-EC7 binary input does not crash" {
  printf '\x00\x01\x02TBD\x00more\n' > "$TEST_TMP/bin.dat"
  run "$SCRIPT" "$TEST_TMP/bin.dat"
  # Detector must complete with exit 0 (informational); content of output is
  # advisory but the script must not segfault or hang.
  [ "$status" -eq 0 ]
}
