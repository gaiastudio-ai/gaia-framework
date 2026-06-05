#!/usr/bin/env bash
# validate-rubric.sh — Validate a single rubric file against rubric.schema.json
#
# Usage:
#   validate-rubric.sh <rubric.json>
#
# Behavior:
#   - If `ajv` (ajv-cli) is available on PATH, delegate to ajv (canonical
#     JSON Schema engine). Otherwise fall back to a structural jq-based
#     validator that enforces the same required fields and enum constraints.
#   - On success: prints `PASS: <path>` and exits 0.
#   - On failure: prints one or more violation lines on stderr (each line
#     names the offending field and the rule it violated) and exits non-zero.
#
# YAML support:
#   Files with a .yaml or .yml extension are accepted. The script converts
#   YAML -> JSON via `yq` (preferred) or `python3` + PyYAML (fallback)
#   before delegating to the canonical JSON validation pipeline. Both
#   formats produce identical PASS/FAIL semantics. Files without a
#   recognized extension are validated as JSON (existing behavior).
#
# Requires: jq. Optionally `ajv` (npm i -g ajv-cli) — preferred when present.
# Optional for YAML input: `yq` OR `python3` with PyYAML.
# =============================================================================

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="validate-rubric.sh"
err()  { printf '%s: %s\n' "$prog" "$*" >&2; }
fail() { printf 'FAIL: %s — %s\n' "${1:-unknown}" "${2:-violation}" >&2; }

if [ "$#" -lt 1 ]; then
  err "usage: $prog <rubric.json>"
  exit 1
fi

RUBRIC="$1"
SCHEMA="${GAIA_RUBRIC_SCHEMA:-$(cd "$(dirname "$0")/../schemas" && pwd)/rubric.schema.json}"

if [ ! -f "$RUBRIC" ]; then
  err "rubric file not found: $RUBRIC"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not found in PATH"
  exit 4
fi

if [ ! -f "$SCHEMA" ]; then
  err "schema not found at $SCHEMA (override via GAIA_RUBRIC_SCHEMA)"
  exit 5
fi

# --- Stage 0: YAML -> JSON conversion ----------------------------------------
# Files with .yaml / .yml extensions are converted to a tempfile JSON before
# the canonical pipeline runs. The original $RUBRIC path is preserved for
# user-facing PASS/FAIL messages — only the schema-validation stages read
# from $RUBRIC_JSON.
RUBRIC_JSON="$RUBRIC"
RUBRIC_TMP=""
case "$RUBRIC" in
  *.yaml|*.yml|*.YAML|*.YML)
    RUBRIC_TMP="$(mktemp -t gaia-rubric-XXXXXX.json)"
    trap 'rm -f "$RUBRIC_TMP"' EXIT
    if command -v yq >/dev/null 2>&1; then
      # `yq` (the Go implementation by mikefarah) reads YAML and emits JSON
      # with `-o json`. The Python `yq` (kislyuk) accepts the same flag.
      if ! yq -o json '.' "$RUBRIC" >"$RUBRIC_TMP" 2>/dev/null; then
        # fall back to `yq eval` for older yq versions
        if ! yq eval -o=json '.' "$RUBRIC" >"$RUBRIC_TMP" 2>/dev/null; then
          fail "$RUBRIC" "yq failed to parse YAML"
          exit 3
        fi
      fi
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
      if ! python3 -c '
import sys, json, yaml
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)
json.dump(data, sys.stdout)
' "$RUBRIC" >"$RUBRIC_TMP" 2>/dev/null; then
        fail "$RUBRIC" "python yaml.safe_load failed to parse YAML"
        exit 3
      fi
    else
      err "YAML rubric input requires either 'yq' or 'python3 + PyYAML' on PATH"
      exit 7
    fi
    RUBRIC_JSON="$RUBRIC_TMP"
    ;;
esac

# --- Stage 1: must be valid JSON --------------------------------------------
if ! jq -e . "$RUBRIC_JSON" >/dev/null 2>&1; then
  fail "$RUBRIC" "file is not valid JSON"
  exit 3
fi

# --- Stage 2: prefer ajv-cli when available --------------------------------
if command -v ajv >/dev/null 2>&1; then
  if ajv validate -s "$SCHEMA" -d "$RUBRIC_JSON" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$RUBRIC"
    exit 0
  fi
  # ajv detected schema violations — re-run with output captured so we can
  # surface the violations on stderr.
  ajv_out=$(ajv validate -s "$SCHEMA" -d "$RUBRIC_JSON" 2>&1 || true)
  fail "$RUBRIC" "schema validation failed"
  printf '%s\n' "$ajv_out" >&2
  exit 6
fi

# --- Stage 3: structural fallback validator (jq) ----------------------------
#
# Enforces the same surface as rubric.schema.json:
#   required top-level: schema_version (pattern N.N), skill (string), severity_rules (array)
#   per-rule required:  id, category, pattern, severity (enum), description
#   severity enum:      Critical | High | Medium | Low | Info
#
# Emits one FAIL line per violation; aggregates and exits non-zero if any.

violations=0

# Required top-level fields
for field in schema_version skill severity_rules; do
  if ! jq -e --arg f "$field" 'has($f)' "$RUBRIC_JSON" >/dev/null 2>&1; then
    fail "$RUBRIC" "missing required top-level field: $field"
    violations=$((violations + 1))
  fi
done

# schema_version pattern
if jq -e 'has("schema_version")' "$RUBRIC_JSON" >/dev/null 2>&1; then
  sv=$(jq -r '.schema_version' "$RUBRIC_JSON")
  if ! printf '%s' "$sv" | grep -Eq '^[0-9]+\.[0-9]+$'; then
    fail "$RUBRIC" "schema_version '$sv' does not match pattern N.N"
    violations=$((violations + 1))
  fi
fi

# skill type
if jq -e 'has("skill")' "$RUBRIC_JSON" >/dev/null 2>&1; then
  if ! jq -e '.skill | type == "string" and length > 0' "$RUBRIC_JSON" >/dev/null 2>&1; then
    fail "$RUBRIC" "field 'skill' must be a non-empty string"
    violations=$((violations + 1))
  fi
fi

# severity_rules type
if jq -e 'has("severity_rules")' "$RUBRIC_JSON" >/dev/null 2>&1; then
  if ! jq -e '.severity_rules | type == "array"' "$RUBRIC_JSON" >/dev/null 2>&1; then
    fail "$RUBRIC" "field 'severity_rules' must be an array"
    violations=$((violations + 1))
  else
    # Per-rule validation
    rule_count=$(jq '.severity_rules | length' "$RUBRIC_JSON")
    i=0
    while [ "$i" -lt "$rule_count" ]; do
      for rf in id category pattern severity description; do
        if ! jq -e --argjson i "$i" --arg f "$rf" '.severity_rules[$i] | has($f)' "$RUBRIC_JSON" >/dev/null 2>&1; then
          fail "$RUBRIC" "severity_rules[$i] missing required field: $rf"
          violations=$((violations + 1))
        fi
      done
      # severity enum
      sev=$(jq -r --argjson i "$i" '.severity_rules[$i].severity // ""' "$RUBRIC_JSON")
      case "$sev" in
        Critical|High|Medium|Low|Info) : ;;
        *)
          fail "$RUBRIC" "severity_rules[$i].severity '$sev' not in enum (Critical|High|Medium|Low|Info)"
          violations=$((violations + 1))
          ;;
      esac
      # id non-empty
      if ! jq -e --argjson i "$i" '.severity_rules[$i].id | type == "string" and length > 0' "$RUBRIC_JSON" >/dev/null 2>&1; then
        if jq -e --argjson i "$i" '.severity_rules[$i] | has("id")' "$RUBRIC_JSON" >/dev/null 2>&1; then
          fail "$RUBRIC" "severity_rules[$i].id must be a non-empty string"
          violations=$((violations + 1))
        fi
      fi
      i=$((i + 1))
    done
  fi
fi

if [ "$violations" -gt 0 ]; then
  fail "$RUBRIC" "$violations violation(s) total"
  exit 6
fi

printf 'PASS: %s\n' "$RUBRIC"
exit 0
