#!/usr/bin/env bats
# lib-env-allowlist.bats — TDD red-phase tests for scripts/lib/env-allowlist.sh
#
# Story: E93-S4. Traces to AC3, T-SGR-1, SR-63, NFR-072.

setup() {
  HELPER="${BATS_TEST_DIRNAME}/../scripts/lib/env-allowlist.sh"
  TMPDIR_TEST="$(mktemp -d)"
  ORIG_PATH="$PATH"
}

teardown() {
  PATH="$ORIG_PATH"
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}

@test "TC-ENV-1: helper exists at canonical path" {
  [ -f "$HELPER" ]
}

@test "TC-ENV-2: helper exports build_env_args function when sourced" {
  source "$HELPER"
  type build_env_args >/dev/null 2>&1
}

@test "TC-ENV-3: build_env_args emits exactly the 7 canonical vars when all present in parent env" {
  source "$HELPER"
  export PATH="/usr/bin" HOME="/tmp" USER="t" TMPDIR="/tmp" TERM="xterm" LANG="C" LC_ALL="C"
  out=$(build_env_args)
  # Each var should appear once
  for v in PATH HOME USER TMPDIR TERM LANG LC_ALL; do
    echo "$out" | grep -Eq "(^| )${v}=" || { echo "missing $v in: $out"; return 1; }
  done
}

@test "TC-ENV-4: build_env_args omits non-allowlisted vars (secrets do not leak)" {
  source "$HELPER"
  export AWS_SECRET_ACCESS_KEY="leak-me"
  export GITHUB_TOKEN="ghp-leak"
  export OPENAI_API_KEY="sk-leak"
  out=$(build_env_args)
  echo "$out" | grep -q "AWS_SECRET_ACCESS_KEY" && return 1
  echo "$out" | grep -q "GITHUB_TOKEN" && return 1
  echo "$out" | grep -q "OPENAI_API_KEY" && return 1
  return 0
}

@test "TC-ENV-5: env -i with build_env_args output spawns process with only allowlist vars" {
  source "$HELPER"
  export AWS_SECRET_ACCESS_KEY="leak-me"
  args=$(build_env_args)
  # Use env -i with the args, then run env to print resulting env
  out=$(eval env -i $args env)
  echo "$out" | grep -q "AWS_SECRET_ACCESS_KEY" && return 1
  echo "$out" | grep -Eq "^PATH=" || return 1
  return 0
}

@test "TC-ENV-6: build_env_args handles missing parent vars gracefully (no error)" {
  source "$HELPER"
  unset LC_ALL LANG TERM TMPDIR
  build_env_args >/dev/null
}
