#!/usr/bin/env bats
# e103-s6-create-arch-threat-model-gate.bats
# Story: E103-S6 — /gaia-create-arch conditional threat-model gate when compliance.ui_present: true.
# Origin: AF-2026-05-24-3. Traces to: FR-535, ADR-120, TC-LOE-6.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SETUP_SH="$REPO_ROOT/gaia-public/plugins/gaia/skills/gaia-create-arch/scripts/setup.sh"
}

teardown() { common_teardown; }

@test "TC-LOE-6a: setup.sh references compliance.ui_present" {
  [ -f "$SETUP_SH" ]
  grep -qF "compliance.ui_present" "$SETUP_SH"
}

@test "TC-LOE-6b: setup.sh references threat-model.md artifact" {
  [ -f "$SETUP_SH" ]
  grep -qF "threat-model.md" "$SETUP_SH"
}

@test "TC-LOE-6c: setup.sh sources the lifecycle-overrides helper" {
  [ -f "$SETUP_SH" ]
  grep -qF "lifecycle-overrides.sh" "$SETUP_SH"
}

@test "TC-LOE-6d: setup.sh emits the canonical AC1 remediation message" {
  [ -f "$SETUP_SH" ]
  grep -qF "/gaia-threat-model" "$SETUP_SH"
  grep -qF -- "--bypass gaia-threat-model" "$SETUP_SH"
}

@test "TC-LOE-6e: setup.sh names the AC2 skip log marker" {
  [ -f "$SETUP_SH" ]
  grep -qF "threat-model gate skipped" "$SETUP_SH"
}
