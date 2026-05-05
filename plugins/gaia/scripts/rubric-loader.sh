#!/usr/bin/env bash
# rubric-loader.sh — Layered rubric loader (base + regimes + domain + project)
#
# Story: E68-S2 — Layered rubric loader + rubric-merger.sh + rubric.schema.json
#                 + /gaia-validate-rubric + /gaia-config-validate
# ADR:   ADR-079 (Layered Rubric Loading), ADR-042 (Scripts-over-LLM).
#
# Pipeline (per ADR-079):
#   layer 1: rubrics/base/<skill>.json                 — always loaded
#   layer 2..N: rubrics/regimes/<regime>.json          — in declaration order
#   layer N+1: rubrics/domain/<domain>.json            — optional
#   layer N+2: rubrics/project/<skill>.json            — optional, project-local
# Each layer is validated against rubric.schema.json BEFORE merging. On
# validation failure the loader halts with a BLOCKED status (NFR-RSV2-4) and
# does NOT proceed.
#
# Usage (when driven by project-config.yaml — typical use):
#   rubric-loader.sh --skill <skill>
#       Reads compliance.regimes and compliance.domain via resolve-config.sh,
#       discovers rubrics under the framework rubrics/ root, emits merged JSON
#       on stdout.
#
# Usage (explicit — used by tests and offline merges):
#   rubric-loader.sh --skill <skill> --rubrics-root <dir>
#       --regimes "<r1,r2,...>" [--domain <name>|--no-domain]
#       [--project-rubric <path>|--no-project|--no-project-discover]
#
# Exit codes:
#   0  success — merged JSON on stdout
#   1  generic / argument error
#   2  required input file not found (base or named regime)
#   3  schema validation failure (BLOCKED) — actionable error on stderr
#   4  merger / engine failure
# =============================================================================

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="rubric-loader.sh"
err()  { printf '%s: %s\n' "$prog" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MERGER="$SCRIPT_DIR/rubric-merger.sh"
VALIDATOR="$SCRIPT_DIR/validate-rubric.sh"
SCHEMA_DEFAULT="$PLUGIN_DIR/schemas/rubric.schema.json"

skill=""
rubrics_root=""
regimes_csv=""
domain=""
no_domain=0
project_rubric=""
no_project=0
no_project_discover=0
auto_discover_root=1

usage() {
  cat <<EOF
$prog — layered rubric loader (E68-S2)

Required:
  --skill <name>                 Review skill (code|qa|test|security|perf|a11y|...)

Optional explicit mode:
  --rubrics-root <dir>           Root of rubrics tree (defaults to plugin rubrics/)
  --regimes "<r1,r2,...>"        Regime list (comma- or space-separated, in
                                 declaration order). Empty string = no regimes.
  --domain <name>                Domain rubric name (loads <root>/domain/<name>.json)
  --no-domain                    Skip the optional domain layer
  --project-rubric <path>        Explicit path to a project rubric layer
  --no-project-discover          Suppress auto-discovery of project rubric;
                                 use only --project-rubric (if given) or none.
  --no-project                   Skip the project layer entirely
  --schema <path>                Override rubric.schema.json (for tests)

Default mode (no --regimes / --domain / --project-rubric flags given):
  Reads compliance.regimes, compliance.domain from project-config.yaml via
  resolve-config.sh and discovers project rubric at <root>/project/<skill>.json
  if present.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skill)              skill="$2"; shift 2 ;;
    --rubrics-root)       rubrics_root="$2"; shift 2 ;;
    --regimes)            regimes_csv="$2"; auto_discover_root=0; shift 2 ;;
    --domain)             domain="$2"; shift 2 ;;
    --no-domain)          no_domain=1; shift ;;
    --project-rubric)     project_rubric="$2"; shift 2 ;;
    --no-project)         no_project=1; shift ;;
    --no-project-discover) no_project_discover=1; shift ;;
    --schema)             SCHEMA_DEFAULT="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 1 ;;
  esac
done

if [ -z "$skill" ]; then
  err "missing --skill argument"
  usage >&2
  exit 1
fi

# Resolve rubrics root: explicit flag > GAIA_RUBRICS_ROOT env > plugin rubrics/.
if [ -z "$rubrics_root" ]; then
  rubrics_root="${GAIA_RUBRICS_ROOT:-$PLUGIN_DIR/rubrics}"
fi

# When called without --regimes, ask resolve-config.sh for compliance.regimes
# and compliance.domain. The resolver lives one level up.
if [ "$auto_discover_root" -eq 1 ] && [ -z "$regimes_csv" ]; then
  resolve_cfg="$SCRIPT_DIR/resolve-config.sh"
  if [ -x "$resolve_cfg" ]; then
    regimes_csv=$("$resolve_cfg" --field compliance.regimes 2>/dev/null || true)
    if [ -z "$domain" ] && [ "$no_domain" -eq 0 ]; then
      domain=$("$resolve_cfg" --field compliance.domain 2>/dev/null || true)
    fi
  fi
fi

# Normalise the regimes CSV: split on comma OR whitespace, trim entries,
# drop empties. Result lives in the `regimes[]` array.
regimes=()
if [ -n "$regimes_csv" ]; then
  # Replace commas with spaces, then split on whitespace.
  IFS=' ,' read -r -a _split <<<"$regimes_csv"
  for r in "${_split[@]}"; do
    [ -z "$r" ] && continue
    regimes+=("$r")
  done
fi

# --- Assemble ordered layer list ------------------------------------------
layers=()

base_path="$rubrics_root/base/${skill}.json"
if [ ! -f "$base_path" ]; then
  err "BLOCKED: base rubric not found at $base_path"
  exit 2
fi
layers+=("$base_path")

for r in ${regimes[@]+"${regimes[@]}"}; do
  rp="$rubrics_root/regimes/${r}.json"
  if [ ! -f "$rp" ]; then
    err "BLOCKED: regime rubric not found at $rp (regime '$r')"
    exit 2
  fi
  layers+=("$rp")
done

if [ -n "$domain" ] && [ "$no_domain" -eq 0 ]; then
  dp="$rubrics_root/domain/${domain}.json"
  if [ ! -f "$dp" ]; then
    err "BLOCKED: domain rubric not found at $dp (domain '$domain')"
    exit 2
  fi
  layers+=("$dp")
fi

if [ "$no_project" -eq 0 ]; then
  if [ -n "$project_rubric" ]; then
    if [ ! -f "$project_rubric" ]; then
      err "BLOCKED: project rubric not found at $project_rubric"
      exit 2
    fi
    layers+=("$project_rubric")
  elif [ "$no_project_discover" -eq 0 ]; then
    pp="$rubrics_root/project/${skill}.json"
    if [ -f "$pp" ]; then
      layers+=("$pp")
    fi
  fi
fi

# --- Schema-validate every layer before merging (NFR-RSV2-4) ---------------
for layer in "${layers[@]}"; do
  if ! GAIA_RUBRIC_SCHEMA="$SCHEMA_DEFAULT" "$VALIDATOR" "$layer" >/dev/null 2>"$rubrics_root/.last-validate-err.$$" ; then
    err "BLOCKED: rubric schema validation failed for $layer"
    cat "$rubrics_root/.last-validate-err.$$" >&2 || true
    rm -f "$rubrics_root/.last-validate-err.$$"
    exit 3
  fi
  rm -f "$rubrics_root/.last-validate-err.$$"
done

# --- Merge ---------------------------------------------------------------
# Special-case base-only: byte-identical output equals base when no other
# layers are present (AC9). The merger normalises via --sort-keys so the
# byte-identical guarantee is delivered against the sort-keys form.
if ! "$MERGER" "${layers[@]}"; then
  err "BLOCKED: merger failed"
  exit 4
fi
