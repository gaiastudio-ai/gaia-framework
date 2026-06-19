#!/usr/bin/env bash
# project-config-slice.sh — project a per-service config slice for multi-repo layouts.
set -euo pipefail
LC_ALL=C
export LC_ALL
#
# Purpose
# -------
# In a multi-repo / per-service layout, each service is its own git repository
# (a `backend` repo, `frontend` repo, ...) and the shared `.gaia/` project
# config lives OUTSIDE/ABOVE them at a non-git project root. A service repo's CI
# clones ONLY that service repo, so the config (which sits above the clone) is
# invisible to it — the workflow config-resolution chain
# (checkout-root -> CLAUDE_PROJECT_ROOT -> upward-walk) finds nothing, and
# selective tests / per-component deploy / version-bump all fall back to
# "do everything". (Generalizes the single-clone config-above-subtree case.)
#
# This script emits the MINIMAL self-contained config SLICE a single service
# repo needs, so it can be checked into that repo's `.gaia/config/` and carried
# into its CI. The slice contains only the information that service needs — not
# the whole multi-service config.
#
# What the slice contains
# -----------------------
#   - the service's own `stacks[]` entries (selected by `repository` match, or
#     by stack `name` when --service names a stack), PLUS the transitive
#     `cross_refs` closure (stacks reachable via cross_refs from the selected
#     set) so within-service transitive narrowing still works and cross-repo
#     dependencies are at least declared;
#   - `ci_cd.promotion_chain` verbatim — so the staging->main promotion-push
#     full-suite rail still fires in the service repo;
#   - `release` (version_files) verbatim — so version-bump still resolves;
#   - `environments` verbatim — deploy ordering / health gates need the full
#     environment definitions;
#   - `platforms` and `project_name` verbatim (schema-required / identifying).
#
# Idempotent: deterministic output for identical inputs (re-runnable when the
# central config changes — overwrite the slice).
#
# Usage
# -----
#   project-config-slice.sh --config <central.yaml> --service <owner/repo|stack-name> [--out <file>]
#
#   --config   Path to the central multi-service project-config.yaml. Required.
#   --service  Either a `owner/repo` value matched against stacks[].repository,
#              or a stack `name`. Required.
#   --out      Write the slice here (default: stdout).
#   --help     Print usage and exit 0.
#
# Exit codes: 0 ok | 1 usage/IO error | 2 no stack matches the service.

usage() {
  cat <<'EOF'
project-config-slice.sh — emit a minimal per-service config slice (multi-repo layouts)

  --config <path>    central multi-service project-config.yaml (required)
  --service <id>     owner/repo (matched vs stacks[].repository) OR a stack name (required)
  --out <path>       output file (default: stdout)
  --help             show this help

The slice carries the service's own stacks[] entries + their transitive
cross_refs closure, plus ci_cd.promotion_chain, release, environments,
platforms, and project_name — a self-contained config the service repo's CI
can resolve at its own checkout root.
EOF
}

CONFIG=""
SERVICE=""
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)  CONFIG="${2:-}"; shift 2 ;;
    --config=*) CONFIG="${1#--config=}"; shift ;;
    --service) SERVICE="${2:-}"; shift 2 ;;
    --service=*) SERVICE="${1#--service=}"; shift ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --out=*)   OUT="${1#--out=}"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'project-config-slice.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$CONFIG" ] || [ -z "$SERVICE" ]; then
  printf 'project-config-slice.sh: --config and --service are both required\n' >&2
  usage >&2
  exit 1
fi
if [ ! -f "$CONFIG" ]; then
  printf 'project-config-slice.sh: config not found: %s\n' "$CONFIG" >&2
  exit 1
fi
command -v yq >/dev/null 2>&1 || { printf 'project-config-slice.sh: yq is required\n' >&2; exit 1; }

# --- Resolve the seed stack set ------------------------------------------------
# A stack is a seed when its `repository` equals SERVICE, OR (fallback) its
# `name` equals SERVICE. Repository match takes precedence; name match lets a
# caller slice by stack name when repositories aren't declared yet.
seed_names="$(SERVICE="$SERVICE" yq -r '
  [.stacks[]? | select((.repository // "") == strenv(SERVICE)) | .name] | .[]
' "$CONFIG" 2>/dev/null || true)"

if [ -z "$seed_names" ]; then
  seed_names="$(SERVICE="$SERVICE" yq -r '
    [.stacks[]? | select(.name == strenv(SERVICE)) | .name] | .[]
  ' "$CONFIG" 2>/dev/null || true)"
fi

if [ -z "$seed_names" ]; then
  printf 'project-config-slice.sh: no stack matches service %q (by repository or name)\n' "$SERVICE" >&2
  exit 2
fi

# --- Transitive cross_refs closure --------------------------------------------
# Start from the seed names; repeatedly add any stack named by a selected
# stack's cross_refs, until the set stops growing. Pure-shell BFS over the
# adjacency that yq exposes as "name<TAB>ref" edges.
edges="$(yq -r '
  .stacks[] | .name as $src | (.cross_refs // [])[] | $src + "\t" + .
' "$CONFIG" 2>/dev/null || true)"

# selected = newline-delimited set; start with seeds (sorted-unique)
selected="$(printf '%s\n' "$seed_names" | sort -u)"
while : ; do
  before="$selected"
  # For every edge whose source is selected, add the target.
  additions=""
  while IFS=$'\t' read -r src dst; do
    [ -z "$src" ] && continue
    if printf '%s\n' "$selected" | grep -qxF "$src"; then
      additions="${additions}${dst}"$'\n'
    fi
  done <<EOF
$edges
EOF
  selected="$(printf '%s\n%s\n' "$selected" "$additions" | grep -v '^$' | sort -u)"
  [ "$selected" = "$before" ] && break
done

# Build a JSON array literal of the selected names for the filter below,
# e.g. ["backend","shared-lib"]. Assembled directly (robust, no yq tsv quirks).
names_json="$(printf '%s\n' "$selected" | grep -v '^$' \
  | sed 's/"/\\"/g; s/.*/"&"/' | paste -sd, - | sed 's/^/[/; s/$/]/')"

# --- Emit the slice -----------------------------------------------------------
# Keep only the selected stacks (preserving their original relative order);
# carry ci_cd / release / environments / platforms / project_name verbatim.
# `with_entries(select(.value != null))` drops keys that are absent in the
# central config so the slice stays minimal and schema-clean. mikefarah yq
# (YAML-native) idioms throughout.
SLICE="$(NAMES="$names_json" yq '
  {
    "project_name": .project_name,
    "platforms": .platforms,
    "stacks": [ .stacks[] | select(.name as $n | (strenv(NAMES) | from_json) | contains([$n])) ],
    "ci_cd": .ci_cd,
    "release": .release,
    "environments": .environments
  } | with_entries(select(.value != null))
' "$CONFIG")"

HEADER="# Generated per-service config slice — DO NOT EDIT BY HAND.
# Source: central project-config.yaml, service: ${SERVICE}
# Regenerate with: /gaia-config-ci --project-slice ${SERVICE}
# (project-config-slice.sh). Carries only this service's stacks + transitive
# cross_refs closure + promotion_chain/release/environments/platforms."

if [ -n "$OUT" ]; then
  mkdir -p -- "$(dirname -- "$OUT")"
  { printf '%s\n' "$HEADER"; printf '%s\n' "$SLICE"; } > "$OUT"
  printf 'project-config-slice.sh: wrote slice for %s -> %s\n' "$SERVICE" "$OUT" >&2
else
  printf '%s\n' "$HEADER"
  printf '%s\n' "$SLICE"
fi
