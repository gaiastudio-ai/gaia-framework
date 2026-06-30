#!/usr/bin/env bash
# scanner-placement.sh — resolve the tiered scanner placement for a tools.<category>.
#
# A category in `tools.<category>` names one blocking PR-gate scanner via
# `provider` (the default single-gate behavior, unchanged) and MAY additionally
# declare one or more non-blocking scheduled deep-scan scanners via `scheduled[]`
# — mirroring the tiered `test_execution.tier_*.placement` model. This helper
# reads that structure and emits, per scanner, its provider name and pipeline
# placement, tagged as the blocking gate or a non-blocking scheduled deep-scan,
# so an orchestrator can route each to the right pipeline stage.
#
# Placement defaults mirror the test-tier model:
#   - the gate `provider`        → `ci-pre-merge`  (blocking) when `placement` absent
#   - a `scheduled[]` entry      → `ci-post-merge` (non-blocking) when `placement` absent
#
# This `placement` axis (WHERE a scanner runs) is ORTHOGONAL to
# `brownfield.scanner_tier` (HOW DEEP the brownfield deterministic-tools battery
# goes — a capability cap). The two are independent and do not conflict; this
# helper never reads `scanner_tier`.
#
# Usage:
#   scanner-placement.sh --config <project-config.yaml> --category <name> [--format tsv|json]
#
# Output (default tsv, one row per scanner):
#   <role>\t<provider>\t<placement>
#     role ∈ { gate, scheduled }
# With --format json: a JSON object {gate:{provider,placement}, scheduled:[{provider,placement}...]}.
#
# Exit codes:
#   0 — resolved (category present with a provider)
#   2 — category not configured (no tools.<category> or no provider) — benign
#   1 — usage error / missing config / yq unavailable

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="scanner-placement.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

GATE_DEFAULT_PLACEMENT="ci-pre-merge"
SCHEDULED_DEFAULT_PLACEMENT="ci-post-merge"

CONFIG=""
CATEGORY=""
FORMAT="tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --config)   [ $# -ge 2 ] || die "--config requires a path"; CONFIG="$2"; shift 2 ;;
    --category) [ $# -ge 2 ] || die "--category requires a value"; CATEGORY="$2"; shift 2 ;;
    --format)   [ $# -ge 2 ] || die "--format requires tsv|json"; FORMAT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ -n "$CONFIG" ]   || die "usage: --config <project-config.yaml> is required"
[ -n "$CATEGORY" ] || die "usage: --category <name> is required"
[ -f "$CONFIG" ]   || die "config not found: $CONFIG"
case "$FORMAT" in tsv|json) ;; *) die "unknown --format: $FORMAT (tsv|json)";; esac
command -v yq >/dev/null 2>&1 || die "yq is required to read tools.<category> placement"

# Parse-validate the config ONCE up front and HARD-FAIL (exit 1) on a malformed
# file. Without this, a YAML parse error is swallowed by the `2>/dev/null ||
# echo ""` fallbacks below and misreported as a benign "category not configured"
# (exit 2) — which would make a corrupted config silently drop the scanner gate
# (a fail-open). After this gate, an empty `// ""` result genuinely means the key
# is absent on a well-formed file, not a parse failure.
if ! yq eval 'true' "$CONFIG" >/dev/null 2>&1; then
  die "config is not valid YAML (yq parse error): $CONFIG"
fi

# Resolve the gate provider. Absent ⇒ category not configured (benign exit 2).
gate_provider=$(yq eval ".tools.\"${CATEGORY}\".provider // \"\"" "$CONFIG" 2>/dev/null || echo "")
gate_provider="$(printf '%s' "$gate_provider" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [ -z "$gate_provider" ] || [ "$gate_provider" = "null" ]; then
  log "tools.${CATEGORY} not configured (no provider) — nothing to place"
  exit 2
fi

# Gate placement (defaults to ci-pre-merge / blocking).
gate_placement=$(yq eval ".tools.\"${CATEGORY}\".placement // \"\"" "$CONFIG" 2>/dev/null || echo "")
gate_placement="$(printf '%s' "$gate_placement" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$gate_placement" ] && [ "$gate_placement" != "null" ] || gate_placement="$GATE_DEFAULT_PLACEMENT"

# Scheduled deep-scan scanners. Each entry is a bare string (provider name) or an
# object {provider, placement?}. Emit one (provider, placement) per entry; an
# entry's placement defaults to ci-post-merge (non-blocking).
scheduled_count=$(yq eval ".tools.\"${CATEGORY}\".scheduled // [] | length" "$CONFIG" 2>/dev/null || echo 0)
case "$scheduled_count" in ''|*[!0-9]*) scheduled_count=0 ;; esac

# Single pass over scheduled[]: build BOTH a newline-delimited tsv body (rows are
# provider<TAB>placement) and the JSON scheduled array in the same loop, reading
# each entry once. This avoids the prior two-parallel-space-joined-lists +
# positional-eval reconstruction, which desynced (silently dropping a scanner /
# mismatching its placement) for any provider value containing whitespace — a
# fail-open class for a security-scanner placement resolver. No word-splitting on
# config-controlled values; no eval.
want_json=0
if [ "$FORMAT" = "json" ]; then
  command -v jq >/dev/null 2>&1 || die "jq is required for --format json"
  want_json=1
fi

sched_tsv=""        # newline-delimited "provider<TAB>placement" rows
sched_json="[]"
i=0
while [ "$i" -lt "$scheduled_count" ]; do
  # tag tells string-vs-object without tripping on a string that looks like a map.
  tag=$(yq eval ".tools.\"${CATEGORY}\".scheduled[$i] | tag" "$CONFIG" 2>/dev/null || echo "")
  if [ "$tag" = "!!str" ]; then
    sp=$(yq eval ".tools.\"${CATEGORY}\".scheduled[$i]" "$CONFIG" 2>/dev/null || echo "")
    spl="$SCHEDULED_DEFAULT_PLACEMENT"
  else
    sp=$(yq eval ".tools.\"${CATEGORY}\".scheduled[$i].provider // \"\"" "$CONFIG" 2>/dev/null || echo "")
    spl=$(yq eval ".tools.\"${CATEGORY}\".scheduled[$i].placement // \"\"" "$CONFIG" 2>/dev/null || echo "")
    spl="$(printf '%s' "$spl" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$spl" ] && [ "$spl" != "null" ] || spl="$SCHEDULED_DEFAULT_PLACEMENT"
  fi
  sp="$(printf '%s' "$sp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -n "$sp" ] && [ "$sp" != "null" ]; then
    # Quote the values into their output sinks at the point of read — they are
    # never re-split. A provider containing whitespace stays one field.
    sched_tsv="${sched_tsv}$(printf 'scheduled\t%s\t%s\n' "$sp" "$spl")
"
    if [ "$want_json" -eq 1 ]; then
      sched_json=$(printf '%s' "$sched_json" | jq --arg p "$sp" --arg pl "$spl" '. + [{provider:$p, placement:$pl}]')
    fi
  fi
  i=$((i + 1))
done

if [ "$want_json" -eq 1 ]; then
  jq -n --arg gp "$gate_provider" --arg gpl "$gate_placement" --argjson sched "$sched_json" \
    '{gate:{provider:$gp, placement:$gpl}, scheduled:$sched}'
  exit 0
fi

# tsv
printf 'gate\t%s\t%s\n' "$gate_provider" "$gate_placement"
# sched_tsv already carries a trailing newline per row; printf %s avoids adding one.
[ -n "$sched_tsv" ] && printf '%s' "$sched_tsv"
exit 0
