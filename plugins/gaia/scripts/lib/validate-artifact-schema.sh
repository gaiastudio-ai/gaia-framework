#!/usr/bin/env bash
# validate-artifact-schema.sh — shared JSON-Schema validator primitive.
#
# The single source of truth for "validate an artifact instance against a JSON
# Schema" used by all artifact-type schema consumers. Follows the
# scripts/lib/heading-present.sh shared-lib precedent (source guard + single
# function, sourceable-not-executable) and the scripts/lib/schema-lookup.sh
# CLI/exit-code-contract precedent.
#
# Validator backend cascade (per feedback_no_per_machine_settings_fixes — the
# helper MUST NOT hard-fail a story's bats on a host that lacks a validator):
#   1. ajv (ajv-cli)            — preferred
#   2. python3 + jsonschema     — fallback
#   3. none present             — graceful SKIP (exit 3), single [SKIP] line
#
# Instance type handling:
#   *.json            — validated directly
#   *.md              — YAML frontmatter (between the first two `---` lines)
#                       extracted, converted to JSON, validated
#   *.yaml / *.yml    — whole YAML document converted to JSON, validated
#
# Exit-code contract:
#   0 — instance VALID against schema
#   1 — instance INVALID (validator findings echoed to stderr)
#   2 — usage error (missing args, unreadable schema/instance, parse failure)
#   3 — SKIP (no JSON-schema validator backend available)
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags. LC_ALL=C. Any temp file uses mktemp and is removed
# on exit via a trap.
#
# Usage:
#   validate-artifact-schema.sh <schema_file> <instance_file>     # CLI
#   source validate-artifact-schema.sh; validate_artifact_schema <schema> <inst>
#
# Sourceable, NOT executable as a side effect when sourced. Idempotent source
# guard prevents redefinition on multiple sources.

if [ "${_GAIA_VALIDATE_ARTIFACT_SCHEMA_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail
LC_ALL=C
export LC_ALL

# _vas_die MSG [CODE] — emit a prefixed error to stderr and return CODE (default 2).
_vas_die() {
  printf 'validate-artifact-schema.sh: %s\n' "$1" >&2
  return "${2:-2}"
}

# _vas_detect_backend — echo "ajv", "python", or "" (none) on stdout.
_vas_detect_backend() {
  if command -v ajv >/dev/null 2>&1; then
    printf 'ajv'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    printf 'python'
    return 0
  fi
  printf ''
  return 0
}

# _vas_instance_to_json INSTANCE_FILE OUT_JSON — materialize a JSON form of the
# instance into OUT_JSON. Returns 2 on parse/extraction failure.
#   - .json  : copy verbatim
#   - .md    : extract YAML frontmatter (first two `---` lines) → JSON
#   - .yaml/.yml : whole document → JSON
# Conversion requires python3 (with PyYAML) for non-JSON inputs.
_vas_instance_to_json() {
  local inst="$1" out="$2"
  case "$inst" in
    *.json)
      cat "$inst" > "$out" 2>/dev/null || return 2
      return 0
      ;;
    *.md)
      # Extract frontmatter block between the first two ^---$ lines.
      local fm
      fm="$(awk '
        BEGIN { depth = 0; in_fm = 0 }
        /^---[[:space:]]*$/ {
          depth++
          if (depth == 1) { in_fm = 1; next }
          if (depth == 2) { exit }
        }
        in_fm { print }
      ' "$inst")"
      [ -n "$fm" ] || return 2
      printf '%s\n' "$fm" | python3 -c 'import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin) or {}, sys.stdout)' > "$out" 2>/dev/null || return 2
      return 0
      ;;
    *.yaml|*.yml)
      python3 -c 'import sys, yaml, json; json.dump(yaml.safe_load(open(sys.argv[1])) or {}, sys.stdout)' "$inst" > "$out" 2>/dev/null || return 2
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

# validate_artifact_schema SCHEMA_FILE INSTANCE_FILE
#   Validate INSTANCE_FILE against SCHEMA_FILE. See exit-code contract above.
validate_artifact_schema() {
  local schema="${1:-}" instance="${2:-}"

  if [ -z "$schema" ] || [ -z "$instance" ]; then
    _vas_die "usage: validate_artifact_schema <schema_file> <instance_file>" 2
    return 2
  fi
  if [ ! -r "$schema" ]; then
    _vas_die "schema file not readable: $schema" 2
    return 2
  fi
  if [ ! -r "$instance" ]; then
    _vas_die "instance file not readable: $instance" 2
    return 2
  fi

  local backend
  backend="$(_vas_detect_backend)"
  if [ -z "$backend" ]; then
    printf '[SKIP] validate-artifact-schema: no JSON-schema validator available (ajv|python3+jsonschema) — structural check skipped\n' >&2
    return 3
  fi

  # YAML/Markdown instances are converted to JSON via python3 + PyYAML. The
  # backend probe above only checks for `jsonschema`, but the conversion of a
  # non-JSON instance ALSO needs the `yaml` module. A host that has jsonschema
  # but not PyYAML (e.g. a stock CI runner) can validate JSON instances yet
  # cannot convert YAML — that is a host-capability gap, not a malformed
  # instance, so it must degrade to SKIP (3) exactly like an absent backend,
  # never a hard rc=2. JSON instances need no conversion tool and are exempt.
  case "$instance" in
    *.yaml|*.yml|*.md)
      if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        printf '[SKIP] validate-artifact-schema: python3 present but PyYAML missing — cannot convert %s for structural check; skipped\n' "$instance" >&2
        return 3
      fi
      ;;
  esac

  # Materialize a JSON form of the instance into a temp file (cleaned on exit).
  local tmp_json
  tmp_json="$(mktemp "${TMPDIR:-/tmp}/vas-XXXXXX")" || { _vas_die "mktemp failed" 2; return 2; }
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_json'" RETURN

  if ! _vas_instance_to_json "$instance" "$tmp_json"; then
    _vas_die "could not extract/convert instance to JSON: $instance" 2
    return 2
  fi

  local rc=0
  case "$backend" in
    ajv)
      # ajv validate -s SCHEMA -d DATA ; exit 0 valid, non-zero invalid.
      if ajv validate -s "$schema" -d "$tmp_json" >&2 2>&1; then
        rc=0
      else
        rc=1
      fi
      ;;
    python)
      python3 - "$schema" "$tmp_json" >&2 <<'PYEOF' || rc=$?
import json
import sys
import jsonschema

schema_path, data_path = sys.argv[1], sys.argv[2]
try:
    with open(schema_path) as fh:
        schema = json.load(fh)
    with open(data_path) as fh:
        data = json.load(fh)
except Exception as exc:  # noqa: BLE001
    sys.stderr.write("validate-artifact-schema: load error: %s\n" % exc)
    sys.exit(2)

validator_cls = jsonschema.validators.validator_for(schema)
try:
    validator_cls.check_schema(schema)
except Exception as exc:  # noqa: BLE001
    sys.stderr.write("validate-artifact-schema: invalid schema: %s\n" % exc)
    sys.exit(2)

errors = sorted(validator_cls(schema).iter_errors(data), key=lambda e: list(e.path))
if errors:
    for err in errors:
        loc = "/".join(str(p) for p in err.path) or "<root>"
        sys.stderr.write("validate-artifact-schema: FINDING at %s: %s\n" % (loc, err.message))
    sys.exit(1)
sys.exit(0)
PYEOF
      ;;
  esac

  return "$rc"
}

_GAIA_VALIDATE_ARTIFACT_SCHEMA_LOADED=1

# CLI dispatch tail: only when executed directly, not when sourced.
# BASH_SOURCE[0] == $0 means the script is the entrypoint.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  validate_artifact_schema "$@"
  exit $?
fi
