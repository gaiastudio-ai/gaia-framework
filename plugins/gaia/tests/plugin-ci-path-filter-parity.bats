#!/usr/bin/env bats
# plugin-ci-path-filter-parity.bats — assert every gaia-core trigger path in
# the project config is matched by plugin-ci.yml's pull_request paths filter.
#
# This test runs on every PR (top-level .bats, assigned to a shard) and fails
# if a gaia-core stack path is added to the config without a corresponding
# entry in the plugin-ci paths filter.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_CI="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  CI_CONFIG="$REPO_ROOT/.gaia/ci-config.yaml"
}
teardown() { common_teardown; }

# _path_matches_filter <path> <filter-pattern>
# Returns 0 if the path would be matched by the GitHub Actions path filter.
# GitHub uses fnmatch-style matching where ** matches any path segment.
_path_matches_filter() {
  local path="$1"
  local pattern="$2"

  # Convert GitHub's glob to a grep regex:
  #   **  -> .*
  #   *   -> [^/]*
  #   .   -> \.
  local regex
  regex="$(printf '%s' "$pattern" | sed \
    -e 's/\./\\./g' \
    -e 's/\*\*/.*/g' \
    -e 's/\([^.]\)\*/\1[^\/]*/g' \
    -e 's/^\*/[^\/]*/g')"
  regex="^${regex}$"
  printf '%s' "$path" | grep -qE "$regex"
}

@test "plugin-ci.yml path filter exists" {
  [ -f "$PLUGIN_CI" ]
}

@test "ci-config.yaml exists with gaia-core stack" {
  [ -f "$CI_CONFIG" ]
  run yq '.stacks[] | select(.name == "gaia-core") | .name' "$CI_CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "gaia-core" ]
}

@test "every gaia-core trigger path is covered by plugin-ci path filter" {
  # Extract plugin-ci paths filter entries
  local -a filters=()
  while IFS= read -r line; do
    [ -n "$line" ] && filters+=("$line")
  done < <(yq '.on.pull_request.paths[]' "$PLUGIN_CI" 2>/dev/null | sed "s/^'//;s/'$//")

  [ ${#filters[@]} -gt 0 ] || fail "no path filters found in plugin-ci.yml"

  # Extract gaia-core stack paths from ci-config.yaml
  local -a core_paths=()
  while IFS= read -r line; do
    [ -n "$line" ] && core_paths+=("$line")
  done < <(yq '.stacks[] | select(.name == "gaia-core") | .paths[]' "$CI_CONFIG" 2>/dev/null)

  [ ${#core_paths[@]} -gt 0 ] || fail "no gaia-core paths found in ci-config.yaml"

  # For each gaia-core path, check it matches at least one filter
  local unmatched=()
  for cp in "${core_paths[@]}"; do
    local matched=0
    for fp in "${filters[@]}"; do
      if _path_matches_filter "$cp" "$fp"; then
        matched=1
        break
      fi
    done
    if [ "$matched" -eq 0 ]; then
      unmatched+=("$cp")
    fi
  done

  if [ ${#unmatched[@]} -gt 0 ]; then
    printf 'gaia-core paths not covered by plugin-ci path filter:\n' >&2
    for u in "${unmatched[@]}"; do
      printf '  %s\n' "$u" >&2
    done
    fail "${#unmatched[@]} gaia-core path(s) not covered by plugin-ci.yml path filter"
  fi
}
