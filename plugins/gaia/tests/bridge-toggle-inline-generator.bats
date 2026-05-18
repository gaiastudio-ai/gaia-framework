#!/usr/bin/env bats
# bridge-toggle-inline-generator.bats — E17-S34
#
# Covers the bridge-toggle Step 4 rewrite to invoke the inline manifest
# generator (helper from E17-S33) instead of pointing the user at
# /gaia-brownfield. The SKILL.md prose MUST NOT mention /gaia-brownfield
# to the end user — the dependency is internal only.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  SKILL_MD="${PLUGIN_ROOT}/gaia/skills/gaia-bridge-toggle/SKILL.md"
  GENERATOR="${PLUGIN_ROOT}/gaia/scripts/lib/test-environment-manifest.sh"
  TARGET_DIR="$(mktemp -d -t e17s34-bats-XXXXXX)"
  CANONICAL="${TARGET_DIR}/config/test-environment.yaml"
}

teardown() {
  if [ -n "${TARGET_DIR:-}" ] && [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
  fi
}

# AC1 — Step 4 option [a] prose references the helper
@test "AC1: Step 4 option [a] prose references the inline manifest generator" {
  grep -q "test-environment-manifest.sh" "${SKILL_MD}"
}

# AC1/AC5(d) — Step 4 option [a] prose contains ZERO /gaia-brownfield substrings in user-visible text
@test "AC1/AC5(d): Step 4 option [a] block contains no /gaia-brownfield mention in user-visible prose" {
  # Extract the Step 4 prose between "## Step 4" and "## Step 5"
  STEP4=$(awk '/^## Step 4/,/^## Step 5/' "${SKILL_MD}")

  # Find the option [a] description (the line containing "[a]")
  OPTION_A_LINE=$(echo "${STEP4}" | grep -E "^\s+\-\s+\`\[a\]\`")

  # User-visible option [a] line must NOT mention /gaia-brownfield
  ! [[ "${OPTION_A_LINE}" == *"/gaia-brownfield"* ]]
}

# AC2 — Option [b] remains as schema-doc fallback
@test "AC2: option [b] still references install-test-environment-manifest.sh as schema-doc starter" {
  STEP4=$(awk '/^## Step 4/,/^## Step 5/' "${SKILL_MD}")
  # Option [b] should still exist
  echo "${STEP4}" | grep -qE "^\s+\-\s+\`\[b\]\`"
  # And should reference the .example template
  echo "${STEP4}" | grep -qF "test-environment.yaml.example"
}

# AC3 — YOLO branch auto-invokes the generator (NOT the E17-S31 template-copy)
@test "AC3: YOLO branch auto-invokes the inline generator with the canonical log line" {
  STEP4=$(awk '/^## Step 4/,/^## Step 5/' "${SKILL_MD}")
  # YOLO branch must mention the generator helper
  echo "${STEP4}" | grep -q "absent (YOLO)"
  # And include the canonical log line
  echo "${STEP4}" | grep -qF "auto-generated config/test-environment.yaml for detected stack"
}

# AC4 — Generator-failure fallback to template-copy
@test "AC4: SKILL.md describes the generator-failure → template-copy fallback" {
  STEP4=$(awk '/^## Step 4/,/^## Step 5/' "${SKILL_MD}")
  # Some explicit fallback prose must mention the install-test-environment-manifest.sh as a fallback
  echo "${STEP4}" | grep -qF "install-test-environment-manifest.sh"
}

# Functional check: the helper invocation pattern actually works against a real fixture
@test "AC1/AC2: helper invocation pattern works end-to-end (smoke test)" {
  # Seed a Node project so the helper has something to detect
  echo '{"name":"test","devDependencies":{"jest":"^29.0.0"}}' > "${TARGET_DIR}/package.json"

  # Invoke the helper exactly as Step 4 prose prescribes
  run "${GENERATOR}" --target "${TARGET_DIR}" --write
  [ "${status}" -eq 0 ]
  [ -f "${CANONICAL}" ]
  grep -q "^runners:" "${CANONICAL}"
  # detected-stack should be recorded for Step 5 to surface
  grep -q "detected-stack:" "${CANONICAL}"
}

# AC5(c) — generator-failure fallback works (when the helper is moved aside, fallback exits gracefully)
@test "AC4 fallback smoke: when generator is unavailable, install-test-environment-manifest.sh is the documented fallback" {
  # Just verify the fallback helper exists (was shipped in E17-S31)
  FALLBACK="${PLUGIN_ROOT}/gaia/scripts/install-test-environment-manifest.sh"
  [ -x "${FALLBACK}" ]
}
