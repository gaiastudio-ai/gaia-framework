#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# escape-boundary-markers.sh — escape << to <~< in stdin, preventing
# boundary-marker injection. The output never contains <<<.

escape_boundary_markers() {
  sed 's/<</<~</g'
}

# Main guard
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  escape_boundary_markers
fi
