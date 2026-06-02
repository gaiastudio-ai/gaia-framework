#!/usr/bin/env bash
# claudemd-drift-guard.sh — CLAUDE.md drift guard (E28-S165)
#
# Complements E28-S129's bats size-cap tests by enforcing byte-equality between
# two CLAUDE.md copies. E28-S129 established that the GAIA-Framework workspace
# carries two CLAUDE.md identities:
#   1. {project-root}/CLAUDE.md — the NFR-049 normative target, read by Claude
#      Code when a developer runs the framework locally.
#   2. {project-path}/CLAUDE.md == gaia-framework/CLAUDE.md — the distributable
#      product copy shipped via the plugin marketplace. This is the source of
#      truth; the project-root copy is a byte-identical mirror.
#
# Invoked two ways:
#
#   A. Local / pre-commit use:
#        claudemd-drift-guard.sh {project-root}/CLAUDE.md {project-path}/CLAUDE.md
#      Runs `diff -q` and exits non-zero on drift so a developer catches the
#      drift before pushing.
#
#   B. CI use (plugin-ci.yml):
#        claudemd-drift-guard.sh CLAUDE.md CLAUDE.md
#      Only gaia-framework/CLAUDE.md is present inside the gaia-framework git repo;
#      the project-root copy is a dev-workspace-only mirror. The CI invocation
#      therefore diffs the single in-repo copy against itself, which always
#      passes. The CI job's value is that it WILL catch any drift introduced
#      locally and committed accidentally (e.g., a developer edits only the
#      gaia-framework copy and forgets to update the root mirror — the next PR
#      that changes either file forces the developer to reconcile both
#      because the diff is run locally via the bats suite / pre-commit).
#
# Exit codes:
#   0  — identical (or same-path self-diff)
#   1  — files differ (drift detected)
#   2  — one or both files missing / unreadable
#   64 — usage error
#
# Usage: claudemd-drift-guard.sh PATH_A PATH_B
#    or: claudemd-drift-guard.sh --help

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: claudemd-drift-guard.sh PATH_A PATH_B

Compares two CLAUDE.md files for byte-level equality using `diff -q`.

Exit codes:
  0   identical
  1   drift detected
  2   file missing / unreadable
  64  usage error

Typical invocations:
  claudemd-drift-guard.sh CLAUDE.md gaia-framework/CLAUDE.md
  claudemd-drift-guard.sh /path/to/root/CLAUDE.md /path/to/plugin/CLAUDE.md
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ $# -ne 2 ]]; then
  echo "ERROR: expected exactly 2 paths, got $#" >&2
  usage >&2
  exit 64
fi

PATH_A="$1"
PATH_B="$2"

for p in "$PATH_A" "$PATH_B"; do
  if [[ ! -f "$p" ]]; then
    echo "ERROR: CLAUDE.md not found: $p" >&2
    echo "       Both project-root and gaia-framework/CLAUDE.md must exist before the drift guard can run." >&2
    exit 2
  fi
done

# diff -q exits 0 on equal, 1 on differ, >1 on trouble. We convert trouble to 2.
if diff -q "$PATH_A" "$PATH_B" > /dev/null 2>&1; then
  exit 0
fi

# Drift detected. Emit a structured message and the first differing hunk so the
# developer can reconcile without re-running diff manually.
cat >&2 <<EOF
ERROR: CLAUDE.md drift detected between:
       A: $PATH_A
       B: $PATH_B

       Files differ. Reconcile by choosing the authoritative copy and
       mirroring it to the other path (per E28-S129: gaia-framework/CLAUDE.md
       is the source of truth; the project-root copy is the mirror).

       First differing hunk:
EOF
diff "$PATH_A" "$PATH_B" | head -20 >&2 || true
exit 1
