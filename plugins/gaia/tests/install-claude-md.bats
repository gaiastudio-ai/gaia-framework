#!/usr/bin/env bats
# install-claude-md.bats
#
# Covers install-claude-md.sh — materialize the project-root CLAUDE.md from
# the plugin template during /gaia-init (greenfield) and /gaia-brownfield.
#
# Bug: a freshly initialized GAIA project never received a CLAUDE.md, so
# Claude Code sessions had no GAIA context (runtime tree, how-to-start, hard
# rules, upstream bug-report policy).
#
# Tests:
#   AC1 — canonical template ships at plugins/gaia/templates/CLAUDE.md
#   AC2 — install helper copies template into target project root
#   AC3 — re-run with target present preserves byte-identity (never clobber)
#   AC4 — clear non-zero error when plugin template source is missing
#   AC5 — usage errors (no --target, missing target dir) exit 2
#
# Filesystem-only; no network.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  HELPER="${PLUGIN_ROOT}/gaia/scripts/install-claude-md.sh"
  TEMPLATE="${PLUGIN_ROOT}/gaia/templates/CLAUDE.md"
  TARGET_DIR="$(mktemp -d -t install-claude-md-XXXXXX)"
  TARGET_FILE="${TARGET_DIR}/CLAUDE.md"
}

teardown() {
  if [ -n "${TARGET_DIR:-}" ] && [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
  fi
}

# AC1 — template ships at canonical plugin path
@test "AC1: canonical CLAUDE.md template exists and is non-empty" {
  [ -f "${TEMPLATE}" ]
  [ -s "${TEMPLATE}" ]
}

@test "AC1: template names GAIA + the .gaia/ runtime tree (sanity)" {
  grep -qF "GAIA" "${TEMPLATE}"
  grep -qF ".gaia/" "${TEMPLATE}"
  grep -qF "How to Start" "${TEMPLATE}"
}

# AC2 — fresh install copies the template
@test "AC2: install helper copies CLAUDE.md into the target project root" {
  [ -x "${HELPER}" ]
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${TARGET_FILE}" ]
  cmp "${TEMPLATE}" "${TARGET_FILE}"
}

# AC3 — copy-if-absent: never clobber a user's existing CLAUDE.md
@test "AC3: re-run preserves an existing CLAUDE.md byte-identical (never clobber)" {
  printf '# my custom project CLAUDE.md\n' > "${TARGET_FILE}"
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  grep -qF "my custom project" "${TARGET_FILE}"
  # And it is NOT the template content.
  ! cmp -s "${TEMPLATE}" "${TARGET_FILE}"
}

# AC4 — missing plugin source template fails loud
@test "AC4: missing plugin template source exits 1 with a clear error" {
  # Point the helper at a fake plugin layout whose templates/ lacks CLAUDE.md.
  fake_plugin="$(mktemp -d)"
  mkdir -p "${fake_plugin}/scripts" "${fake_plugin}/templates"
  cp "${HELPER}" "${fake_plugin}/scripts/install-claude-md.sh"
  # no templates/CLAUDE.md
  run bash "${fake_plugin}/scripts/install-claude-md.sh" --target "${TARGET_DIR}"
  [ "${status}" -eq 1 ]
  echo "${output}" | grep -qF "plugin source template is missing"
  rm -rf "${fake_plugin}"
}

# AC5 — usage errors
@test "AC5: no --target exits 2" {
  run "${HELPER}"
  [ "${status}" -eq 2 ]
}

@test "AC5: nonexistent target dir exits 2" {
  run "${HELPER}" --target "${TARGET_DIR}/does-not-exist"
  [ "${status}" -eq 2 ]
}
