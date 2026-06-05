#!/usr/bin/env bash
# issue-1137-bridge-enable-template-guidance.bats
#
# /gaia-bridge-enable could not complete from a *.example / template manifest:
# the GAIA-MANIFEST-TEMPLATE sentinel correctly fails Layer 0, but the SKILL.md
# never walked the operator through copying + editing the template and removing
# the sentinel — so the user was stuck on a bare "not ready" error.
#
# Fix: a Manifest-readiness guidance step that names the copy-and-edit flow.
# (The guard itself is correct and intentionally does NOT auto-promote a
# placeholder template — these tests assert the GUIDANCE exists, not an
# auto-promote.)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_MD="$PLUGIN_ROOT/skills/gaia-bridge-enable/SKILL.md"
  TEMPLATE="$PLUGIN_ROOT/templates/test-environment.yaml.example"
}

teardown() { common_teardown; }

@test "issue-1137: bridge-enable SKILL.md has a manifest-readiness guidance step" {
  grep -qiF 'Manifest-readiness guidance' "$SKILL_MD"
}

@test "issue-1137: guidance references the GAIA-MANIFEST-TEMPLATE sentinel" {
  grep -qF 'GAIA-MANIFEST-TEMPLATE' "$SKILL_MD"
}

@test "issue-1137: guidance walks the copy-from-example flow" {
  grep -qF 'test-environment.yaml.example' "$SKILL_MD"
  grep -qiE 'cp .*test-environment.yaml.example' "$SKILL_MD"
}

@test "issue-1137: guidance tells the operator to remove the sentinel line" {
  # The sentinel line must be removed for Layer 0 to go green.
  grep -qiE 'remove the .*GAIA-MANIFEST-TEMPLATE|sentinel line is gone|until that sentinel' "$SKILL_MD"
}

@test "issue-1137: the referenced template file exists and carries the sentinel" {
  [ -f "$TEMPLATE" ]
  grep -qF 'GAIA-MANIFEST-TEMPLATE' "$TEMPLATE"
}
