#!/usr/bin/env bats
# lifecycle-overrides-bash32-fd.bats — Regression tests for the flock fd
# assignment path in lifecycle-overrides.sh under bash 3.2 and bash 5.
#
# The flock branch must use bash 3.2-compatible fd syntax.  Under bash 3.2
# the `exec {VARNAME}>file` syntax is not supported: the shell treats
# `{VARNAME}` as a command name and exits 127 at runtime.
#
# Tests 1, 3, 5, 9 require a bash 3.x interpreter (macOS /bin/bash or
# LIFECYCLE_BASH32 override) and skip on hosts that only have bash 5.
# Tests 2, 4, 6, 7, 8, 10 run under the host bash (5.x on Linux CI).

# bats file_tags=scripts-lib

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$PLUGIN/scripts/lib/lifecycle-overrides.sh"
  export LIFECYCLE_OVERRIDES_FILE="$TEST_TMP/.gaia/state/lifecycle-overrides.yaml"
  export LIFECYCLE_OVERRIDES_LOCK="$TEST_TMP/.gaia/state/lifecycle-overrides.yaml.lock"
  mkdir -p "$(dirname "$LIFECYCLE_OVERRIDES_FILE")"
  # Save PATH so teardown can restore it after tests that modify it
  # (make_no_flock_path strips directories, which can break bats' own cleanup).
  _SAVED_PATH="$PATH"
}

teardown() {
  export PATH="$_SAVED_PATH"
  common_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# need_bash32 — set BASH32 to a bash 3.x interpreter, or skip the test.
need_bash32() {
  local b="${LIFECYCLE_BASH32:-/bin/bash}" major=""
  [ -x "$b" ] && major="$("$b" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null)" || true
  if [ "$major" != "3" ]; then
    skip "needs bash 3.x at $b (stock macOS shell); found major version '${major:-none}'"
  fi
  BASH32="$b"
}

# make_flock_shim — place a flock stub (exit 0) on PATH.
make_flock_shim() {
  local shim_dir="$TEST_TMP/flock-shim"
  mkdir -p "$shim_dir"
  printf '#!/bin/sh\nexit 0\n' > "$shim_dir/flock"
  chmod +x "$shim_dir/flock"
  export PATH="$shim_dir:$PATH"
}

# make_no_flock_path — hide flock from PATH while keeping every other tool the
# script needs.  On Linux, flock lives in /usr/bin alongside mktemp, grep, etc.
# Stripping whole directories would break the script for the wrong reason.
# Instead: build a shim dir with symlinks to needed tools, then exclude dirs
# that contain flock, and prepend the shim dir.
make_no_flock_path() {
  local shim_dir="$TEST_TMP/no-flock-shim"
  mkdir -p "$shim_dir"
  # Symlink every tool the script needs (except flock) into the shim dir,
  # so they remain reachable after we strip dirs that contain flock.
  local tool real
  for tool in bash yq jq mktemp date grep mkdir rmdir rm dirname sleep cat chmod; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    [ -x "$real" ] && ln -sf "$real" "$shim_dir/$tool"
  done
  # Rebuild PATH excluding directories that contain flock.
  local new_path=""
  local saved_ifs="$IFS"
  IFS=':'
  for d in $PATH; do
    [ -x "$d/flock" ] && continue
    new_path="${new_path:+$new_path:}$d"
  done
  IFS="$saved_ifs"
  export PATH="$shim_dir:$new_path"
}

# ---------------------------------------------------------------------------
# Test 1: flock path under bash 3.2 exits 0 and appends bypass
# ---------------------------------------------------------------------------
@test "flock path under bash 3.2 exits 0 and appends bypass" {
  need_bash32
  make_flock_shim

  run --separate-stderr "$BASH32" "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -eq 0 ]
  [[ "$stderr" != *"not found"* ]]
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 2: flock path under bash 5 appends bypass
# ---------------------------------------------------------------------------
@test "flock path under bash 5 appends bypass" {
  make_flock_shim

  run --separate-stderr bash "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -eq 0 ]
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 3: mkdir fallback under bash 3.2 without flock
# ---------------------------------------------------------------------------
@test "mkdir fallback under bash 3.2 without flock" {
  need_bash32
  make_no_flock_path

  run --separate-stderr "$BASH32" "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -eq 0 ]
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 4: mkdir fallback under bash 5 without flock
# ---------------------------------------------------------------------------
@test "mkdir fallback under bash 5 without flock" {
  make_no_flock_path

  run --separate-stderr bash "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -eq 0 ]
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 5: flock path under bash 3.2 with caller holding fd 8
# ---------------------------------------------------------------------------
@test "flock path under bash 3.2 with caller holding fd 8" {
  need_bash32
  make_flock_shim

  # Write a wrapper that opens fd 8 (simulating design-gate.sh),
  # calls the library, then verifies fd 8 is still usable.
  cat > "$TEST_TMP/fd8-caller.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail
[ "${BASH_VERSINFO[0]}" -eq 3 ] || { printf 'FAIL: not bash 3 (got %s)\n' "$BASH_VERSION" >&2; exit 99; }
exec 8>/dev/null
source "$1"
lifecycle_append_bypass --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99
{ true >&8; } 2>/dev/null && printf 'FD8_OK\n'
WRAPPER
  chmod +x "$TEST_TMP/fd8-caller.sh"

  run --separate-stderr "$BASH32" "$TEST_TMP/fd8-caller.sh" "$LIB"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FD8_OK"* ]]
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 6: do-append failure does not print lock diagnostic
# ---------------------------------------------------------------------------
@test "do-append failure does not print lock diagnostic" {
  make_flock_shim

  # Set the overrides file to a directory so yq -i fails reliably.
  mkdir -p "$TEST_TMP/is-a-dir"
  export LIFECYCLE_OVERRIDES_FILE="$TEST_TMP/is-a-dir"

  run --separate-stderr bash "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -ne 0 ]
  [[ "$stderr" != *"failed to acquire lock"* ]]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 7: flock path under bash 5 with caller holding fd 8
# ---------------------------------------------------------------------------
@test "flock path under bash 5 with caller holding fd 8" {
  make_flock_shim

  cat > "$TEST_TMP/fd8-caller.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail
exec 8>/dev/null
source "$1"
lifecycle_append_bypass --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99
{ true >&8; } 2>/dev/null && printf 'FD8_OK\n'
WRAPPER
  chmod +x "$TEST_TMP/fd8-caller.sh"

  run --separate-stderr bash "$TEST_TMP/fd8-caller.sh" "$LIB"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FD8_OK"* ]]
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 8: middle-step failure in design-gate caller shape aborts and returns
#         non-zero
# ---------------------------------------------------------------------------
@test "middle-step failure in design-gate caller shape aborts and returns non-zero" {
  make_flock_shim

  # yq shim that records a marker then delegates to real yq.
  local real_yq
  real_yq="$(command -v yq)"
  mkdir -p "$TEST_TMP/yq-shim"
  cat > "$TEST_TMP/yq-shim/yq" <<YQSHIM
#!/bin/sh
touch "$TEST_TMP/yq-ran"
exec "$real_yq" "\$@"
YQSHIM
  chmod +x "$TEST_TMP/yq-shim/yq"

  # Wrapper using the design-gate caller shape:
  #   ( lifecycle_append_bypass ... ) || lo_rc=$?; exit "$lo_rc"
  # Override _lifecycle_bootstrap_if_absent to return 1 (simulate failure).
  cat > "$TEST_TMP/middle-fail.sh" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
export PATH="$TEST_TMP/yq-shim:$PATH"
source "$LIB"
_lifecycle_bootstrap_if_absent() { return 1; }
lo_rc=0
( lifecycle_append_bypass --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99 ) || lo_rc=\$?
exit "\$lo_rc"
WRAPPER
  chmod +x "$TEST_TMP/middle-fail.sh"

  rm -f "$TEST_TMP/yq-ran"
  run --separate-stderr bash "$TEST_TMP/middle-fail.sh"

  [ "$status" -ne 0 ]
  [ ! -f "$TEST_TMP/yq-ran" ]
  [[ "${stderr:-}" != *"failed to acquire lock"* ]]
}

# ---------------------------------------------------------------------------
# Test 9: middle-step failure in design-gate caller shape under bash 3.2
# ---------------------------------------------------------------------------
@test "middle-step failure in design-gate caller shape under bash 3.2" {
  need_bash32
  make_flock_shim

  local real_yq
  real_yq="$(command -v yq)"
  mkdir -p "$TEST_TMP/yq-shim"
  cat > "$TEST_TMP/yq-shim/yq" <<YQSHIM
#!/bin/sh
touch "$TEST_TMP/yq-ran"
exec "$real_yq" "\$@"
YQSHIM
  chmod +x "$TEST_TMP/yq-shim/yq"

  cat > "$TEST_TMP/middle-fail-32.sh" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
[ "\${BASH_VERSINFO[0]}" -eq 3 ] || { printf 'FAIL: not bash 3 (got %s)\n' "\$BASH_VERSION" >&2; exit 99; }
export PATH="$TEST_TMP/yq-shim:$PATH"
source "$LIB"
_lifecycle_bootstrap_if_absent() { return 1; }
lo_rc=0
( lifecycle_append_bypass --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99 ) || lo_rc=\$?
exit "\$lo_rc"
WRAPPER
  chmod +x "$TEST_TMP/middle-fail-32.sh"

  rm -f "$TEST_TMP/yq-ran"
  run --separate-stderr "$BASH32" "$TEST_TMP/middle-fail-32.sh"

  [ "$status" -ne 0 ]
  [ ! -f "$TEST_TMP/yq-ran" ]
}

# ---------------------------------------------------------------------------
# Test 10: failing jq step in design-gate caller shape aborts before yq
# ---------------------------------------------------------------------------
@test "failing jq step in design-gate caller shape aborts before yq" {
  make_flock_shim

  # yq shim with marker
  local real_yq
  real_yq="$(command -v yq)"
  mkdir -p "$TEST_TMP/yq-shim"
  cat > "$TEST_TMP/yq-shim/yq" <<YQSHIM
#!/bin/sh
touch "$TEST_TMP/yq-ran"
exec "$real_yq" "\$@"
YQSHIM
  chmod +x "$TEST_TMP/yq-shim/yq"

  # jq shim that always fails with a diagnostic
  mkdir -p "$TEST_TMP/jq-shim"
  cat > "$TEST_TMP/jq-shim/jq" <<'JQSHIM'
#!/bin/sh
printf 'jq: simulated failure\n' >&2
exit 1
JQSHIM
  chmod +x "$TEST_TMP/jq-shim/jq"

  # Wrapper using the design-gate caller shape.
  # jq shim is on PATH before real jq; yq shim is on PATH before real yq.
  cat > "$TEST_TMP/jq-fail.sh" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
export PATH="$TEST_TMP/jq-shim:$TEST_TMP/yq-shim:$PATH"
source "$LIB"
lo_rc=0
( lifecycle_append_bypass --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99 ) || lo_rc=\$?
exit "\$lo_rc"
WRAPPER
  chmod +x "$TEST_TMP/jq-fail.sh"

  rm -f "$TEST_TMP/yq-ran"
  run --separate-stderr bash "$TEST_TMP/jq-fail.sh"

  [ "$status" -ne 0 ]
  [ ! -f "$TEST_TMP/yq-ran" ]
  [[ "${stderr:-}" != *"failed to acquire lock"* ]]
  [[ "$stderr" == *"jq"* ]]
}
