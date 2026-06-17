#!/usr/bin/env bats
# e103-s3-sprint-plan-strict-lifecycle-gate.bats
# Story: E103-S3 — /gaia-sprint-plan strict lifecycle gate (traceability + readiness).
# Origin: AF-2026-05-24-3. Traces to: FR-537, ADR-120, TC-LOE-3.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETUP_SH="$PLUGIN/skills/gaia-sprint-plan/scripts/setup.sh"
}

teardown() { common_teardown; }

@test "setup.sh sources the lifecycle-overrides helper" {
  [ -f "$SETUP_SH" ]
  grep -qF "lifecycle-overrides.sh" "$SETUP_SH"
}

@test "setup.sh references the traceability-matrix.md artifact" {
  [ -f "$SETUP_SH" ]
  grep -qF "traceability-matrix.md" "$SETUP_SH"
}

@test "setup.sh names the --bypass remediation in error output" {
  [ -f "$SETUP_SH" ]
  grep -qF -- "--bypass gaia-trace" "$SETUP_SH"
}

@test "setup.sh names the readiness-check skill" {
  [ -f "$SETUP_SH" ]
  grep -qF "/gaia-readiness-check" "$SETUP_SH"
}

@test "setup.sh names --bypass gaia-readiness-check remediation" {
  [ -f "$SETUP_SH" ]
  grep -qF -- "--bypass gaia-readiness-check" "$SETUP_SH"
}
