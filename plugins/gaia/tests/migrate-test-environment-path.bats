#!/usr/bin/env bats
# migrate-test-environment-path.bats — E17-S32
#
# Covers the canonical-path relocation (ADR-110): test-environment.yaml moves
# from docs/test-artifacts/ to config/. This test exercises the detect-and-move
# helper that backward-compatibly migrates projects upgraded from v1.156.0 /
# E17-S30 where the file lives at the legacy path.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  HELPER="${PLUGIN_ROOT}/gaia/scripts/migrate-test-environment-path.sh"
  TARGET_DIR="$(mktemp -d -t e17s32-bats-XXXXXX)"
  mkdir -p "${TARGET_DIR}/docs/test-artifacts" "${TARGET_DIR}/config" "${TARGET_DIR}/.gaia/memory"
  LEGACY="${TARGET_DIR}/docs/test-artifacts/test-environment.yaml"
  CANONICAL="${TARGET_DIR}/config/test-environment.yaml"
  SENTINEL="${TARGET_DIR}/.gaia/memory/.test-environment-path-migrated"
}

teardown() {
  if [ -n "${TARGET_DIR:-}" ] && [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
  fi
}

# AC4 — Legacy file detect-and-moved to config/
@test "AC4: legacy file at docs/test-artifacts/ moved to config/ + sentinel emitted" {
  [ -x "${HELPER}" ]
  echo "version: 2" > "${LEGACY}"
  echo "runners: []" >> "${LEGACY}"
  EXPECTED_HASH=$(shasum -a 256 "${LEGACY}" | awk '{print $1}')

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${CANONICAL}" ]
  [ ! -f "${LEGACY}" ]
  ACTUAL_HASH=$(shasum -a 256 "${CANONICAL}" | awk '{print $1}')
  [ "${EXPECTED_HASH}" = "${ACTUAL_HASH}" ]
}

@test "AC4: detect-and-move emits canonical stderr deprecation warning" {
  echo "version: 2" > "${LEGACY}"
  echo "runners: []" >> "${LEGACY}"

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEPRECATION"* ]]
  [[ "${output}" == *"docs/test-artifacts/"* ]]
  [[ "${output}" == *"config/"* ]]
}

@test "AC4: post-move, sentinel file is created at .gaia/memory/.test-environment-path-migrated" {
  echo "version: 2" > "${LEGACY}"
  echo "runners: []" >> "${LEGACY}"

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${SENTINEL}" ]
}

# AC5 — Both files present → prefer config/, legacy untouched
@test "AC5: both files present → canonical preferred, legacy untouched, INFO log emitted" {
  echo "# legacy" > "${LEGACY}"
  echo "# canonical" > "${CANONICAL}"
  LEGACY_HASH=$(shasum -a 256 "${LEGACY}" | awk '{print $1}')
  CANONICAL_HASH=$(shasum -a 256 "${CANONICAL}" | awk '{print $1}')

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]

  [ "$(shasum -a 256 "${LEGACY}" | awk '{print $1}')" = "${LEGACY_HASH}" ]
  [ "$(shasum -a 256 "${CANONICAL}" | awk '{print $1}')" = "${CANONICAL_HASH}" ]
  [[ "${output}" == *"INFO"* ]]
  [[ "${output}" == *"both"* ]]
}

# Idempotency — no-op when only canonical exists (no legacy, nothing to migrate)
@test "AC4 idempotency: no-op when only canonical exists (no legacy)" {
  echo "version: 2" > "${CANONICAL}"
  CANONICAL_HASH=$(shasum -a 256 "${CANONICAL}" | awk '{print $1}')

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ "$(shasum -a 256 "${CANONICAL}" | awk '{print $1}')" = "${CANONICAL_HASH}" ]
  [ ! -f "${LEGACY}" ]
}

# Idempotency — no-op when neither file exists
@test "no-op when neither file exists (fresh project)" {
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ ! -f "${LEGACY}" ]
  [ ! -f "${CANONICAL}" ]
  [ ! -f "${SENTINEL}" ]
}

# Usage error
@test "fails with usage error when --target is missing" {
  run "${HELPER}"
  [ "${status}" -eq 2 ]
}

# AC1 — install-test-environment-example.sh writes to .gaia/config/ on greenfield (AF-2026-05-21-8)
@test "AC1: install-test-environment-example.sh writes to .gaia/config/test-environment.yaml.example" {
  EXAMPLE_HELPER="${PLUGIN_ROOT}/gaia/scripts/install-test-environment-example.sh"
  # Fresh TARGET_DIR for greenfield assertion (per-test isolation).
  GREENFIELD_DIR="$(mktemp -d -t e17s32-greenfield-XXXXXX)"
  TARGET_FILE="${GREENFIELD_DIR}/.gaia/config/test-environment.yaml.example"

  run "${EXAMPLE_HELPER}" --target "${GREENFIELD_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${TARGET_FILE}" ]
  # AF-2026-05-21-8 regression guard: NO rogue config/ created at project root.
  [ ! -d "${GREENFIELD_DIR}/config" ]

  rm -rf "${GREENFIELD_DIR}"
}

# AC1 — install-test-environment-manifest.sh copies .gaia/config/.example → .gaia/config/.yaml on greenfield
@test "AC1: install-test-environment-manifest.sh copies .gaia/config/.example → .gaia/config/.yaml" {
  EXAMPLE_HELPER="${PLUGIN_ROOT}/gaia/scripts/install-test-environment-example.sh"
  MANIFEST_HELPER="${PLUGIN_ROOT}/gaia/scripts/install-test-environment-manifest.sh"
  GREENFIELD_DIR="$(mktemp -d -t e17s32-greenfield2-XXXXXX)"

  run "${EXAMPLE_HELPER}" --target "${GREENFIELD_DIR}"
  [ "${status}" -eq 0 ]
  run "${MANIFEST_HELPER}" --target "${GREENFIELD_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${GREENFIELD_DIR}/.gaia/config/test-environment.yaml" ]
  [ -f "${GREENFIELD_DIR}/.gaia/config/test-environment.yaml.example" ]
  # AF-2026-05-21-8 regression guard: NO rogue config/ at project root.
  [ ! -d "${GREENFIELD_DIR}/config" ]

  rm -rf "${GREENFIELD_DIR}"
}
