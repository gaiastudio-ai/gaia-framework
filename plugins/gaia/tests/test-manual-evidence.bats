#!/usr/bin/env bats
# test-manual-evidence.bats — contract tests for evidence artifacts
# (run-record.md, exit-code.log) and the proof-of-execution gate.
#
# Validates write-evidence.sh behavior, resolve-artifact-path.sh manual_test
# kind, and the PASSED→UNVERIFIED downgrade when evidence is missing/empty.

load 'test_helper.bash'

setup() {
  common_setup
  PUBLIC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITE_EVIDENCE="$PUBLIC_ROOT/plugins/gaia/skills/gaia-test-manual/scripts/write-evidence.sh"
  RESOLVE="$PUBLIC_ROOT/plugins/gaia/scripts/lib/resolve-artifact-path.sh"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC3 — write-evidence.sh is executable.
# ---------------------------------------------------------------------------

@test "write-evidence.sh is executable" {
  [ -x "$WRITE_EVIDENCE" ]
}

# ---------------------------------------------------------------------------
# AC3 — write-evidence.sh creates evidence directory.
# ---------------------------------------------------------------------------

@test "write-evidence.sh creates evidence directory and writes run-record.md" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/my-slug"
  run bash -c "printf '# Run Record\n\n| Step | Command | Expected | Observed | Verdict |\n' | '$WRITE_EVIDENCE' '$evidence_dir' PASSED"
  [ "$status" -eq 0 ]
  [ -f "$evidence_dir/run-record.md" ]
  [ -s "$evidence_dir/run-record.md" ]
}

# ---------------------------------------------------------------------------
# AC3 — write-evidence.sh creates exit-code.log.
# ---------------------------------------------------------------------------

@test "write-evidence.sh creates exit-code.log alongside run-record" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/another-slug"
  run bash -c "printf '# Run Record\n\nSome content here\n' | '$WRITE_EVIDENCE' '$evidence_dir' PASSED"
  [ "$status" -eq 0 ]
  [ -f "$evidence_dir/exit-code.log" ]
  [ -s "$evidence_dir/exit-code.log" ]
}

# ---------------------------------------------------------------------------
# AC3 — exit-code.log final line contains VERDICT.
# ---------------------------------------------------------------------------

@test "exit-code.log final line contains VERDICT" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/verdict-slug"
  run bash -c "printf '# Run Record\n\nContent\n' | '$WRITE_EVIDENCE' '$evidence_dir' PASSED"
  [ "$status" -eq 0 ]
  tail -1 "$evidence_dir/exit-code.log" | grep -F "VERDICT:"
}

# ---------------------------------------------------------------------------
# AC3 — write-evidence.sh fails on empty stdin.
# ---------------------------------------------------------------------------

@test "write-evidence.sh fails on empty stdin" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/empty-slug"
  run bash -c "printf '' | '$WRITE_EVIDENCE' '$evidence_dir' PASSED"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — resolve-artifact-path.sh manual_test kind exits 0.
# ---------------------------------------------------------------------------

@test "resolve-artifact-path.sh manual_test kind exits 0 with slug" {
  # Create the expected file so --existing-only is not needed (default mode
  # returns canonical rung-1 even if file is absent).
  run "$RESOLVE" manual_test --slug my-test-slug --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — resolve-artifact-path.sh manual_test returns path with expected shape.
# ---------------------------------------------------------------------------

@test "resolve-artifact-path.sh manual_test returns path containing test-artifacts/manual-test/<slug>/run-record.md" {
  run "$RESOLVE" manual_test --slug my-test-slug --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-artifacts/manual-test/my-test-slug/run-record.md"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — Proof-of-execution: PASSED verdict but missing run-record → UNVERIFIED.
# ---------------------------------------------------------------------------

@test "proof-of-execution: missing run-record downgrades PASSED to UNVERIFIED" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/proof-slug"
  mkdir -p "$evidence_dir"
  # Write exit-code.log but NOT run-record.md
  printf '2026-01-01T00:00:00Z 0 echo-hi\nVERDICT: PASSED\n' > "$evidence_dir/exit-code.log"
  # The finalize or write-evidence script should detect this and downgrade.
  # We test the gate logic via write-evidence.sh --verify mode.
  run "$WRITE_EVIDENCE" "$evidence_dir" "PASSED" --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — Proof-of-execution: missing exit-code.log downgrades PASSED to UNVERIFIED.
# ---------------------------------------------------------------------------

@test "proof-of-execution: missing exit-code.log downgrades PASSED to UNVERIFIED" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/proof-slug2"
  mkdir -p "$evidence_dir"
  # Write run-record.md but NOT exit-code.log
  printf '# Run Record\n\nContent\n' > "$evidence_dir/run-record.md"
  run "$WRITE_EVIDENCE" "$evidence_dir" "PASSED" --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — Proof-of-execution: both files present → PASSED stays PASSED.
# ---------------------------------------------------------------------------

@test "proof-of-execution: both files present keeps PASSED" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/proof-slug3"
  mkdir -p "$evidence_dir"
  printf '# Run Record\n\nContent\n' > "$evidence_dir/run-record.md"
  printf '2026-01-01T00:00:00Z 0 echo-hi\nVERDICT: PASSED\n' > "$evidence_dir/exit-code.log"
  run "$WRITE_EVIDENCE" "$evidence_dir" "PASSED" --verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

# ---------------------------------------------------------------------------
# W1 — resolve-artifact-path.sh manual_test WITHOUT --slug exits non-zero.
# ---------------------------------------------------------------------------

@test "resolve-artifact-path.sh manual_test without --slug exits non-zero" {
  run "$RESOLVE" manual_test --project-root "$TEST_TMP"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# W2 — Empty run-record.md + empty exit-code.log downgrades PASSED to UNVERIFIED.
# ---------------------------------------------------------------------------

@test "proof-of-execution: empty run-record and empty exit-code downgrade PASSED to UNVERIFIED" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/empty-files-slug"
  mkdir -p "$evidence_dir"
  # Create both files, but leave them zero-length.
  : > "$evidence_dir/run-record.md"
  : > "$evidence_dir/exit-code.log"
  run "$WRITE_EVIDENCE" "$evidence_dir" "PASSED" --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
}

# ---------------------------------------------------------------------------
# W3 — exit-code.log VERDICT line includes the actual verdict value.
# ---------------------------------------------------------------------------

@test "exit-code.log VERDICT line includes the verdict value" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/verdict-value-slug"
  run bash -c "printf '# Run Record\n\nContent\n' | '$WRITE_EVIDENCE' '$evidence_dir' PASSED"
  [ "$status" -eq 0 ]
  tail -1 "$evidence_dir/exit-code.log" | grep -F "VERDICT: PASSED"
}

# ---------------------------------------------------------------------------
# W4 — verify mode with FAILED verdict + missing evidence exits non-zero
#       and surfaces FAILED.
# ---------------------------------------------------------------------------

@test "proof-of-execution: FAILED verdict with missing evidence exits non-zero and surfaces FAILED" {
  evidence_dir="$TEST_TMP/test-artifacts/manual-test/failed-missing-slug"
  mkdir -p "$evidence_dir"
  # Neither run-record.md nor exit-code.log exist.
  run "$WRITE_EVIDENCE" "$evidence_dir" "FAILED" --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]]
}
