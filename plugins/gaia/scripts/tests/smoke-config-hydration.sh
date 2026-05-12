#!/usr/bin/env bash
# smoke-config-hydration.sh — minimal smoke harness for lib/config-hydration.sh.
#
# Story: E85-S1 (AC12).
#
# Runs the seven scenarios from AC12 against a temporary config file and
# reports PASS/FAIL per scenario. Returns 0 only when every scenario passes.
#
# This harness is intentionally simpler than the bats suite (config-hydration.bats)
# so it can be executed in CI environments without bats installed.

set -u

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${PLUGIN_ROOT}/scripts/lib/config-hydration.sh"

if [ ! -f "$LIB" ]; then
  printf 'smoke-config-hydration: library not found at %s\n' "$LIB" >&2
  exit 1
fi

PASS=0
FAIL=0

report() {
  local name="$1" status="$2"
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '  [PASS] %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  [FAIL] %s (status=%d)\n' "$name" "$status"
  fi
}

fresh_tmp() {
  TMP="$(mktemp -d)"
  CFG="${TMP}/project-config.yaml"
  mkdir -p "${TMP}/config"
  export CONFIG_HYDRATION_TARGET="$CFG"
  export CONFIG_HYDRATION_LOCK_PATH="${TMP}/config/.config-hydration.lock"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
}

cleanup() { rm -rf "$TMP" 2>/dev/null || true; }

# Scenario 1 — hydrate new section on minimal config.
fresh_tmp
cat > "$CFG" <<EOF
project_name: smoke
config_phase: minimal
EOF
printf 'stacks:\n  - name: backend\n' > "${TMP}/frag.yaml"
(
  source "$LIB"
  config_hydrate_section stacks "${TMP}/frag.yaml" >/dev/null 2>&1
)
rc=$?
grep -q "^stacks:" "$CFG" && grep -q "^config_phase: partial" "$CFG" && [ "$rc" -eq 0 ]
report "scenario-1 hydrate-new-section + phase advance" $?
cleanup

# Scenario 2 — hydrate existing section (overwrite).
fresh_tmp
cat > "$CFG" <<EOF
project_name: smoke
config_phase: partial
stacks:
  - name: old
EOF
printf 'stacks:\n  - name: new\n' > "${TMP}/frag.yaml"
(
  source "$LIB"
  config_hydrate_section stacks "${TMP}/frag.yaml" >/dev/null 2>&1
)
rc=$?
grep -q "  - name: new" "$CFG" && ! grep -q "  - name: old" "$CFG" && [ "$rc" -eq 0 ]
report "scenario-2 hydrate-existing-overwrite" $?
cleanup

# Scenario 3 — reject unknown section.
fresh_tmp
cat > "$CFG" <<EOF
project_name: smoke
config_phase: minimal
EOF
printf 'foo: bar\n' > "${TMP}/frag.yaml"
(
  source "$LIB"
  config_hydrate_section custom_section "${TMP}/frag.yaml" >/dev/null 2>&1
)
[ "$?" -ne 0 ]
report "scenario-3 reject-unknown-section" $?
cleanup

# Scenario 4 — flock contention with background writer.
fresh_tmp
cat > "$CFG" <<EOF
project_name: smoke
config_phase: minimal
EOF
printf 'stacks:\n  - name: a\n' > "${TMP}/frag-a.yaml"
printf 'platforms:\n  - web\n' > "${TMP}/frag-b.yaml"
(
  source "$LIB"
  config_hydrate_section stacks "${TMP}/frag-a.yaml" >/dev/null 2>&1
) &
PID_A=$!
(
  source "$LIB"
  config_hydrate_section platforms "${TMP}/frag-b.yaml" >/dev/null 2>&1
) &
PID_B=$!
wait "$PID_A"; A=$?
wait "$PID_B"; B=$?
[ "$A" -eq 0 ] && [ "$B" -eq 0 ] && grep -q "^stacks:" "$CFG" && grep -q "^platforms:" "$CFG"
report "scenario-4 parallel-serialization" $?
cleanup

# Scenario 5 — config_phase minimal -> partial.
fresh_tmp
cat > "$CFG" <<EOF
project_name: smoke
config_phase: minimal
EOF
printf 'stacks:\n  - name: a\n' > "${TMP}/frag.yaml"
(
  source "$LIB"
  config_hydrate_section stacks "${TMP}/frag.yaml" >/dev/null 2>&1
)
grep -q "^config_phase: partial$" "$CFG"
report "scenario-5 phase-minimal-to-partial" $?
cleanup

# Scenario 6 — config_phase monotonicity (no backward).
fresh_tmp
cat > "$CFG" <<EOF
project_name: smoke
config_phase: partial
stacks:
  - name: a
EOF
printf 'platforms:\n  - web\n' > "${TMP}/frag.yaml"
(
  source "$LIB"
  config_hydrate_section platforms "${TMP}/frag.yaml" >/dev/null 2>&1
)
grep -q "^config_phase: partial$" "$CFG" && ! grep -q "^config_phase: minimal$" "$CFG"
report "scenario-6 monotonic-no-backward" $?
cleanup

# Scenario 7 — audit comment presence.
fresh_tmp
cat > "$CFG" <<EOF
project_name: smoke
config_phase: minimal
EOF
printf 'stacks:\n  - name: a\n' > "${TMP}/frag.yaml"
(
  source "$LIB"
  config_hydrate_section stacks "${TMP}/frag.yaml" >/dev/null 2>&1
)
grep -qE "^# hydrated by .* at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "$CFG"
report "scenario-7 audit-comment-present" $?
cleanup

printf '\nsmoke-config-hydration: pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
