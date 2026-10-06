#!/usr/bin/env bash
# escape-boundary-markers.sh — escape << to <~< in stdin, preventing
# boundary-marker injection. The output never contains <<<.

escape_boundary_markers() {
  sed 's/<</<~</g'
}

# Main guard — shell options set only when running standalone,
# never when sourced (sourcing must not change the caller's options).
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  LC_ALL=C; export LC_ALL
  escape_boundary_markers
fi
