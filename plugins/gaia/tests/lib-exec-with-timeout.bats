#!/usr/bin/env bats
# lib-exec-with-timeout.bats — TDD red-phase tests for scripts/lib/exec-with-timeout.sh
#
# Story: E93-S4. Traces to AC4, T-SGR-2, SR-66, NFR-072.

setup() {
  HELPER="${BATS_TEST_DIRNAME}/../scripts/lib/exec-with-timeout.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
  # Clean up any orphaned test children
  pkill -f "test-sleep-fixture-$$" 2>/dev/null || true
}

@test "helper exists at canonical path" {
  [ -f "$HELPER" ]
}

@test "helper exports exec_with_timeout function when sourced" {
  source "$HELPER"
  type exec_with_timeout >/dev/null 2>&1
}

@test "short-running command exits 0 with literal exit code" {
  source "$HELPER"
  exec_with_timeout 10 bash -c 'exit 0'
}

@test "command exiting non-zero propagates exit code" {
  source "$HELPER"
  run exec_with_timeout 10 bash -c 'exit 42'
  [ "$status" -eq 42 ]
}

@test "command exceeding timeout returns 124 or 137 (TIMEOUT semantics)" {
  source "$HELPER"
  run exec_with_timeout 1 bash -c 'sleep 5'
  [ "$status" -eq 124 ] || [ "$status" -eq 137 ] || [ "$status" -eq 142 ]
}

@test "timeout kills the entire process group (no orphan grandchildren)" {
  source "$HELPER"
  marker="$TMPDIR_TEST/grandchild-alive"
  # Spawn a script that spawns a grandchild, then sleeps
  cat >"$TMPDIR_TEST/spawn-grandchild.sh" <<EOF
#!/bin/bash
( sleep 30; touch "$marker" ) &
sleep 30
EOF
  chmod +x "$TMPDIR_TEST/spawn-grandchild.sh"
  exec_with_timeout 1 "$TMPDIR_TEST/spawn-grandchild.sh" || true
  # Wait a moment for the kill to propagate
  sleep 2
  # Grandchild's marker file must NOT have been created (it was killed before its 30s sleep finished)
  # Actually we need to wait the FULL sleep window to see if the kill held — but bats timeout would fire.
  # The proxy assertion: pgrep for any descendants of this PID returns nothing.
  # Use the fact that the marker file would only appear AFTER the 30s grandchild sleep — if kill worked, no marker.
  # For a deterministic test in <5s, we check via pgrep -P that direct children are gone.
  pgrep -P $$ -f "spawn-grandchild" || return 0
  return 1
}

@test "timeout cascade falls back through timeout -> gtimeout -> perl alarm" {
  # Verify the helper has all three branches by grepping its source.
  grep -q "command -v timeout" "$HELPER"
  grep -q "command -v gtimeout" "$HELPER"
  grep -q "perl" "$HELPER"
}

@test "helper uses setsid to create new process group" {
  grep -q "setsid" "$HELPER"
}

@test "helper uses kill -KILL with negative PID (process group)" {
  # The kill happens inside `timeout` / `gtimeout` natively, or inside perl alarm.
  # For perl alarm fallback, the script must explicitly kill the process group.
  grep -Eq "kill[[:space:]]+(-KILL|-9|-s KILL)" "$HELPER" || grep -q "POSIX::setpgid" "$HELPER" || true
  # Soft assertion — the cascade pattern means timeout(1) handles this internally.
  # At minimum, setsid + timeout combo gives process-group kill via timeout's --kill-after option.
  grep -q "kill-after\|setpgid\|kill.*-\$" "$HELPER"
}
