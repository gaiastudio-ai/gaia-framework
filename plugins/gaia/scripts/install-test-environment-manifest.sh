#!/usr/bin/env bash
# install-test-environment-manifest.sh — test-environment manifest installer
#
# Materialize .gaia/config/test-environment.yaml (canonical) or
# config/test-environment.yaml (legacy) in a target project by
# copying the matching .example template. This is the
# concrete "copy .example → .yaml" action invoked from:
#   - /gaia-bridge-toggle Step 4 option [b] (interactive 3-option prompt)
#   - /gaia-bridge-toggle Step 4 YOLO-absent branch (auto-copy)
#
# Sibling to install-test-environment-example.sh — that helper
# materializes the .example template from the plugin; this helper
# materializes the live .yaml manifest from the .example in the project.
#
# Semantics:
#   - .yaml absent + .example present: copy .example → .yaml (success).
#   - .yaml present: preserve byte-identical, exit 0 (copy-if-absent).
#   - .example absent: exit 1 with a clear error pointing at /gaia-init
#     or the install-test-environment-example.sh install path (graceful fallback).
#
# Usage:
#   install-test-environment-manifest.sh --target <project-root>
#   install-test-environment-manifest.sh --help
#
# Exit codes:
#   0  success (copy performed, or manifest already present and preserved)
#   1  .example source is missing (fail-fast)
#   2  usage error
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="install-test-environment-manifest.sh"

EXAMPLE_REL=""
MANIFEST_REL=""

target=""

usage() {
  cat <<'USAGE'
Usage: install-test-environment-manifest.sh --target <project-root>

Copy .gaia/config/test-environment.yaml.example → .gaia/config/test-environment.yaml
inside the target project (canonical). Falls back to legacy
config/test-environment.yaml.example → config/test-environment.yaml on legacy
projects. Used by /gaia-bridge-toggle Step 4 option [b] and the
YOLO-absent auto-copy branch.

Behavior:
  - .yaml absent + .example present: copy .example -> .yaml.
  - .yaml present: preserve byte-identical (copy-if-absent semantics).
  - .example absent: exit 1 with a clear error.

Exit codes:
  0  success
  1  .example source missing
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

# Canonical .gaia/config/ default; legacy config/ fallback
# only on positive pre-canonical evidence.
if [ -d "${target}/config" ] && [ ! -d "${target}/.gaia/config" ]; then
  EXAMPLE_REL="config/test-environment.yaml.example"
  MANIFEST_REL="config/test-environment.yaml"
else
  EXAMPLE_REL=".gaia/config/test-environment.yaml.example"
  MANIFEST_REL=".gaia/config/test-environment.yaml"
fi

example_file="${target}/${EXAMPLE_REL}"
manifest_file="${target}/${MANIFEST_REL}"

if [ ! -f "${example_file}" ]; then
  printf '%s: ERROR: %s is missing — cannot materialize manifest.\n' "$SCRIPT_NAME" "${EXAMPLE_REL}" >&2
  printf '%s: run /gaia-init to install the canonical test-environment.yaml.example, or invoke install-test-environment-example.sh directly.\n' "$SCRIPT_NAME" >&2
  exit 1
fi

manifest_dir="$(dirname "${manifest_file}")"
mkdir -p "${manifest_dir}"

if [ -f "${manifest_file}" ]; then
  printf '%s: manifest already exists at %s — preserving byte-identical (copy-if-absent semantics)\n' "$SCRIPT_NAME" "${manifest_file}"
  exit 0
fi

cp "${example_file}" "${manifest_file}"
printf '%s: installed test-environment.yaml -> %s\n' "$SCRIPT_NAME" "${manifest_file}"
exit 0
