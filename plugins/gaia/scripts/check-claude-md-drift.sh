#!/usr/bin/env bash
# check-claude-md-drift.sh — guard the shipped CLAUDE.md template against
# silent drift from the repo-root CLAUDE.md it mirrors.
#
# Why this exists:
#   plugins/gaia/templates/CLAUDE.md is the file install-claude-md.sh copies
#   into every project created by /gaia-init and /gaia-brownfield. It is a
#   near-copy of the repo-root CLAUDE.md, maintained by hand. Twice, an edit
#   landed in the root file and never reached the template, so newly-created
#   projects shipped with guidance missing (a whole documented subsystem, and
#   a Hard Rule). Nothing failed: the install tests only exercise the
#   seed / append / no-op plumbing and pin no body content.
#
# What it checks:
#   Every H2 section heading and every top-level Hard Rules bullet present in
#   the root CLAUDE.md must also be present in the template. That is the
#   failure mode this guards — someone documents a subsystem or adds a rule in
#   the root file and forgets the copy that users actually receive.
#
#   It is deliberately NOT a byte-equality check. The two files carry one
#   sanctioned divergence: the root file describes the project root
#   self-referentially (naming this repo), while the template must stay
#   generic because it ships into an arbitrary user project. A stricter guard
#   would force that wording to be wrong in one file or the other.
#
# Direction is one-way (root -> template): the template may hold content the
# root file does not, but never the reverse.
#
# Usage:
#   check-claude-md-drift.sh [--root <repo-root>]
#   check-claude-md-drift.sh --help
#
# Exit codes:
#   0  no drift
#   1  drift detected (missing section or Hard Rule in the template)
#   2  usage error / an input file is missing

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="check-claude-md-drift.sh"

# <repo-root>/plugins/gaia/scripts/check-claude-md-drift.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: check-claude-md-drift.sh [--root <repo-root>]

Verify the shipped CLAUDE.md template still carries every H2 section and every
Hard Rules bullet present in the repo-root CLAUDE.md.

The template is what /gaia-init and /gaia-brownfield copy into a user's
project, so anything missing from it is missing from every new project.

Exit codes:
  0  no drift
  1  drift detected
  2  usage error / missing input file
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { printf '%s: --root requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      repo_root="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf '%s: unexpected argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
done

ROOT_MD="${repo_root}/CLAUDE.md"
TEMPLATE_MD="${repo_root}/plugins/gaia/templates/CLAUDE.md"

for f in "${ROOT_MD}" "${TEMPLATE_MD}"; do
  [ -f "$f" ] || { printf '%s: missing input file: %s\n' "$SCRIPT_NAME" "$f" >&2; exit 2; }
done

# Emit the H2 headings of a file, one per line.
sections() { grep -E '^## ' "$1" || true; }

# Emit the top-level Hard Rules bullets of a file, one per line. The section
# runs from the "## Hard Rules" heading to the next H2 (or EOF). Only
# column-0 "- " bullets count; the indented sub-bullets under a rule are part
# of their parent and are not tracked independently.
hard_rules() {
  awk '
    /^## Hard Rules[[:space:]]*$/ { in_rules = 1; next }
    in_rules && /^## /            { in_rules = 0 }
    in_rules && /^- /             { print }
  ' "$1"
}

drift=0

# A heading/bullet is "present" if it appears verbatim as a full line in the
# template. Compare with fixed-string, whole-line matching so that markdown
# punctuation is never read as a regex. The `--` is load-bearing: every Hard
# Rules bullet begins with "- ", which grep would otherwise parse as options.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if ! grep -qxF -- "$line" "${TEMPLATE_MD}"; then
    if [ "$drift" -eq 0 ]; then
      printf '%s: DRIFT — the shipped template is missing content present in the root CLAUDE.md.\n' "$SCRIPT_NAME" >&2
      printf '%s: every new project created by /gaia-init and /gaia-brownfield would ship without it.\n\n' "$SCRIPT_NAME" >&2
    fi
    drift=1
    printf '  missing section:  %s\n' "$line" >&2
  fi
done < <(sections "${ROOT_MD}")

while IFS= read -r line; do
  [ -n "$line" ] || continue
  if ! grep -qxF -- "$line" "${TEMPLATE_MD}"; then
    if [ "$drift" -eq 0 ]; then
      printf '%s: DRIFT — the shipped template is missing content present in the root CLAUDE.md.\n' "$SCRIPT_NAME" >&2
      printf '%s: every new project created by /gaia-init and /gaia-brownfield would ship without it.\n\n' "$SCRIPT_NAME" >&2
    fi
    drift=1
    # Hard Rules bullets are long; show enough to identify which one.
    printf '  missing hard rule: %.100s...\n' "$line" >&2
  fi
done < <(hard_rules "${ROOT_MD}")

if [ "$drift" -ne 0 ]; then
  printf '\n%s: fix by porting the missing content into %s\n' \
    "$SCRIPT_NAME" "plugins/gaia/templates/CLAUDE.md" >&2
  exit 1
fi

printf '%s: OK — template carries every section and Hard Rule from the root CLAUDE.md\n' "$SCRIPT_NAME"
exit 0
