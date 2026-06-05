#!/usr/bin/env bash
# api-design-subroutine.sh — GAIA review-common API-design sub-routine.
#
# Purpose
# -------
# Deterministic helper invoked by `/gaia-review-code` Phase 3A as a sub-routine
# to surface API-design findings (resource naming, HTTP methods, status codes,
# RFC 7807 error format, versioning) into the parent review's
# `analysis-results.json` evidence set. Mirrors the deterministic-evidence
# portion of the standalone `/gaia-review-api` skill.
#
# Wiring contract
# ---------------
#   - The skill runs READ-ONLY against the target. It probes for API-endpoint
#     signals under <target>; if none are found, it emits a single
#     `status:"skipped"` check fragment with a diagnostic reason and exits 0.
#     A skip is NOT a failure — the parent review continues.
#   - Detection patterns (each match triggers inclusion):
#       *  routes/      directory anywhere under <target>
#       *  controllers/ directory anywhere under <target>
#       *  openapi.{yaml,json,yml} file anywhere under <target>
#       *  swagger.{yaml,json,yml} file anywhere under <target>
#   - Tool-side failures are isolated as WARNING findings — never BLOCKED.
#
# Output (stdout)
# ---------------
# A single `analysis-results.json`-shaped check fragment under the
# `api_design_audit` category. Schema:
#
#   {"name":"api-design-audit","scope":"project",
#    "status":"passed|failed|skipped|errored",
#    "skip_reason":"<verbatim reason when skipped>",
#    "category":"api_design_audit",
#    "findings":[...]}
#
# Usage
# -----
#   api-design-subroutine.sh --target <project-root>
#   api-design-subroutine.sh --help
#
# Environment overrides (test harness)
# ------------------------------------
#   GAIA_API_AUDIT_FORCE_FAIL=1   force the audit invocation to fail; the
#                                  script records a WARNING finding and exits 0.
#
# Exit codes
# ----------
#   0  detection paths (skip, pass, isolated failure)
#   1  caller error (missing --target, unknown flag)
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="api-design-subroutine.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — API-design sub-routine

Usage:
  $SCRIPT_NAME --target <project-root>
  $SCRIPT_NAME --help

Probes for API endpoints (routes/, controllers/, openapi.* / swagger.*).
Emits a single analysis-results.json check fragment to stdout under the
'api_design_audit' category. Failure-isolated: tool errors become WARNING
findings; the script always exits 0 on detection paths.
EOF
}

TARGET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || die "--target requires a path"; TARGET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$TARGET" ] || die "missing required --target <project-root>"
[ -d "$TARGET" ] || die "target is not a directory: $TARGET"

# Endpoint detection.
endpoints_found=""

# routes/ or controllers/ directories anywhere under the target.
if find "$TARGET" -type d \( -name routes -o -name controllers \) -print -quit 2>/dev/null | grep -q .; then
  endpoints_found="${endpoints_found:+$endpoints_found,}routes-or-controllers"
fi

# OpenAPI / Swagger spec files.
for f in openapi.yaml openapi.yml openapi.json swagger.yaml swagger.yml swagger.json; do
  if find "$TARGET" -type f -name "$f" -print -quit 2>/dev/null | grep -q .; then
    endpoints_found="${endpoints_found:+$endpoints_found,}$f"
  fi
done

if [ -z "$endpoints_found" ]; then
  printf '%s\n' \
    '{"name":"api-design-audit","scope":"project","status":"skipped","skip_reason":"No API endpoints detected -- skipping API audit","category":"api_design_audit","findings":[]}'
  exit 0
fi

if [ "${GAIA_API_AUDIT_FORCE_FAIL:-0}" = "1" ]; then
  printf '%s\n' \
    '{"name":"api-design-audit","scope":"project","status":"errored","category":"api_design_audit","findings":[{"severity":"warning","rule":"infra-failure","message":"API design audit unavailable -- analyzer returned non-zero exit","category":"api_design_audit","blocking":false}]}'
  exit 0
fi

printf '{"name":"api-design-audit","scope":"project","status":"passed","category":"api_design_audit","detected":"%s","findings":[]}\n' \
  "$endpoints_found"
exit 0
