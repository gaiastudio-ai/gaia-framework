#!/usr/bin/env bash
# rubric-loader.sh — Layered rubric loader (base + sub-rubrics + regimes + domain + project)
#
# Stories: E68-S2 — Layered rubric loader + rubric-merger.sh + rubric.schema.json
#                   + /gaia-validate-rubric + /gaia-config-validate.
#          E77-S4 — Sub-rubric loader pipeline migration with byte-identical
#                   contract test (FR-406, ADR-088).
# ADR:     ADR-079 (Layered Rubric Loading), ADR-088 (Sub-Rubric Loader Pipeline
#          Migration), ADR-090 (Mobile dual-path coexistence), ADR-042 (Scripts-
#          over-LLM).
#
# Pipeline (per ADR-079 + ADR-088):
#   layer 1:        rubrics/base/<skill>.json          — always loaded
#   layer 2..M:     rubrics/sub-rubrics/*.json         — predicate-filtered via
#                                                       `when:` clause and merged
#                                                       in deterministic sort order
#                                                       (numeric prefix, then
#                                                       LC_ALL=C alpha)
#   layer M+1..N:   rubrics/regimes/<regime>.json      — in declaration order
#   layer N+1:      rubrics/domain/<domain>.json       — optional
#   layer N+2:      rubrics/project/<skill>.json       — optional, project-local
# Each layer is validated against rubric.schema.json BEFORE merging. On
# validation failure the loader halts with a BLOCKED status (NFR-RSV2-4) and
# does NOT proceed.
#
# Sub-rubric `when:` predicate grammar (ADR-088):
#   - Equality:       `when: {project_kind: "claude-code-plugin"}` — top-level
#                     scalar field of project-config equals the value.
#   - Array intersect: `when: {platforms: ["ios"]}` — top-level array field of
#                     project-config has non-empty intersection with the array
#                     value.
#   - AND across keys: a `when:` map with multiple keys requires ALL keys to
#                     match (logical AND).
#   - No OR, no negation, no nesting. Sub-rubric authors needing OR ship two
#                     separate sub-rubric files with single-key `when:` maps.
#   - A sub-rubric with no `when:` (or `when: null`) is INCLUDED unconditionally.
#
# Sub-rubric sort contract (ADR-088):
#   - Files matching `^[0-9]+-` (numeric-prefixed) sort BEFORE non-prefixed files.
#   - Among prefixed files, sort numerically ASC by the integer prefix.
#   - Among non-prefixed files, sort by LC_ALL=C alpha order.
#   - Sub-rubric merge order = sort order (later files override earlier ones via
#                     RFC 7396 JSON-merge-patch).
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
config_path=""
debug_order=0

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
  --config <path>                Project-config YAML used to evaluate sub-rubric
                                 \`when:\` predicates (ADR-088). When omitted,
                                 the loader falls back to resolve-config.sh.
  --debug-order                  Diagnostic: emit one filename per line in
                                 sub-rubric merge order, then exit 0.

Default mode (no --regimes / --domain / --project-rubric flags given):
  Reads compliance.regimes, compliance.domain from project-config.yaml via
  resolve-config.sh and discovers project rubric at <root>/project/<skill>.json
  if present.
EOF
}

# --- Sub-rubric helpers (E77-S4 / ADR-088) --------------------------------

# emit_subrubric_sort_key <filename>
#
# Print a sort key for the sub-rubric basename that yields the ADR-088 order:
#   prefixed files BEFORE non-prefixed files; prefixed files in numeric ASC;
#   non-prefixed files in LC_ALL=C alpha. The key is constructed so that a
#   plain LC_ALL=C sort -k1 gives that order.
emit_subrubric_sort_key() {
  local name="$1"
  local prefix
  if [[ "$name" =~ ^([0-9]+)- ]]; then
    prefix="${BASH_REMATCH[1]}"
    # Zero-pad to 20 digits so lexicographic sort = numeric sort, and use
    # bucket "0" so prefixed files sort before non-prefixed ("1" bucket).
    printf '0:%020d:%s\n' "$prefix" "$name"
  else
    printf '1:%s\n' "$name"
  fi
}

# subrubric_predicate_passes <subrubric_path> <project_config_yaml_or_empty>
#
# Returns 0 if the sub-rubric's `when:` predicate evaluates to true against
# the project-config (and 1 otherwise). A sub-rubric with no `when:` block
# (or `when: null`) is treated as unconditionally included (returns 0). When
# `<project_config_yaml_or_empty>` is empty the predicate evaluator treats
# the project context as the empty object {} — every non-trivial `when:`
# clause then evaluates to false, so project_kind-gated sub-rubrics are
# correctly EXCLUDED in the no-config case (AC9.10).
subrubric_predicate_passes() {
  local subrubric="$1"
  local cfg="$2"

  # Extract `when:` block as JSON. Sub-rubric files are JSON, so jq is enough.
  local when_json
  when_json=$(jq -c '.when // null' "$subrubric" 2>/dev/null) || return 1

  # Missing or null `when:` → unconditional include.
  if [ "$when_json" = "null" ] || [ -z "$when_json" ]; then
    return 0
  fi

  # Build the project context as a JSON object.
  local ctx_json="{}"
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    if command -v yq >/dev/null 2>&1; then
      ctx_json=$(yq -o=json '.' "$cfg" 2>/dev/null || printf '{}')
    elif command -v python3 >/dev/null 2>&1; then
      ctx_json=$(python3 -c '
import sys, json
try:
    import yaml
except ImportError:
    print("{}"); sys.exit(0)
with open(sys.argv[1]) as f:
    print(json.dumps(yaml.safe_load(f) or {}))
' "$cfg" 2>/dev/null || printf '{}')
    fi
  fi
  # Defensive: ensure ctx_json parses as JSON; otherwise treat as empty.
  if ! printf '%s' "$ctx_json" | jq empty >/dev/null 2>&1; then
    ctx_json="{}"
  fi

  # Evaluate the predicate via jq:
  #   for each (k,v) in when:
  #     - if v is array: ctx[k] (as array) intersect v → non-empty
  #     - else (scalar): ctx[k] == v
  #   AND across all keys.
  local verdict
  verdict=$(jq -nc \
    --argjson ctx "$ctx_json" \
    --argjson when "$when_json" '
      def passes(ctx; when):
        (when | to_entries) as $kvs
        | reduce $kvs[] as $kv
            (true;
             . and (
               ($kv.value | type) as $t |
               if $t == "array" then
                 ((ctx[$kv.key] // []) | type) as $cval_t |
                 (if $cval_t == "array" then ctx[$kv.key] else [ctx[$kv.key]] end) as $cval |
                 (any($cval[]; . as $x | $kv.value | index($x) != null))
               else
                 (ctx[$kv.key] == $kv.value)
               end
             ));
      passes($ctx; $when)
    ') || verdict="false"

  [ "$verdict" = "true" ]
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
    --config)             config_path="$2"; shift 2 ;;
    --debug-order)        debug_order=1; shift ;;
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

# --- Phase 2: sub-rubrics (ADR-088 / E77-S4) ------------------------------
# Sub-rubrics live in <rubrics_root>/sub-rubrics/*.json. They are filtered
# by their optional `when:` predicate (equality + array-intersection + AND)
# and merged in deterministic sort order between the base layer and the
# regime layers. The sub-rubrics directory is OPTIONAL — when absent or
# empty the loader is a no-op for this phase, preserving byte-identical
# output for projects that have not adopted any sub-rubric (AC9.9).
sub_rubric_dir="$rubrics_root/sub-rubrics"
selected_subrubrics=()
if [ -d "$sub_rubric_dir" ]; then
  # Discover candidate sub-rubric files matching this skill. The convention
  # is that a sub-rubric file contains a top-level `skill` field equal to
  # the active skill (or no skill field — applies to all skills). We avoid
  # re-validating the schema here; the standard validate-rubric.sh pass
  # below catches malformed files.
  candidates=()
  shopt -s nullglob
  for f in "$sub_rubric_dir"/*.json; do
    [ -f "$f" ] || continue
    file_skill=$(jq -r '.skill // empty' "$f" 2>/dev/null || true)
    if [ -z "$file_skill" ] || [ "$file_skill" = "$skill" ]; then
      candidates+=("$f")
    fi
  done
  shopt -u nullglob

  if [ "${#candidates[@]}" -gt 0 ]; then
    # Sort candidates by ADR-088 contract: numeric prefix bucket "0" before
    # non-prefixed bucket "1"; numeric ASC by prefix; LC_ALL=C alpha within
    # the non-prefixed bucket. The transform pairs each absolute path with
    # its sort key on a tab-delimited line, sorts under LC_ALL=C, then
    # strips the key.
    sort_input=""
    for f in "${candidates[@]}"; do
      base=$(basename "$f")
      key=$(emit_subrubric_sort_key "$base")
      sort_input+="${key}"$'\t'"${f}"$'\n'
    done
    sorted_pairs=$(printf '%s' "$sort_input" | LC_ALL=C sort)

    # Predicate-filter the sorted candidates and keep the surviving paths.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      f=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
      if subrubric_predicate_passes "$f" "$config_path"; then
        selected_subrubrics+=("$f")
      fi
    done <<<"$sorted_pairs"
  fi
fi

# Diagnostic: emit sub-rubric merge order and exit 0 (used by AC6 test).
if [ "$debug_order" -eq 1 ]; then
  for f in ${selected_subrubrics[@]+"${selected_subrubrics[@]}"}; do
    basename "$f"
  done
  exit 0
fi

# Append surviving sub-rubrics to the layer list (between base and regimes).
for f in ${selected_subrubrics[@]+"${selected_subrubrics[@]}"}; do
  layers+=("$f")
done

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
