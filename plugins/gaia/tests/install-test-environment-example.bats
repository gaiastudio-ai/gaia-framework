#!/usr/bin/env bats
# install-test-environment-example.bats — E17-S30
#
# Covers the V2 plugin port of test-environment.yaml.example installation
# (originally shipped by E17-S25 via the legacy V1 gaia-install.sh).
#
# Tests:
#   AC1 — canonical template ships under plugins/gaia/templates/
#   AC2 — install helper copies template into target project at canonical path
#   AC3 — re-running install with target present preserves byte-identity
#   AC4 — install helper exits non-zero with clear error when template source is missing
#
# All tests are filesystem-only (no network, no service dispatch) per AC2's
# contract-only annotation.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  HELPER="${PLUGIN_ROOT}/gaia/scripts/install-test-environment-example.sh"
  TEMPLATE="${PLUGIN_ROOT}/gaia/templates/test-environment.yaml.example"
  TARGET_DIR="$(mktemp -d -t e17s30-bats-XXXXXX)"
  # AF-2026-05-21-8: canonical post-ADR-111 path. Pre-ADR-111 fixture cases
  # explicitly create config/ before invoking to exercise the legacy branch.
  TARGET_FILE="${TARGET_DIR}/.gaia/config/test-environment.yaml.example"
  LEGACY_TARGET_FILE="${TARGET_DIR}/config/test-environment.yaml.example"
}

teardown() {
  if [ -n "${TARGET_DIR:-}" ] && [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
  fi
}

# AC1 — template ships at canonical plugin path
@test "canonical template exists at plugins/gaia/templates/test-environment.yaml.example" {
  [ -f "${TEMPLATE}" ]
  # Non-empty
  [ -s "${TEMPLATE}" ]
}

@test "canonical template is byte-identical to V1 source-of-truth" {
  # The canonical template MUST be byte-identical to the V1 source at
  # Gaia-framework/docs/test-artifacts/test-environment.yaml.example
  # so the schema captured by E17-S7/S25 is preserved verbatim.
  # V1 source lives at project-root level, sibling to gaia-public/.
  V1_SOURCE="${BATS_TEST_DIRNAME}/../../../../Gaia-framework/docs/test-artifacts/test-environment.yaml.example"
  if [ ! -f "${V1_SOURCE}" ]; then
    skip "V1 source-of-truth missing (e.g., CI runner without project-root); template content is still validated by AC1 above"
  fi
  cmp "${TEMPLATE}" "${V1_SOURCE}"
}

# AC2 — install helper copies template into target project
@test "install helper copies template to target/docs/test-artifacts/" {
  [ -x "${HELPER}" ]
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${TARGET_FILE}" ]
  [ -s "${TARGET_FILE}" ]
}

@test "install helper copy is byte-identical to template" {
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  cmp "${TEMPLATE}" "${TARGET_FILE}"
}

# AC3 — re-running install preserves byte-identical user customization
@test "re-running install preserves user-edited target file byte-identical" {
  # First install — copies template
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]

  # User edits the file
  echo "" >> "${TARGET_FILE}"
  echo "# USER EDIT MARKER E17-S30 AC3" >> "${TARGET_FILE}"
  USER_HASH=$(shasum -a 256 "${TARGET_FILE}" | awk '{print $1}')

  # Second install — must NOT overwrite
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]

  POST_HASH=$(shasum -a 256 "${TARGET_FILE}" | awk '{print $1}')
  [ "${USER_HASH}" = "${POST_HASH}" ]

  # And the marker should still be there
  grep -q "USER EDIT MARKER E17-S30 AC3" "${TARGET_FILE}"
}

# AC4 — fail-fast when template source is missing (validate_source equivalent)
@test "install helper exits non-zero with clear error when template source is missing" {
  # Move the template aside temporarily
  TEMPLATE_BACKUP="${TEMPLATE}.bats-backup-$$"
  mv "${TEMPLATE}" "${TEMPLATE_BACKUP}"

  run "${HELPER}" --target "${TARGET_DIR}"
  STATUS_CODE=$status
  OUTPUT="$output"

  # Restore template before any assertion can fail
  mv "${TEMPLATE_BACKUP}" "${TEMPLATE}"

  [ "${STATUS_CODE}" -ne 0 ]
  [[ "${OUTPUT}" == *"test-environment.yaml.example"* ]]
}

# Idempotency in absent-target path (AC2 + AC3 combined)
@test "+: install on absent target creates the file, second run is a no-op preserving identity" {
  # First run creates
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  HASH1=$(shasum -a 256 "${TARGET_FILE}" | awk '{print $1}')

  # Second run with no user edit — still no-op (file already exists at canonical path)
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  HASH2=$(shasum -a 256 "${TARGET_FILE}" | awk '{print $1}')

  [ "${HASH1}" = "${HASH2}" ]
}
