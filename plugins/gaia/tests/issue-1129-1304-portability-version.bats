#!/usr/bin/env bash
# issue-1129-1304-portability-version.bats
#
# #1129 — run-tests.sh used `compgen -G "*.bats"` (a bash builtin that errors
#         under sh/zsh) for provider auto-detection. Replaced with a POSIX
#         `find -maxdepth 1` glob test.
# #1304 — the gaia-doctor spotbugs version_cmd was `spotbugs -version 2>&1`,
#         which yielded a blank/unparsed version in the BOM. Now it extracts
#         the numeric version token.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RUN_TESTS="$PLUGIN_ROOT/skills/gaia-test-run/scripts/run-tests.sh"
  REGISTRY="$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
}
teardown() { common_teardown; }

# --- #1129 ---

@test "issue-1129: run-tests.sh no longer CALLS the bash-only compgen builtin" {
  # Allow the word in an explanatory comment; forbid an actual `compgen` call
  # (a line where compgen is not preceded by a `#` comment marker).
  ! grep -nE '^[^#]*compgen' "$RUN_TESTS"
}

@test "issue-1129: run-tests.sh detects bats via a POSIX find glob" {
  grep -qE "find . -maxdepth 1 -type f -name '\*\.bats'" "$RUN_TESTS"
}

@test "issue-1129: run-tests.sh passes bash -n" {
  run bash -n "$RUN_TESTS"
  [ "$status" -eq 0 ]
}

# --- #1304 ---

@test "issue-1304: spotbugs version_cmd extracts a numeric version token" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local vc
  vc="$(jq -r '.tools.spotbugs.version_cmd' "$REGISTRY")"
  # Must pipe through a version-extracting filter, not the raw banner.
  printf '%s\n' "$vc" | grep -qE 'grep -oE'
}

@test "issue-1304: the version_cmd's extraction tail yields 4.8.3 from a banner" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local vc tail out
  vc="$(jq -r '.tools.spotbugs.version_cmd' "$REGISTRY")"
  # The pipeline is `spotbugs -version 2>&1 | <extraction tail>`. Drive a
  # sample banner through the extraction tail (everything after the first `|`).
  tail="${vc#*| }"
  out="$(printf 'SpotBugs 4.8.3\n' | bash -c "$tail" 2>/dev/null || true)"
  [ "$out" = "4.8.3" ]
}

@test "issue-1304: tool-readiness.json remains valid JSON" {
  if command -v jq >/dev/null 2>&1; then
    run jq -e . "$REGISTRY"
    [ "$status" -eq 0 ]
  else
    run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$REGISTRY"
    [ "$status" -eq 0 ]
  fi
}
