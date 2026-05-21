#!/usr/bin/env bats
# test-environment-manifest-generator.bats — E17-S33
#
# Covers the shared library helper that extracts /gaia-brownfield Phase 5
# manifest-generation logic (FR-496 inline auto-generate, FR-497 populated
# runners contract; ADR-110).

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  HELPER="${PLUGIN_ROOT}/gaia/scripts/lib/test-environment-manifest.sh"
  TARGET_DIR="$(mktemp -d -t e17s33-bats-XXXXXX)"
  # AF-2026-05-21-8: canonical post-ADR-111 path.
  TARGET_YAML="${TARGET_DIR}/.gaia/config/test-environment.yaml"
}

teardown() {
  if [ -n "${TARGET_DIR:-}" ] && [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
  fi
}

# AC1 — helper exists + executable
@test "AC1: helper exists + executable at scripts/lib/test-environment-manifest.sh" {
  [ -f "${HELPER}" ]
  [ -x "${HELPER}" ]
}

# AC2 — stdout emit + --write semantics
@test "AC2: --target alone emits yaml on stdout (no write)" {
  echo '{"name":"test","version":"0.0.1"}' > "${TARGET_DIR}/package.json"

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"runners:"* ]]
  [[ "${output}" == *"version:"* ]]
  [ ! -f "${TARGET_YAML}" ]
}

@test "AC2: --write creates config/test-environment.yaml at canonical path" {
  echo '{"name":"test","version":"0.0.1"}' > "${TARGET_DIR}/package.json"

  run "${HELPER}" --target "${TARGET_DIR}" --write
  [ "${status}" -eq 0 ]
  [ -f "${TARGET_YAML}" ]
  grep -q "^runners:" "${TARGET_YAML}"
  grep -q "^version:" "${TARGET_YAML}"
}

# AC2 — copy-if-absent preserves existing user-edited manifest
@test "AC2: --write preserves user-edited manifest byte-identical (copy-if-absent)" {
  # AF-2026-05-21-8: canonical post-ADR-111 .gaia/config/ path.
  mkdir -p "${TARGET_DIR}/.gaia/config"
  cat > "${TARGET_YAML}" << 'YAML'
# USER EDIT MARKER E17-S33
version: 2
runners:
  - name: custom
    command: "make test"
    tier: 1
YAML
  EXPECTED_HASH=$(shasum -a 256 "${TARGET_YAML}" | awk '{print $1}')

  # Seed a Node project signal so the helper has something to detect
  echo '{"name":"test"}' > "${TARGET_DIR}/package.json"

  run "${HELPER}" --target "${TARGET_DIR}" --write
  [ "${status}" -eq 0 ]
  ACTUAL_HASH=$(shasum -a 256 "${TARGET_YAML}" | awk '{print $1}')
  [ "${EXPECTED_HASH}" = "${ACTUAL_HASH}" ]
  grep -q "USER EDIT MARKER E17-S33" "${TARGET_YAML}"
}

# AC3 — no-stack project → generic single-tier-1 fallback runner
@test "AC3: no-stack project emits generic single-tier-1 runner" {
  # No package.json, pyproject.toml, etc. — bare empty target.
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"runners:"* ]]
  # Must have at least ONE runner entry — generic placeholder
  COUNT=$(echo "${output}" | grep -c "^  - name:" || echo 0)
  [ "${COUNT}" -ge 1 ]
  # Tier 1 (unit) is the conventional placeholder tier
  [[ "${output}" == *"tier: 1"* ]]
}

# AC4 — Helper consults detection-signals.yaml (delegates to detect-signals.sh)
@test "AC4: helper output is driven by detection signals (Node detected → node-runner)" {
  echo '{"name":"test","devDependencies":{"jest":"^29.0.0"}}' > "${TARGET_DIR}/package.json"

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  # Should include an npm-stack-flavored runner (npm/yarn/pnpm based)
  [[ "${output}" == *"npm"* ]] || [[ "${output}" == *"yarn"* ]] || [[ "${output}" == *"jest"* ]]
}

# AC6/c — bash/bats stack regression guard (AF-4 root-cause guard)
@test "AC6/c: bash/bats project (GAIA itself) → bats-runner (NOT npm) [AF-4 regression guard]" {
  # Simulate a bats-detected project — no package.json, presence of .bats files
  mkdir -p "${TARGET_DIR}/tests"
  echo '@test "smoke" { true; }' > "${TARGET_DIR}/tests/smoke.bats"
  # No package.json — should NOT see npm in output

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  # The output should NOT contain npm-flavored runners when there's no package.json
  ! [[ "${output}" == *"npm test"* ]]
}

# AC6/f — byte-stable: rerunning helper on same project produces identical output
@test "AC6/f: byte-stable output across runs (deterministic)" {
  echo '{"name":"test","devDependencies":{"jest":"^29.0.0"}}' > "${TARGET_DIR}/package.json"

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  HASH1=$(echo "${output}" | shasum -a 256 | awk '{print $1}')

  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  HASH2=$(echo "${output}" | shasum -a 256 | awk '{print $1}')

  [ "${HASH1}" = "${HASH2}" ]
}

# AC5 — brownfield Phase 5 delegates to the helper (prose grep)
@test "AC5: gaia-brownfield/SKILL.md Phase 5 prose references the new helper" {
  grep -q "test-environment-manifest.sh" "${PLUGIN_ROOT}/gaia/skills/gaia-brownfield/SKILL.md"
}

# Usage error
@test "fails with usage error when --target is missing" {
  run "${HELPER}"
  [ "${status}" -eq 2 ]
}
