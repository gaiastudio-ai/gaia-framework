#!/usr/bin/env bash
# validate-project-config.sh — JSON Schema validation for project-config.yaml
#
# Behavior:
#   - Converts the YAML input to JSON via `yq` (preferred) or python3+PyYAML.
#   - Backend selection (replaces the old "PASS+silent" fallback):
#       1. `ajv` / `ajv-cli` on PATH                — canonical full-schema engine.
#       2. python3 + `jsonschema` module available  — canonical fallback engine
#          (covers enum / additionalProperties / type / pattern equivalently
#          to ajv; preferred over the jq-structural path when present).
#       3. `jq`-only structural check               — degraded mode. Validates
#          required-keys + credential deny-list + compliance.regimes enum.
#          CANNOT validate enum / additionalProperties / type / pattern.
#          When this path runs, the script prints a prominent stderr WARNING
#          and emits `PASS (DEGRADED): <path>` on success (still exit 0 — the
#          structural checks really did pass; downstream gates that need full
#          coverage should look for the DEGRADED marker).
#   - On full-engine success: prints `PASS: <path>` and exits 0.
#   - On structural-only success: prints `PASS (DEGRADED): <path>` and exits 0,
#     having already printed a stderr WARNING naming exactly which checks
#     were skipped + recommending `ajv-cli` or `pip install jsonschema`.
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

# ---------------------------------------------------------------------------
# _post_validate_test_policy_refs — cross-property referential-integrity check
#
# Validates that every stack name in test_policy.triggers.<t>.include_stacks
# and test_policy.triggers.<t>.exclude_stacks references a stack declared in
# stacks[].name. Called on ALL engine success paths before exit 0.
#
# Args: $1 = path to the converted JSON file
# Returns: 0 if valid or no test_policy.triggers present; 1 if violations found.
# ---------------------------------------------------------------------------
_post_validate_test_policy_refs() {
  local json_file="$1"

  # Guard: jq required for this cross-property check
  if ! command -v jq >/dev/null 2>&1; then
    err "WARNING: jq not available — skipping test_policy stack-name referential check"
    return 0
  fi

  # No-op when test_policy.triggers is absent
  if ! jq -e '.test_policy.triggers // empty' "$json_file" >/dev/null 2>&1; then
    return 0
  fi

  local violations=0
  local declared_stacks
  declared_stacks="$(jq -r '[.stacks[]?.name // empty] | join(",")' "$json_file" 2>/dev/null)"

  local trigger field count i stack_name
  for trigger in pr push schedule; do
    for field in include_stacks exclude_stacks; do
      count="$(jq -r ".test_policy.triggers.${trigger}.${field} // [] | length" "$json_file" 2>/dev/null)"
      [ "$count" = "0" ] && continue
      i=0
      while [ "$i" -lt "$count" ]; do
        stack_name="$(jq -r ".test_policy.triggers.${trigger}.${field}[$i]" "$json_file")"
        if ! printf '%s' ",$declared_stacks," | grep -qF ",$stack_name,"; then
          fail "\$.test_policy.triggers.${trigger}.${field}[$i]" \
            "stack '${stack_name}' is not declared in stacks[]; declared: ${declared_stacks//,/, }"
          violations=$((violations + 1))
        fi
        i=$((i + 1))
      done
    done
  done

  [ "$violations" -gt 0 ] && return 1
  return 0
}

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
# Path A — ajv-cli (canonical full-schema engine)
# ----------------------------------------------------------------------------
if command -v ajv >/dev/null 2>&1; then
  if ajv_out="$(ajv validate -s "$SCHEMA" -d "$TMP_JSON" 2>&1)"; then
    _post_validate_test_policy_refs "$TMP_JSON" || exit 1
    printf 'PASS: %s\n' "$INPUT"
    exit 0
  else
    err "$ajv_out"
    exit 1
  fi
fi

# ----------------------------------------------------------------------------
# Path A2 — python3 + jsonschema (canonical fallback engine)
#
# Equivalent coverage to ajv for the checks the structural fallback misses:
# enum, additionalProperties, type, pattern. Preferred over the jq path
# when present — closes the silent false-PASS surfaced by the fallback engine.
# ----------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
  if py_out="$(python3 - "$SCHEMA" "$TMP_JSON" 2>&1 <<'PY'
import json, sys
import jsonschema
schema_path, data_path = sys.argv[1], sys.argv[2]
with open(schema_path) as f:
    schema = json.load(f)
with open(data_path) as f:
    data = json.load(f)
cls = jsonschema.validators.validator_for(schema)
cls.check_schema(schema)
validator = cls(schema)
errors = list(validator.iter_errors(data))
if not errors:
    sys.exit(0)
for e in errors:
    # Build a JSONPath-style location. For root-level violations (e.g. a
    # missing required property at the top), the absolute_path is empty —
    # surface the missing-property name in the path so downstream consumers
    # (the JSONPath-presence grep at tests/skills/gaia-config-validate-schema.bats)
    # can locate it without parsing the prose message body.
    path_parts = list(map(str, e.absolute_path))
    if e.validator == "required":
        missing = e.message.split("'")[1] if "'" in e.message else ""
        if missing:
            path_parts.append(missing)
    loc = "$." + ".".join(path_parts) if path_parts else "$."
    sys.stderr.write("FAIL: {} — {}\n".format(loc, e.message))
sys.exit(1)
PY
)"; then
    _post_validate_test_policy_refs "$TMP_JSON" || exit 1
    printf 'PASS: %s\n' "$INPUT"
    exit 0
  else
    # Stderr already carries the FAIL: lines from the python block.
    [ -n "$py_out" ] && printf '%s\n' "$py_out" >&2
    exit 1
  fi
fi

# ----------------------------------------------------------------------------
# Path B — jq-based degraded fallback
#
# Last-resort structural check. Cannot validate enum / additionalProperties
# / type / pattern. Emits a prominent WARNING + `PASS (DEGRADED):` marker
# so downstream consumers can detect the reduced coverage.
# ----------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { err "neither ajv, python3+jsonschema, nor jq available; cannot validate"; exit 2; }

err "WARNING: neither ajv nor python3+jsonschema available — running DEGRADED structural validation only."
err "WARNING: the following schema checks are SKIPPED in this mode: enum, additionalProperties, type, pattern."
err "WARNING: install one of: 'npm i -g ajv-cli' or 'pip install jsonschema' to get full-schema validation."

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

_post_validate_test_policy_refs "$TMP_JSON" || exit 1

# Emit the DEGRADED marker so downstream consumers (CI, /gaia-config-validate
# skill) can distinguish a full schema-engine PASS from a structural-only PASS.
printf 'PASS (DEGRADED): %s\n' "$INPUT"
exit 0
