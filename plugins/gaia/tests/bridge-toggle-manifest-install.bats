#!/usr/bin/env bats
# bridge-toggle-manifest-install.bats — E17-S31
#
# Covers the /gaia-bridge-toggle Step 4 option [b] path correction + the
# new YOLO-mode auto-copy behavior (replaces auto-skip-to-[c]).
#
# Tests:
#   AC1/AC2 — install-test-environment-manifest.sh copies .yaml.example
#             → .yaml at user-project canonical path; idempotent on re-run.
#   AC3 — invocable from YOLO branch (helper is a thin wrapper, so YOLO
#         coverage = direct invocation coverage).
#   AC4 — fail-fast when source .yaml.example is absent (graceful fallback
#         per Dev Notes "if S30 has NOT landed").
#
# The SKILL.md prose change (AC1, AC5) is verified by separate string-match
# tests in this file as defense-in-depth — these grep for the new option
# [b] path and the new YOLO auto-copy log line so a future regression that
# reverts the prose is caught at test time.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  HELPER="${PLUGIN_ROOT}/gaia/scripts/install-test-environment-manifest.sh"
  SKILL_MD="${PLUGIN_ROOT}/gaia/skills/gaia-bridge-toggle/SKILL.md"
  TARGET_DIR="$(mktemp -d -t e17s31-bats-XXXXXX)"
  mkdir -p "${TARGET_DIR}/docs/test-artifacts"
  EXAMPLE_FILE="${TARGET_DIR}/docs/test-artifacts/test-environment.yaml.example"
  MANIFEST_FILE="${TARGET_DIR}/docs/test-artifacts/test-environment.yaml"
}

teardown() {
  if [ -n "${TARGET_DIR:-}" ] && [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
  fi
}

# Helper: seed the .example file in the fixture (post-S30 install state)
seed_example() {
  cp "${PLUGIN_ROOT}/gaia/templates/test-environment.yaml.example" "${EXAMPLE_FILE}"
}

# AC1/AC2 — copy .example → .yaml
@test "AC1/AC2: helper copies test-environment.yaml.example to test-environment.yaml" {
  [ -x "${HELPER}" ]
  seed_example
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${MANIFEST_FILE}" ]
  cmp "${EXAMPLE_FILE}" "${MANIFEST_FILE}"
}

# AC1/AC2 idempotency — re-running with manifest present is a no-op
@test "AC1/AC2: re-running with manifest present preserves user customizations byte-identical" {
  seed_example
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]

  # User edits the manifest
  echo "" >> "${MANIFEST_FILE}"
  echo "# USER EDIT MARKER E17-S31" >> "${MANIFEST_FILE}"
  USER_HASH=$(shasum -a 256 "${MANIFEST_FILE}" | awk '{print $1}')

  # Re-run helper
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]

  POST_HASH=$(shasum -a 256 "${MANIFEST_FILE}" | awk '{print $1}')
  [ "${USER_HASH}" = "${POST_HASH}" ]
  grep -q "USER EDIT MARKER E17-S31" "${MANIFEST_FILE}"
}

# AC4 — fail-fast when .example source is absent
@test "AC4: helper exits non-zero with clear error when .example source is missing" {
  # Do NOT seed_example — .example is absent
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test-environment.yaml.example"* ]]
}

# AC1 / AC5 — SKILL.md prose update
@test "AC1: bridge-toggle SKILL.md Step 4 option [b] references the new install helper" {
  # The new prose must mention install-test-environment-manifest.sh
  grep -q "install-test-environment-manifest.sh" "${SKILL_MD}"
}

@test "AC3 / AC5: bridge-toggle SKILL.md AC-EC5 YOLO-absent branch auto-copies (not auto-skip to c)" {
  # The new prose must contain the YOLO auto-copy log line
  grep -q "auto-copied test-environment.yaml from template (YOLO mode)" "${SKILL_MD}"
  # And must NOT still say "auto-select option [c] Skip" in the YOLO-absent block
  # (defense-in-depth against a partial revert)
  ! grep -q "auto-select option \`\[c\]\` Skip" "${SKILL_MD}"
}

@test "AC5: bridge-toggle SKILL.md non-YOLO option [b] still copies but now from a real path" {
  # Option [b] must still describe a copy from .example
  grep -qE "\\[b\\].*Copy.*test-environment\\.yaml\\.example" "${SKILL_MD}"
}
