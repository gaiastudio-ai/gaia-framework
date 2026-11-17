#!/usr/bin/env bats
# lifecycle-overrides-bash32-fd.bats — Regression tests for the flock fd
# assignment path in lifecycle-overrides.sh under bash 3.2 and bash 5.
#
# The flock branch must use bash 3.2-compatible fd syntax.  Under bash 3.2
# the `exec {VARNAME}>file` syntax is not supported: the shell treats
# `{VARNAME}` as a command name and exits 127 at runtime.
#
# Tests 1, 3, 5, 9 require a bash 3.2 interpreter (macOS /bin/bash or
# LIFECYCLE_BASH32 override).  On macOS (Darwin), the test fails when
# /bin/bash is not 3.2; on other hosts, it skips when no 3.2 interpreter
# is available.
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
  # BASH_ENV snippet: sourced by non-interactive bash before the script runs,
  # printing BASH_VERSION from the same process that executes the lib.
  _BASH_ENV_PRINT_VER="$TEST_TMP/print-bash-version.sh"
  printf 'printf "BASH_VERSION=%%s\\n" "$BASH_VERSION" >&2\n' > "$_BASH_ENV_PRINT_VER"
}

teardown() {
  export PATH="$_SAVED_PATH"
  common_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# need_bash32 — set BASH32 to a bash 3.2 interpreter.  On macOS (Darwin),
# fail the test if /bin/bash is not 3.2; on other hosts, skip the test.
need_bash32() {
  local b="${LIFECYCLE_BASH32:-/bin/bash}" ver=""
  [ -x "$b" ] && ver="$("$b" -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" || true
  case "$ver" in
    3.2.*)
      BASH32="$b"
      return 0
      ;;
  esac
  # On macOS, bash 3.2 is the stock interpreter; a missing or non-3.2
  # binary is a test environment problem, not a reason to skip.
  if [ "$(uname -s)" = "Darwin" ]; then
    printf 'test requires bash 3.2 at %s but found version %s\n' "$b" "${ver:-none}" >&2
    return 1
  fi
  skip "needs bash 3.2 at $b (stock macOS shell); found version '${ver:-none}'"
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
  for tool in bash env yq jq mktemp date grep mkdir rmdir rm dirname sleep cat chmod; do
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

# make_lock_observer — place a jq shim first on PATH that records whether the
# mkdir lock directory exists when the lib invokes jq (inside the critical
# section).  Sets _LOCK_OBSERVE_MARKER to the observation file path.
# Must be called AFTER make_no_flock_path (which symlinks the real jq).
make_lock_observer() {
  local real_jq
  real_jq="$(command -v jq)"
  local observer_dir="$TEST_TMP/lock-observer"
  mkdir -p "$observer_dir"
  _LOCK_OBSERVE_MARKER="$TEST_TMP/lock-observer-result"
  rm -f "$_LOCK_OBSERVE_MARKER"
  export _LOCK_OBSERVE_DIR="${LIFECYCLE_OVERRIDES_LOCK}.d"
  export _LOCK_OBSERVE_MARKER
  export _REAL_JQ="$real_jq"
  cat > "$observer_dir/jq" <<'SHIMEOF'
#!/bin/sh
if [ -d "$_LOCK_OBSERVE_DIR" ]; then
  printf 'HELD\n' > "$_LOCK_OBSERVE_MARKER"
else
  printf 'NOT_HELD\n' > "$_LOCK_OBSERVE_MARKER"
fi
exec "$_REAL_JQ" "$@"
SHIMEOF
  chmod +x "$observer_dir/jq"
  export PATH="$observer_dir:$PATH"
}

# ---------------------------------------------------------------------------
# Test 1: flock path under bash 3.2 exits 0 and appends bypass
# ---------------------------------------------------------------------------
@test "flock path under bash 3.2 exits 0 and appends bypass" {
  need_bash32
  make_flock_shim

  # Run the lib under bash 3.2 with BASH_ENV printing BASH_VERSION from the
  # same process.  BASH_ENV is sourced by non-interactive bash before the
  # script runs, so the version comes from the process that executes the lib.
  run --separate-stderr env BASH_ENV="$_BASH_ENV_PRINT_VER" \
    "$BASH32" "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -eq 0 ]
  # Verify the process ran under bash 3.2
  case "$stderr" in *"BASH_VERSION=3.2."*) ;; *) printf 'expected BASH_VERSION=3.2.* on stderr; got: %s\n' "$stderr" >&2; return 1 ;; esac
  case "$stderr" in *"not found"*) printf 'unexpected not-found diagnostic on stderr: %s\n' "$stderr" >&2; return 1 ;; esac
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
  make_lock_observer

  # Run the lib under bash 3.2 with BASH_ENV printing BASH_VERSION from the
  # same process.
  run --separate-stderr env BASH_ENV="$_BASH_ENV_PRINT_VER" \
    "$BASH32" "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -eq 0 ]
  # Verify the process ran under bash 3.2
  case "$stderr" in *"BASH_VERSION=3.2."*) ;; *) printf 'expected BASH_VERSION=3.2.* on stderr; got: %s\n' "$stderr" >&2; return 1 ;; esac
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
  # The mkdir lock directory must have been held during the append
  [ -f "$_LOCK_OBSERVE_MARKER" ]
  local observed
  observed="$(cat "$_LOCK_OBSERVE_MARKER")"
  case "$observed" in
    HELD) ;;
    *) printf 'mkdir lock directory was not held during append (observed: %s)\n' "$observed" >&2; return 1 ;;
  esac
  # The lock directory must be cleaned up after the call returns
  if [ -d "${LIFECYCLE_OVERRIDES_LOCK}.d" ]; then
    printf 'mkdir lock directory still exists after append returned\n' >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 4: mkdir fallback under bash 5 without flock
# ---------------------------------------------------------------------------
@test "mkdir fallback under bash 5 without flock" {
  make_no_flock_path
  make_lock_observer

  run --separate-stderr bash "$LIB" append \
    --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99

  [ "$status" -eq 0 ]
  [ -f "$LIFECYCLE_OVERRIDES_FILE" ]
  local count
  count="$(yq '.bypasses | length' "$LIFECYCLE_OVERRIDES_FILE")"
  [ "$count" -eq 1 ]
  # The mkdir lock directory must have been held during the append
  [ -f "$_LOCK_OBSERVE_MARKER" ]
  local observed
  observed="$(cat "$_LOCK_OBSERVE_MARKER")"
  case "$observed" in
    HELD) ;;
    *) printf 'mkdir lock directory was not held during append (observed: %s)\n' "$observed" >&2; return 1 ;;
  esac
  # The lock directory must be cleaned up after the call returns
  if [ -d "${LIFECYCLE_OVERRIDES_LOCK}.d" ]; then
    printf 'mkdir lock directory still exists after append returned\n' >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 5: flock path under bash 3.2 with caller holding fd 8
# ---------------------------------------------------------------------------
@test "flock path under bash 3.2 with caller holding fd 8" {
  need_bash32
  make_flock_shim

  # Write a wrapper that opens fd 8 (simulating design-gate.sh),
  # calls the library, then verifies fd 8 is still usable.
  # BASH_ENV prints BASH_VERSION from the same process.
  cat > "$TEST_TMP/fd8-caller.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail
exec 8>/dev/null
source "$1"
lifecycle_append_bypass --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99
{ true >&8; } 2>/dev/null && printf 'FD8_OK\n'
WRAPPER
  chmod +x "$TEST_TMP/fd8-caller.sh"

  run --separate-stderr env BASH_ENV="$_BASH_ENV_PRINT_VER" \
    "$BASH32" "$TEST_TMP/fd8-caller.sh" "$LIB"

  [ "$status" -eq 0 ]
  # Verify the process ran under bash 3.2
  case "$stderr" in *"BASH_VERSION=3.2."*) ;; *) printf 'expected BASH_VERSION=3.2.* on stderr; got: %s\n' "$stderr" >&2; return 1 ;; esac
  case "$output" in *FD8_OK*) ;; *) printf 'FD8_OK missing from output: %s\n' "$output" >&2; return 1 ;; esac
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
  case "$stderr" in *"failed to acquire lock"*) echo "unexpected lock diagnostic on stderr: $stderr" >&2; return 1 ;; esac
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
  case "$output" in *FD8_OK*) ;; *) echo "FD8_OK missing from output: $output" >&2; return 1 ;; esac
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

  # BASH_ENV prints BASH_VERSION from the same process.
  cat > "$TEST_TMP/middle-fail-32.sh" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
export PATH="$TEST_TMP/yq-shim:$PATH"
source "$LIB"
_lifecycle_bootstrap_if_absent() { return 1; }
lo_rc=0
( lifecycle_append_bypass --skill /gaia-trace --reason "valid reason for bypass" --sprint-id sprint-99 ) || lo_rc=\$?
exit "\$lo_rc"
WRAPPER
  chmod +x "$TEST_TMP/middle-fail-32.sh"

  rm -f "$TEST_TMP/yq-ran"
  run --separate-stderr env BASH_ENV="$_BASH_ENV_PRINT_VER" \
    "$BASH32" "$TEST_TMP/middle-fail-32.sh"

  [ "$status" -ne 0 ]
  # Verify the process ran under bash 3.2
  case "${stderr:-}" in *"BASH_VERSION=3.2."*) ;; *) printf 'expected BASH_VERSION=3.2.* on stderr; got: %s\n' "${stderr:-}" >&2; return 1 ;; esac
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
  case "${stderr:-}" in *"failed to acquire lock"*) echo "unexpected lock diagnostic on stderr: ${stderr:-}" >&2; return 1 ;; esac
  [[ "$stderr" == *"jq"* ]]
}
