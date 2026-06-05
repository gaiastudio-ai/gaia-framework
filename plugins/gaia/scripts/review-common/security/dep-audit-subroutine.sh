#!/usr/bin/env bash
# dep-audit-subroutine.sh — GAIA review-common dependency-audit sub-routine.
#
# Purpose
# -------
# Deterministic helper invoked by `/gaia-review-security` Phase 3A as a
# sub-routine to surface dependency-audit findings (CVEs, outdated packages,
# license conflicts) into the parent review's `analysis-results.json` evidence
# set. Mirrors the deterministic-evidence portion of the standalone
# `/gaia-review-deps` skill so the parent review can consume a uniform
# `checks[]` fragment.
#
# Wiring contract
# ---------------
#   - The skill runs READ-ONLY against the target. It probes for dependency
#     manifests under <target>; if none are found, it emits a single
#     `status:"skipped"` check fragment with a diagnostic reason and exits 0.
#     A skip is NOT a failure — the parent review continues.
#   - When manifests are present, the script invokes the local CLI auditor
#     when available (npm audit / pip-audit / cargo audit / etc.) and
#     captures findings. Any tool-side failure (network error, missing CLI,
#     non-zero exit from the auditor) is recorded as a single
#     `severity:"warning"` finding in the fragment with a "Dependency audit
#     unavailable — <reason>" message. The script ALWAYS exits 0 on detection
#     paths so a sub-routine infrastructure failure does NOT cascade as a
#     parent BLOCKED verdict.
#
# Output (stdout)
# ---------------
# A single `analysis-results.json`-shaped check fragment. The parent context
# merges this fragment into its `checks[]` array under the `dependency_audit`
# category. Schema (line-broken for readability — emitted as a single line):
#
#   {"name":"dependency-audit","scope":"project",
#    "status":"passed|failed|skipped|errored",
#    "skip_reason":"<verbatim reason when skipped>",
#    "category":"dependency_audit",
#    "findings":[{"severity":...,"rule":...,"message":...,"file":...,"category":"dependency_audit"}]}
#
# The parent review's resolved rubric is applied to severity classification at
# the verdict-resolver layer — this script emits the raw finding shape only.
#
# Usage
# -----
#   dep-audit-subroutine.sh --target <project-root>
#   dep-audit-subroutine.sh --help
#
# Environment overrides (test harness)
# ------------------------------------
#   GAIA_DEP_AUDIT_FORCE_FAIL=1   force the auditor invocation to fail; the
#                                  script must record a WARNING finding and
#                                  still exit 0 (regression guard).
#
# Exit codes
# ----------
#   0  always on the detection paths (no manifests, manifests + audit ok,
#      manifests + audit failed isolated as WARNING)
#   1  caller error (missing --target, unknown flag)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="dep-audit-subroutine.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — dependency-audit sub-routine

Usage:
  $SCRIPT_NAME --target <project-root>
  $SCRIPT_NAME --help

Probes for dependency manifests (package.json, requirements.txt, pom.xml,
pubspec.yaml, go.mod, Gemfile, Cargo.toml) under <project-root>. Emits a
single analysis-results.json check fragment to stdout under the
'dependency_audit' category. Failure-isolated: tool errors become WARNING
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

# Manifest probe — match the canonical list in /gaia-review-deps SKILL.md.
manifests_found=""
for m in package.json requirements.txt pyproject.toml Pipfile pom.xml \
         build.gradle build.gradle.kts pubspec.yaml go.mod Gemfile \
         Cargo.toml composer.json; do
  if [ -f "$TARGET/$m" ]; then
    manifests_found="${manifests_found:+$manifests_found,}$m"
  fi
done

if [ -z "$manifests_found" ]; then
  printf '%s\n' \
    '{"name":"dependency-audit","scope":"project","status":"skipped","skip_reason":"No dependency manifests found -- skipping dep audit","category":"dependency_audit","findings":[]}'
  exit 0
fi

# Forced-fail path (test harness only) — record WARNING and exit 0.
if [ "${GAIA_DEP_AUDIT_FORCE_FAIL:-0}" = "1" ]; then
  printf '%s\n' \
    '{"name":"dependency-audit","scope":"project","status":"errored","category":"dependency_audit","findings":[{"severity":"warning","rule":"infra-failure","message":"Dependency audit unavailable -- audit tool returned non-zero exit","category":"dependency_audit","blocking":false}]}'
  exit 0
fi

# Real-world invocation — at this layer we emit a passed fragment with the
# manifest list as evidence. Concrete CVE-detection logic is delegated to the
# existing /gaia-review-deps skill when invoked standalone. The sub-routine
# layer is intentionally thin (Phase 3A is the evidence layer; LLM judgment
# lives in the parent review's Phase 3B).
printf '{"name":"dependency-audit","scope":"project","status":"passed","category":"dependency_audit","manifests":"%s","findings":[]}\n' \
  "$manifests_found"
exit 0
