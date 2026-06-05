#!/usr/bin/env bash
# review-common/verdict-resolver.sh — re-export entry point
#
# Thin wrapper around plugins/gaia/scripts/verdict-resolver.sh that exposes the
# parameterized verdict resolver under the review-common/ public-API surface.
# All arguments are forwarded verbatim to the canonical script. Behavior is
# identical to invoking the root script directly.
#
# Public API:
#   review-common/verdict-resolver.sh [--skill <name>] --analysis-results <path> --llm-findings <path>
#   review-common/verdict-resolver.sh --help
#
# Exit codes and stdout/stderr semantics: see ../verdict-resolver.sh.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../verdict-resolver.sh"

if [ ! -x "$TARGET" ]; then
  printf 'review-common/verdict-resolver.sh: target not executable: %s\n' "$TARGET" >&2
  exit 1
fi

exec "$TARGET" "$@"
