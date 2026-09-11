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

# ---------------------------------------------------------------------------
# _post_validate_parallel_execution — cross-field concurrency-budget check
#
# JSON Schema draft-07 cannot express an arithmetic relation between two
# sibling integers, so the headroom rule lives here:
#   teammate_dispatch_ceiling >= max_parallel_dev_slots + PE_HEADROOM
#
# Reads the ALREADY-CONVERTED JSON, never the raw YAML. yq/python3 have
# normalised flow mappings, comments, quoting and signed integers into
# canonical JSON, so a section written in an unusual-but-valid shape cannot
# read as "absent" and silently skip the check.
#
# Fails CLOSED: if neither jq nor python3 can read the document the check
# reports a violation rather than returning 0. (The YAML->JSON conversion
# above already hard-requires yq or python3, so this cannot normally fire.)
#
# Args: $1 = path to the converted JSON file
# Returns: 0 if valid or the section is absent; 1 if violations found.
# ---------------------------------------------------------------------------
_post_validate_parallel_execution() {
  local json_file="$1"
  local PE_HEADROOM=4
  local state="" probe="" reader=""

  if command -v jq >/dev/null 2>&1; then
    state="$(jq -r '.parallel_execution
      | if . == null then "ABSENT" elif type != "object" then "NOTOBJ" else "OBJ" end' \
      "$json_file" 2>/dev/null)" || state=""
    # Commit to jq only if it produced a RECOGNISED verdict. Checking mere
    # non-emptiness would trust a jq that exits 0 while emitting garbage: the
    # garbage falls past the ABSENT/NOTOBJ arms, the probe yields unparseable
    # lines, and the defaults survive to satisfy the headroom rule — an
    # under-provisioned config would then PASS.
    case "$state" in
      ABSENT|NOTOBJ|OBJ) reader=jq ;;
      *) state="" ;;
    esac
  fi
  if [ -z "$reader" ] && command -v python3 >/dev/null 2>&1; then
    reader=python3
    state="$(python3 - "$json_file" <<'PYPROBE_A' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
s = d.get("parallel_execution", None)
if "parallel_execution" not in d or s is None:
    print("ABSENT")
elif not isinstance(s, dict):
    print("NOTOBJ")
else:
    print("OBJ")
PYPROBE_A
)" || state=""
  fi

  case "$state" in
    ABSENT|NOTOBJ|OBJ) : ;;
    *) state="" ;;
  esac

  if [ -z "$reader" ] || [ -z "$state" ]; then
    fail "\$.parallel_execution" \
      "cannot verify the concurrency budget — install jq or python3"
    return 1
  fi

  case "$state" in
    ABSENT) return 0 ;;
    NOTOBJ)
      fail "\$.parallel_execution" "must be an object"
      return 1
      ;;
  esac

  # Per-key probe: one tab-separated line per key carrying name, type and
  # value. Type-tagged and self-delimiting so a value containing a space or
  # newline cannot bleed into the next field; has() rather than // so an
  # explicit null reads as present-but-invalid, never as absent.
  if [ "$reader" = jq ]; then
    probe="$(jq -r '.parallel_execution as $p
      | (["slots",   (if ($p|has("max_parallel_dev_slots"))    then ($p.max_parallel_dev_slots|type)    else "absent" end), ($p.max_parallel_dev_slots|tostring)]    | @tsv),
        (["ceiling", (if ($p|has("teammate_dispatch_ceiling")) then ($p.teammate_dispatch_ceiling|type) else "absent" end), ($p.teammate_dispatch_ceiling|tostring)] | @tsv)' \
      "$json_file" 2>/dev/null)" || probe=""
  else
    probe="$(python3 - "$json_file" <<'PYPROBE_B' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
p = d.get("parallel_execution", {})
def tag(v):
    if isinstance(v, bool):  return "boolean"
    if isinstance(v, int):   return "number"
    if isinstance(v, float): return "number"
    if isinstance(v, str):   return "string"
    if v is None:            return "null"
    if isinstance(v, list):  return "array"
    return "object"
for label, key in (("slots", "max_parallel_dev_slots"),
                   ("ceiling", "teammate_dispatch_ceiling")):
    if key not in p:
        print("%s\tabsent\tnull" % label)
    else:
        v = p[key]
        if v is True: sv = "true"
        elif v is False: sv = "false"
        elif v is None: sv = "null"
        else: sv = str(v)
        print("%s\t%s\t%s" % (label, tag(v), sv))
PYPROBE_B
)" || probe=""
  fi

  if [ -z "$probe" ]; then
    fail "\$.parallel_execution" "cannot read the concurrency budget values"
    return 1
  fi

  local slots=8 ceiling=12 violations=0 seen=0 unknown=0
  local label vtype vval key tab
  tab="$(printf '\t')"
  while IFS="$tab" read -r label vtype vval; do
    [ -z "$label" ] && continue
    case "$label" in
      slots)   key="max_parallel_dev_slots" ;;
      ceiling) key="teammate_dispatch_ceiling" ;;
      # An unrecognised label means the probe emitted something we did not ask
      # for. Skipping it silently would let a reader inject extra lines while
      # the two expected ones still arrive, so count it and refuse below.
      *)       unknown=$((unknown + 1)); continue ;;
    esac
    case "$vtype" in
      absent|number|string|null|boolean|array|object) ;;
      *) unknown=$((unknown + 1)); continue ;;
    esac
    seen=$((seen + 1))
    [ "$vtype" = "absent" ] && continue
    if [ "$vtype" != "number" ]; then
      fail "\$.parallel_execution.${key}" "must be an integer; got ${vtype}"
      violations=$((violations + 1))
      continue
    fi
    case "$vval" in
      # Scientific / exponent notation FIRST, and independently of the reader's
      # spelling: the same out-of-range value is rendered as a digit string by
      # one JSON stack and as 1e+20 / 1.0E+20 by another, so a digit-only test
      # classifies it differently per platform. Only a huge or fractional
      # magnitude is ever written this way, and neither is a usable budget.
      *[eE]+[0-9]*|*[eE]-[0-9]*|*[eE][0-9]*)
        fail "\$.parallel_execution.${key}" \
          "must be between 1 and 64; got ${vval}"
        violations=$((violations + 1))
        continue
        ;;
      ''|*[!0-9]*)
        fail "\$.parallel_execution.${key}" \
          "must be a non-negative integer; got ${vval}"
        violations=$((violations + 1))
        continue
        ;;
      # Bound the DIGIT COUNT before any `[` arithmetic below. A value beyond
      # the shell's integer range makes the headroom test abort with "integer
      # expression expected" and evaluate FALSE, so the function falls through
      # to `return 0` and the degraded path prints PASS — green validation for a
      # config that bricks dispatch at runtime. The degraded path deliberately
      # skips the schema's `maximum`, so this range check cannot be delegated
      # to the schema engine.
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
        fail "\$.parallel_execution.${key}" \
          "must be between 1 and 64; got ${vval}"
        violations=$((violations + 1))
        continue
        ;;
    esac
    # Explicit range check, for the same reason: the degraded path never sees
    # the schema's minimum/maximum.
    if [ "$vval" -lt 1 ] || [ "$vval" -gt 64 ]; then
      fail "\$.parallel_execution.${key}" \
        "must be between 1 and 64; got ${vval}"
      violations=$((violations + 1))
      continue
    fi
    if [ "$label" = slots ]; then slots="$vval"; else ceiling="$vval"; fi
  done <<PROBE_EOF
$probe
PROBE_EOF

  [ "$violations" -gt 0 ] && return 1

  # Both keys must have been reported with a recognised type tag. Anything less
  # means the probe output was not trustworthy, and defaulting past it would let
  # an under-provisioned budget through.
  if [ "$seen" -ne 2 ] || [ "$unknown" -ne 0 ]; then
    fail "\$.parallel_execution" "cannot read the concurrency budget values"
    return 1
  fi

  if [ "$ceiling" -lt $((slots + PE_HEADROOM)) ]; then
    fail "\$.parallel_execution.teammate_dispatch_ceiling" \
      "must be at least max_parallel_dev_slots + ${PE_HEADROOM} (headroom for gate agents); got ${ceiling} with max_parallel_dev_slots ${slots}"
    return 1
  fi
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
    _post_validate_parallel_execution "$TMP_JSON" || exit 1
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
    _post_validate_parallel_execution "$TMP_JSON" || exit 1
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
_post_validate_parallel_execution "$TMP_JSON" || exit 1

# Emit the DEGRADED marker so downstream consumers (CI, /gaia-config-validate
# skill) can distinguish a full schema-engine PASS from a structural-only PASS.
printf 'PASS (DEGRADED): %s\n' "$INPUT"
exit 0
