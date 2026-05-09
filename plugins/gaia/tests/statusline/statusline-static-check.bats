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
  FETCHER="$PLUGIN_ROOT/scripts/statusline-update-check.sh"
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

# E82-S2 / NFR-STATUSLINE-3: fetcher MUST NOT use /tmp/ — all temp writes
# are siblings of the target so `mv -f` is atomic on the same filesystem.
@test "static-check: fetcher source contains zero /tmp/ paths (NFR-STATUSLINE-3)" {
  [ -f "$FETCHER" ]
  run grep -E '/tmp/' "$FETCHER"
  [ "$status" -eq 1 ]
}
