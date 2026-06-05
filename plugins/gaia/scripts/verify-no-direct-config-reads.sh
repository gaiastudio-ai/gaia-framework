#!/usr/bin/env bash
# verify-no-direct-config-reads.sh — CI guard for direct config-file references
#
# Scans SKILL.md files for direct references to `global.yaml` or
# `project-config.yaml` and exits non-zero when any non-comment, non-allowlisted
# reference is found. Wire into CI to keep the invariant that all skill-level
# config reads flow through `scripts/resolve-config.sh`.
#
# Exclusions (comments / docstrings / metadata):
#   - Lines inside HTML comments (`<!-- ... -->`).
#   - Lines inside Markdown block-quotes where the reference is explanatory.
#
# Allowlist (config-editor / meta-validator skills that MUST reference the
# files directly because they act ON them rather than READ from them):
#   - gaia-bridge-toggle, gaia-bridge-enable, gaia-bridge-disable
#         — toggle test_execution_bridge.bridge_enabled in-place.
#   - gaia-ci-setup, gaia-ci-edit
#         — CRUD on ci_cd.promotion_chain in-place.
#   - gaia-validate-framework
#         — meta-validator; its purpose is to parse global.yaml end-to-end.
#
# These skills are architecturally unable to route through resolve-config.sh
# because resolve-config.sh is read-only and returns flattened key-value
# output, while the editors need to modify YAML in place preserving comments
# and formatting. Allowlisting them is the pragmatic choice.
#
# Exit codes:
#   0 — clean (no direct reads outside the allowlist)
#   1 — violation detected; offending lines printed to stderr
#   2 — invalid argument (target dir missing)
#
# Usage:
#   verify-no-direct-config-reads.sh [SKILLS_DIR]

set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    TARGET="${CLAUDE_PLUGIN_ROOT}/skills"
  else
    TARGET="$(cd "$(dirname "$0")/.." && pwd)/skills"
  fi
fi

if [ ! -d "$TARGET" ]; then
  printf 'verify-no-direct-config-reads: target directory not found: %s\n' "$TARGET" >&2
  exit 2
fi

# Allowlisted skill directory basenames — these skills are permitted to
# reference global.yaml / project-config.yaml directly because they edit
# or validate those files as their core responsibility.
ALLOWLIST="gaia-bridge-toggle gaia-bridge-enable gaia-bridge-disable gaia-ci-setup gaia-ci-edit gaia-validate-framework"

is_allowlisted() {
  local skill_dir="$1" entry
  for entry in $ALLOWLIST; do
    [ "$skill_dir" = "$entry" ] && return 0
  done
  return 1
}

violations=0
violation_lines=""

# Use find with -print0 and a while-read loop to tolerate spaces / unusual
# paths. Resolve each SKILL.md relative to TARGET for compact output.
while IFS= read -r -d '' file; do
  # Extract the skill's immediate parent directory name (e.g. gaia-sprint-plan).
  skill_dir="$(basename "$(dirname "$file")")"

  if is_allowlisted "$skill_dir"; then
    continue
  fi

  # Strip HTML comments before grepping so in-comment references do not
  # count as violations. The sed pattern handles single-line HTML comments.
  # Multi-line comments are rare in SKILL.md and left to a stricter future
  # pass — the single-line form is the documented convention.
  stripped="$(sed -E 's#<!--[^>]*-->##g' "$file")"

  # Grep the stripped content line-by-line. Matches are recorded with the
  # original line number via awk + the stripped body.
  line_no=0
  while IFS= read -r content_line; do
    line_no=$((line_no + 1))
    case "$content_line" in
      *global.yaml*|*project-config.yaml*)
        violations=$((violations + 1))
        violation_lines="${violation_lines}${file}:${line_no}:${content_line}
"
        ;;
    esac
  done <<EOF
$stripped
EOF

done < <(find "$TARGET" -type f -name 'SKILL.md' -print0)

if [ "$violations" -gt 0 ]; then
  {
    printf 'verify-no-direct-config-reads: FAIL (%d violation(s))\n' "$violations"
    printf '%s\n' 'Skills must route config reads through scripts/resolve-config.sh.'
    printf '%s\n' 'If a skill legitimately edits or validates the file directly, add it to the allowlist in'
    printf '%s\n' 'scripts/verify-no-direct-config-reads.sh with a rationale comment.'
    printf '\nViolations:\n%s' "$violation_lines"
  } >&2
  exit 1
fi

printf 'verify-no-direct-config-reads: OK (no direct config reads outside allowlist)\n'
exit 0
