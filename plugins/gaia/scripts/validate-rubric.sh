#!/usr/bin/env bash
# validate-rubric.sh — Validate a single rubric file against rubric.schema.json
#
# Story: E68-S2 — backs the /gaia-validate-rubric skill (AC6).
# ADR:   ADR-079 (Layered Rubric Loading), ADR-042 (Scripts-over-LLM).
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
# Requires: jq. Optionally `ajv` (npm i -g ajv-cli) — preferred when present.
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

# --- Stage 1: must be valid JSON --------------------------------------------
if ! jq -e . "$RUBRIC" >/dev/null 2>&1; then
  fail "$RUBRIC" "file is not valid JSON"
  exit 3
fi

# --- Stage 2: prefer ajv-cli when available --------------------------------
if command -v ajv >/dev/null 2>&1; then
  if ajv validate -s "$SCHEMA" -d "$RUBRIC" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$RUBRIC"
    exit 0
  fi
  # ajv detected schema violations — re-run with output captured so we can
  # surface the violations on stderr.
  ajv_out=$(ajv validate -s "$SCHEMA" -d "$RUBRIC" 2>&1 || true)
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
  if ! jq -e --arg f "$field" 'has($f)' "$RUBRIC" >/dev/null 2>&1; then
    fail "$RUBRIC" "missing required top-level field: $field"
    violations=$((violations + 1))
  fi
done

# schema_version pattern
if jq -e 'has("schema_version")' "$RUBRIC" >/dev/null 2>&1; then
  sv=$(jq -r '.schema_version' "$RUBRIC")
  if ! printf '%s' "$sv" | grep -Eq '^[0-9]+\.[0-9]+$'; then
    fail "$RUBRIC" "schema_version '$sv' does not match pattern N.N"
    violations=$((violations + 1))
  fi
fi

# skill type
if jq -e 'has("skill")' "$RUBRIC" >/dev/null 2>&1; then
  if ! jq -e '.skill | type == "string" and length > 0' "$RUBRIC" >/dev/null 2>&1; then
    fail "$RUBRIC" "field 'skill' must be a non-empty string"
    violations=$((violations + 1))
  fi
fi

# severity_rules type
if jq -e 'has("severity_rules")' "$RUBRIC" >/dev/null 2>&1; then
  if ! jq -e '.severity_rules | type == "array"' "$RUBRIC" >/dev/null 2>&1; then
    fail "$RUBRIC" "field 'severity_rules' must be an array"
    violations=$((violations + 1))
  else
    # Per-rule validation
    rule_count=$(jq '.severity_rules | length' "$RUBRIC")
    i=0
    while [ "$i" -lt "$rule_count" ]; do
      for rf in id category pattern severity description; do
        if ! jq -e --argjson i "$i" --arg f "$rf" '.severity_rules[$i] | has($f)' "$RUBRIC" >/dev/null 2>&1; then
          fail "$RUBRIC" "severity_rules[$i] missing required field: $rf"
          violations=$((violations + 1))
        fi
      done
      # severity enum
      sev=$(jq -r --argjson i "$i" '.severity_rules[$i].severity // ""' "$RUBRIC")
      case "$sev" in
        Critical|High|Medium|Low|Info) : ;;
        *)
          fail "$RUBRIC" "severity_rules[$i].severity '$sev' not in enum (Critical|High|Medium|Low|Info)"
          violations=$((violations + 1))
          ;;
      esac
      # id non-empty
      if ! jq -e --argjson i "$i" '.severity_rules[$i].id | type == "string" and length > 0' "$RUBRIC" >/dev/null 2>&1; then
        if jq -e --argjson i "$i" '.severity_rules[$i] | has("id")' "$RUBRIC" >/dev/null 2>&1; then
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
