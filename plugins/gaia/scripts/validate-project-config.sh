#!/usr/bin/env bash
# validate-project-config.sh — JSON Schema validation for project-config.yaml
#
# Story: E71-S3 (/gaia-config-validate AC5).
# ADR:   ADR-079 (schema discipline), ADR-042 (Scripts-over-LLM), E68-S1
#        (project-config.schema.json).
#
# Behavior:
#   - Converts the YAML input to JSON via `yq` (preferred) or python3+PyYAML.
#   - If `ajv` (ajv-cli) is on PATH, delegates to ajv against
#     plugins/gaia/schemas/project-config.schema.json (canonical engine).
#   - Falls back to a structural jq-based validator that enforces the
#     schema's `required` keys and credential-pattern deny-list when ajv
#     is absent.
#   - On success: prints `PASS: <path>` and exits 0.
#   - On failure: prints one or more violation lines on stderr, each
#     including a JSONPath-style location and a human-readable message,
#     then exits 1.
#
# Usage:
#   validate-project-config.sh <project-config.yaml>
#
# Exit codes:
#   0  valid (schema-conformant)
#   1  invalid (one or more violations reported on stderr)
#   2  usage / I/O error
# =============================================================================

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="validate-project-config.sh"
err()  { printf '%s: %s\n' "$prog" "$*" >&2; }
fail() { printf 'FAIL: %s — %s\n' "${1:-unknown}" "${2:-violation}" >&2; }

if [ "$#" -lt 1 ]; then
  err "usage: $prog <project-config.yaml>"
  exit 2
fi

INPUT="$1"
[ -f "$INPUT" ] || { err "file not found: $INPUT"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../schemas/project-config.schema.json"
[ -f "$SCHEMA" ] || { err "schema file missing: $SCHEMA"; exit 2; }

# ----------------------------------------------------------------------------
# Convert YAML to JSON
# ----------------------------------------------------------------------------
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

if command -v yq >/dev/null 2>&1; then
  # `yq -o=json` works for mikefarah yq; fallback handles kislyuk yq too.
  if yq -o=json '.' "$INPUT" > "$TMP_JSON" 2>/dev/null; then
    :
  elif yq . "$INPUT" > "$TMP_JSON" 2>/dev/null; then
    :
  else
    err "yq failed to convert YAML to JSON"
    exit 2
  fi
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$INPUT" > "$TMP_JSON" <<'PY' || { err "python3 yaml conversion failed"; exit 2; }
import json
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML not installed; cannot convert YAML\n")
    sys.exit(2)
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
json.dump(data, sys.stdout)
PY
else
  err "neither yq nor python3 available; cannot convert YAML"
  exit 2
fi

# ----------------------------------------------------------------------------
# Path A — ajv-cli (canonical)
# ----------------------------------------------------------------------------
if command -v ajv >/dev/null 2>&1; then
  if ajv_out="$(ajv validate -s "$SCHEMA" -d "$TMP_JSON" 2>&1)"; then
    printf 'PASS: %s\n' "$INPUT"
    exit 0
  else
    err "$ajv_out"
    exit 1
  fi
fi

# ----------------------------------------------------------------------------
# Path B — jq-based fallback
# ----------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { err "neither ajv nor jq available; cannot validate"; exit 2; }

violations=0

# Required top-level keys (per project-config.schema.json `required` array).
required_keys="project_root project_path memory_path checkpoint_path installed_path framework_version date"

for key in $required_keys; do
  if ! jq -e --arg k "$key" 'has($k)' "$TMP_JSON" >/dev/null 2>&1; then
    fail "\$.${key}" "required property '${key}' is missing"
    violations=$((violations + 1))
  fi
done

# Credential deny-list — environments.*.credentials.* values must NOT be
# literal credentials. Patterns mirror the schema's credentialEnvVarRef.
deny_pattern='^(sk-|ghp_|gho_|github_pat_|AKIA|xox[abposr]-|glpat-)'
deny_kv='(password|secret|token|credential|PASSWORD|SECRET|TOKEN|CREDENTIAL)[[:space:]]*=[[:space:]]*[^[:space:]]+'
if jq -e '.environments // empty' "$TMP_JSON" >/dev/null 2>&1; then
  while IFS=$'\t' read -r env_name cred_name cred_value; do
    [ -z "$env_name" ] && continue
    if printf '%s' "$cred_value" | grep -qE "$deny_pattern"; then
      fail "\$.environments.${env_name}.credentials.${cred_name}" "credential value matches forbidden literal-secret pattern"
      violations=$((violations + 1))
    fi
    if printf '%s' "$cred_value" | grep -qE "$deny_kv"; then
      fail "\$.environments.${env_name}.credentials.${cred_name}" "credential value contains literal key=value secret"
      violations=$((violations + 1))
    fi
  done < <(jq -r '
    (.environments // {}) | to_entries[] |
    .key as $e |
    (.value.credentials // {}) | to_entries[] |
    [$e, .key, (.value // "")] | @tsv
  ' "$TMP_JSON")
fi

# Compliance regimes enum check.
valid_regimes="gdpr hipaa pci-dss sox ccpa soc2 iso-27001 wcag-2.1-aa wcag-2.1-aaa"
if jq -e '.compliance.regimes // empty' "$TMP_JSON" >/dev/null 2>&1; then
  while read -r regime; do
    [ -z "$regime" ] && continue
    found=0
    for valid in $valid_regimes; do
      [ "$regime" = "$valid" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      fail "\$.compliance.regimes" "regime '${regime}' is not a recognized value (allowed: ${valid_regimes// /, })"
      violations=$((violations + 1))
    fi
  done < <(jq -r '.compliance.regimes[]?' "$TMP_JSON")
fi

if [ "$violations" -gt 0 ]; then
  err "$violations violation(s) found"
  exit 1
fi

printf 'PASS: %s\n' "$INPUT"
exit 0
