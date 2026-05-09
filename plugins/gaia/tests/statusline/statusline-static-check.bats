#!/usr/bin/env bats
# statusline-static-check.bats — TC-STATUSLINE-9 structural contract.
#
# Story: E82-S1 — Statusline runtime + glyph helper + color helper + install.
#
# NFR-STATUSLINE-2 forbids network primitives in the statusline runtime.
# This is a structural contract enforced at static-check time: the runtime
# source MUST contain zero matches of `curl`, `wget`, `nc ` (with trailing
# space to avoid `nc` substrings), or `gh api`. Drift here is load-bearing
# — the install script copies the runtime byte-for-byte to ~/.claude.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNTIME="$PLUGIN_ROOT/scripts/statusline.sh"
  GLYPHS="$PLUGIN_ROOT/scripts/lib/statusline-glyphs.sh"
  COLORS="$PLUGIN_ROOT/scripts/lib/statusline-colors.sh"
}

teardown() { common_teardown; }

@test "static-check: runtime has zero curl/wget/nc/gh-api matches (TC-STATUSLINE-9)" {
  [ -f "$RUNTIME" ]
  run grep -E 'curl|wget|nc[[:space:]]|gh api' "$RUNTIME"
  # grep exits 1 when no match — which is what we want
  [ "$status" -eq 1 ]
}

@test "static-check: glyph helper has zero curl/wget/nc/gh-api matches" {
  [ -f "$GLYPHS" ]
  run grep -E 'curl|wget|nc[[:space:]]|gh api' "$GLYPHS"
  [ "$status" -eq 1 ]
}

@test "static-check: color helper has zero curl/wget/nc/gh-api matches" {
  [ -f "$COLORS" ]
  run grep -E 'curl|wget|nc[[:space:]]|gh api' "$COLORS"
  [ "$status" -eq 1 ]
}
