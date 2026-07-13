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
@test "canonical CLAUDE.md template exists and is non-empty" {
  [ -f "${TEMPLATE}" ]
  [ -s "${TEMPLATE}" ]
}

@test "template is GAIA-marker-bounded and names the runtime tree" {
  grep -qF "${GAIA_MARKER}" "${TEMPLATE}"
  grep -qF "<!-- <<< GAIA -->" "${TEMPLATE}"
  grep -qF "GAIA" "${TEMPLATE}"
  grep -qF ".gaia/" "${TEMPLATE}"
  grep -qF "How to Start" "${TEMPLATE}"
}

# AC2 — greenfield: seed the template verbatim
@test "greenfield (no CLAUDE.md) seeds the template verbatim" {
  [ -x "${HELPER}" ]
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  [ -f "${TARGET_FILE}" ]
  cmp "${TEMPLATE}" "${TARGET_FILE}"
}

# AC3 — brownfield: existing CLAUDE.md, no GAIA block -> append, preserve user content
@test "brownfield appends the GAIA block and preserves the user's content above it" {
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
@test "re-run on a greenfield-seeded file is a no-op (no duplicate block)" {
  "${HELPER}" --target "${TARGET_DIR}" >/dev/null
  before="$(cksum "${TARGET_FILE}")"
  run "${HELPER}" --target "${TARGET_DIR}"
  [ "${status}" -eq 0 ]
  after="$(cksum "${TARGET_FILE}")"
  [ "${before}" = "${after}" ]
  [ "$(grep -cF "${GAIA_MARKER}" "${TARGET_FILE}")" -eq 1 ]
}

@test "re-run on a brownfield-appended file does not duplicate the GAIA block" {
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
@test "missing plugin template source exits 1 with a clear error" {
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
@test "no --target exits 2" {
  run "${HELPER}"
  [ "${status}" -eq 2 ]
}

@test "nonexistent target dir exits 2" {
  run "${HELPER}" --target "${TARGET_DIR}/does-not-exist"
  [ "${status}" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Template content + drift guard.
#
# The template is what a user's project actually receives, so content missing
# from it is content missing from every new project. The install tests above
# exercise only the seed/append/no-op plumbing and pin no body content — which
# is precisely why the template was able to fall two edits behind the root
# CLAUDE.md (a whole documented subsystem and a Hard Rule) with CI green.
# ---------------------------------------------------------------------------

DRIFT_GUARD="${BATS_TEST_DIRNAME}/../scripts/check-claude-md-drift.sh"
REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."

# The Brain subsystem must be documented in what ships to users.
@test "template documents the Brain knowledge layer and its gestures (AC7)" {
  grep -qF "## GAIA Brain" "${TEMPLATE}"
  grep -qF ".gaia/knowledge/" "${TEMPLATE}"
  for gesture in /gaia-feed /gaia-brain-query /gaia-brain-reindex \
                 /gaia-brain-health /gaia-unfeed /gaia-knowledge-refresh; do
    grep -qF "${gesture}" "${TEMPLATE}"
  done
}

# The runtime-tree bullet list and its stated count must agree.
@test "template runtime-tree count matches the number of listed subdirs (AC7)" {
  listed="$(grep -cE '^  - `\.gaia/[a-z]+/`' "${TEMPLATE}")"
  [ "${listed}" -eq 6 ]
  grep -qF 'carries six canonical subdirectories' "${TEMPLATE}"
}

# The no-silent-deferral rule is the project's strictest behavioural contract;
# a project that never receives it never enforces it.
@test "template carries the no-silent-deferral Hard Rule (AC8)" {
  grep -qF "NEVER defer, descope, skip, or partially-complete any work" "${TEMPLATE}"
  grep -qF "Silence is not consent." "${TEMPLATE}"
}

# The guard passes on the real tree — this is the regression pin.
@test "drift guard passes against the shipped template (AC9)" {
  [ -x "${DRIFT_GUARD}" ]
  run "${DRIFT_GUARD}" --root "${REPO_ROOT}"
  [ "${status}" -eq 0 ]
}

# Drive the REAL guard against a drifted fixture — a mocked guard would have
# missed the original bug. A section present in root but absent from the
# template must fail.
@test "drift guard catches a section missing from the template (AC9)" {
  fake_root="$(mktemp -d)"
  mkdir -p "${fake_root}/plugins/gaia/templates"
  printf '# X\n\n## Kept\n\nbody\n\n## Hard Rules\n\n- a rule\n' \
    > "${fake_root}/CLAUDE.md"
  # template omits "## Kept"
  printf '# X\n\n## Hard Rules\n\n- a rule\n' \
    > "${fake_root}/plugins/gaia/templates/CLAUDE.md"

  run "${DRIFT_GUARD}" --root "${fake_root}"
  [ "${status}" -eq 1 ]
  echo "${output}" | grep -qF "## Kept"
  rm -rf "${fake_root}"
}

# A Hard Rule present in root but absent from the template must fail. Bullets
# start with "- ", which is why the guard's grep needs `--`; without it every
# rule reports as missing and the output is useless.
@test "drift guard catches a Hard Rule missing from the template (AC9)" {
  fake_root="$(mktemp -d)"
  mkdir -p "${fake_root}/plugins/gaia/templates"
  printf '# X\n\n## Hard Rules\n\n- **NEVER** drop scope silently.\n- keep secrets out.\n' \
    > "${fake_root}/CLAUDE.md"
  # template carries only the second rule
  printf '# X\n\n## Hard Rules\n\n- keep secrets out.\n' \
    > "${fake_root}/plugins/gaia/templates/CLAUDE.md"

  run "${DRIFT_GUARD}" --root "${fake_root}"
  [ "${status}" -eq 1 ]
  echo "${output}" | grep -qF "missing hard rule"
  echo "${output}" | grep -qF "NEVER"
  rm -rf "${fake_root}"
}

# No false positives: a rule the template DOES carry must not be reported.
# (Regression pin for the leading-dash grep-option bug.)
@test "drift guard does not report rules the template carries (AC9)" {
  fake_root="$(mktemp -d)"
  mkdir -p "${fake_root}/plugins/gaia/templates"
  printf '# X\n\n## Hard Rules\n\n- keep secrets out.\n- feature branches only.\n' \
    > "${fake_root}/CLAUDE.md"
  cp "${fake_root}/CLAUDE.md" "${fake_root}/plugins/gaia/templates/CLAUDE.md"

  run "${DRIFT_GUARD}" --root "${fake_root}"
  [ "${status}" -eq 0 ]
  ! echo "${output}" | grep -qF "invalid option"
  rm -rf "${fake_root}"
}

# The template may hold content the root file does not (one-way check).
@test "drift guard allows template-only content (AC9)" {
  fake_root="$(mktemp -d)"
  mkdir -p "${fake_root}/plugins/gaia/templates"
  printf '# X\n\n## Hard Rules\n\n- a rule\n' > "${fake_root}/CLAUDE.md"
  printf '# X\n\n## Extra\n\n## Hard Rules\n\n- a rule\n' \
    > "${fake_root}/plugins/gaia/templates/CLAUDE.md"

  run "${DRIFT_GUARD}" --root "${fake_root}"
  [ "${status}" -eq 0 ]
  rm -rf "${fake_root}"
}

@test "drift guard exits 2 on a missing input file (AC9)" {
  fake_root="$(mktemp -d)"
  run "${DRIFT_GUARD}" --root "${fake_root}"
  [ "${status}" -eq 2 ]
  rm -rf "${fake_root}"
}
