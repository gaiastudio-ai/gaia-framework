#!/usr/bin/env bash
# check-stale-flag-registry.sh — E86-S6 / FR-475 / SR-59 / ADR-102 static check.
#
# Scans `_memory/.*-stale` markers and verifies every marker on disk is
# registered in the ADR-102 registry table in the architecture document.
# Unregistered markers are CRITICAL findings — they represent a governance
# audit gap that must be resolved before deployment (SR-59).
#
# Per ADR-102 marker contract clause 3, markers MUST live at the `_memory/`
# top level (`-maxdepth 1` scope) — this keeps `ls -a _memory/` discoverable
# and avoids ambiguity with checkpoint / sidecar dotfiles under nested
# subdirectories. Widening the scope would silently include unrelated state.
#
# Exit codes:
#   0 — every found marker is registered (or no markers exist)
#   1 — at least one CRITICAL finding (unregistered marker, missing registry)
#
# Output: one CRITICAL line per finding to stdout, no output on clean run.
#
# Environment:
#   CLAUDE_PROJECT_ROOT  — project root (resolves _memory/ and registry path)
#   GAIA_MEMORY_PATH     — override for the `_memory/` directory (fixtures)
#   GAIA_REGISTRY_PATH   — override for the ADR-102 registry document
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

# ---- Resolve memory dir ----
memory_dir="${GAIA_MEMORY_PATH:-${CLAUDE_PROJECT_ROOT:-.}/_memory}"

# ---- Resolve registry path ----
if [ -n "${GAIA_REGISTRY_PATH:-}" ]; then
  registry_path="$GAIA_REGISTRY_PATH"
else
  # E96-S7 partial-4b: smart-fallback — prefer .gaia/artifacts/planning-artifacts/
  # over legacy docs/planning-artifacts/ for the architecture detail-records shard.
  _proj="${CLAUDE_PROJECT_ROOT:-.}"
  if [ -d "$_proj/.gaia/artifacts/planning-artifacts" ]; then
    registry_path="$_proj/.gaia/artifacts/planning-artifacts/architecture/12-12-adr-detail-records.md"
  else
    registry_path="$_proj/docs/planning-artifacts/architecture/12-12-adr-detail-records.md"
  fi
  unset _proj
fi

exit_code=0

# ---- Scan _memory/ for stale markers — -maxdepth 1 per ADR-102 clause 3 ----
if [ ! -d "$memory_dir" ]; then
  # No _memory/ → no markers to audit. Clean exit.
  exit 0
fi

# Collect found markers as basenames (e.g. ".config-stale"). Bash 3.2: no mapfile.
found_markers=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  found_markers="$found_markers $(basename "$f")"
done <<EOF
$(find "$memory_dir" -maxdepth 1 -type f -name '.*-stale' 2>/dev/null)
EOF

# Trim leading space.
found_markers="${found_markers# }"

# No markers? Clean exit.
if [ -z "$found_markers" ]; then
  exit 0
fi

# ---- Registry must exist when markers are present ----
if [ ! -f "$registry_path" ]; then
  printf 'CRITICAL: ADR-102 registry not found at %s. Cannot audit %d marker(s).\n' \
    "$registry_path" "$(printf '%s\n' $found_markers | wc -l | tr -d ' ')" >&2
  printf 'CRITICAL: ADR-102 registry missing — cannot audit stale-flag markers.\n'
  exit 1
fi

# ---- Parse registry: extract marker basenames from rows like ----
#   | `_memory/.{name}-stale` | ... | ... | ... |
registered=$(grep -oE '`_memory/\.[A-Za-z0-9_-]+-stale`' "$registry_path" \
             | sed 's:^`_memory/::; s:`$::')

# ---- Audit found vs registered ----
for marker in $found_markers; do
  if ! printf '%s\n' "$registered" | grep -qxF "$marker"; then
    printf 'CRITICAL: Unregistered stale-flag marker: _memory/%s. Register in ADR-102 or remove.\n' \
      "$marker"
    exit_code=1
  fi
done

exit "$exit_code"
