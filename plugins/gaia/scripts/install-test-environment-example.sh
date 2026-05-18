#!/usr/bin/env bash
# install-test-environment-example.sh — E17-S30 (V2 plugin port of E17-S25)
#
# Materialize the canonical test-environment.yaml.example template into a
# target project at docs/test-artifacts/test-environment.yaml.example.
#
# Semantics:
#   - Unconditional copy when target is ABSENT (fresh-install path, AC2).
#   - Byte-identical preserve when target EXISTS (copy-if-absent, AC3).
#   - Fail-fast non-zero when plugin source template is missing (AC4).
#
# Mirrors the V1 install pattern from Gaia-framework/gaia-install.sh
# (cmd_init unconditional copy + cmd_update copy-if-absent at L640-663).
#
# Usage:
#   install-test-environment-example.sh --target <project-root>
#   install-test-environment-example.sh --help
#
# Exit codes:
#   0  success (copy performed, or target already present and preserved)
#   1  plugin source template is missing (AC4 fail-fast)
#   2  usage error
#
# Traces: E17-S30, FR-201, ADR-028.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="install-test-environment-example.sh"

# Resolve plugin root from this script's location:
#   <plugin-root>/scripts/install-test-environment-example.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_PATH="${PLUGIN_ROOT}/templates/test-environment.yaml.example"
TARGET_REL="docs/test-artifacts/test-environment.yaml.example"

target=""

usage() {
  cat <<'USAGE'
Usage: install-test-environment-example.sh --target <project-root>

Materialize plugins/gaia/templates/test-environment.yaml.example into the
target project at docs/test-artifacts/test-environment.yaml.example.

Behavior:
  - Target absent: copy template (fresh-install path).
  - Target present: preserve byte-identical (copy-if-absent semantics).
  - Plugin source missing: exit 1 with a clear error.

Exit codes:
  0  success
  1  plugin source template missing
  2  usage error
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { printf '%s: --target requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      target="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf '%s: unexpected argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
done

[ -n "${target}" ] || { printf '%s: --target is required\n' "$SCRIPT_NAME" >&2; usage >&2; exit 2; }
[ -d "${target}" ] || { printf '%s: target directory does not exist: %s\n' "$SCRIPT_NAME" "${target}" >&2; exit 2; }

if [ ! -f "${TEMPLATE_PATH}" ]; then
  printf '%s: ERROR: plugin source template is missing at %s\n' "$SCRIPT_NAME" "${TEMPLATE_PATH}" >&2
  printf '%s: cannot install test-environment.yaml.example without source. Plugin may be corrupted; reinstall via /plugin marketplace add.\n' "$SCRIPT_NAME" >&2
  exit 1
fi

target_file="${target}/${TARGET_REL}"
target_dir="$(dirname "${target_file}")"

mkdir -p "${target_dir}"

if [ -f "${target_file}" ]; then
  printf '%s: target already exists at %s — preserving byte-identical (copy-if-absent semantics)\n' "$SCRIPT_NAME" "${target_file}"
  exit 0
fi

cp "${TEMPLATE_PATH}" "${target_file}"
printf '%s: installed test-environment.yaml.example -> %s\n' "$SCRIPT_NAME" "${target_file}"
exit 0
