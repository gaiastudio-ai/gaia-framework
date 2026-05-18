#!/usr/bin/env bats
# layer-0-sentinel-guard.bats — E17-S35
#
# Covers the canonical GAIA-MANIFEST-TEMPLATE sentinel + the Layer 0 readiness
# guard that detects it. Defense-in-depth against the AF-4 root cause (a user
# blindly copying the .example template to .yaml without customizing).

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  TEMPLATE="${PLUGIN_ROOT}/gaia/templates/test-environment.yaml.example"
  GUARD="${PLUGIN_ROOT}/gaia/scripts/lib/check-manifest-sentinel.sh"
  GENERATOR="${PLUGIN_ROOT}/gaia/scripts/lib/test-environment-manifest.sh"
  TARGET_DIR="$(mktemp -d -t e17s35-bats-XXXXXX)"
  MANIFEST="${TARGET_DIR}/config/test-environment.yaml"
  SENTINEL_LINE='# GAIA-MANIFEST-TEMPLATE: edit this file before enabling the bridge -- bridge will fail Layer 0 readiness check until this line is removed'
}

teardown() {
  if [ -n "${TARGET_DIR:-}" ] && [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
  fi
}

# AC1 — example template ships with canonical sentinel
@test "AC1: example template contains canonical GAIA-MANIFEST-TEMPLATE sentinel" {
  grep -qF "# GAIA-MANIFEST-TEMPLATE" "${TEMPLATE}"
}

# AC2 — Layer 0 sentinel guard FAILS with canonical error when sentinel present
@test "AC2: check-manifest-sentinel.sh FAILS when sentinel present" {
  [ -x "${GUARD}" ]
  mkdir -p "${TARGET_DIR}/config"
  echo "${SENTINEL_LINE}" > "${MANIFEST}"
  echo "version: 2" >> "${MANIFEST}"

  run "${GUARD}" --manifest "${MANIFEST}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GAIA-MANIFEST-TEMPLATE"* ]]
  [[ "${output}" == *"Layer 0 readiness FAILED"* ]]
}

# AC2 — bridge_status: manifest_unmodified_template surfaced
@test "AC2: check-manifest-sentinel.sh emits bridge_status: manifest_unmodified_template" {
  mkdir -p "${TARGET_DIR}/config"
  echo "${SENTINEL_LINE}" > "${MANIFEST}"

  run "${GUARD}" --manifest "${MANIFEST}"
  [[ "${output}" == *"bridge_status: manifest_unmodified_template"* ]]
}

# AC3 — sentinel-absent manifest PASSES
@test "AC3: check-manifest-sentinel.sh PASSES when sentinel absent" {
  mkdir -p "${TARGET_DIR}/config"
  cat > "${MANIFEST}" << 'YAML'
version: 2
runners:
  - name: unit
    command: "make test"
    tier: 1
YAML

  run "${GUARD}" --manifest "${MANIFEST}"
  [ "${status}" -eq 0 ]
}

# AC4 — E17-S33 generator output with stack-match does NOT include sentinel
@test "AC4: generator with stack-match does NOT include sentinel" {
  echo '{"name":"test","devDependencies":{"jest":"^29.0.0"}}' > "${TARGET_DIR}/package.json"

  run "${GENERATOR}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  ! [[ "${output}" == *"GAIA-MANIFEST-TEMPLATE"* ]]
}

# AC4 — E17-S33 generator output with NO stack-match DOES include sentinel
@test "AC4: generator with no-stack-match (FR-497 placeholder) DOES include sentinel" {
  # Bare empty target — no stack signals
  run "${GENERATOR}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GAIA-MANIFEST-TEMPLATE"* ]]
}

# Usage error
@test "guard fails with usage error when --manifest is missing" {
  run "${GUARD}"
  [ "${status}" -eq 2 ]
}

# Guard handles missing manifest gracefully (manifest doesn't exist at the path)
@test "guard exits non-zero with clear error when manifest file is missing" {
  run "${GUARD}" --manifest "${TARGET_DIR}/missing.yaml"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing"* ]] || [[ "${output}" == *"not found"* ]]
}
