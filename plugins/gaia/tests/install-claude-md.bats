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
#   AC1 — canonical template ships at plugins/gaia/templates/CLAUDE.md (marker-bounded)
#   AC2 — greenfield (no CLAUDE.md): seed the template verbatim
#   AC3 — brownfield (existing CLAUDE.md, no GAIA block): APPEND the block,
#         preserving the user's content above it (never clobber)
#   AC4 — idempotent: re-run on a managed file is a byte-identical no-op
#   AC5 — clear non-zero error when plugin template source is missing
#   AC6 — usage errors (no --target, missing target dir) exit 2
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

GAIA_MARKER="<!-- >>> GAIA (managed by /gaia-init · /gaia-brownfield) -->"

# AC1 — template ships at canonical plugin path, marker-bounded
@test "AC1: canonical CLAUDE.md template exists and is non-empty" {
  [ -f "${TEMPLATE}" ]
  [ -s "${TEMPLATE}" ]
}

@test "AC1: template is GAIA-marker-bounded and names the runtime tree" {
  grep -qF "${GAIA_MARKER}" "${TEMPLATE}"
  grep -qF "<!-- <<< GAIA -->" "${TEMPLATE}"
  grep -qF "GAIA" "${TEMPLATE}"
  grep -qF ".gaia/" "${TEMPLATE}"
  grep -qF "How to Start" "${TEMPLATE}"
}

# AC2 — greenfield: seed the template verbatim
@test "AC2: greenfield (no CLAUDE.md) seeds the template verbatim" {
  [ -x "${HELPER}" ]
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${TARGET_FILE}" ]
  cmp "${TEMPLATE}" "${TARGET_FILE}"
}

# AC3 — brownfield: existing CLAUDE.md, no GAIA block -> append, preserve user content
@test "AC3: brownfield appends the GAIA block and preserves the user's content above it" {
  cat > "${TARGET_FILE}" <<'USERMD'
# My App

Django app. Run tests with `pytest`. Never touch the legacy/ folder.
USERMD
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  # User content preserved verbatim.
  grep -qF "My App" "${TARGET_FILE}"
  grep -qF "Never touch the legacy/ folder" "${TARGET_FILE}"
  # GAIA block appended below it.
  grep -qF "${GAIA_MARKER}" "${TARGET_FILE}"
  grep -qF "GAIA Framework" "${TARGET_FILE}"
  # The user's heading appears BEFORE the GAIA marker (block was appended, not prepended/clobbered).
  user_line="$(grep -nF 'My App' "${TARGET_FILE}" | head -1 | cut -d: -f1)"
  marker_line="$(grep -nF "${GAIA_MARKER}" "${TARGET_FILE}" | head -1 | cut -d: -f1)"
  [ "${user_line}" -lt "${marker_line}" ]
}

# AC4 — idempotent: re-run on a managed file is a byte-identical no-op
@test "AC4: re-run on a greenfield-seeded file is a no-op (no duplicate block)" {
  "${HELPER}" --target "${TARGET_DIR}" >/dev/null
  before="$(cksum "${TARGET_FILE}")"
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  after="$(cksum "${TARGET_FILE}")"
  [ "${before}" = "${after}" ]
  [ "$(grep -cF "${GAIA_MARKER}" "${TARGET_FILE}")" -eq 1 ]
}

@test "AC4: re-run on a brownfield-appended file does not duplicate the GAIA block" {
  printf '# My App\nNever touch legacy/.\n' > "${TARGET_FILE}"
  "${HELPER}" --target "${TARGET_DIR}" >/dev/null   # append
  before="$(cksum "${TARGET_FILE}")"
  "${HELPER}" --target "${TARGET_DIR}" >/dev/null   # no-op
  after="$(cksum "${TARGET_FILE}")"
  [ "${before}" = "${after}" ]
  [ "$(grep -cF "${GAIA_MARKER}" "${TARGET_FILE}")" -eq 1 ]
  grep -qF "Never touch legacy/." "${TARGET_FILE}"
}

# AC5 — missing plugin source template fails loud
@test "AC5: missing plugin template source exits 1 with a clear error" {
  fake_plugin="$(mktemp -d)"
  mkdir -p "${fake_plugin}/scripts" "${fake_plugin}/templates"
  cp "${HELPER}" "${fake_plugin}/scripts/install-claude-md.sh"
  # no templates/CLAUDE.md
  run bash "${fake_plugin}/scripts/install-claude-md.sh" --target "${TARGET_DIR}"
  [ "${status}" -eq 1 ]
  echo "${output}" | grep -qF "plugin source template is missing"
  rm -rf "${fake_plugin}"
}

# AC6 — usage errors
@test "AC6: no --target exits 2" {
  run "${HELPER}"
  [ "${status}" -eq 2 ]
}

@test "AC6: nonexistent target dir exits 2" {
  run "${HELPER}" --target "${TARGET_DIR}/does-not-exist"
  [ "${status}" -eq 2 ]
}
