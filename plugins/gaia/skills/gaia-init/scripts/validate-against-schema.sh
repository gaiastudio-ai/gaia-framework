#!/usr/bin/env bash
# validate-against-schema.sh — validate a generated project-config.yaml
# against project-config.schema.json. Deterministic.
#
# Validators tried, in order:
#   1. ajv-cli (npx ajv-cli or system ajv)
#   2. python3 with the `jsonschema` package
# If neither is available, emits an advisory on stderr and exits 0 — the
# greenfield init must not hard-fail on a missing dev dependency.
#
# Usage:
#   validate-against-schema.sh <config.yaml> [--schema <schema.json>]
#
# Exit codes:
#   0  Validation passed (or skipped because no validator available).
#   1  Validation failed.
#   2  Usage error.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-init/validate-against-schema.sh"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
default_schema="$SELF_DIR/../../../schemas/project-config.schema.json"

cfg=""
schema="$default_schema"

while [ $# -gt 0 ]; do
  case "$1" in
    --schema)
      [ $# -ge 2 ] || { printf '%s: --schema requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      schema="$2"; shift 2 ;;
    --help|-h) sed -n '1,20p' "$0"; exit 0 ;;
    -*) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
    *) cfg="$1"; shift ;;
  esac
done

[ -n "$cfg" ] || { printf '%s: missing positional <config.yaml>\n' "$SCRIPT_NAME" >&2; exit 2; }
[ -r "$cfg" ] || { printf '%s: cannot read %s\n' "$SCRIPT_NAME" "$cfg" >&2; exit 2; }
[ -r "$schema" ] || {
  printf '%s: schema not readable: %s — skipping validation\n' "$SCRIPT_NAME" "$schema" >&2
  exit 0
}

# Convert YAML → JSON for ajv. Use python3.
#
# Pass `default=str` to json.dumps so PyYAML-parsed datetime.date /
# datetime.datetime objects (e.g. an unquoted top-level `date: 2026-05-21`
# line emitted by generate-config.sh) are serialized as ISO-8601 strings
# instead of crashing the whole validator with
# `TypeError: Object of type date is not JSON serializable`. Without this,
# every freshly /gaia-init'd config with a bare date value would trip the
# error and the SKILL.md delete-on-validation-failure contract would erase
# real configs on tooling crashes — not actual schema violations.
yaml_to_json() {
  python3 -c '
import sys, json
try:
    import yaml
except ImportError:
    sys.exit(2)
print(json.dumps(yaml.safe_load(sys.stdin), default=str))
' < "$1"
}

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  json_tmp="$(mktemp -t gaia-init-cfg.XXXXXX).json"
  trap 'rm -f -- "$json_tmp" 2>/dev/null || true' EXIT
  yaml_to_json "$cfg" > "$json_tmp" || {
    printf '%s: failed to convert YAML to JSON\n' "$SCRIPT_NAME" >&2
    exit 1
  }

  # Try jsonschema (Python) first — typically available in dev environments.
  if python3 -c 'import jsonschema' 2>/dev/null; then
    python3 - "$json_tmp" "$schema" <<'PYEOF'
import json, sys, jsonschema
data = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
try:
    jsonschema.validate(data, schema)
except jsonschema.ValidationError as e:
    print(f"validation failed: {e.message} at path: {list(e.path)}", file=sys.stderr)
    sys.exit(1)
PYEOF
    exit $?
  fi

  # Fall back to ajv-cli.
  # Pass --strict=false so ajv accepts the framework's custom
  # x-no-auto-hydration annotation declared on schema properties. Without
  # this flag, ajv strict mode fails the whole schema with "unknown keyword:
  # x-no-auto-hydration" — and per SKILL.md the failure handler would delete
  # a valid config. The Python `jsonschema` validator does not have an
  # equivalent strict mode and accepts the annotation natively.
  if command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$schema" -d "$json_tmp" --strict=false >/dev/null
    exit $?
  fi
  if command -v npx >/dev/null 2>&1; then
    npx --yes ajv-cli validate -s "$schema" -d "$json_tmp" --strict=false >/dev/null && exit 0 || exit 1
  fi
fi

printf '%s: no JSON-schema validator available (jsonschema, ajv); skipping schema validation\n' "$SCRIPT_NAME" >&2
exit 0
